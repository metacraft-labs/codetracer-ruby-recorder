#!/usr/bin/env ruby

# Demonstrate various ways of executing Ruby code obtained from another program.
# The code snippet is produced by `code_provider.rb` based on a command-line
# argument.

require 'rbconfig'
require 'tempfile'

snippet_id = ARGV.shift || '1'
provider = File.expand_path('code_provider.rb', __dir__)
code = `#{RbConfig.ruby} #{provider} #{snippet_id}`

puts "Retrieved code:\n#{code}"

puts '\n[Kernel.eval]'
eval(code)

puts '\n[Binding#eval]'
binding.eval(code)

puts '\n[Object#instance_eval]'
Object.new.instance_eval(code)

puts '\n[Class#class_eval]'
Class.new.class_eval(code)

puts '\n[load from file]'
Tempfile.create(['snippet', '.rb']) do |f|
  f.write(code)
  f.flush
  load f.path
end

