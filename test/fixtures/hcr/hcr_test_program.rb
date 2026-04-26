require 'fileutils'

dir = File.dirname(File.expand_path(__FILE__))
load File.join(dir, 'mymodule.rb')

counter = 0
history = []

12.times do
  counter += 1
  if counter == 7
    FileUtils.cp(File.join(dir, 'mymodule_v2.rb'), File.join(dir, 'mymodule.rb'))
    load File.join(dir, 'mymodule.rb')
    $stdout.puts "RELOAD_APPLIED"
    $stdout.flush
  end
  value = compute(counter)
  delta = transform(value, counter)
  history << delta
  total = aggregate(history)
  $stdout.puts "step=#{counter} value=#{value} delta=#{delta} total=#{total}"
  $stdout.flush
end
