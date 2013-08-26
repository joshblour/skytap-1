module Skytap
  module ApiSchema
    SCHEMA_FILE = File.join(File.dirname(__FILE__), '..', '..', 'api_schema.yaml')
    def get
      return @info unless @info.nil?

      @info = YAML.load_file(SCHEMA_FILE)
    end
    module_function :get
  end
end
