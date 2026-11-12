#!/usr/bin/env bash
# `just build-extension` leaves a loadable extension where the gem's loader
# looks, whatever CARGO_TARGET_DIR says, and fails when it does not.
#
# The gem's loader (`load_extension!`, gems/codetracer-ruby-recorder/lib/
# codetracer/native.rb), the gemspec and every consumer read only
# gems/codetracer-ruby-recorder/ext/native_tracer/target/release/. cargo honours
# CARGO_TARGET_DIR, which self-hosted CI runners export runner-wide, so a recipe
# that leaves the target directory to the environment builds the cdylib
# somewhere nothing looks, and used to exit 0 regardless.
#
# Asserted:
#
#   1. With CARGO_TARGET_DIR pointing at a scratch directory and no extension in
#      the gem's target/release, the recipe (real cargo, real build) produces
#      `codetracer_ruby_recorder.<RbConfig DLEXT>` there as a regular file and
#      puts no cdylib under the scratch directory.
#   2. When the build yields no extension, the recipe exits non-zero.
#
# Case 2 runs the recipe from a scratch copy of the Justfile with a stand-in
# `cargo` first on PATH that exits 0 and writes nothing. That stand-in is the
# only way to get a "successful" cargo that produced no artefact without
# breaking the real crate, and it is all the case needs: the claim under test
# is the recipe's own post-build check, not cargo's behaviour, which case 1
# covers with the real toolchain.
#
#   bash tests/test_build_extension_target_dir.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

ext_rel="gems/codetracer-ruby-recorder/ext/native_tracer/target/release"
dlext="$(ruby -e 'print RbConfig::CONFIG["DLEXT"]')"

# --- 1. A foreign CARGO_TARGET_DIR does not move the extension -------------
ext_dir="$REPO/$ext_rel"
rm -f "$ext_dir"/codetracer_ruby_recorder.* "$ext_dir"/libcodetracer_ruby_recorder.*
foreign="$SCRATCH/foreign-target"
mkdir -p "$foreign"
( cd "$REPO" && CARGO_TARGET_DIR="$foreign" CARGO_BUILD_TARGET_DIR="$foreign" \
    just build-extension ) || fail "just build-extension failed under CARGO_TARGET_DIR=$foreign"
ext="$ext_dir/codetracer_ruby_recorder.$dlext"
[ -f "$ext" ] && [ ! -L "$ext" ] \
  || fail "no regular file $ext after the build; $ext_dir holds: $(ls -A "$ext_dir" 2>/dev/null | tr '\n' ' ')"
stray="$(find "$foreign" -name 'libcodetracer_ruby_recorder.*' -o -name 'codetracer_ruby_recorder.*' | head -1)"
[ -z "$stray" ] || fail "the build followed CARGO_TARGET_DIR: $stray"
echo "ok: extension built into $ext_rel under a foreign CARGO_TARGET_DIR"

# --- 2. No extension produced => non-zero exit ------------------------------
copy="$SCRATCH/repo"
mkdir -p "$copy/$ext_rel" "$SCRATCH/bin"
cp "$REPO/Justfile" "$copy/Justfile"
# The stand-in records that it ran, so a recipe that fails before it reaches
# cargo (a Justfile that no longer parses, a missing tool) cannot pass for the
# post-build check refusing.
printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$SCRATCH/cargo-ran" > "$SCRATCH/bin/cargo"
chmod +x "$SCRATCH/bin/cargo"
if ( cd "$copy" && PATH="$SCRATCH/bin:$PATH" just build-extension ) >"$SCRATCH/case2.log" 2>&1; then
  cat "$SCRATCH/case2.log" >&2
  fail "just build-extension exited 0 although no extension was produced"
fi
[ -e "$SCRATCH/cargo-ran" ] \
  || { cat "$SCRATCH/case2.log" >&2; fail "the recipe failed before it ran cargo"; }
# Match the refusal itself: `just` echoes recipe lines that already mention
# codetracer_ruby_recorder (the Windows rename), so the bare name would match
# any failure.
grep -q "error: cargo reported success but .*/codetracer_ruby_recorder\.$dlext does not exist" "$SCRATCH/case2.log" \
  || { cat "$SCRATCH/case2.log" >&2; fail "the refusal does not name the missing extension"; }
echo "ok: build-extension fails when no extension results"
