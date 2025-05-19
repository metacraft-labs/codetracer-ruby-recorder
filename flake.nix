{
  description = "Development environment for codetracer-ruby-recorder";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forEachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              ruby

              # The native extension is implemented in Rust
              rustc
              cargo
              libiconv # required as a dependency when building the rb-sys Rust crate
              
              # For build automation
              libclang # required for building the rb-sys-env build tools
              just
              git-lfs
            ];
          };
        });
    };
}
