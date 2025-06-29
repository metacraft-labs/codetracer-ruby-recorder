#!/usr/bin/env ruby

# Build a simple graph of objects with a reference cycle.
class Node
  attr_accessor :name, :neighbors

  def initialize(name)
    @name = name
    @neighbors = []
  end
end

a = Node.new('A')
b = Node.new('B')
c = Node.new('C')

a.neighbors << b
b.neighbors << c
c.neighbors << a

puts 'Reference cycle created: A -> B -> C -> A'
puts "A neighbors: #{a.neighbors.map(&:name).join(', ')}"
puts "B neighbors: #{b.neighbors.map(&:name).join(', ')}"
puts "C neighbors: #{c.neighbors.map(&:name).join(', ')}"

