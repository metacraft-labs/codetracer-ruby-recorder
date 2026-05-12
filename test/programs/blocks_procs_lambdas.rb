# frozen_string_literal: true
# Blocks, Procs, and Lambdas.
# Highlights the semantic differences between the three:
#   - blocks via `yield` and `&block`
#   - Proc.new — `return` inside a Proc returns from the enclosing method
#   - lambda  — `return` inside a lambda only returns from the lambda
#   - arity strictness differs (lambda is strict, proc is permissive)
#
# RECORDER BUG: the pure and native recorders disagree on how a Proc
# value is serialised (pure → Struct{}, native → Raw with `to_s` text
# including the object's memory address).  The native semantic-match
# half of `test_blocks_procs_lambdas` is therefore skipped — see the
# `NATIVE_SEMANTIC_SKIP` table in `test/test_tracer.rb`.  The pure
# recorder still asserts the full strict snapshot, so any change in
# pure behaviour (event count, ordering, value content) is caught.

def with_yield
  result = []
  [1, 2, 3].each do |x|
    result << yield(x)
  end
  result
end

def with_block_param(&block)
  block.call(10) + block.call(20)
end

def proc_return_demo
  p = Proc.new { return 42 }
  p.call
  # Unreachable: a Proc-style `return` returns from `proc_return_demo`.
  -1
end

def lambda_return_demo
  l = ->(x) { return x * 2 }
  inner = l.call(5)
  inner + 1 # reachable: lambda return only exits the lambda
end

def arity_demo
  p = Proc.new { |a, b| [a, b] }
  l = ->(a, b) { [a, b] }
  proc_result = p.call(1, 2, 3) # extra arg silently dropped
  begin
    l.call(1, 2, 3)
    lambda_result = 'no-error'
  rescue ArgumentError => e
    lambda_result = e.message
  end
  [proc_result, lambda_result]
end

puts with_yield { |n| n * n }.inspect
puts(with_block_param { |n| n + 1 })
puts proc_return_demo
puts lambda_return_demo
puts arity_demo.inspect
