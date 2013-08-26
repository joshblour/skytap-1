module Skytap
  class Response
    def self.build(result, is_error=nil)
      case result
      when self
        result
      when Requester::Response
        is_error ||= result.code !~ /^[123]/
        if is_error && result.payload.is_a?(Hash)
          err_msg = "Server error (code #{result.code}): " +
            (result.payload['error'] ||
             result.payload['errors'].try(:join, ' ') ||
             result.body)
        end
        new(result.payload, is_error, err_msg)
      when Skytap::Error
        new(result, true, result.to_s)
      when Exception
        log_exception(result)
        new(result, true, "Internal error: #{result}")
      else
        new(result, is_error)
      end
    end

    attr_reader :payload

    def initialize(payload, error = nil, error_message = nil)
      @payload = payload
      @error = error
      if @error
        @error_message = error_message || @payload.to_s
      end
    end

    def error?
      @error
    end

    def error_message
      @error_message.color(:red).bright
    end


    private


    def self.log_exception(ex)
      begin
        message = "#{Time.now}: -- #{Skytap::VERSION} -- " +
        "#{ex} (#{ex.class.name})\n#{ex.backtrace.join("\n")}\n"

        File.open(File.expand_path(File.join(ENV['HOME'], '.skytap.log')), 'a') do |f|
          f << message
        end
      rescue
        # No-op
      end
    end
  end
end
