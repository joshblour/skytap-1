module Skytap
  class Requester
    #TODO:NLA Move more of the implementation in request() below into this class.
    class Response
      attr_reader :logger, :http_response
      def initialize(logger, http_response, options = {})
        @logger = logger
        @http_response = http_response

        logger.debug 'Response:'.color(:cyan).bright
        each_header do |k, v|
          logger.debug "#{k}: #{v}".color(:cyan)
        end
        logger.debug "\n#{body}".color(:cyan)
        logger.debug '---'.color(:cyan).bright

        # Raise unless response is 2XX.
        @http_response.value if options[:raise]
      end

      def method_missing(*args, &block)
        http_response.send(*args, &block)
      end

      def pretty_body
        return body if body.blank?
        if content_type.include?('json')
          begin
            JSON.pretty_generate(JSON.load(body))
          rescue
            body
          end
        else
          body
        end
      end
    end

    attr_reader :logger, :format

    def initialize(logger, username, api_token, base_url, http_format, verify_certs=true)
      @logger = logger
      @username = username or raise Skytap::Error.new 'No username provided'
      @api_token = api_token or raise Skytap::Error.new 'No API token provided'
      @base_uri = URI.parse(base_url) or raise Skytap::Error.new 'No base URL provided'
      @format = "application/#{http_format}" or raise Skytap::Error.new 'No HTTP format provided'
      @verify_certs = verify_certs
    end

    # Raises on error code unless :raise => false is passed.
    def request(method, url, options = {})
      options = options.symbolize_keys
      options[:raise] = true unless options.has_key?(:raise)

      with_session do |http|
        begin
          #TODO:NLA Move this into method
          if p = options[:params]
            if p.is_a?(Hash)
              p = p.collect {|k,v| CGI.escape(k) + '=' + CGI.escape(v)}.join('&')
            end

            path, params = url.split('?', 2)
            if params
              params << '&'
            else
              params = ''
            end
            params << p
            url = [path, params].join('?')
          end

          body = options[:body] || ''
          headers = base_headers.merge(options[:headers] || {})
          logger.debug 'Request:'.color(:cyan).bright
          logger.debug "#{method} #{url}\n#{headers.collect {|k,v| "#{k}:#{v}"}.join("\n")}\n\n#{body}".color(:cyan)
          logger.debug '---'.color(:cyan).bright

          response = Response.new(logger, http.send_request(method, url, body, headers),
                                 :raise => options[:raise])
        rescue OpenSSL::SSL::SSLError => ex
          $stderr.puts <<-"EOF"
An SSL error occurred (probably certificate verification failed).

If you are pointed against an internal test environment, set
"verify-certs: false" in your ~/.skytaprc file or use --no-verify-certs.

If not, then you may be subject to a man-in-the-middle attack, or the web
site's SSL certificate may have expired.

The error was: #{ex}
EOF
          exit(-1)
        rescue Net::HTTPServerException => ex
          logger.debug 'Response:'.color(:cyan).bright
          logger.info "Code: #{ex.response.code} #{ex.response.message}".color(:red).bright
          logger.info ex.response.body
          raise
        end
      end
    end

    def base_headers
      headers = {
        'Authorization' => auth_header,
        'Content-Type' => format,
        'Accept' => format,
        'User-Agent' => "SkytapCLI/#{Skytap::VERSION}",
      }
    end

    def auth_header
      "Basic #{Base64.encode64(@username + ":" + @api_token)}".gsub("\n", '')
    end

    def with_session
      http = Net::HTTP.new(@base_uri.host, @base_uri.port)
      http.use_ssl = @base_uri.port == 443 || @base_uri.scheme == 'https'

      if http.use_ssl?
        # Allow cert-checking to be disabled, since internal test environments
        # have bad certs.
        if @verify_certs
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.ca_file = File.join(File.dirname(__FILE__), '..', '..', 'ca-bundle.crt')
        else
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
      end

      yield http
    end
  end
end
