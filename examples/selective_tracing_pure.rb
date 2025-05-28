#!/usr/bin/env ruby

# Load the pure Ruby tracer library if RubyRecorder is not already defined
unless defined?(RubyRecorder)
  lib_base = File.expand_path('../gems/codetracer-pure-ruby-recorder/lib/codetracer_pure_ruby_recorder', __dir__)
  require lib_base
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
