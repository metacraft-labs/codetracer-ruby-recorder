Gem::Specification.new do |spec|
  spec.name          = 'codetracer-ruby-recorder'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'CodeTracer Ruby recorder with native extension'
  spec.description   = 'Ruby tracer that records execution steps via a Rust native extension.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir[
    'lib/**/*',
    'ext/native_tracer/**/{Cargo.toml,*.rs}',
    'ext/native_tracer/extconf.rb',
    'ext/native_tracer/target/release/*'
  ]
  spec.require_paths = ['lib']
  spec.extensions    = []
  spec.bindir        = 'bin'
  spec.executables   = ['codetracer-ruby-recorder']

  spec.add_development_dependency 'rb_sys', '~> 0.9'
end
