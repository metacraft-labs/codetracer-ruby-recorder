#!/usr/bin/env ruby

ext_base = File.expand_path('../gems/codetracer-ruby-recorder/ext/native_tracer/target/release/libcodetracer_ruby_recorder', __dir__)
require ext_base

recorder = CodeTracer::RubyRecorder.new

puts 'start trace'
recorder.disable_tracing
puts 'this will not be traced'
recorder.enable_tracing
puts 'this will be traced'
recorder.disable_tracing
puts 'tracing disabled'
recorder.flush_trace(Dir.pwd)
