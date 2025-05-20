alias t := test

test:
    ruby -Itest test/test_tracer.rb

bench name="heavy_work" write_report="console":
    ruby test/benchmarks/run_benchmark.rb {{name}} --write-report={{write_report}}

build-extension:
    cargo build --release --manifest-path gems/native-tracer/ext/native_tracer/Cargo.toml
