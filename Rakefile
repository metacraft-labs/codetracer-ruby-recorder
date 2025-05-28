require 'rb_sys/extensiontask'

RbSys::ExtensionTask.new('codetracer_ruby_recorder') do |ext|
  ext.ext_dir = 'gems/codetracer-ruby-recorder/ext/native_tracer'
  ext.lib_dir = 'gems/codetracer-ruby-recorder/lib'
  ext.gem_spec = Gem::Specification.load('gems/codetracer-ruby-recorder/codetracer-ruby-recorder.gemspec')
end
