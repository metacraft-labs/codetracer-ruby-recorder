#!/usr/bin/env bash
# Verify that the codetracer-ruby-recorder and codetracer-pure-ruby-recorder
# CLIs comply with `codetracer-specs/Recorder-CLI-Conventions.md` (no
# silent skip — every assertion either passes or fails loudly):
#
#   * `--format` / `-f` is absent from `--help` (CTFS-only — convention §4).
#   * `CODETRACER_FORMAT` is absent from `--help` (convention §5).
#   * `--out-dir` and `--version` are present in `--help` (§3).
#   * `--help` mentions `ct print` (the canonical conversion tool, §4).
#   * `CODETRACER_RUBY_RECORDER_OUT_DIR` and `CODETRACER_RUBY_RECORDER_DISABLED`
#     are referenced in source so the env-var fallbacks (§5) cannot
#     regress silently.
#   * Passing `--format json` (or any other format token) is rejected with
#     a non-zero exit (i.e. the recorder does not silently accept the flag).
#
# Wire-up: see `Justfile` (`just lint` and `just test` both run this
# script).
#
# Exit codes:
#   0  all assertions held
#   1  at least one assertion failed (the failing line is printed to
#      stderr and the script exits at the first failure for clarity)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# We invoke the CLIs through `ruby <bin/...>` so the verification works
# without the gems being installed system-wide.  Callers that want to
# override the interpreter (e.g. Nix builds with a wrapped interpreter)
# can set `RUBY_BIN`.
RUBY_BIN="${RUBY_BIN:-$(command -v ruby || true)}"
if [[ -z "${RUBY_BIN}" ]] || [[ ! -x "${RUBY_BIN}" ]]; then
  echo "ERROR: ruby interpreter not found (set RUBY_BIN)" >&2
  exit 1
fi

NATIVE_BIN="${REPO_ROOT}/gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder"
PURE_BIN="${REPO_ROOT}/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder"

if [[ ! -f "${NATIVE_BIN}" ]]; then
  echo "ERROR: native recorder bin not found at ${NATIVE_BIN}" >&2
  exit 1
fi
if [[ ! -f "${PURE_BIN}" ]]; then
  echo "ERROR: pure recorder bin not found at ${PURE_BIN}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_absent() {
  # assert_absent <needle> <haystack-description> <haystack>
  local needle="$1"
  local desc="$2"
  local haystack="$3"
  if grep -qF -- "${needle}" <<< "${haystack}"; then
    echo "FAIL: ${desc} must NOT contain '${needle}'" >&2
    echo "----- ${desc} -----" >&2
    echo "${haystack}" >&2
    echo "-------------------" >&2
    exit 1
  fi
  echo "ok: '${needle}' absent from ${desc}"
}

assert_present() {
  # assert_present <needle> <haystack-description> <haystack>
  local needle="$1"
  local desc="$2"
  local haystack="$3"
  if ! grep -qF -- "${needle}" <<< "${haystack}"; then
    echo "FAIL: ${desc} must contain '${needle}'" >&2
    echo "----- ${desc} -----" >&2
    echo "${haystack}" >&2
    echo "-------------------" >&2
    exit 1
  fi
  echo "ok: '${needle}' present in ${desc}"
}

# ---------------------------------------------------------------------------
# Native recorder --help
# ---------------------------------------------------------------------------

NATIVE_HELP="$("${RUBY_BIN}" "${NATIVE_BIN}" --help)"

assert_absent "--format" "native --help" "${NATIVE_HELP}"
assert_absent "CODETRACER_FORMAT" "native --help" "${NATIVE_HELP}"
assert_present "--help" "native --help" "${NATIVE_HELP}"
assert_present "--out-dir" "native --help" "${NATIVE_HELP}"
assert_present "--version" "native --help" "${NATIVE_HELP}"
assert_present "ct print" "native --help" "${NATIVE_HELP}"
assert_present "CODETRACER_RUBY_RECORDER_OUT_DIR" "native --help" "${NATIVE_HELP}"
assert_present "CODETRACER_RUBY_RECORDER_DISABLED" "native --help" "${NATIVE_HELP}"

# ---------------------------------------------------------------------------
# Pure recorder --help
# ---------------------------------------------------------------------------

PURE_HELP="$("${RUBY_BIN}" "${PURE_BIN}" --help)"

assert_absent "--format" "pure --help" "${PURE_HELP}"
assert_absent "CODETRACER_FORMAT" "pure --help" "${PURE_HELP}"
assert_present "--help" "pure --help" "${PURE_HELP}"
assert_present "--out-dir" "pure --help" "${PURE_HELP}"
assert_present "--version" "pure --help" "${PURE_HELP}"
assert_present "ct print" "pure --help" "${PURE_HELP}"
assert_present "CODETRACER_RUBY_RECORDER_OUT_DIR" "pure --help" "${PURE_HELP}"
assert_present "CODETRACER_RUBY_RECORDER_DISABLED" "pure --help" "${PURE_HELP}"

# ---------------------------------------------------------------------------
# --version output
# ---------------------------------------------------------------------------

NATIVE_VERSION="$("${RUBY_BIN}" "${NATIVE_BIN}" --version)"
assert_present "codetracer-ruby-recorder" "native --version" "${NATIVE_VERSION}"

PURE_VERSION="$("${RUBY_BIN}" "${PURE_BIN}" --version)"
assert_present "codetracer-pure-ruby-recorder" "pure --version" "${PURE_VERSION}"

# ---------------------------------------------------------------------------
# --format must be rejected (non-zero exit)
# ---------------------------------------------------------------------------

assert_format_rejected() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: ${desc}: --format unexpectedly accepted" >&2
    exit 1
  fi
  echo "ok: ${desc}: --format rejected with non-zero exit"
}

assert_format_rejected "native --format json" "${RUBY_BIN}" "${NATIVE_BIN}" --format json /dev/null
assert_format_rejected "native -f binary"     "${RUBY_BIN}" "${NATIVE_BIN}" -f binary /dev/null
assert_format_rejected "pure --format json"   "${RUBY_BIN}" "${PURE_BIN}"   --format json /dev/null
assert_format_rejected "pure -f binary"       "${RUBY_BIN}" "${PURE_BIN}"   -f binary /dev/null

# ---------------------------------------------------------------------------
# Source-level references for env-var fallbacks
# ---------------------------------------------------------------------------

# The recorder libraries must reference both env vars; otherwise the
# fallback either doesn't exist or has been silently removed.  We grep
# across both gems' lib/ trees.
LIB_ROOTS=(
  "${REPO_ROOT}/gems/codetracer-ruby-recorder/lib"
  "${REPO_ROOT}/gems/codetracer-pure-ruby-recorder/lib"
)

for var in CODETRACER_RUBY_RECORDER_OUT_DIR CODETRACER_RUBY_RECORDER_DISABLED; do
  for lib_root in "${LIB_ROOTS[@]}"; do
    if ! grep -rqF "${var}" "${lib_root}"; then
      echo "FAIL: ${var} must be referenced in ${lib_root}" >&2
      exit 1
    fi
  done
  echo "ok: ${var} referenced in both gem lib/ trees"
done

# ---------------------------------------------------------------------------
# CTFS-only contract: native lib must not write trace.json or trace.bin.
# ---------------------------------------------------------------------------

NATIVE_LIB="${REPO_ROOT}/gems/codetracer-ruby-recorder/lib/codetracer_ruby_recorder.rb"
# Filter out comment lines (those whose first non-whitespace char is `#`)
# from the `grep -n` output.  We strip the `<lineno>:` prefix before
# applying the comment-line check so the regex anchors against the file
# content, not the line number.
if grep -nE 'trace\.(json|bin)' "${NATIVE_LIB}" \
   | sed -E 's/^[0-9]+://' \
   | grep -vE '^\s*#' >/dev/null; then
  echo "FAIL: ${NATIVE_LIB} must not reference trace.json / trace.bin (CTFS-only)" >&2
  grep -nE 'trace\.(json|bin)' "${NATIVE_LIB}" >&2
  exit 1
fi
echo "ok: native lib does not reference legacy trace.json / trace.bin output paths"

NATIVE_RUST="${REPO_ROOT}/gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs"
# The Rust extension's `begin_trace` body must not branch on the
# format: it should always join `trace.ct`.  We approximate this with a
# match-pattern check (grep for any `TraceEventsFileFormat::Json` or
# `TraceEventsFileFormat::Binary` left over outside of comment lines).
if grep -nE 'TraceEventsFileFormat::(Json|Binary|BinaryV0)' "${NATIVE_RUST}" \
   | sed -E 's/^[0-9]+://' \
   | grep -vE '^\s*//' >/dev/null; then
  echo "FAIL: ${NATIVE_RUST} still references TraceEventsFileFormat::{Json,Binary,BinaryV0}" >&2
  grep -nE 'TraceEventsFileFormat::(Json|Binary|BinaryV0)' "${NATIVE_RUST}" >&2
  exit 1
fi
echo "ok: Rust extension does not branch on Json / Binary format variants"

echo "verify-cli-convention-no-silent-skip: all checks passed"
