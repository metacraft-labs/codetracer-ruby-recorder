Gem::Specification.new do |spec|
  spec.name          = 'codetracer-pure-ruby-recorder'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'Test oracle for the CodeTracer Ruby recorder: writes JSON that CodeTracer cannot open'
  spec.description   = 'A pure-Ruby test oracle, not a production recorder. It writes a JSON trace that the codetracer-ruby-recorder test suite compares against the production recorder\'s .ct output (converted with ct print). CodeTracer cannot open its output; to record Ruby for CodeTracer use the codetracer-ruby-recorder gem.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir['lib/**/*', 'bin/*']
  spec.require_paths = ['lib']
  spec.bindir        = 'bin'
  spec.executables   = ['codetracer-pure-ruby-recorder']
end
