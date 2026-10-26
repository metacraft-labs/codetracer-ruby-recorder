# Agent notes: codetracer-pure-ruby-recorder

**This gem is a test oracle, not a production recorder.**

- It writes JSON (`trace.json`, `trace_metadata.json`, `trace_paths.json`).
  **CodeTracer cannot open that output** and must not be taught to: a
  `trace.json` is refused as a test-oracle output, not a recording.
- The production Ruby recorder is the native gem in
  `../codetracer-ruby-recorder/`. It writes `.ct` and is the only Ruby
  recorder whose output CodeTracer opens.

## The testing protocol

Run the same program through this recorder (JSON) and through the
production recorder (`.ct`), convert the `.ct` with `ct print`
(`ct-print --json-events`), and compare. `test/test_tracer.rb` asserts
that the two agree (`assert_trace_semantic_match(pure_trace,
native_trace)`), and refuses a reference with no steps or no functions so
the comparison can never pass vacuously.

## Rules

- Keep it JSON-only. Do not add CTFS output; do not add a JSON output to
  the production recorder either.
- Do not present it to users as a fallback for when the native extension
  cannot be built.
- A trace-shape change goes here first, then fixtures under
  `test/fixtures/`, then `normalise_ct_events` in `test/test_tracer.rb`,
  then the native recorder until `just test` is green.
- Clarity over speed: it is a reference implementation.
