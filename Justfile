alias t := test

test:
    ruby -Itest test/test_tracer.rb

bench pattern="*" write_report="console":
    ruby test/benchmarks/run_benchmarks.rb '{{pattern}}' --write-report={{write_report}}

build-extension:
    cargo build --release --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml
