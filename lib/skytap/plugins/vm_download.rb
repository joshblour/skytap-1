module Skytap
  module Commands
    class Download < Skytap::Commands::Base
      MAX_CONCURRENCY = 5
      CHECK_PERIOD = 15
      AT_CAPACITY_RETRY_PERIOD = 15.minutes.to_i

      attr_reader :vm_ids
      attr_reader :downloaders

      self.parent = Vm
      self.plugin = true

      def self.description
        <<-"EOF"
Download the specified Skytap template VM to the local filesystem

The VM must belong to a template, not a configuration. The template cannot be
public.
        EOF
      end

      def expected_args
        ActiveSupport::OrderedHash[
          'vm_id*', 'One or more IDs of template VMs to donwload'
        ]
      end

      def expected_options
        ActiveSupport::OrderedHash[
          :dir, {:flag_arg => 'DIR', :desc => 'Directory into which to download VM and metadata'},
        ]
      end

      attr_reader :downloaders

      def run!
        @vm_ids = args.collect {|a| find_id(a)}
        @downloaders = []

        until finished?
          if vm_ids.present? && slots_available?
            kick_off_export(vm_ids.shift)
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

      def kick_off_export(vm_id)
        begin
          # Create export job on server in main thread.
          job = VmExportJob.new(logger, username, api_token, vm_id, command_options[:dir])

          # If successful, start FTP download and subsequent steps in new thread.
          dl = Downloader.new(job)
          downloaders << dl
          log_line(dl.status_line)
        rescue NoSlotsAvailable => ex
          vm_ids << vm_id
          signal_full
          log_line(("VM #{vm_id}: " << no_capacity_message).color(:yellow))
        rescue Exception => ex
          dl = DeadDownloader.new(vm_id, ex)
          downloaders << dl
          log_line(dl.status_line)
        end
      end

      def no_capacity_message
        m = AT_CAPACITY_RETRY_PERIOD / 60
        "No export capacity is currently available on Skytap. Will retry in #{m} minutes".tap do |msg|
          if active_downloaders.present?
            msg << ' or when another export completes.'
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
        logger.info "#{status_lines}\n---"
      end

      def print_summary
        unless response.error?
          logger.info "#{'Summary'.bright}\n#{response.payload}"
        end
      end

      def finished?
        vm_ids.empty? && concurrency == 0
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
        active_downloaders.collect(&:status_line).join("\n")
      end

      def active_downloaders
        downloaders.reject(&:finished?)
      end


      private

      def concurrency
        downloaders.select(&:alive?).length
      end

      def response
        @_response ||= begin
                         error = !downloaders.any?(&:success?)
                         Response.build(downloaders.collect(&:status_line).join("\n"), error)
                       end
      end
    end

    class NoSlotsAvailable < RuntimeError
    end

    class VmExportJob
      attr_reader :logger, :vm, :vm_id, :export_dir, :username, :api_token

      def initialize(logger, username, api_token, vm_id, dir=nil)
        @logger = logger
        @username = username
        @api_token = api_token
        @vm_id = vm_id

        @vm = Skytap.invoke!(username, api_token, "vm show #{vm_id}")
        @export_dir = File.join(File.expand_path(dir || '.'), "vm_#{vm_id}")
        FileUtils.mkdir_p(export_dir)

        create_on_server
      end

      def create_on_server
        begin
          export
        rescue Exception => ex
          if at_capacity?(ex)
            raise NoSlotsAvailable.new
          else
            raise
          end
        end
      end

      def at_capacity?(exception)
        exception.message.include?('You cannot export a VM because you may not have more than')
      end

      def export(force_reload=false)
        return @export unless @export.nil? || force_reload

        if @export
          id = @export['id']
          @export = Skytap.invoke!(username, api_token, "export show #{id}")
        else
          @export = Skytap.invoke!(username, api_token, "export create", {}, :param => {'vm_id' => vm_id})
        end
      end
    end

    class DeadDownloader
      def initialize(vm_id, exception)
        @vm_id = vm_id
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
        "VM #{@vm_id}: Error: #{@exception}"
      end
    end

    class Downloader < Thread
      MAX_WAIT = 2.days
      EXPORT_CHECK_PERIOD = 5

      attr_reader :job, :bytes_transferred, :bytes_total, :result
      delegate :logger, :vm, :vm_id, :export, :export_dir, :username, :api_token, :to => :job

      def initialize(job)
        @job = job
        @bytes_transferred = @bytes_total = 0

        super do
          begin
            run
          rescue Exception => ex
            @result = Response.build(ex)
          end
        end
      end

      def run
        wait_until_ready
        ftp_download
        download_data
        Skytap.invoke!(username, api_token, "export destroy #{id}")
        @result = Response.build(export_dir)
      end

      def finished?
        !!@finished
      end

      def success?
        result && !result.error?
      end

      def status_line
        prefix = "VM #{vm_id}".tap do |str|
          if vm
            str << " (#{vm['name']})"
          end
        end
        prefix << ': ' << status
      end

      def status
        if result.try(:error?)
          @finished = true
          "Error: #{result.error_message}".color(:red).bright
        elsif result
          @finished = true
          "Downloaded: #{result.payload}".color(:green).bright
        elsif bytes_transferred == 0
          'Exporting'.color(:yellow)
        else
          gb_transferred = bytes_transferred / 1.gigabyte.to_f
          gb_total = bytes_total / 1.gigabyte.to_f
          percent_done = 100.0 * bytes_transferred / bytes_total
          "Downloading #{'%0.1f' % percent_done}% (#{'%0.1f' % gb_transferred} / #{'%0.1f' % gb_total} GB)".color(:yellow)
        end
      end

      def ftp_download
        remote_path = export['filename']
        local_path = File.join(export_dir, File.basename(export['filename']))
        FileUtils.mkdir_p(export_dir)

        ftp = Net::FTP.new(export['ftp_host'])
        ftp.login(export['ftp_user_name'], export['ftp_password'])
        ftp.chdir(File.dirname(remote_path))
        @bytes_total = ftp.size(File.basename(remote_path))
        ftp.getbinaryfile(File.basename(remote_path), local_path) do |data|
          @bytes_transferred += data.size
        end
        ftp.close
      end

      def download_data
        vm = Skytap.invoke!(username, api_token, "vm show #{vm_id}")
        template_id = export['template_url'] =~ /templates\/(\d+)/ && $1
        template = Skytap.invoke!(username, api_token, "template show #{template_id}")

        exportable_vm = ExportableVm.new(vm, template)

        File.open(File.join(export_dir, 'vm.yaml'), 'w') do |f|
          f << YAML.dump(exportable_vm.data)
        end
      end

      def id
        export['id']
      end

      def wait_until_ready
        cutoff = MAX_WAIT.from_now
        finished = nil

        while Time.now < cutoff
          case export(true)['status']
          when 'processing'
          when 'complete'
            finished = true
            break
          else
            raise Skytap::Error.new "Export job had unexpected state of #{export['status'].inspect}"
          end

          sleep EXPORT_CHECK_PERIOD
        end

        unless finished
          raise Skytap::Error.new 'Timed out waiting for export job to complete'
        end
      end
    end

    #TODO:NLA Probably should pull this into a method that also sets e.g., Download.parent = Vm.
    Vm.subcommands << Download

    class ExportableVm
      DEFAULT_IP = '10.0.0.1'
      DEFAULT_HOSTNAME = 'host-1'
      DEFAULT_SUBNET = '10.0.0.0/24'
      DEFAULT_DOMAIN = 'test.net'

      attr_reader :vm, :template
      attr_reader :name, :description, :credentials, :ip, :hostname, :subnet, :domain

      def initialize(vm, template)
        @vm = vm
        @template = template

        @name = vm['name']
        @description = template['description'].present? ? template['description'] : @name

        if iface = vm['interfaces'][0]
          case iface['network_type']
          when 'automatic'
            @ip = iface['ip']
            @hostname = iface['hostname']

            network = template['networks'].detect {|net| net['id'] == iface['network_id']}
            raise Skytap::Error.new('Network for VM interface not found') unless network
            @subnet = network['subnet']
            @domain = network['domain']
          when 'manual'
            @manual_network = true

            network = template['networks'].detect {|net| net['id'] == iface['network_id']}
            raise Skytap::Error.new('Network for VM interface not found') unless network

            @subnet = network['subnet']
            @domain = DEFAULT_DOMAIN

            @ip = Subnet.new(@subnet).min_machine_ip.to_s
            @hostname = DEFAULT_HOSTNAME
          else # not connected
            @ip = DEFAULT_IP
            @hostname = iface['hostname'] || DEFAULT_HOSTNAME
            @subnet = DEFAULT_SUBNET
            @domain = DEFAULT_DOMAIN
          end
        else
          # Choose default everything for VM hostname, address and network subnet and domain
          @ip = DEFAULT_IP
          @hostname = DEFAULT_HOSTNAME
          @domain = DEFAULT_DOMAIN
          @subnet = DEFAULT_SUBNET
        end
      end

      def data
        @data ||= {
          'template_name' => @name,
          'template_description' => @description,
          'network_domain' => @domain,
          'network_subnet' => @subnet,
          'interface_ip' => @ip,
          'interface_hostname' => @hostname,
        }.tap do |d|
          if creds = vm['credentials'].try(:collect){|c| c['text']}
            d['credentials'] = creds
          end
        end
      end

      def manual_network?
        @manual_network
      end
    end
  end
end
