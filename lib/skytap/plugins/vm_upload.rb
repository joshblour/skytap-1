module Skytap
  module Commands
    class Upload < Skytap::Commands::Base
      MAX_CONCURRENCY = 5
      CHECK_PERIOD = 15
      AT_CAPACITY_RETRY_PERIOD = 15.minutes.to_i

      # What was passed in, either a reference to a VM directory or a VM archive file.
      attr_reader :vms
      attr_reader :uploaders

      self.parent = Vm
      self.plugin = true
      self.ask_interactively = true

      def self.description
          <<-"EOF"
Upload one or more VM directories or VM archive files to Skytap

The file must be one of the following archive types:
  .tgz .tar.gz .tbz .tbz2 .tar.bz2 .tar .ova .ovf .7z .7z.001 .zip

The contents of the archive file must contain a VMware image in either
VMX/VMDK or OVF/VMDK format.

See the following page for more information:
https://cloud.skytap.com/docs/index.php/Importing_and_Exporting_Virtual_Machines#How_to_Import_VMs_in_to_Skytap
          EOF
      end

      def expected_args
        ActiveSupport::OrderedHash[
          'file*', 'One or more directories or VM archive files to upload'
        ]
      end

      def parameters
        # Only display import parameters if a single VM will be uploaded.
        if args.length == 1
          Import.subcommands.detect{|s| s.command_name == 'create'}.spec['params']
        else
          {}
        end
      end

      def run!
        @vms = args
        @uploaders = []
        params = composed_params

        until finished?
          if vms.present? && slots_available?
            kick_off_import(vms.shift, params.dup)
          else
            sleep CHECK_PERIOD
            print_status
            invoker.try(:call, self)

            signal_available if signal_stale? || (concurrency_at_overage && concurrency < concurrency_at_overage)
          end
        end

        signal_available
        print_summary
        return response
      end

      def concurrency_at_overage
        @concurrency_at_overage
      end

      def kick_off_import(vm, params)
        begin
          # Create import job on server in main thread.
          job = VmImportJob.new(logger, username, api_token, vm, params)

          # If successful, start FTP upload and subsequent steps in new thread.
          up = Uploader.new(job)
          uploaders << up
          log_line(up.status_line)
        rescue NoSlotsAvailable => ex
          vms << vm
          signal_full
          log_line(("#{vm}: " << no_capacity_message).color(:yellow))
        rescue Exception => ex
          up = DeadUploader.new(vm, ex)
          uploaders << up
          log_line(up.status_line)
        end
      end

      def no_capacity_message
        m = AT_CAPACITY_RETRY_PERIOD / 60
        "No import capacity is currently available on Skytap. Will retry in #{m} minutes".tap do |msg|
          if active_uploaders.present?
            msg << ' or when another import completes.'
          else
            msg << '.'
          end
        end
      end

      def log_line(msg, include_separator=true)
        line = msg
        line += "\n---" if include_separator
        logger.info line
      end

      def print_status
        if (stat = status_lines).present?
          log_line(stat)
        end
      end

      def print_summary
        unless response.error?
          logger.info "#{'Summary'.bright}\n#{response.payload}"
        end
      end

      def finished?
        vms.empty? && concurrency == 0
      end

      def slots_available?
        estimated_available_slots > 0
      end

      def signal_stale?
        full? && Time.now - @full_at > AT_CAPACITY_RETRY_PERIOD
      end

      def seconds_until_retry
        return unless full?
        [0, AT_CAPACITY_RETRY_PERIOD - (Time.now - @full_at)].max
      end

      def estimated_available_slots
        if full?
          0
        else
          MAX_CONCURRENCY - concurrency
        end
      end

      def signal_full
        @concurrency_at_overage = concurrency
        @full_at = Time.now
      end

      def signal_available
        @concurrency_at_overage = @full_at = nil
      end

      def full?
        @full_at
      end

      def status_lines
        active_uploaders.collect(&:status_line).join("\n")
      end

      def active_uploaders
        uploaders.reject(&:finished?)
      end


      private

      def concurrency
        uploaders.select(&:alive?).length
      end

      def response
        @_response ||= begin
                         error = !uploaders.any?(&:success?)
                         Response.build(uploaders.collect(&:status_line).join("\n"), error)
                       end
      end
    end

    class NoSlotsAvailable < RuntimeError
    end

    class VmImportJob
      attr_reader :logger, :import_path, :params, :vm, :username, :api_token, :other_credentials

      def initialize(logger, username, api_token, vm, params = {})
        @logger = logger
        @username = username
        @api_token = api_token
        @vm = File.expand_path(vm)
        @params = params
        @vm_filename = File.basename(@vm)

        create_on_server
      end

      def create_on_server
        setup
        begin
          import
        rescue Exception => ex
          if at_capacity?(ex)
            raise NoSlotsAvailable.new
          else
            raise
          end
        end
      end

      def at_capacity?(exception)
        exception.message.include?('You cannot import a VM because you may not have more than')
      end

      def setup
        if File.directory?(vm)
          @import_path = File.join(vm, 'vm.7z')
          unless File.exist?(@import_path)
            raise Skytap::Error.new("Directory provided (#{vm}) but no vm.7z file found inside")
          end

          metadata_file = File.join(vm, 'vm.yaml')
          if File.exist?(metadata_file)
            #TODO:NLA If hostname is present, truncate it to 15 chars. This is the max import hostname length.
            extra_params = YAML.load_file(metadata_file)
          end

        elsif File.exist?(vm)
          @import_path = vm
        else
          raise Skytap::Error.new("File does not exist: #{vm}")
        end

        @params = (extra_params || {}).merge(params)
        if @params['credentials'].is_a?(Array)
          cred = @params['credentials'].shift
          @other_credentials = @params['credentials']
          @params['credentials'] = cred
        end
      end

      def import(force_reload=false)
        return @import unless @import.nil? || force_reload

        if @import
          id = @import['id']
          @import = Skytap.invoke!(username, api_token, "import show #{id}")
        else
          @import = Skytap.invoke!(username, api_token, 'import create', {}, :param => params)
        end
      end
    end

    class DeadUploader
      def initialize(vm, exception)
        @vm = vm
        @exception = exception
      end

      def finished?
        true
      end

      def alive?
        false
      end

      def success?
        false
      end

      def status_line
        "VM #{@vm}: Error: #{@exception}"
      end
    end

    class Uploader < Thread
      MAX_WAIT = 2.days
      IMPORT_CHECK_PERIOD = 5

      attr_reader :job, :bytes_transferred, :bytes_total, :result
      delegate :logger, :import, :import_path, :params, :vm, :username, :api_token, :other_credentials, :to => :job

      def initialize(job)
        @job = job
        @bytes_transferred = @bytes_total = 0
        path, basename = File.split(File.expand_path(import_path))
        @vm_filename = File.join(File.basename(path), basename) # E.g., "myfolder/vm.7z"
        @vm_filename << " (#{params['template_name']})" if params['template_name']

        super do
          begin
            run
          rescue Exception => ex
            @result = Response.build(ex)
          end
        end
      end

      def run
        ftp_upload
        Skytap.invoke!(username, api_token, "import update #{id}", {}, :param => {'status' => 'processing'})
        wait_until_ready
        add_other_credentials
        Skytap.invoke!(username, api_token, "import destroy #{id}")
        @result = Response.build(import['template_url'])
      end


      def finished?
        !!@finished
      end

      def success?
        result && !result.error?
      end

      def status_line
        "#{@vm_filename}: #{status}"
      end

      def status
        if result.try(:error?)
          @finished = true
          "Error: #{result.error_message}".color(:red).bright
        elsif result
          @finished = true
          "Uploaded to: #{result.payload}".color(:green).bright
        elsif bytes_transferred == 0
          'Starting'.color(:yellow)
        elsif bytes_transferred >= bytes_total
          'Importing'.color(:yellow)
        else
          gb_transferred = bytes_transferred / 1.gigabyte.to_f
          gb_total = bytes_total / 1.gigabyte.to_f
          percent_done = 100.0 * bytes_transferred / bytes_total
          "Uploading #{'%0.1f' % percent_done}% (#{'%0.1f' % gb_transferred} / #{'%0.1f' % gb_total} GB)".color(:yellow)
        end
      end


      private


      def ftp_upload
        local_path = import_path
        # FTP URL looks like: ftp://67x8meqCr:a3hnalxZLg@ftp.cloud.skytap.com/upload/
        remote_dir = import['ftp_url'] =~ %r{@.*?(/.+)$} && $1

        ftp = Net::FTP.new(import['ftp_host'])
        ftp.login(import['ftp_user_name'], import['ftp_password'])
        ftp.chdir(remote_dir)
        @bytes_total = File.size(local_path)
        ftp.putbinaryfile(local_path) do |data|
          @bytes_transferred += data.size
        end
        ftp.close
      end

      def add_other_credentials
        template_id = import['template_url'] =~ /\/templates\/(\d+)/ && $1
        template = Skytap.invoke!(username, api_token, "template show #{template_id}")
        vm_id = template['vms'].first['id']
        (other_credentials || []).each do |cred|
          Skytap.invoke!(username, api_token, "credential create /vms/#{vm_id}", {}, :param => {'vm_id' => vm_id, 'text' => cred})
        end
      end

      def id
        import['id']
      end

      def wait_until_ready
        cutoff = MAX_WAIT.from_now
        finished = nil

        while Time.now < cutoff
          case import(true)['status']
          when 'processing'
          when 'complete'
            finished = true
            break
          else
            #TODO:NLA Check that this actually is displayed to the user, for both normal `vm upload` and for `vm copytoregion` too.
            raise Skytap::Error.new "Import job had unexpected state of #{import['status'].inspect}"
          end

          sleep IMPORT_CHECK_PERIOD 
        end

        unless finished
          raise Skytap::Error.new 'Timed out waiting for import job to complete'
        end
      end
    end

    #TODO:NLA Probably should pull this into a method that also sets e.g., Upload.parent = Vm.
    Vm.subcommands << Upload
  end
end
