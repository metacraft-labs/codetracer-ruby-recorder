# codetracer_ruby_recorder

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
require_relative 'target/release/libcodetracer_ruby_recorder'
```

Once loaded, the tracer starts writing a trace to `trace.json` in the
directory specified via the `CODETRACER_RUBY_RECORDER_OUT_DIR` environment
variable (defaults to the current directory).

## Publishing platform-specific gems

This extension can be packaged as a Ruby gem so the compiled library is
distributed for each target platform. The gemspec at the project root uses
[`rb_sys`](https://github.com/oxidize-rb/rb-sys) to build the library.

To publish prebuilt binaries:

1. Install the development dependencies:

   ```bash
   bundle install
   ```

2. For each target triple, set `RB_SYS_CARGO_TARGET` and run the packaging task:

   ```bash
   RB_SYS_CARGO_TARGET=x86_64-unknown-linux-gnu rake cross_native_gem
   ```

   Replace the target triple with the platform you want to build for, e.g.
   `aarch64-apple-darwin` or `x86_64-pc-windows-msvc`.

3. Push the generated gem from the `pkg/` directory to RubyGems:

   ```bash
   gem push pkg/codetracer-ruby-recorder-0.1.0-x86_64-linux.gem
   ```

Repeat these steps for each platform to provide platform-specific gems.
