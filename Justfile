alias t := test

test:
    ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'

bench pattern="*" write_report="console":
    ruby test/benchmarks/run_benchmarks.rb '{{pattern}}' --write-report={{write_report}}

build-extension:
    cargo build --release --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml
