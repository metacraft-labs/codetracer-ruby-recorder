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
    # Ensure the expected filename exists as a real file (not an absolute symlink)
    # so that gem build/install works correctly.
    @release_dir="gems/codetracer-ruby-recorder/ext/native_tracer/target/release"; \
    dlext=$(ruby -e 'print RbConfig::CONFIG["DLEXT"]' 2>/dev/null || echo "so"); \
    target="$release_dir/codetracer_ruby_recorder.$dlext"; \
    if [ -L "$target" ]; then \
        real=$(readlink -f "$target"); \
        rm "$target"; \
        cp "$real" "$target"; \
    elif [ ! -f "$target" ]; then \
        src="$release_dir/libcodetracer_ruby_recorder.$dlext"; \
        if [ -f "$src" ]; then cp "$src" "$target"; fi; \
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

# Bump version in version.txt (usage: just bump-version 0.2.0)
bump-version version:
    echo "{{version}}" > version.txt
    @echo "version.txt → {{version}}"
