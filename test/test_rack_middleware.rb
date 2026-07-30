# frozen_string_literal: true

# Unit coverage for `CodeTracer::Rack::Middleware` in the configuration no
# other test in this repo exercises: **with no recorder installed**.
#
# A Rack application may be deployed with the middleware mounted and the
# native recorder absent — that is why `span_recorder.rb` duplicates the span
# status constants instead of reading them from `CodeTracer::Native`.  In that
# configuration nothing is written anywhere, so what has to hold is that the
# middleware is *invisible*: the wrapped app's status, headers and body pass
# through unchanged, its exceptions are re-raised, and the request/response
# cycle costs the application nothing.
#
# ## What changed in RS-M12
#
# This file used to assert all of the above indirectly, by pointing
# `CODETRACER_SPAN_MANIFEST` at a temporary file and reading the JSONL rows the
# middleware appended to it.  RS-M12 removed that writer (see
# `span_recorder.rb`'s "No sidecar" section), so the rows no longer exist.
#
# The span CONTENT those rows carried — method, url, status, duration, route,
# framework, error.message, the label, the span type, the error status, the
# metadata ORDER and the open/settled pairing — is asserted by
# `test_request_spans.rb` against a real recorded container, over real HTTP,
# against a real Sinatra and a real Rails app.  That is strictly stronger:
# a container span also names the step range the request occupies, which a
# sidecar row never could.  What was NOT covered anywhere else is the
# no-recorder path, so that is what this file keeps, plus a direct guard that
# the sidecar writer stays gone.
require 'English'
require 'minitest/autorun'
require 'tmpdir'
require 'rack'
require_relative '../gems/codetracer-rack/lib/codetracer-rack'

class TestRackMiddleware < Minitest::Test
  def setup
    # Deliberately switched ON.  Before RS-M12 this made the middleware append
    # a JSONL row per request; now nothing may appear at this path, and
    # asserting that with the variable UNSET would only have tested the
    # default rather than the removal.
    @manifest_path = File.join(Dir.tmpdir, "codetracer_test_spans_#{$PROCESS_ID}.jsonl")
    @saved_manifest = ENV['CODETRACER_SPAN_MANIFEST']
    ENV['CODETRACER_SPAN_MANIFEST'] = @manifest_path
    File.delete(@manifest_path) if File.exist?(@manifest_path)
  end

  def teardown
    File.delete(@manifest_path) if File.exist?(@manifest_path)
    if @saved_manifest
      ENV['CODETRACER_SPAN_MANIFEST'] = @saved_manifest
    else
      ENV.delete('CODETRACER_SPAN_MANIFEST')
    end
  end

  def simple_app
    ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['OK']] }
  end

  def error_app
    ->(_env) { [500, { 'Content-Type' => 'text/plain' }, ['Error']] }
  end

  def raising_app
    ->(_env) { raise 'kaboom' }
  end

  def assert_no_sidecar(context)
    refute File.exist?(@manifest_path),
           "#{context}: CODETRACER_SPAN_MANIFEST must no longer produce a sidecar"
    refute File.exist?(File.join(Dir.tmpdir, 'codetracer_spans.jsonl')),
           "#{context}: no sidecar may be written to the old default path"
  end

  def test_rack_middleware_is_transparent_to_the_wrapped_app
    app = CodeTracer::Rack::Middleware.new(simple_app)

    3.times do |i|
      env = ::Rack::MockRequest.env_for("/api/test#{i}", method: 'GET')
      status, headers, body = app.call(env)
      assert_equal 200, status
      assert_equal 'text/plain', headers['Content-Type']
      assert_equal ['OK'], body.to_a
    end

    assert_no_sidecar('three GETs')
  end

  def test_rack_middleware_passes_every_method_through
    app = CodeTracer::Rack::Middleware.new(simple_app)

    [%w[GET /users], %w[POST /users], %w[DELETE /users/1]].each do |method, path|
      env = ::Rack::MockRequest.env_for(path, method: method)
      status, = app.call(env)
      assert_equal 200, status, "#{method} #{path}"
    end

    assert_no_sidecar('mixed methods')
  end

  def test_rack_middleware_passes_an_error_status_through
    app = CodeTracer::Rack::Middleware.new(error_app)
    env = ::Rack::MockRequest.env_for('/fail', method: 'POST')
    status, _headers, body = app.call(env)

    assert_equal 500, status
    assert_equal ['Error'], body.to_a
    assert_no_sidecar('500 response')
  end

  def test_rack_middleware_reraises_the_application_exception
    # The middleware settles the span from a `rescue`/`ensure` pair, so the
    # failure mode it must not have is swallowing the exception on the way.
    app = CodeTracer::Rack::Middleware.new(raising_app)
    env = ::Rack::MockRequest.env_for('/boom', method: 'GET')

    error = assert_raises(RuntimeError) { app.call(env) }
    assert_equal 'kaboom', error.message
    assert_no_sidecar('raising handler')
  end

  def test_status_maps_to_the_span_status_the_panel_colours
    # The mapping is what decides a row's colour in the Request Panel, and it
    # is a pure function, so it is asserted here rather than only through a
    # recorded session.
    klass = CodeTracer::Rack::PendingRequestSpan
    assert_equal CodeTracer::Rack::SPAN_STATUS_UNKNOWN, klass.status_for(nil)
    assert_equal CodeTracer::Rack::SPAN_STATUS_UNKNOWN, klass.status_for(0)
    assert_equal CodeTracer::Rack::SPAN_STATUS_OK, klass.status_for(200)
    assert_equal CodeTracer::Rack::SPAN_STATUS_OK, klass.status_for(304)
    assert_equal CodeTracer::Rack::SPAN_STATUS_ERROR, klass.status_for(404)
    assert_equal CodeTracer::Rack::SPAN_STATUS_ERROR, klass.status_for(500)
  end

  def test_the_recorder_no_longer_accepts_a_manifest_path
    # RS-M12 removed the option as well as the writer, so a caller that still
    # passes it gets a loud ArgumentError instead of a silently ignored kwarg.
    assert_raises(ArgumentError) do
      CodeTracer::Rack::RequestSpanRecorder.new(manifest_path: @manifest_path)
    end
  end
end
