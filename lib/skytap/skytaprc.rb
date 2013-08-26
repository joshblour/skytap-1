module Skytap
  module SkytapRC
    extend self

    RC_FILE = File.expand_path(File.join(ENV['HOME'], '.skytaprc'))
    RECOGNIZED_OPTIONS = [:'verify-certs', :'base-url', :'api-token', :'http-format', :ask, :'log-level', :username, :colorize]

    def exists?
      File.exist?(RC_FILE)
    end

    def load
      @rc_contents ||= (if File.exist?(RC_FILE)
                         YAML.load_file(RC_FILE).symbolize_keys
                       else
                         {}
                       end).subset(RECOGNIZED_OPTIONS)
    end

    def write(hash)
      @rc_contents = nil
      hash = (hash || {}).subset(RECOGNIZED_OPTIONS)
      File.open(RC_FILE, 'w') do |f|
        f << YAML.dump(hash)
      end
    end
  end
end
