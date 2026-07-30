# frozen_string_literal: true

# RS-M6 — request spans in the recorded `.ct` container.
#
# ## Design
#
# Both tests here are end-to-end integration tests over the REAL path:
#
#   a real server process, started under the recorder by
#   `test-programs/web/serve.rb`
#     -> a real framework app (Sinatra / Rails) with
#        `CodeTracer::Rack::Middleware` mounted the way that framework's users
#        mount it
#     -> real HTTP requests over loopback from this process
#     -> a real `.ct` container written when the recording stops
#     -> decoded by the CANONICAL Nim span reader
#        (`CodeTracer::Native.read_span_stream`, which calls `ct_spans_json`,
#        the same decoder `ct print -f http` uses).
#
# **No mocks.** There is no fake server, no fake app, no hand-built container
# and no second span decoder. Reading the spans back through the shipped Nim
# reader is deliberate: a test-local decoder could agree with a writer bug and
# report success for bytes no consumer can read.
#
# The one thing these tests do NOT do is assert the recorded bytes by hand;
# that is what the reader is for.
#
# ## Scenarios
#
# * `rack_requests_land_in_span_stream` — the Sinatra demo app (a plain Rack
#   app, wrapped by the Rack middleware under test) served over a real TCP
#   socket. Five requests: two successes, a 404, a 304 and a handler that
#   RAISES. Sinatra runs with `raise_errors`, so the exception escapes the app
#   and it is the middleware's own `rescue` that records the span — the branch
#   the milestone names ("assert spans with error status and error.message").
#
# * `rails_requests_land_in_span_stream` — the Rails demo app, five requests,
#   two of them to the same parameterised route with different ids. The
#   assertion that matters is that `http.route` is the ROUTED PATTERN
#   (`/api/users/:user_id`) for both, and not the raw path — i.e. the value
#   really comes from `ActionDispatch::Journey::Router` and is not the URL
#   copied under a second key. The Rails demo also covers the OTHER error
#   branch: the middleware sits above `ActionDispatch::ShowExceptions`, so it
#   observes the 500 Rails produced and takes `error.message` from
#   `env['action_dispatch.exception']`.
#
# ## Assertions common to both
#
# 1. The container declares a span stream and holds exactly one settled span
#    per request — every request is published OPEN first and then settled, so a
#    reader without last-record-wins would see twice as many.
# 2. Method, URL, status code, duration, route, framework and (where
#    applicable) `error.message` match the schedule this file issued. The
#    schedule is the ground truth and is written out literally, never derived
#    from the container: a recorder bug must not be able to make the
#    expectations agree with themselves.
# 3. **The step range is a real coordinate INSIDE the container** — that is the
#    whole point of an inline-bound span, and what a JSONL sidecar row could
#    never be. Every `[start_step, end_step]` is checked against the
#    container's own step count, and the ranges are ascending and disjoint
#    because the server handles one request at a time.
# 4. The metadata keys arrive in the documented display order, since order is
#    part of the wire contract.

require 'English'
require 'minitest/autorun'

require_relative '../test-programs/web/session_driver'

$LOAD_PATH.unshift(File.expand_path('../gems/codetracer-ruby-recorder/lib', __dir__))
require 'codetracer/native'

# Shared assertions over a recorded web session.
module RequestSpanAssertions
  SPAN_STATUS_OK = 1
  SPAN_STATUS_ERROR = 2

  # One expected row of the schedule.
  Expected = Struct.new(:http_method, :url, :status, :route, :error, keyword_init: true)

  # Record `schedule` against `framework` and return the decoded settled
  # web-request spans plus the container path and its step count.
  def record_session(framework, schedule)
    dir = Dir.mktmpdir("codetracer-#{framework}-spans-")
    @trace_dirs << dir
    server = CodeTracerDemo::ServerUnderRecorder.new(framework, dir)
    server.start
    begin
      statuses = schedule.map do |row|
        status, = server.request(row.url, method: row.http_method.capitalize,
                                          body: row.http_method == 'POST' ? '{"name":"Carol"}' : nil)
        status
      end
    ensure
      server.stop
    end

    schedule.each_with_index do |row, i|
      assert_equal row.status, statuses[i],
                   "request #{i} (#{row.http_method} #{row.url}) returned #{statuses[i]}\n#{server.log}"
    end

    container = server.container
    spans = CodeTracer::Native.read_span_stream(container)
    web = spans.select { |s| s['span_type'] == 'web-request' }
    [container, web, CodeTracer::Native.trace_step_count(container), server]
  end

  def meta(span, key, default = '')
    CodeTracer::Native.span_metadata_value(span, key, default)
  end

  # Everything that must hold for any recorded session, whatever the framework.
  def assert_session(framework:, schedule:, container:, spans:, step_count:, server:)
    assert_equal schedule.length, spans.length,
                 "expected one settled span per request\n#{server.log}"

    # Every request was published open and then settled: the append-only stream
    # holds two records per request, and last-record-wins collapses them.
    raw = CodeTracer::Native.read_span_stream(container, settled: false)
    assert_equal schedule.length * 2, raw.length,
                 'expected an open record and a settled record per request'
    assert_equal schedule.length, raw.count { |s| s['is_open'] }
    # The open record is appended BEFORE the request is handled, so in a
    # sequential session it always precedes its own settled record.
    schedule.length.times do |i|
      assert raw[2 * i]['is_open'], "record #{2 * i} should be the open record"
      refute raw[(2 * i) + 1]['is_open'], "record #{(2 * i) + 1} should be the settled record"
      assert_equal raw[2 * i]['span_id'], raw[(2 * i) + 1]['span_id']
    end

    previous_end = nil
    spans.each_with_index do |span, i|
      want = schedule[i]
      context = "span #{i} (#{span['label']})"

      assert_equal "#{want.http_method} #{want.url}", span['label'], context
      assert_equal want.http_method, meta(span, 'http.method'), context
      assert_equal want.url, meta(span, 'http.url'), context
      assert_equal want.status.to_s, meta(span, 'http.status_code'), context
      assert_equal want.route, meta(span, 'http.route'), context
      assert_equal framework, meta(span, 'framework'), context
      assert_equal '127.0.0.1', meta(span, 'http.remote_addr'), context
      assert_equal(want.status >= 400 ? SPAN_STATUS_ERROR : SPAN_STATUS_OK,
                   span['status'], context)
      refute span['is_open'], context
      # Inline binding: the steps live in THIS container, which is what makes
      # the span seekable and a sidecar row not.
      refute span['is_external'], context

      if want.error
        assert_match(/\A#{Regexp.escape(want.error)}/, meta(span, 'error.message'),
                     "#{context}: expected error.message naming the raised exception")
      else
        assert_equal '', meta(span, 'error.message'), "#{context}: unexpected error.message"
      end

      assert_operator meta(span, 'http.duration_ms').to_i, :>=, 0, context

      # --- the step range is a coordinate in this container ---
      assert_operator span['start_step'], :>, 0, "#{context}: start_step"
      assert_operator span['end_step'], :>=, span['start_step'], "#{context}: end_step"
      assert_operator span['end_step'], :<, step_count,
                      "#{context}: end_step must be a step of this container (#{step_count} steps)"
      # One request at a time, so the ranges are ascending and disjoint.
      assert_operator span['start_step'], :>, previous_end, "#{context}: overlaps its predecessor" if previous_end
      previous_end = span['end_step']

      # Sequential serving: the spans say so rather than claiming concurrency.
      assert span['contiguous_on_one_thread'], context
      refute span['concurrent_with_siblings'], context
      assert span['shares_timeline'], context
      # The thread coordinate is the recorder's own thread id, so it names a
      # thread the container has actually seen.
      assert_operator span['thread_id'], :>, 0, "#{context}: thread_id"

      # Metadata order is part of the wire contract.
      keys = span['metadata'].map(&:first)
      assert_equal %w[http.method http.url http.status_code http.duration_ms], keys.first(4), context
      assert_operator keys.index('framework'), :>, keys.index('http.route'), context
      assert_equal 'error.message', keys.last, context if want.error
    end

    # Span ids are 1-based and monotonic within the container.
    assert_equal (1..schedule.length).to_a, spans.map { |s| s['span_id'] }
  end
end

class TestRequestSpans < Minitest::Test
  include RequestSpanAssertions

  # Recording a session starts a real server and drives real HTTP; the default
  # minitest timeout does not apply, but a stuck server must not hang CI, so
  # `ServerUnderRecorder` bounds every wait itself.
  def setup
    @trace_dirs = []
    # A stray manifest variable in the developer's shell would re-enable the
    # sidecar this milestone took off the recorded path.
    @saved_manifest = ENV.delete('CODETRACER_SPAN_MANIFEST')
  end

  def teardown
    ENV['CODETRACER_SPAN_MANIFEST'] = @saved_manifest if @saved_manifest
    @trace_dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # Five requests through the Rack middleware against a real Sinatra app on a
  # real TCP server, including a handler that raises.
  def test_rack_requests_land_in_span_stream
    schedule = [
      Expected.new(http_method: 'GET', url: '/api/users', status: 200, route: '/api/users'),
      Expected.new(http_method: 'GET', url: '/api/users/2', status: 200, route: '/api/users/:user_id'),
      Expected.new(http_method: 'GET', url: '/static/app.css', status: 304, route: '/static/app.css'),
      Expected.new(http_method: 'GET', url: '/api/users/999', status: 404, route: '/api/users/:user_id'),
      Expected.new(http_method: 'GET', url: '/api/boom', status: 500, route: '/api/boom',
                   error: 'ArgumentError: demo failure in /api/boom')
    ]

    container, spans, step_count, server = record_session('sinatra', schedule)
    assert_session(framework: 'sinatra', schedule: schedule, container: container,
                   spans: spans, step_count: step_count, server: server)

    # The exception path is the reason this test issues five requests rather
    # than four: the raising handler must produce an ERROR span carrying the
    # exception, not merely a 500 row.
    boom = spans.last
    assert_equal SPAN_STATUS_ERROR, boom['status']
    assert_equal 'ArgumentError: demo failure in /api/boom', meta(boom, 'error.message')

    # And a 404 is an error status WITHOUT an error message: the two are
    # independent, so a span that carried one whenever it carried the other
    # would pass a weaker test than this.
    not_found = spans[3]
    assert_equal SPAN_STATUS_ERROR, not_found['status']
    assert_equal '', meta(not_found, 'error.message')

    # Sidecar emission is opt-in since RS-M6; a recorded session must not have
    # written one behind the container's back.
    refute File.exist?(File.join(Dir.tmpdir, 'codetracer_spans.jsonl')),
           'the recorded path must not write a JSONL sidecar'
  end

  # The same shape against a real Rails app, where `http.route` comes from the
  # Rails router.
  def test_rails_requests_land_in_span_stream
    schedule = [
      Expected.new(http_method: 'GET', url: '/api/users', status: 200, route: '/api/users'),
      Expected.new(http_method: 'POST', url: '/api/users', status: 201, route: '/api/users'),
      Expected.new(http_method: 'GET', url: '/api/users/2', status: 200, route: '/api/users/:user_id'),
      Expected.new(http_method: 'GET', url: '/api/users/999', status: 404, route: '/api/users/:user_id'),
      Expected.new(http_method: 'GET', url: '/api/boom', status: 500, route: '/api/boom',
                   error: 'ArgumentError: demo failure in /api/boom')
    ]

    container, spans, step_count, server = record_session('rails', schedule)
    assert_session(framework: 'rails', schedule: schedule, container: container,
                   spans: spans, step_count: step_count, server: server)

    # THE assertion of this test: two different concrete URLs that matched the
    # same route report the same PATTERN, and neither reports its own path.
    # `http.route` therefore genuinely comes from the router.
    by_url = spans.to_h { |s| [meta(s, 'http.url'), meta(s, 'http.route')] }
    assert_equal '/api/users/:user_id', by_url['/api/users/2']
    assert_equal '/api/users/:user_id', by_url['/api/users/999']
    refute_equal '/api/users/2', by_url['/api/users/2']

    # Rails' own `ShowExceptions` turned the raised error into the 500 the
    # client saw; the middleware sits above it and still records what went
    # wrong, from `env['action_dispatch.exception']`.
    assert_equal 'ArgumentError: demo failure in /api/boom', meta(spans.last, 'error.message')
  end
end
