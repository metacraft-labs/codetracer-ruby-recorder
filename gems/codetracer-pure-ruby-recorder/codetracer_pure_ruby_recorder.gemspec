Gem::Specification.new do |spec|
  spec.name          = 'codetracer-pure-ruby-recorder'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'Pure-Ruby reference implementation of the CodeTracer Ruby recorder (legacy JSON output)'
  spec.description   = 'Pure-Ruby reference recorder for CodeTracer. Emits the legacy 3-file JSON trace shape and serves as the cross-validation oracle for the production native gem `codetracer-ruby-recorder`, which writes CTFS v3 bundles. Both recorders are run against the same fixtures in the project test suite to keep them honest.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir['lib/**/*', 'bin/*']
  spec.require_paths = ['lib']
  spec.bindir        = 'bin'
  spec.executables   = ['codetracer-pure-ruby-recorder']
end
