## codetracer-ruby-recorder

A recorder of Ruby programs that produces [CodeTracer](https://github.com/metacraft-labs/CodeTracer) traces.

> [!WARNING]
> Currently it is in a very early phase: we're welcoming contribution and discussion!


### usage

you can currently use it directly with

```bash
ruby trace.rb <path to ruby file>
# produces several trace json files in the current directory
# or in the folder of `$CODETRACER_DB_TRACE_PATH` if such an env var is defined
```

however you probably want to use it in combination with CodeTracer, which would be released soon.

### env variables

* if you pass `CODETRACER_RUBY_TRACER_DEBUG=1`, you enables some additional debug-related logging
* `CODETRACER_DB_TRACE_PATH` can be used to override the path to `trace.json` (it's used internally by codetracer as well)

## future directions

The current Ruby support is a prototype. In the future, it may be expanded to function in a way to similar to the more complete implementations, e.g. [Noir](https://github.com/blocksense-network/noir/tree/blocksense/tooling/tracer).

### Current approach: TracePoint API

Currently we're using the TracePoint API: https://rubyapi.org/3.4/o/tracepoint .
This is very flexible and can function with probably multiple Ruby versions out of the box. 
However, this is limited:

* it's not optimal
* it can't track more detailed info/state, needed for some CodeTracer features(or for more optimal replays).

For other languages, we've used a more deeply integrated approach: patching the interpreter or VM itself (e.g. Noir).

### Possible Alternative Approaches

#### Create a C extension for the VM, based on the `rb_add_event_hook2`

This would be a straigh-forward port of the current code, but developed as a native extension (e.g. in C/C++ or Rust). The expected speedup will be significant.

#### Patching the VM

This approach may provide more depth: it can let us record more precisely calculated sub-expressions, assignments to record fields and other details required for the full CodeTracer experience.

The patching can be done either directly in the source code of the VM or through a binary instrumentation framework, such as Frida. The existing [ruby-trace](https://www.nccgroup.com/us/research-blog/tool-update-ruby-trace-a-low-level-tracer-for-ruby/) project provides an example for this.

#### Filtering

It would be useful to have a way to record only certain intervals within the program execution, or certain functions or modules: 
we plan on expanding the [trace format](https://github.com/metacraft-labs/runtime_tracing/) and CodeTracer' support, so that this is possible. It would let one be able to record interesting
parts of even long-running or more heavy programs.

### Contributing

We'd be very happy if the community finds this useful, and if anyone wants to:

* Use and test the Ruby support or CodeTracer.
* Cooperate with us on supporting/advancing the Ruby support of [CodeTracer](https://github.com/metacraft-labs/CodeTracer).
* Provide feedback and discuss alternative implementation ideas: in the issue tracker, or in our [discord](https://discord.gg/qSDCAFMP).
* Provide [sponsorship](https://opencollective.com/codetracer), so we can hire dedicated full-time maintainers for this project.

### Legal info

LICENSE: MIT

Copyright (c) 2025 Metacraft Labs Ltd
