begin
  require 'set'
rescue Exception
  class Set
    def initialize(arr) = @arr = arr
    def to_a = @arr
    def inspect = "#<Set: {#{@arr.join(', ')}}>"
  end
end
begin
  require 'ostruct'
rescue Exception
  OpenStruct = Struct.new(:foo, :bar)
end

Point = Struct.new(:x, :y)

values = [
  1.5,
  {a: 1, b: 2},
  (1..3),
  Set.new([1, 2, 3]),
  Time.at(0).utc,
  /ab/,
  Point.new(5, 6),
  OpenStruct.new(foo: 7, bar: 8)
]

p values
