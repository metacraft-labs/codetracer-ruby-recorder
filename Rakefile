require 'rb_sys/extensiontask'

RbSys::ExtensionTask.new('codetracer_ruby_recorder') do |ext|
  ext.ext_dir = 'gems/native-tracer/ext/native_tracer'
  ext.lib_dir = 'gems/native-tracer/lib'
  ext.gem_spec = Gem::Specification.load('gems/native-tracer/codetracer-ruby-recorder.gemspec')
end
