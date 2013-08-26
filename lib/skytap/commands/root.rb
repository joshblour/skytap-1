module Skytap
  module Commands
    class Root < Base
      self.container = true

      def self.go!(logger, args, global_options, command_options, programmatic_context=false, &invoker)
        new(logger, args, global_options, command_options, programmatic_context, &invoker).invoke
      end

      def self.banner_prefix
        'skytap'
      end

      def self.command_name
        nil
      end

      def self.populate_with(specification={})
        self.subcommands = specification.sort.collect do |resource, spec|
          Base.make_from(resource, spec).tap do |klass|
            klass.parent = self
          end
        end
      end

      def run!
        help!
      end

      def help_with_initial_setup!
        if SkytapRC.exists? || !solicit_user_input?
          help_without_initial_setup!
        else
          logger.puts <<-"EOF"
Do you want to store your API credentials in a text file for convenience?

If you answer yes, your username and API token will be stored in a .skytaprc
file in plain text. If you answer no, you must provide your username and API
token each time you invoke this tool.

          EOF
          if ask('Store username?', ActiveSupport::OrderedHash['y', true, 'n', false, :default, 'y'])
            username = ask('Skytap username:') while username.blank?
          end
          if ask('Store API token?', ActiveSupport::OrderedHash['y', true, 'n', false, :default, 'y'])
            logger.puts "\nYour API security token is on the My Account page.\nIf missing, ask your admin to enable API tokens on the Security Policies page."
            # Allow API token to be blank, in case the user realizes they don't have one.
            api_token = ask('API token:')
          end

          logger.puts <<-"EOF"

Do you want to turn on interactive mode?

If so, you will be shown the request parameters available for a command and
asked if you want to enter any. If you plan to use this tool primarily in
scripts, you may want to answer no.
          EOF

          ask_mode = ask('Enable interactive mode?', ActiveSupport::OrderedHash['y', true, 'n', false, :default, 'y'])

          config = global_options.symbolize_keys.merge(:username => username, :'api-token' => api_token, :ask => ask_mode)

          SkytapRC.write(config)

          logger.puts <<-"EOF"
Config file written to #{SkytapRC::RC_FILE}.

Example commands:
#{'skytap'.bright} - show all commands
#{'skytap help configuration'.bright} - show configuration commands
#{'skytap help vm upload'.bright} - help for VM upload command
          EOF
        end
      end
      alias_method_chain :help!, :initial_setup
    end
  end
end
