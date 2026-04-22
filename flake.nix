{
  description = "Development environment for codetracer-ruby-recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs = {
    self,
    nixpkgs,
    fenix,
    pre-commit-hooks,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forEachSystem = nixpkgs.lib.genAttrs systems;

    rust-toolchain-for = system: fenix.packages.${system}.fromToolchainFile {
      file = ./rust-toolchain.toml;
      sha256 = "sha256-Qxt8XAuaUR2OMdKbN4u8dBJOhSHxS+uS06Wl9+flVEk=";
    };

    # Helper function to build the native Ruby recorder for a given pkgs and Ruby.
    # Consumers can call this with their own nixpkgs and Ruby version to ensure
    # ABI compatibility (the native .so must match the Ruby that loads it).
    mkRubyRecorderPackage = pkgs: ruby: let
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
        ruby              # build.rs runs `ruby` to discover RbConfig paths
        pkgs.pkg-config
        pkgs.capnproto     # codetracer_trace_format_capnp build.rs needs capnp
        pkgs.llvmPackages.libclang  # bindgen (used by rb-sys) needs libclang
      ] ++ lib.optionals stdenv.isDarwin [
        pkgs.libiconv
        pkgs.darwin.apple_sdk.frameworks.CoreFoundation
        pkgs.darwin.apple_sdk.frameworks.Security
      ];

      buildInputs = [ ruby ];

      # bindgen needs LIBCLANG_PATH to find libclang.so
      LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

      # bindgen also needs C standard headers (stdio.h, stddef.h, etc.)
      BINDGEN_EXTRA_CLANG_ARGS = lib.optionalString isLinux (
        builtins.concatStringsSep " " [
          "-isystem ${stdenv.cc.libc.dev}/include"
          "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${lib.versions.major pkgs.llvmPackages.libclang.version}/include"
        ]
      );

      cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ./gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.lock;
      };

      postUnpack = ''
        # cargoSetupHook expects Cargo.lock at the source root
        cp $sourceRoot/gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.lock \
           $sourceRoot/Cargo.lock
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

    devShells = forEachSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      preCommit = self.checks.${system}.pre-commit-check;
      isLinux = pkgs.stdenv.isLinux;
      isDarwin = pkgs.stdenv.isDarwin;
    in {
      default = pkgs.mkShell {
        packages = with pkgs; [
          # WARNING: `3.4` needed in `./gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`
          #          for the `thread` field of `rb_internal_thread_event_data_t`
          ruby_3_4

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
          git-lfs

          capnproto # Required for the native tracer's Cap'n Proto serialization
          zstd # Required for linking the Nim trace writer (libzstd)
        ] ++ pkgs.lib.optionals isLinux [
          # C standard library headers required for Ruby C extension compilation on Linux
          # Without this, build fails with "stdarg.h file not found" error
          glibc.dev
        ] ++ pkgs.lib.optionals isDarwin [
          # Required for Ruby C extension compilation on macOS
          darwin.apple_sdk.frameworks.CoreFoundation
          darwin.apple_sdk.frameworks.Security
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

        inherit (preCommit) shellHook;
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

    packages = forEachSystem (system: let
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
