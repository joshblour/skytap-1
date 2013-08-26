require 'skytap/templates'

module Skytap
  module Commands
    module Help

      module ClassMethods
        def banner_prefix
          parent_prefix = parent.try(:banner_prefix)
          "#{parent_prefix.try(:+, ' ')}#{self.command_name}"
        end

        def banner
          b = "#{banner_prefix} - #{short_desc}"
          if plugin
            b.color(:cyan)
          else
            b
          end
        end

        def description
          spec['description'] || default_description
        end

        def default_description
          nil
        end

        def short_desc
          description.split("\n\n").first.split("\n").join(' ') if description
        end

        def subcommand_banners
          subcommands.inject([]) do |acc, klass|
            acc << klass.banner unless klass.container
            acc.concat(klass.subcommand_banners)
            acc
          end
        end
      end

      def synopsis
        if self.container
          command_name = self.class.command_name
          "skytap #{command_name + ' ' if command_name}<subcommand> <options>"
        else
          "#{self.class.banner_prefix} #{expected_args.keys.collect(&:upcase).join(' ') << ' '}<options> - #{self.class.short_desc}"
        end
      end

      def help?
        !!global_options[:help]
      end

      def help!
        puts Skytap::Templates::Help.render(self)
      end

      def version?
        !!global_options[:version]
      end

      def parameters
        spec['params']
      end

      def description
        self.class.description
      end

      def self.included(base)
        base.extend(ClassMethods)
        # Indicates whether this class is only a container for subcommands.
        base.class_attribute :container, :spec, :plugin
        base.container = false
        base.plugin = false
        base.spec = {}
      end
    end
  end
end
