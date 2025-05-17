def prime?(n)
  return false if n < 2
  (2..Math.sqrt(n).floor).each do |i|
    return false if n % i == 0
  end
  true
end

def primes(n)
  arr = []
  i = 2
  while arr.length < n
    arr << i if prime?(i)
    i += 1
  end
  arr
end

def compute
  arr = primes(100)
  hash = arr.each_with_index.to_h
  sum = arr.reduce(:+)
  str = arr.map(&:to_s).join(',')
  [sum, str, hash[arr.size]]
end

compute
