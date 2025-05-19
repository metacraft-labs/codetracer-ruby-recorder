#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# Simple utility loading the native tracer extension and executing a program.

require 'optparse'
require 'fileutils'
require 'rbconfig'

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
ext_dir = File.expand_path('../ext/native_tracer/target/release', __dir__)
dlext = RbConfig::CONFIG['DLEXT']
target_path = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
unless File.exist?(target_path)
  extensions = %w[so bundle dylib dll]
  alt_path = extensions
             .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
             .find { |path| File.exist?(path) }
  if alt_path
    begin
      File.symlink(alt_path, target_path)
    rescue StandardError
      FileUtils.cp(alt_path, target_path)
    end
  end
end

recorder = nil
begin
  require target_path
  recorder = RubyRecorder.new
  recorder.enable_tracing
rescue Exception => e
  warn "native tracer unavailable: #{e}"
end

program = ARGV.shift
load program
if recorder
  recorder.disable_tracing
  recorder.flush_trace(out_dir)
end

