# codetracer-pure-ruby-recorder

Pure-Ruby reference implementation of the CodeTracer Ruby recorder.
**Legacy 3-file JSON output (`trace.json`, `trace_metadata.json`,
`trace_paths.json`) by design.**

## Why a pure-Ruby version exists

The production recorder lives in the sibling gem
[`codetracer-ruby-recorder`](../codetracer-ruby-recorder/), a Rust
native extension. It emits a single CTFS v3 binary trace bundle
(`<prog>.ct`) per `codetracer-specs/Recorder-CLI-Conventions.md` §4.

This gem deliberately stays on the older line-delimited JSON shape and
is the cross-validation oracle that keeps the native recorder honest.

The repository's test suite (`test/test_tracer.rb`) runs every program
in `test/programs/` through **both** recorders:

1. The pure-Ruby recorder writes `trace.json` directly.
2. The native recorder writes `<prog>.ct`. The test framework then
   shells out to `ct print --json-events` (from
   [`codetracer-trace-format-nim`](https://github.com/metacraft-labs/codetracer-trace-format-nim))
   and normalises the result back into this gem's JSON shape — see
   `read_trace` and `normalise_ct_events` in `test/test_tracer.rb`.
3. Both normalised event streams are compared against the same fixtures
   under `test/fixtures/`.

That symmetry is the whole point: any behaviour change in the native
recorder is caught by structural divergence from the pure reference. If
both recorders quietly drifted in lockstep, the test suite would lose
its independent oracle.

## When to modify this recorder

- **Trace-shape change** (new event kind, new field, semantic
  adjustment): change the pure recorder first, regenerate fixtures,
  then mirror the change in the native recorder until the test suite
  is green again. The pure recorder is treated as the canonical
  specification of the recorded behaviour.
- **Bug fix that only affects this recorder**: fix it, update fixtures
  if needed, and — critically — verify the native recorder did not
  silently rely on the same buggy shape.
- **Fixture regeneration**: see `just test` / the regen helpers under
  `scripts/`. Touching the JSON output requires regenerating
  `test/fixtures/**` **and** keeping `normalise_ct_events` in sync so
  the ct-print path still produces the same normalised events.

## What NOT to do

- **Do not migrate this gem to CTFS v3.** That would defeat the
  cross-validation oracle and silently weaken the test suite. If you
  need CTFS output from Ruby, use the native gem at
  `../codetracer-ruby-recorder/`.
- **Do not rename or reshape JSON fields without updating fixtures and
  `test/test_tracer.rb::normalise_ct_events`.** The normaliser exists
  precisely to map the native recorder's ct-print output onto this
  gem's shape; if the shape moves, the normaliser must move with it.
- **Do not optimise this recorder for production throughput.** It is a
  reference implementation. Clarity beats speed here; speed is the
  native recorder's job.

## Audience

Reading this six months from now and wondering why this gem still
exists in the JSON era? It exists so the test suite has two
independent implementations to compare. That redundancy is the design.

## CLI

```bash
ruby gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder \
  [--out-dir DIR] <path to ruby file> [-- <program args>]
```

Writes `trace.json`, `trace_metadata.json`, and `trace_paths.json` into
`DIR` (defaults to `$CODETRACER_RUBY_RECORDER_OUT_DIR`, then `cwd`).
There is no `--format` flag — the pure recorder is JSON-only and the
native recorder is CTFS-only. Use `ct print` to read a `.ct` bundle as
JSON or text.

## See also

- [`../codetracer-ruby-recorder/`](../codetracer-ruby-recorder/) —
  production native recorder (CTFS v3).
- [`../../test/test_tracer.rb`](../../test/test_tracer.rb) —
  cross-recorder test harness; `normalise_ct_events` documents the
  exact shape this gem is expected to produce.
- [`../../CLAUDE.md`](../../CLAUDE.md) — repo-level notes including the
  rationale for keeping both recorders side by side.
