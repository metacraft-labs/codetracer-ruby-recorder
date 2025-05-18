# codetracer_ruby_native_recoreder

This crate provides a minimal Ruby tracer implemented in Rust.
It registers a Ruby VM event hook using `rb_add_event_hook2` and
records basic information for each executed line.

Recorded events are written using the [`runtime_tracing`](https://github.com/metacraft-labs/runtime_tracing) crate.

## Building

```
cargo build --release
```

If you have `just` installed, run `just build-extension` from the project root.

The produced shared library can be required from Ruby:

```ruby
require_relative 'target/release/libcodetracer_ruby_native_recoreder'
```

Once loaded, the tracer starts writing a trace to `trace.json` or the
path specified via the `CODETRACER_DB_TRACE_PATH` environment variable.
