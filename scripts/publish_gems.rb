#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rubygems'

def gem_version(path)
  Gem::Specification.load(path).version.to_s
end

def ensure_tag_matches_version
  tag = ENV['GITHUB_REF_NAME'] || ENV['RELEASE_TAG'] || `git describe --tags --exact-match`.strip
  tag = tag.sub(/^v/, '')

  version = File.read(File.expand_path('../version.txt', __dir__)).strip

  unless tag == version
    abort("Tag #{tag} does not match gem version #{version}")
  end
end

ensure_tag_matches_version

def load_targets
  return ARGV unless ARGV.empty?

  config_path = File.join(__dir__, 'targets.txt')
  unless File.exist?(config_path)
    abort("No targets specified and #{config_path} is missing")
  end

  File.readlines(config_path, chomp: true)
      .map { |l| l.strip }
      .reject { |l| l.empty? || l.start_with?('#') }
end

TARGETS = load_targets.freeze

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

# Build and publish fallback gem for generic Ruby platform
run('rake build')
generic_gem = Dir['pkg/codetracer-ruby-recorder-*.gem'].max_by { |f| File.mtime(f) }
run("gem push #{generic_gem}")
FileUtils.rm_f(generic_gem)

# Build and publish pure Ruby gem
run('gem build gems/codetracer-pure-ruby-recorder/codetracer_pure_ruby_recorder.gemspec')
pure_gem = Dir['codetracer_pure_ruby_recorder-*.gem'].max_by { |f| File.mtime(f) }
run("gem push #{pure_gem}")
FileUtils.rm_f(pure_gem)
