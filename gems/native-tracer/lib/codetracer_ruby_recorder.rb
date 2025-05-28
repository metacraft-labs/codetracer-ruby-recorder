require 'fileutils'
require 'rbconfig'

ext_dir = File.expand_path('../ext/native_tracer/target/release', __dir__)
dlext = RbConfig::CONFIG['DLEXT']
lib = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
unless File.exist?(lib)
  alt = %w[so bundle dylib dll]
         .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
         .find { |path| File.exist?(path) }
  if alt
    begin
      File.symlink(alt, lib)
    rescue StandardError
      FileUtils.cp(alt, lib)
    end
  end
end
require lib
