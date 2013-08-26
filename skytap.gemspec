# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'skytap/version'

Gem::Specification.new do |gem|
  gem.name          = "skytap"
  gem.version       = Skytap::VERSION
  gem.authors       = ["Yonah Forst"]
  gem.email         = ["joshblour@hotmail.com"]
  gem.description   = %q{integrates with skytap api}
  gem.summary       = %q{desc}
  gem.homepage      = ""

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.require_paths = ["lib"]

  
end
