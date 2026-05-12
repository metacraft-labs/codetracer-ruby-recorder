# frozen_string_literal: true
# Exception handling:
#   - raise with custom message
#   - rescue by class hierarchy (specific first, generic later)
#   - ensure block always runs
#   - retry until a counter is exhausted
#   - re-raise / propagate to outer rescue handler

class AppError < StandardError; end
class NotFoundError < AppError; end

def lookup(name)
  raise NotFoundError, "no entry for #{name}" if name == 'missing'

  "found:#{name}"
end

def with_ensure(name)
  ensure_log = []
  begin
    result = lookup(name)
    ensure_log << 'ok'
    result
  rescue NotFoundError => e
    ensure_log << "rescued:#{e.message}"
    'fallback'
  ensure
    ensure_log << 'ensure'
    puts ensure_log.join('|')
  end
end

def retrying
  attempts = 0
  begin
    attempts += 1
    raise 'transient' if attempts < 3

    "ok after #{attempts}"
  rescue StandardError
    retry if attempts < 3
    'giving up'
  end
end

def propagate
  raise AppError, 'inner'
rescue NotFoundError
  # Specific handler does NOT match AppError -> propagates.
  'wrong handler'
end

puts with_ensure('alice')
puts with_ensure('missing')
puts retrying

# Outer rescue absorbs the propagated AppError so the program completes.
begin
  puts propagate
rescue AppError => e
  puts "outer caught: #{e.message}"
end
