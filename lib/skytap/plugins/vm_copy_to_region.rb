module Skytap
  module Commands
    class CopyToRegion < Skytap::Commands::Base
      CHECK_PERIOD = 20

      self.parent = Vm
      self.plugin = true

      def self.command_name
        'copytoregion'
      end

      def self.description
        <<-"EOF"
Copy one or more VMs to a new region

This process involves exporting the VMs to the local filesystem,
importing them into the new region, then deleting them from the local
filesystem. Ensure you have sufficient disk space.
        EOF
      end

      def expected_args
        ActiveSupport::OrderedHash[
          'region', 'Name of target region',
          'vm_id*', 'One or more IDs of template VMs to copy to the region'
        ]
      end

      def expected_options
        ActiveSupport::OrderedHash[
          :tmpdir, {:flag_arg => 'TMPDIR', :desc => 'Temporary directory into which to download VMs'},
        ]
      end

      attr_reader :copiers

      def run!
        @copiers = []
        region = args.shift
        vm_ids = args.collect {|a| find_id(a)}

        until vm_ids.empty? && concurrency == 0
          if vm_ids.present?
            cop = Copier.new(logger, username, api_token, vm_ids.shift, region, command_options[:tmpdir])
            copiers << cop
            if (line = cop.status_line).present?
              logger.info "#{line}\n---"
            end
          else
            sleep CHECK_PERIOD
            if (lines = status_lines).present?
              logger.info "#{lines}\n---"
            end
          end
        end

        response.tap do |res|
          logger.info "#{'Summary:'.bright}\n#{res.payload}" unless res.error?
        end
      end

      def status_lines
        copiers.reject(&:finished?).collect(&:status_line).reject(&:blank?).join("\n")
      end


      private

      def concurrency
        copiers.select(&:alive?).length
      end

      def response
        error = !copiers.any?(&:success?)
        Response.build(copiers.collect(&:summary).join("\n"), error)
      end
    end

    class Copier < Thread
      attr_reader :logger, :vm_id, :region, :root_dir, :result, :username, :api_token

      def initialize(logger, username, api_token, vm_id, region, root_dir = nil)
        @logger = logger
        @username = username
        @api_token = api_token
        @vm_id = vm_id
        @region = region
        @root_dir = File.expand_path(root_dir || '.')

        warn_if_manual_network

        super do
          begin
            run
          rescue Exception => ex
            @result = Response.build(ex)
          end
        end
      end

      def run
        FileUtils.mkdir_p(root_dir)

        #TODO:NLA Set vmdir = File.join(tmpdir, "tmp_vm_#{vm_id}"). Then on success, remove vmdir.

        downloads = Skytap.invoke!(username, api_token, "vm download #{vm_id}", :dir => root_dir) do |downloader|
          @no_slots_msg = if seconds = downloader.seconds_until_retry
                            m = Integer(seconds / 60)
                            "VM #{vm_id}: No export capacity is currently available on Skytap. Will retry ".tap do |msg|
                              if m < 1
                                msg << 'soon.'
                              else
                                msg << "in #{m} minutes or when more capacity is detected."
                              end
                            end.color(:yellow)
                          end
          @status_line = downloader.status_lines
        end

        @no_slots_msg = nil

        vm_dir = File.join(root_dir, "vm_#{vm_id}")
        unless downloads.include?(vm_dir)
          raise Skytap::Error.new("Response dir unexpected (was: #{downloads}; expected to contain #{vm_dir})")
        end

        # Invoke with an array to treat vm_dir as one token, even if it contains spaces.
        uploads = Skytap.invoke!(username, api_token, ['vm', 'upload', vm_dir], {}, :param => {'region' => region}) do |uploader|
          @no_slots_msg = if seconds = uploader.seconds_until_retry
                            m = Integer(seconds / 60)
                            "VM #{vm_id}: No import capacity is currently available on Skytap. Will retry ".tap do |msg|
                              if m < 1
                                msg << 'soon.'
                              else
                                msg << "in #{m} minutes or when more capacity is detected."
                              end
                              msg
                            end.color(:yellow)
                          end
          @status_line = uploader.status_lines
        end

        FileUtils.rm_r(vm_dir)

        @result = Response.build(uploads)
      end

      def finished?
        @finished.tap do
          @finished = true if @result
        end
      end

      def success?
        result && !result.error?
      end

      def status_line
        payload = result.try(:payload) and return payload

        if @no_slots_msg
          unless @skip_print
            @skip_print = true
            return @no_slots_msg
          end
        else
          @skip_print = false
        end

        @status_line
      end

      def summary
        status_line.tap do |msg|
          if manual_network?
            msg << " This template has an automatic network, but the template from which it was copied has a manual network. You may want to change the network settings of the new template by creating a configuration from it, editing the network, and finally creating another template from that configuration."
          end
        end
      end

      def manual_network?
        @_manual_network ||= begin
                              vm = Skytap.invoke!(username, api_token, "vm show #{vm_id}")
                              (iface = vm['interfaces'].try(:first)) && iface['network_type'] == 'manual'
                            end
      end

      def warn_if_manual_network
        if manual_network?
          msg = 'This VM is attached to a manual network, but the new template will instead contain an automatic network. You may want to change the network settings of the new template by creating a configuration from it, editing the network, and finally creating another template from that configuration.'
          logger.info "VM #{vm_id}: #{msg.color(:yellow)}\n---"
        end
      end
    end

    Vm.subcommands << CopyToRegion
  end
end

