require 'skytap/requester'

module Skytap
  module Commands
    class HttpBase < Base
      self.ask_interactively = false

      class << self
        # This is a factory that is called on subclasses.
        def make_for(command_class, spec={})
          command_name = self.command_name
          Class.new(self).tap do |klass|
            klass.parent = command_class
            klass.singleton_class.send(:define_method, :command_name) { command_name }
            klass.spec = spec || {}
          end
        end
      end

      def requester
        base_url = global_options[:'base-url'] or raise Skytap::Error.new 'Must provide base-url option'
        http_format = global_options[:'http-format'] or raise Skytap::Error.new 'Must provide http-format option'
        verify_certs = global_options.has_key?(:'verify-certs') ? global_options[:'verify-certs'] : true

        @requester ||= Requester.new(logger, username, api_token, base_url, http_format, verify_certs)
      end

      def root_path
        "/#{resource.pluralize}"
      end

      def resource_path(id)
        "#{root_path}/#{id}"
      end

      def resource
        parent.command_name
      end

      def encode_body(params)
        return unless params.present?

        case format = global_options[:'http-format']
        when 'json'
          JSON.dump(params)
        when 'xml'
          params.to_xml(:root => resource)
        else
          raise "Unknown http-format: #{format.inspect}"
        end
      end

      def request(method, path, options={})
        response = requester.request(method, path, options_for_request)
        success = response.code.start_with?('2')

        logger.info "Code: #{response.code} #{response.message}".color(success ? :green : :red).bright
        logger.puts response.pretty_body
        response.tap do |resp|
          resp.singleton_class.instance_eval do
            define_method(:payload) do
              return unless body.present?

              case self['Content-Type']
              when /json/i
                JSON.load(body)
              when /xml/i
                parsed = Hash.from_xml(body)
                # Strip out the root name.
                if parsed.is_a?(Hash)
                  parsed.values.first
                else
                  parsed
                end
              else
                body
              end
            end
          end
        end
      end

      def options_for_request
        {:raise => false}.tap do |options|
          if ask_interactively
            options[:body] = encode_body(composed_params)
          else
            options[:params] = composed_params
          end
        end
      end

      def expected_args
        ActiveSupport::OrderedHash.new.tap do |expected|
          if parent_resources = parent.spec['parent_resources']
            example_path = join_paths(*parent_resources.collect {|r| [r.pluralize, "#{r.singularize.upcase}-ID"]}.flatten)
            expected['parent_path'] = "path of parent #{'resource'.pluralize(parent_resources.length)}, in the form #{example_path}"
          end
        end
      end

      def parent_path
        if expected_args['parent_path']
          index = expected_args.keys.index('parent_path')
          path = args[index].dup
        end
      end

      def path
        path = parent_path || ''
        if expected_args['id']
          index = expected_args.keys.index('id')
          id = args[index]
          join_paths(path, resource_path(id))
        else
          join_paths(path, root_path)
        end
      end

      def join_paths(*parts)
        '/' + parts.collect{|p| p.split('/')}.flatten.reject(&:blank?).join('/')
      end

      def get(*args)    ; request('GET', *args) ; end
      def post(*args)   ; request('POST', *args) ; end
      def put(*args)    ; request('PUT', *args) ; end
      def delete(*args) ; request('DELETE', *args) ; end
    end


    class Show < HttpBase
      def expected_args
        super.merge('id' => "ID or URL of #{resource} to show")
      end

      def self.default_description
        "Show specified #{parent.command_name.gsub('_', ' ')}"
      end

      def run!
        get(path)
      end
    end

    class Index < HttpBase
      def self.default_description
        "Show all #{parent.command_name.pluralize.gsub('_', ' ')} to which you have access"
      end

      def run!
        get(path)
      end
    end

    class Create < HttpBase
      self.ask_interactively = true

      def self.default_description
        "Create #{parent.command_name.gsub('_', ' ')}"
      end

      def run!
        post(path)
      end
    end

    class Destroy < HttpBase
      def expected_args
        super.merge('id' => "ID or URL of #{resource} to delete")
      end

      def self.default_description
        "Delete specified #{parent.command_name.gsub('_', ' ')}"
      end

      def run!
        delete(path)
      end
    end

    class Update < HttpBase
      def expected_args
        super.merge('id' => "ID or URL of #{resource} to update")
      end
      self.ask_interactively = true

      def self.default_description
        "Update attributes of specified #{parent.command_name.gsub('_', ' ')}"
      end

      def run!
        put(path)
      end
    end
  end
end
