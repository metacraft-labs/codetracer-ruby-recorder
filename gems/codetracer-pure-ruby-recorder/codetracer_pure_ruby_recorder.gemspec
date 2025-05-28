Gem::Specification.new do |spec|
  spec.name          = 'codetracer-pure-ruby-recorder'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']

  spec.summary       = 'CodeTracer Ruby recorder implemented purely in Ruby'
  spec.description   = 'Ruby tracer that records execution steps using only Ruby code.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'

  spec.files         = Dir['lib/**/*', 'bin/*']
  spec.require_paths = ['lib']
  spec.bindir        = 'bin'
  spec.executables   = ['codetracer-pure-ruby-recorder']
end
