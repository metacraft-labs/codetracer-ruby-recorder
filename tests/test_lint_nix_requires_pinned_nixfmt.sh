#!/usr/bin/env bash
# `just lint-nix` and `just format-nix` give one verdict for one tree: they do
# not depend on an ambient `nixfmt`.
#
# Before this was fixed the recipes ran `if command -v nixfmt; then ...; fi`, so
# the gate checked nothing in the dev shell (which provided no nixfmt) and
# failed only for callers whose profile happened to carry one. Asserted:
#
#   1. With no `nixfmt` on PATH, `lint-nix` and `format-nix` FAIL (a missing
#      formatter is an error, never a skip) and say why.
#   2. The dev shell provides `nixfmt` (the flake's pinned nixpkgs), and
#      `just lint-nix` passes on the committed tree inside it.
#
# Leg 1 runs without nix; leg 2 runs `nix develop`, so this is not part of the
# in-shell test recipes (see `just test-lint-nix`).
#
#   bash tests/test_lint_nix_requires_pinned_nixfmt.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
fail() { echo "FAIL: $*" >&2; exit 1; }

# A PATH holding just, find, xargs and bash but certainly no nixfmt.
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
for tool in just find xargs bash sh env dirname; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done

for recipe in lint-nix format-nix; do
  if out="$(PATH="$BIN" just "$recipe" 2>&1)"; then
    fail "$recipe passed without nixfmt on PATH: $out"
  fi
  grep -q 'nixfmt' <<<"$out" || fail "$recipe failed without naming nixfmt: $out"
  echo "ok: $recipe fails loudly without nixfmt"
done

nix develop "$REPO" --command bash -c 'command -v nixfmt >/dev/null' \
  || fail "the dev shell does not provide nixfmt"
echo "ok: dev shell provides nixfmt"
# --ignore-environment drops the caller's profile, so only the shell's nixfmt can answer.
nix develop "$REPO" --ignore-environment --keep-env-var HOME --command just lint-nix \
  || fail "lint-nix fails on the committed tree in the dev shell"
echo "ok: lint-nix passes in the dev shell"
