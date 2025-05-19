#!/usr/bin/env ruby

def sum_args(args)
  args.map(&:to_i).reduce(0, :+)
end

puts sum_args(ARGV)

