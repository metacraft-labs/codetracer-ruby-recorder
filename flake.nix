{
  description = "Development environment for codetracer-ruby-recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/dev";
      flake = false;
    };
    # codetracer_trace_writer_nim's build.rs reads the FFI entry
    # point from this sibling repo and compiles it to a static lib
    # at cargo build time.  Without the source the build aborts with
    # "Nim FFI entry point not found".
    codetracer-trace-format-nim = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/dev";
      flake = false;
    };
    # Nim packages the Nim FFI library declares as ``requires`` in its
    # .nimble.  Resolve them via flake inputs (no network access
    # inside the Nix sandbox) and pass their paths through
    # CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS.
    nim-stew = {
      url = "github:status-im/nim-stew/master";
      flake = false;
    };
    nim-results = {
      url = "github:arnetheduck/nim-results/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, fenix, pre-commit-hooks, codetracer-trace-format
    , codetracer-trace-format-nim, nim-stew, nim-results, }:
    let
      systems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      rust-toolchain-for = system:
        fenix.packages.${system}.fromToolchainFile {
          file = ./rust-toolchain.toml;
          sha256 = "sha256-Qxt8XAuaUR2OMdKbN4u8dBJOhSHxS+uS06Wl9+flVEk=";
        };

      # Helper function to build the native Ruby recorder for a given pkgs and Ruby.
      # Consumers can call this with their own nixpkgs and Ruby version to ensure
      # ABI compatibility (the native .so must match the Ruby that loads it).
      mkRubyRecorderPackage = pkgs: ruby:
        let
          inherit (pkgs) stdenv lib;
          isLinux = stdenv.isLinux;
        in stdenv.mkDerivation {
          pname = "ruby-recorder-native";
          version = builtins.readFile ./version.txt;

          src = ./.;

          nativeBuildInputs = [
            pkgs.rustc
            pkgs.cargo
            pkgs.rustPlatform.cargoSetupHook
            ruby # build.rs runs `ruby` to discover RbConfig paths
            pkgs.pkg-config
            pkgs.capnproto # codetracer_trace_format_capnp build.rs needs capnp
            pkgs.llvmPackages.libclang # bindgen (used by rb-sys) needs libclang
            # codetracer_trace_writer_nim/build.rs compiles the Nim FFI
            # static lib at cargo build time -- without Nim on PATH the
            # build fails with "could not find native static library
            # codetracer_trace_writer".
            pkgs.nim
            pkgs.nimble
          ] ++ lib.optionals stdenv.isDarwin [ pkgs.libiconv ];

          buildInputs = [ ruby ];

          # codetracer_trace_writer_nim/build.rs needs the Nim FFI
          # source on disk + ``stew`` / ``results`` Nim packages on the
          # Nim path.  ``nimble install`` would need network access,
          # so skip it and feed the sources directly.
          CODETRACER_TRACE_FORMAT_NIM_DIR = "${codetracer-trace-format-nim}";
          CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";
          CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS =
            "${nim-stew}:${nim-results}";

          # bindgen needs LIBCLANG_PATH to find libclang.so
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          # bindgen also needs C standard headers (stdio.h, stddef.h, etc.)
          BINDGEN_EXTRA_CLANG_ARGS = lib.optionalString isLinux
            (builtins.concatStringsSep " " [
              "-isystem ${stdenv.cc.libc.dev}/include"
              "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${
                lib.versions.major pkgs.llvmPackages.libclang.version
              }/include"
            ]);

          cargoDeps = pkgs.rustPlatform.importCargoLock {
            lockFile =
              ./gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.lock;
          };

          postUnpack = ''
            # cargoSetupHook expects Cargo.lock at the source root
            cp $sourceRoot/gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.lock \
               $sourceRoot/Cargo.lock

            # Place the sibling trace-format repo where Cargo.toml path deps expect it
            # (five levels up from gems/codetracer-ruby-recorder/ext/native_tracer/)
            ln -s ${codetracer-trace-format} $sourceRoot/../codetracer-trace-format
          '';

          preBuild = ''
            cd gems/codetracer-ruby-recorder/ext/native_tracer
          '';

          buildPhase = ''
            runHook preBuild
            cargo build --release --offline
            runHook postBuild
          '';

          installPhase = ''
            GEM_ROOT="$NIX_BUILD_TOP/$sourceRoot/gems/codetracer-ruby-recorder"

            # Preserve gems/ path component — the native recorder's should_ignore_path()
            # in Rust uses "gems/" as an ignore pattern to avoid tracing kernel_patches.rb.
            mkdir -p $out/gems/bin $out/gems/lib/codetracer $out/gems/ext/native_tracer/target/release

            # Copy compiled .so (Rust cdylib produces lib<name>.so on Linux, lib<name>.dylib on macOS)
            local dlext="${if isLinux then "so" else "dylib"}"
            cp target/release/libcodetracer_ruby_recorder.$dlext \
               $out/gems/ext/native_tracer/target/release/
            # Create the name the Ruby wrapper expects (codetracer_ruby_recorder.<dlext>)
            ln -s libcodetracer_ruby_recorder.$dlext \
               $out/gems/ext/native_tracer/target/release/codetracer_ruby_recorder.$dlext

            # Copy Ruby wrapper files
            cp "$GEM_ROOT/lib/codetracer_ruby_recorder.rb" $out/gems/lib/
            cp "$GEM_ROOT/lib/codetracer/kernel_patches.rb" $out/gems/lib/codetracer/
            # RS-M6: the span-emission facade the Rack middleware talks to.
            cp "$GEM_ROOT/lib/codetracer/native.rb" $out/gems/lib/codetracer/

            # Copy bin entry script
            cp "$GEM_ROOT/bin/codetracer-ruby-recorder" $out/gems/bin/

            # Top-level bin/ symlink so consumers' symlinkJoin picks it up
            mkdir -p $out/bin
            ln -s $out/gems/bin/codetracer-ruby-recorder $out/bin/codetracer-ruby-recorder
          '';

          doCheck = false;
        };
    in {
      # Expose the helper function for consumers who need a custom Ruby version
      lib.mkRubyRecorderPackage = mkRubyRecorderPackage;

      checks = forEachSystem (system: {
        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            lint = {
              enable = true;
              name = "Lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
          };
        };
      });

      devShells = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          preCommit = self.checks.${system}.pre-commit-check;
          isLinux = pkgs.stdenv.isLinux;
          isDarwin = pkgs.stdenv.isDarwin;
          rubyWithTestGems = pkgs.ruby_3_4.withPackages (ps: [
            ps.minitest
            ps.rack
            # RS-M6 (`codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`)
            # requires the Rack middleware's request spans to be verified
            # against REAL framework apps — `test/test_request_spans.rb` and the
            # demo apps in `test-programs/web/{sinatra,rails}/`.  Sinatra and
            # Rails supply the two route sources the milestone cares about:
            # `env['sinatra.route']` and Rails'
            # `env['action_dispatch.route_uri_pattern']`, which is what makes
            # `http.route` a routed PATTERN rather than the raw path.
            ps.sinatra
            ps.rails
          ]);
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/this-repo` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            fi
            unset _own_repo_root
          '';
        in {
          default = pkgs.mkShell {
            packages = with pkgs;
              [
                # WARNING: `3.4` needed in `./gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`
                #          for the `thread` field of `rb_internal_thread_event_data_t`
                rubyWithTestGems

                # The native extension is implemented in Rust
                (rust-toolchain-for system)
                libiconv # Required dependency when building the rb-sys Rust crate on macOS and some Linux systems

                # Required for bindgen (used by rb-sys crate for generating Ruby C API bindings)
                # Without these, build fails with "Unable to find libclang" error
                libclang # Provides libclang library that bindgen requires
                llvmPackages.clang # Clang compiler used by bindgen for parsing C headers
                pkg-config # Used by build scripts to find library paths

                # For build automation
                just
                prek
                git-lfs

                capnproto # Required for the native tracer's Cap'n Proto serialization
                zstd # Required for linking the Nim trace writer (libzstd)

                # codetracer_trace_writer_nim/build.rs invokes nim+nimble
                # to compile the FFI sources into a static library.
                nim
                nimble
              ] ++ pkgs.lib.optionals isLinux [
                # C standard library headers required for Ruby C extension compilation on Linux
                # Without this, build fails with "stdarg.h file not found" error
                glibc.dev
              ] ++ preCommit.enabledPackages;

            # Environment variables required to fix build issues with rb-sys/bindgen

            # LIBCLANG_PATH: Required by bindgen to locate libclang shared library
            # Without this, bindgen fails with "couldn't find any valid shared libraries" error
            LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

            # Compiler environment variables to ensure consistent toolchain usage
            # These help rb-sys and other build scripts use the correct clang installation
            CLANG_PATH = "${pkgs.llvmPackages.clang}/bin/clang";
            CC = "${pkgs.llvmPackages.clang}/bin/clang";
            CXX = "${pkgs.llvmPackages.clang}/bin/clang++";

            # `cargo <subcommand>` looks for `cargo-<subcommand>` in
            # `$CARGO_HOME/bin` BEFORE it searches PATH. On any machine with
            # rustup -- including the self-hosted macOS runner -- that
            # directory holds rustup's proxies, so `cargo fmt` runs rustup's
            # `cargo-fmt` instead of the toolchain above and fails with
            # "'cargo-fmt' is not installed for the toolchain" (or formats
            # with a different rustfmt than this shell's).
            #
            # The shell therefore gets its own CARGO_HOME with no `bin/`, so
            # subcommand lookup falls through to PATH. `registry/` and `git/`
            # are symlinks to the real CARGO_HOME, and so are its config and
            # credentials when present: the download cache is shared, and
            # only the proxy directory is left behind.
            shellHook = ''
              _ct_real_cargo_home="''${CARGO_HOME:-$HOME/.cargo}"
              _ct_cargo_home="''${XDG_CACHE_HOME:-$HOME/.cache}/codetracer-ruby-recorder/cargo-home"
              if [ "$_ct_real_cargo_home" != "$_ct_cargo_home" ]; then
                mkdir -p "$_ct_cargo_home" \
                  "$_ct_real_cargo_home/registry" "$_ct_real_cargo_home/git"
                # Re-pointed on every entry, so a changed CARGO_HOME is
                # followed rather than left sharing the previous one's cache.
                # Only a link is ever replaced; a real file placed here is
                # left alone.
                for _ct_entry in registry git config.toml credentials.toml; do
                  if [ -e "$_ct_real_cargo_home/$_ct_entry" ] &&
                    { [ -L "$_ct_cargo_home/$_ct_entry" ] ||
                      [ ! -e "$_ct_cargo_home/$_ct_entry" ]; }; then
                    ln -sfn "$_ct_real_cargo_home/$_ct_entry" "$_ct_cargo_home/$_ct_entry"
                  fi
                done
                export CARGO_HOME="$_ct_cargo_home"
              fi
              unset _ct_real_cargo_home _ct_cargo_home _ct_entry

              ${ownRepoOnly preCommit.shellHook}
            '';
          } // pkgs.lib.optionalAttrs isLinux {
            # BINDGEN_EXTRA_CLANG_ARGS: Additional clang arguments for bindgen when parsing Ruby headers
            # Includes system header paths that are not automatically discovered in NixOS
            # --sysroot ensures clang can find standard C library headers like stdarg.h
            BINDGEN_EXTRA_CLANG_ARGS = with pkgs;
              builtins.concatStringsSep " " [
                "-I${libclang.lib}/lib/clang/${libclang.version}/include" # Clang builtin headers
                "-I${glibc.dev}/include" # System C headers
                "--sysroot=${glibc.dev}" # System root for header resolution
              ];
          };
        });

      packages = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          ruby = pkgs.ruby;
        in {
          # Native Rust extension-based recorder (default)
          codetracer-ruby-recorder = mkRubyRecorderPackage pkgs ruby;
          default = self.packages.${system}.codetracer-ruby-recorder;

          # Pure Ruby recorder (fallback, no compilation needed)
          codetracer-pure-ruby-recorder = pkgs.stdenv.mkDerivation {
            pname = "ruby-recorder-pure";
            version = builtins.readFile ./version.txt;
            src = ./.;
            dontInstall = true;
            buildPhase = ''
              mkdir -p $out/gems/bin $out/gems/lib
              cp -Lr ./gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder $out/gems/bin/
              cp -Lr ./gems/codetracer-pure-ruby-recorder/lib/* $out/gems/lib/
              mkdir -p $out/bin
              ln -s $out/gems/bin/codetracer-pure-ruby-recorder $out/bin/codetracer-pure-ruby-recorder
            '';
          };
        });
    };
}
