#TODO:NLA Move this monkey patch elsewhere.
module Terminal
  class Table
    def additional_column_widths
      return [] if style.width.nil?
      spacing = style.width - columns_width
      if spacing < 0
        # SKYTAP: Modify this line not to raise an execption.
        return []
      else
        per_col = spacing / number_of_columns
        arr = (1...number_of_columns).to_a.map { |i| per_col }
        other_cols = arr.inject(0) { |s, i| s + i }
        arr << spacing - other_cols
        arr
      end
    end
  end
end

module Skytap
  module Templates
    class Base < OpenStruct

      # The template can refer to hash keys as if they were local variables.
      def self.render(hash)
        attrs = {'description' => 'DEFAULT DESCRIPTION HERE'}.merge(hash)
        new(attrs).render
      end

      def template_str
        raise 'must be overridden'
      end

      def render
        # Allow -%> to trim surrounding whitespace in ERB.
        trim_mode_char = '-'
        ERB.new(template_str, nil, trim_mode_char).result(binding)
      end

      def indent(msg='', width=5)
        msg ||= ''
        msg.split("\n").collect do |line|
          (' ' * width) << line
        end.join("\n")
      end
    end

    class Help < Base
      TEMPLATE = File.expand_path(File.join(File.dirname(__FILE__), 'help_templates', 'help.erb'))

      def self.render(command)
        new('command' => command).render
      end

      def template_str
        File.open(TEMPLATE, &:read)
      end

      def header(name)
        name.bright
      end

      def error_msg
        if command.error
          "Error: ".color(:red).bright << command.error
        end
      end

      def subcommands
        @subcommands ||= command.class.subcommand_banners
      end

      #TODO:NLA These two methods are from
      #https://github.com/cldwalker/hirb/blob/master/lib/hirb/util.rb#L61-71,
      #which is under the MIT license. Figure out how to cite it properly.
      def detect_terminal_size
        if (ENV['COLUMNS'] =~ /^\d+$/) && (ENV['LINES'] =~ /^\d+$/)
          [ENV['COLUMNS'].to_i, ENV['LINES'].to_i]
        elsif (RUBY_PLATFORM =~ /java/ || (!STDIN.tty? && ENV['TERM'])) && command_exists?('tput')
          [`tput cols`.to_i, `tput lines`.to_i]
        elsif STDIN.tty? && command_exists?('stty')
          `stty size`.scan(/\d+/).map { |s| s.to_i }.reverse
        else
          nil
        end
      rescue
        nil
      end
      # Determines if a shell command exists by searching for it in ENV['PATH'].
      def command_exists?(command)
        ENV['PATH'].split(File::PATH_SEPARATOR).any? {|d| File.exists? File.join(d, command) }
      end

      def hard_wrap(text, line_width)
        breaking_word_wrap(text, :line_width => line_width)
      end

      # Taken from http://apidock.com/rails/ActionView/Helpers/TextHelper/word_wrap#1023-word-wrap-with-breaking-long-words
      def breaking_word_wrap(text, *args)
        options = args.extract_options!
        unless args.blank?
          options[:line_width] = args[0] || 80
        end
        options.reverse_merge!(:line_width => 80)
        text = text.split(" ").collect do |word|
          word.length > options[:line_width] ? word.gsub(/(.{1,#{options[:line_width]}})/, "\\1 ") : word
        end * " "
          text.split("\n").collect do |line|
            line.length > options[:line_width] ? line.gsub(/(.{1,#{options[:line_width]}})(\s+|$)/, "\\1\n").strip : line
          end * "\n"
      end

      def global_options_table
        min_width, max_width = 70, 120
        indentation = 5
        tty_cols = [detect_terminal_size.try(:first) || 80, min_width].max
        width = [tty_cols, max_width].min - indentation
        option_col_width = CommandLine.global_options.values.collect(&:signature).collect(&:length).max
        padding = 7

        table = Terminal::Table.new do |t|
          t.style = {:width => width}
          t.headings = ['Option'.underline, 'Description'.underline]
          desc_col_width = width - option_col_width - padding
          t.rows = CommandLine.global_options.values.inject([]) do |acc, opt|
            acc << [
              opt.signature,
              description_cell(opt, desc_col_width)
            ]

            # Add separator unless we're at the very end.
            acc << :separator unless acc.length == 2 * CommandLine.global_options.values.length - 1
            acc
          end
        end
        indent(table.to_s, indentation)
      end


      def description_cell(option, col_width)
        [description(option, col_width),
          default(option, col_width),
          choices(option, col_width)].compact.join("\n")
      end

      def description(option, col_width)
        if option.desc.present?
          hard_wrap(option.desc, col_width) << "\n"
        end
      end

      def default(option, col_width)
        if option.default.present? && option.show_default?
          hard_wrap("Default: #{option.default}", col_width)
        end
      end

      def choices(option, col_width)
        if option.choices.present?
          hard_wrap("Options: #{option.choices.join(', ')}", col_width)
        end
      end

      def parameters_table
        min_width, max_width = 70, 120
        indentation = 5
        tty_cols = [detect_terminal_size.try(:first) || 80, min_width].max
        width = [tty_cols, max_width].min - indentation
        left_col_width = command.parameters.collect{|name, _| name}.collect(&:length).max || 0
        padding = 7

        table = Terminal::Table.new do |t|
          t.style = {:width => width}
          t.headings = ['Parameter'.underline << "\n#{'*'.color(:cyan)} = required", 'Description'.underline]
          desc_col_width = width - left_col_width - padding

          t.rows = command.parameters.inject([]) do |acc, hash|
            name = hash.keys.first
            info = hash[name]

            acc << [
              info['required'] ? ('*'.color(:cyan) << name) : (' ' << name),
              param_description_cell(info, desc_col_width)
            ]

            # Add separator unless we're at the very end.
            acc << :separator unless acc.length == 2 * command.parameters.length - 1
            acc
          end
        end
        indent(table.to_s, indentation)
      end

      #TODO:NLA Lots of duplication here (see methods in class Help, above.
      def param_description_cell(param, col_width)
        [param_description(param, col_width),
          param_examples(param, col_width)].compact.join("\n")
      end

      def param_description(param, col_width)
        if param['description'].present?
          hard_wrap(param['description'], col_width) << "\n"
        end
      end

      def param_examples(param, col_width)
        if param['examples'].present?
          param['examples'].collect do |example|
            hard_wrap("Example: #{example}", col_width)
          end
        end
      end
    end
  end
end
