#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# Simple utility loading the native tracer extension and executing a program.

if ARGV.empty?
  $stderr.puts("usage: ruby native_trace.rb <program> [args]")
  exit 1
end

# Path to the compiled native extension
ext_path = File.expand_path('../ext/native_tracer/target/release/libcodetracer_ruby_recorder', __dir__)
require ext_path

program = ARGV.shift
load program

