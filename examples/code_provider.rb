#!/usr/bin/env ruby

# Output a Ruby code snippet based on the provided identifier.
# This simulates retrieving code from another program at runtime.

snippet = ARGV.shift.to_s

code = case snippet
when '1'
  "puts 'Hello from snippet 1'"
when '2'
  "msg = 'hello from snippet 2'; puts msg.upcase"
when '3'
  "5.times { |i| print i }; puts"
when '4'
  "class DynamicClass; def self.greet; puts 'greet from snippet 4'; end; end; DynamicClass.greet"
else
  "puts 'Default snippet'"
end

puts code

