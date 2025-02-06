## codetracer-ruby-recorder

A recorder of Ruby programs that produces CodeTracer traces.

> [!WARNING]
> Currently it is in a very early phase: we're going to update the documentation
> with more info about the tracing and possible improvements soon.

We're open for ideas and contributors, especially after we finish open sourcing the Codetracer interface!

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

### Legal info

LICENSE: MIT

Copyright (c) 2025 Metacraft Labs Ltd
