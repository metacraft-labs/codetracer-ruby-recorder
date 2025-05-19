#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# Simple utility loading the native tracer extension and executing a program.

require 'optparse'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "usage: ruby native_trace.rb [options] <program> [args]"
  opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') do |dir|
    options[:out_dir] = dir
  end
  opts.on('-h', '--help', 'Print this help') do
    puts opts
    exit
  end
end
parser.order!

if ARGV.empty?
  $stderr.puts parser
  exit 1
end

out_dir = options[:out_dir] || ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] || Dir.pwd
ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] = out_dir

# Path to the compiled native extension
ext_path = File.expand_path('../ext/native_tracer/target/release/libcodetracer_ruby_recorder', __dir__)
require ext_path

program = ARGV.shift
load program

