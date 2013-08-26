require 'skytap/skytaprc'

module Skytap
  class CommandLine
    ALLOWED_GLOBAL_OPTIONS = {
      # Flags
      :'base-url' => { :default => 'https://cloud.skytap.com' },
      :'username' => { :desc => 'Skytap username' },
      :'api-token' => { :desc => 'Skytap API token, found on "My Account" page', :hide_default_value => true },
      :'http-format' => { :default => 'json', :in => ['json', 'xml'], :desc => 'HTTP request and response format' },
      :'log-level' => { :default => 'info', :in => ['quiet', 'info', 'verbose'], :desc => 'Output verbosity' },
      :'params-file' => { :desc => 'File whose contents to send as request params, read according to http-format' },
      :'param' => { :desc => 'Request parameters in form --param=key1:value1 --param=key2:value2', :default => [], :multiple => true },

      # Switches
      :'help' => { :desc => 'Show help message for command', :switch => true },
      :'version' => { :desc => 'Show CLI version', :switch => true },
      :'colorize' => { :default => true, :desc => 'Colorize output?', :switch => true, :negatable => true },
      :'verify-certs' => { :default => true, :desc => 'Verify HTTPS certificates?', :switch => true, :negatable => true },
      :'ask' => { :default => true, :desc => 'Ask for params interactively?', :switch => true, :negatable => true }
    }


    def self.parse(argv=ARGV)
      global = read_global_options
      command_opts = {}
      args = []
      argv.each do |arg|
        if arg =~ /^[^-]/
          args << arg
        # Switches
        elsif arg =~ /^\-\-(no-)?([^=]+)$/
          negated, name = $1, $2.to_sym
          val = !negated
          if global.has_key?(name)
            global[name] = val
          else
            command_opts[name] = val
          end
        # Flags
        elsif arg =~ /^\-\-(.+?)=(.+)$/
          name, val = $1.to_sym, $2

          if global.has_key?(name)
            multiple = ALLOWED_GLOBAL_OPTIONS[name].try(:[], :multiple)
            if multiple
              if global[name].present?
                global[name] << val
              else
                global[name] = [val]
              end
            else
              global[name] = val
            end
          else
            command_opts[name] = val
          end
        elsif arg =~ /^\-([A-Za-z0-9]+)$/
          raise Skytap::Error.new 'Single-dash flags not supported. Use --flag form.'
        else
          raise "Unrecognized command-line arg: #{arg.inspect}"
        end
      end

      # To simplify client handling, treat a first arg of "help" as --help.
      if args.first == 'help'
        args.shift
        global[:help] = true
      end

      [args, global, command_opts]
    end

    def self.read_global_options
      global_options.inject({}) do |acc, (k, option)|
        acc[k] = option.val
        acc
      end
    end

    def self.global_options
      return @global_options if @global_options

      rc = SkytapRC.load
      @global_options = ALLOWED_GLOBAL_OPTIONS.inject({}) do |acc, (k, opts)|
        opts[:default] = rc[k] if rc.has_key?(k)
        acc[k] = Option.new(k, opts)
        acc
      end
    end
  end

  class Option
    attr_reader :name, :desc, :default

    def initialize(name, options = {})
      @name = name.to_s
      @options = options.symbolize_keys
      @desc = @options[:desc]
      @default = @options[:default]
    end

    def show_default?
      !@options[:hide_default_value]
    end

    def switch?
      @options[:switch]
    end

    def negatable?
      switch? && @options[:negatable]
    end

    def val
      if @set
        @val
      else
        default
      end
    end

    def val=(v)
      @set = true
      if switch?
        @val = !!v
      else
        @val = v
      end
    end

    def signature
      if switch?
        negation = '[no-]' if negatable?
        "--#{negation}#{name}"
      else
        "--#{name}=#{name.upcase}"
      end
    end

    def choices
      @options[:in]
    end
  end
end
