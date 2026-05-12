# frozen_string_literal: true
# Per-language Ruby coverage extras: ranges, regex, symbols, hashes,
# frozen strings.  Each value type drives at least one observable
# operation so the recorder must encode it in the trace.

range = (1..5)
range_sum = range.reduce(0) { |acc, n| acc + n }

pattern = /\Ahello/
matched = pattern.match?('hello world')

sym = :status
sym_str = sym.to_s

hash = { name: 'ada', age: 36 }
hash_keys = hash.keys.map(&:to_s)

frozen = 'immutable'.freeze
frozen_dup = frozen.dup
frozen_dup << '!' # mutating the dup is fine; the original stays frozen

puts range_sum
puts matched
puts sym_str
puts hash_keys.inspect
puts frozen.frozen?
puts frozen_dup
