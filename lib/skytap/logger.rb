module Skytap
  class Logger
    attr_accessor :log_level

    def initialize(log_level)
      @log_level = log_level
    end

    # The message is logged unconditionally.
    def puts(msg = '', options = {})
      do_log(msg, options)
    end

    # The message is logged unless the --quiet option is present.
    def info(msg = '', options = {})
      if log_level == 'info' || log_level == 'verbose'
        do_log(msg, options)
      end
    end

    def debug(msg = '', options = {})
      if log_level == 'verbose'
        do_log(msg, options)
      end
    end

    def mute!
      @muted = true
    end

    def unmute!
      @muted = false
    end

    def muted?
      !!@muted
    end


    private

    def do_log(msg, options = {})
      return if muted?
      options = options.symbolize_keys
      newline = options.has_key?(:newline) ? options[:newline] : true
      $stdout.flush
      $stdout.print msg
      $stdout.puts if newline
      $stdout.flush
    end
  end
end
