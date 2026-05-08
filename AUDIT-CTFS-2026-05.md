# Ruby Recorder CTFS Audit — 2026-05

This file tracks Ruby recorder CTFS-format compliance and follow-up
work.  Prior recorder audits established the canonical patterns:
Python (1.27), JavaScript (1.38), EVM (1.39), PHP (1.41), Solana (1.44),
Move (1.46), Cardano (1.48), Cairo (2026-05-02).

The Ruby recorder ships in two flavours:

* **`codetracer-ruby-recorder`** — Rust-backed native gem
  (`gems/codetracer-ruby-recorder/`).  Uses the Nim-backed
  `codetracer_trace_writer_nim` crate, so every canonical entry point
  (`register_call`, `arg`, `register_special_event`, etc.) is
  reachable.  Writes the canonical `*.ct` CTFS multi-stream bundle.
* **`codetracer-pure-ruby-recorder`** — Pure-Ruby fallback gem
  (`gems/codetracer-pure-ruby-recorder/`) for environments where the
  Rust extension cannot be built.  Writes the legacy 3-file JSON shape
  (`trace.json` + `trace_metadata.json` + `trace_paths.json`); kept as
  a fallback because no Ruby-native CTFS encoder exists yet.

## Convention compliance follow-up — 2026-05-08

Pre-2026-05-08, `codetracer-ruby-recorder` exposed `-f` / `--format` with
`ctfs`, `json`, `binary`, `binaryv0` choices (default `ctfs`) and the
recorder writer dispatched the events file path on the format
(`trace.ct` / `trace.json` / `trace.bin`).  This conflicted with the
tightened `Recorder-CLI-Conventions.md` §4 which mandates **CTFS-only**
output: recorders no longer accept a `--format` flag and `ct print`
(shipped with `codetracer-trace-format-nim`) is the canonical
conversion tool for human-readable output.

The Ruby recorder also lacked `CODETRACER_RUBY_RECORDER_DISABLED`
support (convention §5).

This entry records the compliance follow-up applied to both gems on
2026-05-08:

### Native recorder (`codetracer-ruby-recorder`)

* The `--format` / `-f` CLI flag was removed from
  `gems/codetracer-ruby-recorder/lib/codetracer_ruby_recorder.rb`.
  An explicit reject-with-error path catches any leftover `--format`
  / `-f` invocation and prints a clear message pointing users at
  `ct print` for human-readable conversion.
* The Rust extension `gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`
  was hard-pinned to `TraceEventsFileFormat::Ctfs`.  The
  `begin_trace(dir, format)` signature became `begin_trace(dir)` and
  no longer dispatches the events filename on the format — the writer
  always joins `trace.ct`.  The `match` arms for `Json` / `Binary` /
  `BinaryV0` were deleted.

  Before (`begin_trace`):
  ```rust
  let events = match format {
      TraceEventsFileFormat::Json => dir.join("trace.json"),
      TraceEventsFileFormat::Ctfs => dir.join("trace.ct"),
      TraceEventsFileFormat::BinaryV0 | TraceEventsFileFormat::Binary => dir.join("trace.bin"),
  };
  ```

  After:
  ```rust
  let events = dir.join("trace.ct");
  ```

* The Rust `initialize` FFI function preserves its arity-2 signature
  (Ruby's `rb_define_method` registered it with arity 2), but the
  `format:` argument is now restricted to `:ctfs` / `:ct`.  Any other
  symbol raises a clear error so callers cannot silently ask for JSON
  or binary and believe they got it.
* The Ruby-level `trace_produced` check in
  `lib/codetracer_ruby_recorder.rb::trace_ruby_file` no longer falls
  back to `trace.json` or `trace.bin` — only `Dir.glob('*.ct')` counts
  as a successful recording.
* `CODETRACER_RUBY_RECORDER_DISABLED=1` (or `true`) was added.  When
  set, the recorder short-circuits before calling the native writer:
  the target script still runs (so callers get the same stdout / exit
  behaviour) but no trace is written.

### Pure-Ruby recorder (`codetracer-pure-ruby-recorder`)

* The CLI gained `--version` / `-V`, an extended `--help` epilogue
  documenting `ct print` and the env vars, and explicit rejection of
  `--format` / `-f` (convention §4: there is no format selector even
  though the pure recorder happens to write JSON; the convention
  forbids the flag itself).
* `CODETRACER_RUBY_RECORDER_DISABLED=1` short-circuits the same way as
  in the native recorder.
* The pure recorder's `serialize` writer was **not** changed: there is
  no Ruby-native CTFS encoder yet, and the fallback's whole purpose is
  to remain useful when the native extension can't be built.  This is
  the same posture the Python recorder family takes
  (`codetracer-pure-python-recorder` also writes JSON).  The
  `trace.json` / `trace_metadata.json` / `trace_paths.json` paths are
  internal to this fallback gem and not surfaced as a user-facing
  format choice.

### Tests

* `test/test_tracer.rb`'s existing `read_trace` helper already preferred
  `*.ct` over `trace.json`, so the structural `assert_equal expected,
  pure_trace` and `assert_trace_semantic_match(expected, native_trace)`
  assertions kept their existing strength against CTFS.  No silent
  weakening — the same fixtures still drive both recorders.
* Two new tests in `test/test_tracer.rb` mirror the cairo / python
  precedent for the CTFS-only convention surface:
  - `test_recorded_trace_via_ct_print_json` — records `addition.rb`
    with the native recorder and pipes the produced `*.ct` through
    `ct-print --json`, asserting structural anchors (program name,
    function names, step / call / return counts, named user
    function presence) without tying the assertions to a specific
    type-id ordering.
  - `test_env_out_dir_used_when_flag_omitted` — both recorders pick
    up `CODETRACER_RUBY_RECORDER_OUT_DIR` when `--out-dir` is omitted.
  - `test_env_disabled_skips_recording` — both recorders skip writing
    any artefacts when `CODETRACER_RUBY_RECORDER_DISABLED=1` is set,
    while still running the target script (its stdout is preserved).
  - `test_format_flag_rejected` — both recorders reject `--format
    json`, `--format=json`, `-f binary`, etc. with a non-zero exit.
  - `test_no_format_flag_in_help` — `--help` output for both
    recorders contains neither `--format` nor `CODETRACER_FORMAT`.
  - `test_help_mentions_ct_print` — `--help` mentions `ct print` for
    both recorders.
* `tests/verify-cli-convention-no-silent-skip.sh` was added as a
  shell-level guard.  It runs both binaries' `--help`, asserts the
  forbidden tokens (`--format`, `CODETRACER_FORMAT`) are absent, the
  required tokens (`--out-dir`, `--version`, `ct print`,
  `CODETRACER_RUBY_RECORDER_OUT_DIR`,
  `CODETRACER_RUBY_RECORDER_DISABLED`) are present, the `--version`
  output follows `<binary-name> <version>`, and the source files no
  longer reference legacy `trace.json` / `trace.bin` output paths nor
  the `Json` / `Binary` / `BinaryV0` `TraceEventsFileFormat` variants.
  Wired into `just test` and `just lint`.

References:

* [`codetracer-specs/Recorder-CLI-Conventions.md`](../codetracer-specs/Recorder-CLI-Conventions.md) §4 (CTFS-only) and §5 (env vars).
