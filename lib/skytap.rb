# Standard library
require 'net/https'
require 'ostruct'
require 'net/https'
require 'net/ftp'
require 'uri'
require 'base64'
require 'fileutils'
require 'yaml'
require 'erb'
require 'cgi'
require 'optparse'
require 'set'
require 'json'

# Gems
require 'rainbow'
require 'active_support/core_ext'
require 'terminal-table'

# Skytap files
require 'skytap/version'
require 'skytap/core_ext'
require 'skytap/error'
require 'skytap/command_line'
require 'skytap/commands'
require 'skytap/logger'
require 'skytap/api_schema'
require 'skytap/response'
require 'skytap/subnet'

module Skytap
  extend self

  SCHEMA = Skytap::ApiSchema.get
  BASE_RESOURCES = %w[asset
                      configuration
                      credential
                      export
                      import
                      ip
                      template
                      user
                      vm]

  # Returns a numeric code indicating exit status; 0 iff success.
  def exec! #TODO:NLA Rename to something indicating that this is called when running from a command-line context.
    response = begin
      args, global_options, command_options = CommandLine.parse(ARGV)

      logger = Logger.new(global_options[:'log-level'])

      # Disable color if needed. We don't unconditionally execute this line so that
      # color is still disabled for non-TTY terminals irrespective of the colorize
      # setting.
      Sickill::Rainbow.enabled = false unless global_options[:colorize]

      build_response(Commands::Root.go!(logger, args, global_options, command_options))
    rescue SystemExit
      raise
    rescue Interrupt
      return 0
    rescue Exception => ex
      log_exception(ex, args, global_options, command_options)
      build_response(ex)
    end

    if response.error?
      if logger
        logger.info response.error_message
      else
        $stderr.puts response.error_message
      end
      return 1
    else
      return 0
    end
  end

  # Invokes the command in a way suitable for Ruby programs which use Skytap as
  # a third-party library, or for Skytap plugins.
  def invoke(username, api_token, args, command_options = {}, global_options = {}, &invoker)
    #TODO:NLA This is hacky, and basically just to get the defaults for global options. FIXME
    _, loaded_global_options, _ = CommandLine.parse([])
    global_options = loaded_global_options.merge(global_options).merge(:username => username, :'api-token' => api_token)

    if args.is_a?(String)
      args = args.split
    end

    logger = Logger.new(global_options[:'log-level']).tap do |l|
      l.mute! unless l.log_level == 'verbose'
    end

    build_response(Commands::Root.go!(logger, args, global_options, command_options, true, &invoker))
  end

  def invoke!(*args, &block)
    resp = invoke(*args, &block)
    if resp.error?
      raise Skytap::Error.new resp.error_message
    else
      resp.payload
    end
  end

  def specification
    resources.inject({}) do |acc, resource|
      acc[resource] = SCHEMA[resource] || {}
      acc
    end
  end


  private

  def build_response(result)
    Response.build(result)
  end

  def resources
    SCHEMA.keys | BASE_RESOURCES
  end

  def log_exception(ex, args, global_options, command_options)
    begin
      global_options.try(:delete, :'api-token')
      message = "#{Time.now}: -- #{args.inspect} -- #{global_options.inspect} -- " +
        "#{command_options.inspect} -- #{Skytap::VERSION} -- " +
        "#{ex} (#{ex.class.name})\n#{ex.backtrace.join("\n")}\n"

      File.open(File.expand_path(File.join(ENV['HOME'], '.skytap.log')), 'a') do |f|
        f << message
      end

      if global_options.try(:[], :'log-level') == 'verbose'
        puts message
      end
    rescue
      # No-op
    end
  end
end

Skytap::Commands::Root.populate_with(Skytap.specification)

Dir.glob(File.join(File.dirname(__FILE__), 'skytap', 'plugins', '*.rb')) do |path|
  require path
end
