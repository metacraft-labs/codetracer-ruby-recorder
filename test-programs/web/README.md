# Web demo apps and the recorded-session harness (RS-M6)

Everything here exists so that HTTP request spans can be produced by a REAL
server: `test/test_request_spans.rb`, `just demo-request-panel-ruby` and
`just record-request-panel-fixture` all drive the same code, so the tested path
and the demonstrated path cannot drift.

| File                | What it is                                                                 |
| ------------------- | -------------------------------------------------------------------------- |
| `sinatra/app.rb`    | Demo Sinatra app: routes covering every status bucket the Request Panel colours, a parameterised route, a slow handler and a handler that raises. |
| `rails/app.rb`      | The same API as a single-file Rails application, so `http.route` can be shown to come from the Rails router. |
| `rack_server.rb`    | A minimal single-threaded HTTP server for a Rack app. No WEBrick / Puma dependency, and one thread so the recorded step timeline is a strict sequence of request handling. |
| `serve.rb`          | The recorded process: builds the app, starts the recording, prints `READY <port>`, serves until `POST /__shutdown`, stops the recording. |
| `session_driver.rb` | Runs `serve.rb` as a subprocess, issues real HTTP, and hands back the `.ct` container. Also runnable as a script to record the demo schedule. |

## Recording a session by hand

```sh
ruby test-programs/web/session_driver.rb \
    --framework sinatra --trace-dir /tmp/ct-ruby-session --print-spans
```

## Two things to know before changing any of this

1. **The framework is loaded before the recording starts.** `serve.rb` drives
   `CodeTracer::RubyRecorder` as a library rather than running under
   `bin/codetracer-ruby-recorder`, because loading Rails under an armed event
   hook takes minutes. See `serve.rb`'s header.
2. **There is no trace filter.** The recorder's own `should_ignore_path` drops
   `gems/` and `lib/ruby`, which is where every framework here lives, so the
   recording contains only these files.
