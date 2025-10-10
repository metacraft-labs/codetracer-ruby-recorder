alias t := test

cargo_build_target_opt := if os_family() == "windows" { "--target x86_64-pc-windows-gnu" } else { "" }

test:
    ruby -Itest test/gem_installation.rb
    ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'

bench pattern="*" write_report="console":
    ruby test/benchmarks/run_benchmarks.rb '{{pattern}}' --write-report={{write_report}}

build-extension:
    cargo build {{ cargo_build_target_opt }} --release --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml
    if [ -d "gems/codetracer-ruby-recorder/ext/native_tracer/target/x86_64-pc-windows-gnu/release" ]; then \
        rm -rf gems/codetracer-ruby-recorder/ext/native_tracer/target/release; \
        cp -r gems/codetracer-ruby-recorder/ext/native_tracer/target/x86_64-pc-windows-gnu/release gems/codetracer-ruby-recorder/ext/native_tracer/target; \
        mv gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.dll gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.so; \
    fi

format-rust:
    cargo fmt --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml

format-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt; fi

format-ruby:
    if command -v bundle >/dev/null && bundle exec rubocop -v >/dev/null 2>&1; then bundle exec rubocop -A; else echo "Ruby formatter not available; skipping"; fi

format:
    just format-rust
    just format-ruby
    just format-nix

lint-rust:
    cargo fmt --check --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml

lint-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt --check; fi

lint-ruby:
    if command -v bundle >/dev/null && bundle exec rubocop -v >/dev/null 2>&1; then bundle exec rubocop; else echo "rubocop not available; skipping"; fi

lint:
    just lint-rust
    just lint-ruby
    just lint-nix

alias fmt := format
