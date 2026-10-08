# Identical owning dev-shell Ruby/test-gem SDK from this repository's lock.
{ system ? builtins.currentSystem }:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  resolveNode = node: edge:
    if builtins.isString edge then
      edge
    else
      assert builtins.isList edge && edge != [ ];
      builtins.foldl'
      (current: name: resolveNode current lock.nodes.${current}.inputs.${name})
      lock.root edge;
  key = resolveNode lock.root lock.nodes.${lock.root}.inputs.nixpkgs;
  locked = lock.nodes.${key}.locked;
  source = assert locked.type == "github"; builtins.fetchTree locked;
  pkgs = import source.outPath { inherit system; };
in assert builtins.elem system [
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-darwin"
  "aarch64-darwin"
];
assert pkgs.ruby_3_4.version.majMinTiny == "3.4.8";
pkgs.ruby_3_4.withPackages (ps: [ ps.minitest ps.rack ps.sinatra ps.rails ])
