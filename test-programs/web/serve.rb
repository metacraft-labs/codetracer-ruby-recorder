# frozen_string_literal: true

# Serve one of the web demo apps UNDER THE RECORDER (RS-M6).
#
# The single entry point used by both `test/test_request_spans.rb` and
# `just demo-request-panel-ruby`, so the tested path and the demonstrated path
# cannot drift:
#
#     ruby test-programs/web/serve.rb --framework sinatra \
#         --trace-dir /tmp/session --port 18901
#
# It builds the chosen demo app, wraps it in `CodeTracer::Rack::Middleware`,
# STARTS THE RECORDING, prints `READY <port>`, and serves real HTTP until
# `POST /__shutdown` arrives — then stops the recording so the `.ct` container,
# span stream included, is written.
#
# Five details matter:
#
# 1. **The framework is loaded BEFORE the recording starts.**  This is the
#    difference between a demo that runs in two seconds and one that does not
#    finish: `require "action_controller/railtie"` under an armed event hook
#    took over 400 s in this environment, because the hook fires for every
#    executed line of Rails' boot even though the recorder then discards the
#    events.  That is why this file drives `CodeTracer::RubyRecorder` as a
#    LIBRARY (`new` / `start` / `stop` / `flush_trace`) instead of being run
#    under `bin/codetracer-ruby-recorder`, which arms the hook before it loads
#    the program.  Handlers are still recorded in full: the hook is global, not
#    per-file, so everything executed after `start` is seen.
# 2. **No trace filter is needed.**  Unlike the Python milestone, this
#    recorder's `should_ignore_path` already drops every path containing
#    `gems/` or `lib/ruby`, which is where Sinatra, Rails, Rack and the
#    CodeTracer middleware live.  The recorded timeline is therefore the demo
#    app's own steps plus this harness's, and a request's span range is its
#    handler's steps.
# 3. **One thread.**  `CodeTracerDemo::RackServer` accepts and handles on the
#    main thread; see its header.  A second thread would interleave the single
#    recorded step timeline and make every span's range meaningless.
# 4. **Shutdown is explicit.**  The container is written only when the recording
#    stops, so a killed process yields no trace.  `POST /__shutdown` ends the
#    accept loop; `SIGTERM` / `SIGINT` do the same as a backstop.
# 5. **The middleware is mounted the way each framework's users mount it** —
#    `use` for Sinatra, `config.middleware.insert_before` for Rails — so the
#    demo shows the integration and not a test harness.

require 'fileutils'
require 'optparse'
require 'rack'

HERE = File.expand_path(__dir__)
REPO_ROOT = File.expand_path('../..', HERE)

require File.join(HERE, 'rack_server')
require File.join(REPO_ROOT, 'gems', 'codetracer-rack', 'lib', 'codetracer-rack')
require File.join(REPO_ROOT, 'gems', 'codetracer-ruby-recorder', 'lib', 'codetracer_ruby_recorder')

FRAMEWORKS = %w[sinatra rails].freeze

# The Ruby sources bundled into the recording, so a replayed session can show
# the code the steps point at.  `bin/codetracer-ruby-recorder` does this for the
# single program it loads; driving the recorder as a library means doing it for
# every file whose steps end up in the trace.
def recorded_sources(framework)
  [__FILE__,
   File.join(HERE, 'rack_server.rb'),
   File.join(HERE, framework, 'app.rb')]
end

# Build the Rack app for the requested framework, mounting the CodeTracer
# middleware the way that framework's users would.
def build_app(framework)
  case framework
  when 'sinatra'
    require File.join(HERE, 'sinatra', 'app')
    # `use` is how a Sinatra application declares middleware; doing it from the
    # outside keeps the demo app itself free of CodeTracer references.
    Rack::Builder.new do
      use CodeTracer::Rack::Middleware, framework: 'sinatra'
      run CodeTracerDemo::SinatraApp
    end.to_app
  when 'rails'
    require File.join(HERE, 'rails', 'app')
    # Above ShowExceptions, so the span records the status the client actually
    # received; see the demo app's header.
    CodeTracerDemo::RailsApp.config.middleware.insert_before(
      ActionDispatch::ShowExceptions,
      CodeTracer::Rack::Middleware,
      framework: 'rails'
    )
    CodeTracerDemo::RailsApp.initialize!
    CodeTracerDemo::RailsApp
  else
    raise ArgumentError, "unknown framework #{framework}"
  end
end

options = { framework: 'sinatra', port: 0 }
OptionParser.new do |opts|
  opts.banner = 'usage: serve.rb --framework <sinatra|rails> --trace-dir DIR [--port N]'
  opts.on('--framework NAME', FRAMEWORKS, "one of #{FRAMEWORKS.join(', ')}") do |name|
    options[:framework] = name
  end
  opts.on('--trace-dir DIR', 'where to write the .ct container') do |dir|
    options[:trace_dir] = dir
  end
  opts.on('--port PORT', Integer, 'listen port (0 = pick a free one)') do |port|
    options[:port] = port
  end
end.parse!
abort('serve.rb: --trace-dir is required') unless options[:trace_dir]

# --- everything above the recording ---------------------------------------
app = build_app(options[:framework])
server = CodeTracerDemo::RackServer.new(app, port: options[:port])

FileUtils.mkdir_p(options[:trace_dir])
recorded_sources(options[:framework]).each do |source|
  CodeTracer::RubyRecorder.bundle_source_file(source, options[:trace_dir])
end

recorder = CodeTracer::RubyRecorder.new(options[:trace_dir])
abort('serve.rb: the native recorder is unavailable; run `just build-extension`') unless recorder.available?

%w[TERM INT].each do |signal|
  Signal.trap(signal) { server.stop }
end

# --- the recorded window ---------------------------------------------------
recorder.start
begin
  # The socket is already bound (see RackServer#initialize), so a client that
  # connects the instant it reads this line is queued rather than refused.
  $stdout.puts("READY #{server.port}")
  $stdout.flush
  server.serve
ensure
  recorder.stop
  recorder.flush_trace
end

$stdout.puts('STOPPED')
$stdout.flush
