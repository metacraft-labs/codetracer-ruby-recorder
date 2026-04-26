def compute(n)
  n * 3
end

def transform(value, n)
  value - n
end

def aggregate(history)
  history.max || 0
end
