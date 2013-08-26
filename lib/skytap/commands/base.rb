require 'skytap/commands/help'

module Skytap
  module Commands
    class Base
      include Help

      class_attribute :subcommands, :parent, :ask_interactively
      self.subcommands = []

      attr_accessor :error
      attr_reader :args, :global_options, :command_options, :logger, :invoker

      def initialize(logger, args, global_options, command_options, programmatic_context=false, &invoker)
        @logger = logger
        @args = args
        @global_options = global_options
        @command_options = command_options || {}
        @programmatic_context = programmatic_context
        @invoker = invoker
      end

      def programmatic?
        !!@programmatic_context
      end

      class << self
        # A factory that makes a command class from the given resource
        def make_from(resource, spec={})
          spec ||= {}
          Class.new(Base).tap do |klass|
            klass.instance_eval do
              self.container = true
              self.subcommands = [Index, Show, Create, Update, Destroy].reject do |sub|
                spec['skip_actions'].try(:include?, sub.command_name)
              end.collect do |sub|
                sub_spec = spec['actions'].try(:[], sub.command_name)
                sub.make_for(self, sub_spec)
              end
              self.spec = spec
              alias_method :run!, :help!
            end

            Skytap::Commands.const_set(resource.classify, klass)
          end
        end

        def command_name
          name.split('::').last.underscore
        end
      end

      def invoke
        if matching_subcommand
          matching_subcommand.new(logger, args[1..-1], global_options, command_options, @programmatic_context, &invoker).invoke
        elsif help?
          help!
        elsif version?
          logger.puts "skytap version #{Skytap::VERSION}"
          exit
        elsif container && args.present?
          self.error = "Subcommand '#{args.first}' not found"
          help!
          exit(false)
        else
          validate_args
          validate_command_options
          run!
        end
      end

      def expected_args
        ActiveSupport::OrderedHash.new
      end

      # Expected command-specific options (not global options)
      def expected_options
        {}
      end

      # Returns an ID string from an URL, path or ID
      def find_id(arg)
        arg.to_s =~ /(.*\/)?(.+)$/ && $2
      end

      def solicit_user_input?
        global_options[:ask] && !programmatic? && $stdin.tty?
      end


      def ask_param
        name = ask('Name: '.bright)
        value = ask('Value: '.bright)
        [name, value]
      end

      def ask(question, choices={})
        return unless solicit_user_input?
        default = choices.delete(:default)
        raise "Default choice must be in the choices hash" if default && !choices.has_key?(default)
        if choices.present?
          letters = " [#{choices.collect{|l, _| l == default ? l.upcase : l.downcase}.join}]"
        end

        loop do
          line = "#{question}#{letters} ".color(:yellow)
          $stdout.print line
          $stdout.flush

          answer = $stdin.gets.try(&:strip)
          if choices.blank?
            break answer
          elsif answer.blank? && default
            break choices[default]
          elsif choices.has_key?(answer.downcase)
            break choices[answer.downcase]
          end
        end
      end

      def composed_params
        noninteractive_params.merge(interactive_params)
      end

      def file_params
        file = global_options[:'params-file'] or return {}
        file = File.expand_path(file)
        raise 'Params file not found' unless File.exist?(file)
        case File.basename(file)
        when /\.json$/i
          format = 'json'
        when /\.xml$/i
          format = 'xml'
        else
          format = global_options[:'http-format']
        end

        body = File.open(file, &:read)
        deserialized = case format
                       when 'json'
                         JSON.load(body)
                       when 'xml'
                         parsed = Hash.from_xml(body)
                         # Strip out the root name.
                         if parsed.is_a?(Hash)
                           parsed.values.first
                         else
                           parsed
                         end
                       else
                         raise Skytap::Error.new("Unknown format: #{format.inspect}")
                       end
      end

      def command_line_params
        param = global_options[:param]
        return {} if param.blank?
        case param
        when Hash
          param
        when String
          #TODO:NLA This will blow up if param has a weird form.
          Hash[*param.split(':', 2)]
        when Array
          split = param.collect {|v| v.split(':', 2)}.flatten
          Hash[*split]
        else
          param
        end
      end

      def noninteractive_params
        @noninteractive_params ||= file_params.merge(command_line_params)
      end

      def interactive_params
        if !solicit_user_input? ||
          !ask_interactively ||
          parameters.blank? ||
          (required_parameters.empty? && noninteractive_params.present?) ||
          (required_parameters.present? && (required_parameters - noninteractive_params.keys).empty?)

          return {}
        end

        param_info = Templates::Help.new('command' => self).parameters_table
        logger.info param_info << "\n"

        params = {}
        loop do
          answer = ask('include a param?', ActiveSupport::OrderedHash['y', 'y', 'n', 'n', 'q', 'q', '?', '?', :default, 'n'])
          case answer.downcase
          when 'y'
            k, v = ask_param
            params[k] = v
          when 'n'
            break
          when 'q'
            logger.info 'Bye.'
            exit
          else
            logger.puts <<-"EOF"
y - include an HTTP request parameter
n - stop adding parameters (default answer)
q - quit
? - show this message

            EOF
          end
        end

        params
      end

      def username
        return @_username if @_username
        username = global_options[:username]
        if username.blank?
          if solicit_user_input?
            username = ask('Skytap username:') while username.blank?
          else
            raise Skytap::Error.new('Must provide --username')
          end
        end
        @_username = username
      end

      def api_token
        return @_api_token if @_api_token
        api_token = global_options[:'api-token']
        if api_token.blank?
          if solicit_user_input?
            api_token = ask('API token:') while api_token.blank?
          else
            raise Skytap::Error.new('Must provide --api-token')
          end
        end
        @_api_token = api_token
      end

      private


      def run!
        raise NotImplementedError.new('Must override #run!')
      end

      def required_parameters
        @required_parameters ||= parameters.collect{|p| p.keys.first if p.values.first['required']}.compact
      end

      #TODO:NLA Need to track somewhere that only the last expected arg may end with *
      def validate_args
        unlimited = expected_args.keys.last.try(:end_with?, '*')
        if unlimited
          min = expected_args.keys.length
          if args.length < expected_args.keys.length
            self.error = "Expected at least #{min} command line #{'argument'.pluralize(min)} but got #{args.length}."
            help!
            exit(false)
          end
        else
          expected = expected_args.keys.length
          unless args.length == expected
            self.error = "Expected #{expected} command line #{'argument'.pluralize(expected)} but got #{args.length}."
            help!
            exit(false)
          end
        end
      end

      def validate_command_options
        bad = command_options.inject([]) do |acc, (name, value)|
          if !expected_options[name]
            acc << "Unknown option '#{name}'."
          elsif !expected_options[name][:flag_arg] && (value != true && value != false)
            acc << "'#{name}' option is a switch and cannot be set to a value."
          end
          acc
        end
        if bad.present?
          self.error = bad.join(' ')
          help!
          exit(false)
        end
      end

      def matching_subcommand
        next_command = args.first
        subcommands.detect {|k| k.command_name == next_command}
      end
    end
  end
end
