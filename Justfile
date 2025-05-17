alias t := test

test:
    ruby -Itest test/test_tracer.rb

bench name="heavy_work":
    ruby test/benchmarks/run_benchmark.rb {{name}}
