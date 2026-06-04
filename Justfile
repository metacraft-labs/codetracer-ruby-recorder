alias t := test

cargo_build_target_opt := if os_family() == "windows" { "--target x86_64-pc-windows-gnu" } else { "" }

test:
    ruby -Itest test/gem_installation.rb
    ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'
    just verify-cli-convention

# Verify the recorder CLI complies with `Recorder-CLI-Conventions.md`.
# See tests/verify-cli-convention-no-silent-skip.sh for the assertion list.
verify-cli-convention:
    bash tests/verify-cli-convention-no-silent-skip.sh

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
    just verify-cli-convention

alias fmt := format

# Bump version in version.txt (usage: just bump-version 0.2.0, or patch/minor/major)
bump-version version:
    #!/usr/bin/env python3
    import pathlib, re
    raw = "{{version}}"
    cur_file = pathlib.Path("version.txt")
    cur = cur_file.read_text().strip() if cur_file.exists() else "0.1.0"
    if re.match(r"^\d+\.\d+\.\d+$", raw):
        new = raw
    else:
        a, b, p = map(int, cur.split("."))
        if raw == "major": new = f"{a+1}.0.0"
        elif raw == "minor": new = f"{a}.{b+1}.0"
        elif raw == "patch": new = f"{a}.{b}.{p+1}"
        else: raise SystemExit(f"unknown bump component: {raw!r}")
    cur_file.write_text(new + "\n")
    print(f"version.txt: {cur} -> {new}")

# --- M13: Packaging UX Standardization ---
# Implements Repo-Requirements.md §2.8 packaging UX for the Ruby
# language-ecosystem recorder. Single channel: rubygems.

# Build a release artifact for the given channel.
# Supported channels: rubygems
build-package channel:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{channel}}" in
        rubygems)
            just build-extension
            cd gems/codetracer-ruby-recorder && gem build *.gemspec
            ;;
        *)
            echo "::error::unknown channel '{{channel}}'. Ruby recorder only supports 'rubygems'." >&2
            exit 1
            ;;
    esac

# Verify the artifact produced by `build-package <channel>`.
verify-package channel:
    #!/usr/bin/env python3
    import os, shutil, subprocess, sys
    from pathlib import Path
    ch = "{{channel}}"
    strict = os.environ.get("CT_VERIFY_STRICT") == "1"
    if ch != "rubygems":
        print(f"::error::unknown channel {ch!r}; Ruby recorder only supports 'rubygems'")
        sys.exit(1)
    gem_dir = Path("gems/codetracer-ruby-recorder")
    gems = list(gem_dir.glob("*.gem"))
    if not gems:
        print(f"[verify] no .gem in {gem_dir} — run `just build-package rubygems` first")
        sys.exit(0 if not strict else 1)
    if shutil.which("gem"):
        for g in gems:
            subprocess.run(["gem", "specification", str(g)], check=True, capture_output=True)
            print(f"[verify] gem {g.name} OK")
    else:
        if strict:
            print("::error::gem required in strict mode"); sys.exit(1)
        print("[verify] SKIP: gem not on PATH")

# Per-channel shortcut.
build-gem:
    just build-package rubygems

verify-gem:
    just verify-package rubygems
