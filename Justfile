alias t := test

test:
    ruby -Itest test/test_tracer.rb

bench name="heavy_work":
    ruby test/benchmarks/run_benchmark.rb {{name}}

build-extension:
    cargo build --release --manifest-path ext/native_tracer/Cargo.toml
