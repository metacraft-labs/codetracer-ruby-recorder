# frozen_string_literal: true
# Control-flow coverage:
#   - if / elsif / else
#   - while / until
#   - case / when
#   - break, next, redo (redo guarded by a counter so it can't loop forever).
# Designed to surface step-ordering and event-count regressions.

def classify(n)
  if n < 0
    'negative'
  elsif n.zero?
    'zero'
  elsif n.odd?
    'odd'
  else
    'even'
  end
end

def collect_until_five
  i = 0
  collected = []
  while i < 10
    i += 1
    next if i.even?
    break if i > 5
    collected << i
  end
  collected
end

def countdown(n)
  result = []
  until n.zero?
    result << n
    n -= 1
  end
  result
end

def dispatch(cmd)
  case cmd
  when :start then 'starting'
  when :stop then 'stopping'
  when 1..3 then 'small-int'
  else 'unknown'
  end
end

# `redo` re-executes the current iteration of the innermost loop without
# re-evaluating the loop guard.  We bound the retry count to make sure the
# program terminates and the trace stays finite.
def retry_each(values)
  retries = 0
  out = []
  values.each do |v|
    if v == :flaky && retries < 1
      retries += 1
      v = :recovered
      redo
    end
    out << v
  end
  out
end

puts classify(-3)
puts classify(0)
puts classify(7)
puts classify(8)
puts collect_until_five.inspect
puts countdown(3).inspect
puts dispatch(:start)
puts dispatch(:other)
puts dispatch(2)
puts retry_each([:ok, :flaky, :done]).inspect
