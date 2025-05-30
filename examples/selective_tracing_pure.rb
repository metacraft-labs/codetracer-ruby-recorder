#!/usr/bin/env ruby

lib_base = File.expand_path('../gems/codetracer-pure-ruby-recorder/lib/codetracer_pure_ruby_recorder', __dir__)
require lib_base

recorder = CodeTracer::PureRubyRecorder.new

puts 'start trace'
recorder.stop
puts 'this will not be traced'
recorder.start
recorder.stop
puts 'tracing disabled'
recorder.flush_trace(Dir.pwd)
