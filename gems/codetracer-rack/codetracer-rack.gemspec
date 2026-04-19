# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'codetracer-rack'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'CodeTracer Rack middleware for HTTP request span tracking'
  spec.description   = 'Rack middleware that wraps HTTP requests in CodeTracer spans with method, URL, status, and duration metadata.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']

  spec.add_dependency 'json'
  spec.add_dependency 'rack', '>= 2.0'
end
