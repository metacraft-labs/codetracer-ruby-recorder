#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

TARGETS = [
  'x86_64-unknown-linux-gnu',
  'aarch64-unknown-linux-gnu',
  'x86_64-apple-darwin',
  'aarch64-apple-darwin',
  'x86_64-pc-windows-msvc'
].freeze


def run(cmd, env = {})
  command = env.map { |k, v| "#{k}=#{v}" }.join(' ')
  command = [command, cmd].reject(&:empty?).join(' ')
  puts "$ #{command}"
  system(env, *cmd.split(' ')) || abort("Command failed: #{command}")
end

# Build and publish native extension gems
TARGETS.each do |target|
  run('rake cross_native_gem', 'RB_SYS_CARGO_TARGET' => target)
  gem_file = Dir['pkg/codetracer-ruby-recorder-*.gem'].max_by { |f| File.mtime(f) }
  run("gem push #{gem_file}")
  FileUtils.rm_f(gem_file)
end

# Build and publish pure Ruby gem
run('gem build gems/pure-ruby-tracer/codetracer_pure_ruby_recorder.gemspec')
pure_gem = Dir['codetracer_pure_ruby_recorder-*.gem'].max_by { |f| File.mtime(f) }
run("gem push #{pure_gem}")
FileUtils.rm_f(pure_gem)
