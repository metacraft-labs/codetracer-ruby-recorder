# frozen_string_literal: true
# Classes + modules: per-language Ruby checklist coverage.
#   - class with initialize / instance methods / instance vars
#   - inheritance + `super`
#   - class methods + class instance variables
#   - attr_accessor
#   - module mixin (include) with shared instance method

module Greeting
  def greet
    "hello, #{name}"
  end
end

class Animal
  include Greeting

  attr_accessor :name, :legs

  @@population = 0

  def self.population
    @@population
  end

  def initialize(name, legs)
    @name = name
    @legs = legs
    @@population += 1
  end

  def describe
    "#{@name} has #{@legs} legs"
  end

  # Override `to_s` so the recorder's `self` rendering (which calls
  # `tp.self.to_s` in the pure recorder) is deterministic across runs.
  # Without this, instances render as `#<Animal:0x[address]>` and the
  # address changes every run — defeating fixture comparison.
  def to_s
    "#<Animal #{@name}>"
  end
end

class Dog < Animal
  def initialize(name)
    super(name, 4)
  end

  def describe
    "#{super} and barks"
  end

  def to_s
    "#<Dog #{@name}>"
  end
end

a = Animal.new('cat', 4)
d = Dog.new('rex')

puts a.describe
puts d.describe
puts a.greet
puts d.greet
puts Animal.population
