## codetracer-ruby-recorder

A recorder of Ruby programs that produces [CodeTracer](https://github.com/metacraft-labs/CodeTracer) traces.

> [!WARNING]
> Currently it is in a very early phase: we're welcoming contribution and discussion!


### Installing as a gem

```bash
gem install codetracer-ruby-recorder
```

The command downloads a prebuilt native extension when available and falls back
to building it from source. If this fails, install the pure Ruby version:

```bash
gem install codetracer-pure-ruby-recorder
```

After installing, load the tracer:

```ruby
require 'codetracer_ruby_recorder' # native implementation
# require 'codetracer_pure_ruby_recorder' # pure Ruby implementation

recorder = RubyRecorder.new
recorder.enable_tracing
# ... your code ...
recorder.flush_trace(Dir.pwd)
```

### Usage

you can currently use it directly with

```bash
ruby gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder [--out-dir DIR] <path to ruby file> [-- <program args>]
# produces several trace json files in DIR,
# or in `$CODETRACER_RUBY_RECORDER_OUT_DIR` if DIR is not provided.
# Defaults to the current directory.
# Use `--` to stop option parsing and pass arguments to the program.
# Pass --help to list all options.
```

You can also invoke a lightweight CLI that loads the native tracer extension
directly:

```bash
ruby gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder [--out-dir DIR] [--format json|binary] <path to ruby file> [-- <program args>]
# Uses DIR or `$CODETRACER_RUBY_RECORDER_OUT_DIR` to choose where traces are saved.
# `--format` selects the trace format (`json` or `binary`).
# Use `--` to pass arguments to the traced program.
```

Example recording a binary trace while passing arguments to the program:

```bash
ruby gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder --format=binary --out-dir traces examples/runtime_code_execution.rb -- 2
```

however you probably want to use it in combination with CodeTracer, which would be released soon.

### ENV variables

* if you pass `CODETRACER_RUBY_RECORDER_DEBUG=1`, you enable some additional debug-related logging
* `CODETRACER_RUBY_RECORDER_OUT_DIR` can be used to specify the directory for trace files

## Development Setup

This repository includes a comprehensive Ruby debugging setup for Visual Studio Code. See [`.vscode/README.md`](.vscode/README.md) for detailed information about:

* VS Code tasks for running and debugging Ruby code
* Debug configurations for rdbg debugger  
* Ruby LSP integration for full language support
* Interactive debugging with Pry

### Quick Start for Contributors

1. **Install debugging gems** (if not using nix):

   ```bash
   gem install debug pry
   ```

2. **Use VS Code tasks**: Open Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`) and search for "Tasks: Run Task"

3. **Debug with F5**: Use the debug panel to set breakpoints and step through code

4. **Run tests**: Use the provided tasks or run manually:

   ```bash
   ruby -I lib -I test test/test_tracer.rb
   ```

## Future directions

The current Ruby support is a prototype. In the future, it may be expanded to function in a way similar to the more complete implementations, e.g. [Noir](https://github.com/blocksense-network/noir/tree/blocksense/tooling/tracer).

### Current approach: TracePoint API

Currently we're using the [TracePoint API](https://rubyapi.org/3.4/o/tracepoint).
This is very flexible and can function with probably multiple Ruby versions out of the box.
However, this is limited:

* it's not optimal
* it can't track more detailed info/state, needed for some CodeTracer features(or for more optimal replays).

For other languages, we've used a more deeply integrated approach: patching the interpreter or VM itself (e.g. Noir).

### Possible Alternative Approaches

#### Create a C extension for the VM, based on the `rb_add_event_hook2`

This would be a straight-forward port of the current code, but developed as a native extension (e.g. in C/C++ or Rust). The expected speedup will be significant.

#### Patching the VM

This approach may provide more depth: it can let us record more precisely calculated sub-expressions, assignments to record fields and other details required for the full CodeTracer experience.

The patching can be done either directly in the source code of the VM or through a binary instrumentation framework, such as Frida. The existing [ruby-trace](https://www.nccgroup.com/us/research-blog/tool-update-ruby-trace-a-low-level-tracer-for-ruby/) project provides an example for this.

#### Filtering

It would be useful to have a way to record only certain intervals within the program execution, or certain functions or modules:
we plan on expanding the [trace format](https://github.com/metacraft-labs/runtime_tracing/) and CodeTracer's support, so that this is possible. It would let one be able to record interesting
parts of even long-running or more heavy programs.

### Contributing

We'd be very happy if the community finds this useful, and if anyone wants to:

* Use and test the Ruby support or CodeTracer.
* Cooperate with us on supporting/advancing the Ruby support of [CodeTracer](https://github.com/metacraft-labs/CodeTracer).
* Provide feedback and discuss alternative implementation ideas: in the issue tracker, or in our [discord](https://discord.gg/qSDCAFMP).
* Provide [sponsorship](https://opencollective.com/codetracer), so we can hire dedicated full-time maintainers for this project.

For maintainer instructions, see [MAINTAINERS.md](MAINTAINERS.md).

### Development workflow

Use [just](https://github.com/casey/just) for common tasks:

```bash
just build-extension  # compile native extension
just test             # run the test suite
just format           # apply automatic formatting for all languages
just lint             # run all linters

# Language-specific tasks
just format-rust      # Rust code
just format-ruby      # Ruby code (requires rubocop)
just format-nix       # Nix files
just lint-rust        # Rust formatting check
just lint-ruby        # Ruby syntax check
just lint-nix         # Nix formatting check
```

### Legal info

LICENSE: MIT

Copyright (c) 2025 Metacraft Labs Ltd
