#!/usr/bin/env ruby

ext_base = File.expand_path('../gems/codetracer-ruby-recorder/lib', __dir__)
$LOAD_PATH.unshift(ext_base) unless $LOAD_PATH.include?(ext_base)
require 'codetracer_ruby_recorder'

recorder = CodeTracer::RubyRecorder.new

puts 'start trace'
recorder.stop
puts 'this will not be traced'
recorder.start
puts 'this will be traced'
recorder.stop
puts 'tracing disabled'
recorder.flush_trace(Dir.pwd)
