alias t := test

cargo_build_target_opt := if os_family() == "windows" { "--target x86_64-pc-windows-gnu" } else { "" }

# Primary build target — required by Repo-Requirements.md §1.3 and
# §2.4. Builds the native extension via `build-extension`; the
# packaged gem is produced separately by `build-gem`.
build: build-extension

test: ensure-ct-print
    ruby -Itest test/gem_installation.rb
    ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'
    just verify-cli-convention

ensure-ct-print:
    @if ! command -v ct-print >/dev/null 2>&1 && [ ! -x ../codetracer-trace-format-nim/ct-print ]; then \
        cd ../codetracer-trace-format-nim && nimble buildCtPrint -y; \
    fi

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

# --- RS-M6: Request Panel demo and fixture --------------------------------
# `codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`

# Record the Ruby web demo app under the recorder and open the recorded
# session in the CodeTracer GUI with its Request Panel populated.
#
# This is the Ruby row of the `just demo-request-panel <lang>` convention
# established by codetracer's RS-M4 recipe.  The container-production half
# lives here (only this repo can record Ruby); the GUI half is codetracer's, so
# `direnv exec ../codetracer just demo-request-panel ruby` calls back into this
# recipe with `CODETRACER_DEMO_DIR` set and then opens the result.
#
# What is real: a real Sinatra (or Rails) app served over real HTTP by a real
# recorded process, and real `web-request` span records in the container's
# `spans.dat` (meta.dat bit 13, set by the writer because spans were
# registered).  Nothing is synthesised — that was RS-M4's demo, which this
# replaces for Ruby.
#
# FRAMEWORK selects the demo app: sinatra (default) or rails.
demo-request-panel-ruby FRAMEWORK="sinatra":
    #!/usr/bin/env bash
    set -euo pipefail
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-ruby}"
    echo "=== RS-M6 Request Panel demo — ruby/{{FRAMEWORK}} ==="
    just build-extension
    rm -rf "$demo_dir"
    mkdir -p "$demo_dir"
    ruby test-programs/web/session_driver.rb \
        --framework {{FRAMEWORK}} --trace-dir "$demo_dir" --print-spans
    echo "[demo] recorded session in $demo_dir"
    if [ -n "${CODETRACER_DEMO_RECORD_ONLY:-}" ]; then
      # Invoked as the container-production half of codetracer's
      # `just demo-request-panel ruby`, which opens the GUI itself.
      exit 0
    fi
    if command -v ct >/dev/null 2>&1; then
      echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
      echo "[demo] first delta arrives (bottom edge strip if you close it)."
      exec ct replay -t "$demo_dir"
    fi
    echo "[demo] no 'ct' on PATH — open it by hand with:"
    echo "         ct replay -t $demo_dir"
    echo "[demo] (or run this through codetracer's recipe, which supplies ct:"
    echo "         direnv exec ../codetracer just demo-request-panel ruby)"

# Regenerate the committed Ruby request-panel fixture consumed by codetracer's
# `vm_ruby_request_panel_rows` ViewModel test.
#
# OUT is a directory in the codetracer checkout; the recorded trace folder (the
# `.ct` container plus the recorded app sources) is written there.  Run this
# whenever the demo app or the span metadata changes, then commit the result in
# codetracer — the fixture is checked in so the ViewModel test needs no Ruby
# toolchain.
record-request-panel-fixture OUT FRAMEWORK="sinatra":
    #!/usr/bin/env bash
    set -euo pipefail
    just build-extension
    rm -rf "{{OUT}}"
    mkdir -p "{{OUT}}"
    ruby test-programs/web/session_driver.rb \
        --framework {{FRAMEWORK}} --trace-dir "{{OUT}}" --print-spans
    # The bundled sources are keyed by the recording machine's ABSOLUTE paths,
    # so they are pure churn in a checked-in fixture and the ViewModel test
    # reads only the container.  `demo-request-panel-ruby` keeps them, because
    # opening that session in the GUI does want the code.
    rm -rf "{{OUT}}/meta_dat"
    echo "[fixture] wrote {{OUT}}"
