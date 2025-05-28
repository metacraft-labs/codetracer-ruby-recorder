#!/usr/bin/env ruby

# Load the native extension only if RubyRecorder is not already available
# (e.g., when running directly without the codetracer wrapper)
unless defined?(RubyRecorder)
  ext_base = File.expand_path('../gems/native-tracer/ext/native_tracer/target/release/libcodetracer_ruby_recorder', __dir__)
  require ext_base
end

recorder = RubyRecorder.new

puts 'start trace'
recorder.disable_tracing
puts 'this will not be traced'
recorder.enable_tracing
puts 'this will be traced'
recorder.disable_tracing
puts 'tracing disabled'
recorder.flush_trace(Dir.pwd)
