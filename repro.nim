## Reprobuild dev env + build recipe for codetracer-ruby-recorder.
##
## Ships a Ruby gem whose native extension is implemented in Rust +
## Magnus and built through cargo. The recipe expresses the cargo
## build + test edges natively per
## ``codetracer-specs/Repo-Requirements.md`` §2.8 — no
## ``shell(command = "bash scripts/...")`` delegations.
##
## Provisioning note (MR2): ``packages/ruby.nim`` now declares a
## rubyinstaller2 3.3.5-1 tarball entry for Windows alongside the
## existing ``nixpkgs#ruby`` entry. The recipe therefore drops
## ``defaultToolProvisioning "path"`` and relies on the engine's own
## provisioning end-to-end. rb-sys's bindgen step still resolves Ruby
## headers through ``ruby --vendor-include`` against the materialised
## prefix; the rubyinstaller archive ships ``include/`` and
## ``msys64/``-vendored libclang at the same prefix root.

import repro_project_dsl

package codetracer_ruby_recorder:
  uses:
    "rustc >=1.85"
    "cargo >=1.85"
    "ruby >=3.1"
    "nim >=2.2 <3.0"
    "nimble"
    "capnp"
    "zstd"
    when not defined(windows):
      "pkg-config"
      "openssl"

  library codetracerRubyRecorder

  devEnv:
    activity "default"

  build:
    # ---- Native cargo build of the Magnus extension ------------------
    #
    # The shared-library output's filename depends on the host
    # platform — Linux `.so`, macOS `.dylib`, Windows `.dll`. The
    # existing `just build-extension` recipe renames the Windows
    # `.dll` to `.so` so Ruby's dlopen sees the expected name; that
    # rename happens at gem-packing time, not in the cargo edge. The
    # cargo edge here produces the platform-native artefact.
    const dylibExt =
      when defined(windows): "dll"
      elif defined(macosx): "dylib"
      else: "so"
    const extensionBinary =
      "gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder." &
      dylibExt
    const manifestPath =
      "gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml"

    let extensionBuild = cargo.build(
      release = true,
      manifestPath = manifestPath,
      actionId = "codetracer-ruby-recorder.cargo-build",
      extraInputs = @[
        manifestPath,
        "gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.lock",
        "gems/codetracer-ruby-recorder/ext/native_tracer/src"
      ],
      extraOutputs = @[extensionBinary])
    discard collect("default", @[extensionBuild])

    # ---- Rust-side cargo tests ---------------------------------------
    let cargoTestsBuild = cargo.test(
      noRun = true,
      manifestPath = manifestPath,
      actionId = "codetracer-ruby-recorder.cargo-test-build",
      extraInputs = @[
        manifestPath,
        "gems/codetracer-ruby-recorder/ext/native_tracer/src"
      ],
      extraOutputs = @[
        "gems/codetracer-ruby-recorder/ext/native_tracer/target/debug/deps"
      ])

    let cargoTestsRun = cargo.test(
      manifestPath = manifestPath,
      actionId = "codetracer-ruby-recorder.cargo-test-run",
      after = @[cargoTestsBuild.action],
      extraInputs = @[
        manifestPath,
        "gems/codetracer-ruby-recorder/ext/native_tracer/src",
        "gems/codetracer-ruby-recorder/ext/native_tracer/target/debug/deps"
      ])

    # Collection name deviation: this recorder's repo root has a
    # ``test/`` directory (Ruby's MiniTest convention) that shadows
    # ``repro build test`` — the positional ``test`` arg resolves
    # to the directory path before the collection name, so the
    # canonical Repo-Requirements §2.8 name is unusable here. We
    # ship the alias ``cargo-test`` instead; invoke as
    # ``repro build cargo-test``.
    discard collect("cargo-test", @[cargoTestsRun.action])
