# frozen_string_literal: true
# Nested + recursive function calls.
# - 3-deep nested call chain (outer -> middle -> inner).
# - Recursive factorial (call/return ordering must be exact).
# - Mutual recursion (is_even / is_odd).

def inner(value)
  value * 2
end

def middle(value)
  inner(value) + 1
end

def outer(value)
  middle(value) + 100
end

def factorial(n)
  return 1 if n <= 1

  n * factorial(n - 1)
end

def is_even(n)
  return true if n.zero?

  is_odd(n - 1)
end

def is_odd(n)
  return false if n.zero?

  is_even(n - 1)
end

puts outer(3)
puts factorial(5)
puts is_even(4)
puts is_odd(4)
