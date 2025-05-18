Gem::Specification.new do |spec|
  spec.name          = 'codetracer-ruby-recorder'
  spec.version       = '0.1.0'
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'CodeTracer Ruby recorder with native extension'
  spec.description   = 'Ruby tracer that records execution steps via a Rust native extension.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir['src/**/*', 'ext/native_tracer/**/{Cargo.toml,*.rs}', 'ext/native_tracer/extconf.rb', 'README.md', 'LICENSE']
  spec.require_paths = ['src']
  spec.extensions    = ['ext/native_tracer/extconf.rb']

  spec.add_development_dependency 'rb_sys', '~> 0.9'
end
