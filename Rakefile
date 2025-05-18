require 'rb_sys/extensiontask'

RbSys::ExtensionTask.new('codetracer_ruby_recorder') do |ext|
  ext.ext_dir = 'ext/native_tracer'
  ext.lib_dir = 'src'
  ext.gem_spec = Gem::Specification.load('codetracer-ruby-recorder.gemspec')
end
