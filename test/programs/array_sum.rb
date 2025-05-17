def sum(arr)
  total = 0
  arr.each do |n|
    total += n
  end
  total
end

puts sum([1, 2, 3])
