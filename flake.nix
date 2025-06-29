{
  description = "Development environment for codetracer-ruby-recorder";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  inputs.pre-commit-hooks.url = "github:cachix/git-hooks.nix";

  outputs = {
    self,
    nixpkgs,
    pre-commit-hooks,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forEachSystem = nixpkgs.lib.genAttrs systems;
  in {
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
          ruby

          # The native extension is implemented in Rust
          rustc
          cargo
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
  };
}
