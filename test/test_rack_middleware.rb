# frozen_string_literal: true

require 'English'
require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'rack'
require_relative '../gems/codetracer-rack/lib/codetracer-rack'

class TestRackMiddleware < Minitest::Test
  def setup
    @manifest_path = File.join(Dir.tmpdir, "codetracer_test_spans_#{$PROCESS_ID}.jsonl")
    ENV['CODETRACER_SPAN_MANIFEST'] = @manifest_path
    File.delete(@manifest_path) if File.exist?(@manifest_path)
  end

  def teardown
    File.delete(@manifest_path) if File.exist?(@manifest_path)
    ENV.delete('CODETRACER_SPAN_MANIFEST')
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

  def test_rack_middleware_emits_spans
    app = CodeTracer::Rack::Middleware.new(simple_app)

    # Send 3 requests
    3.times do |i|
      env = Rack::MockRequest.env_for("/api/test#{i}", method: 'GET')
      status, = app.call(env)
      assert_equal 200, status
    end

    # Verify 3 spans in manifest
    lines = File.readlines(@manifest_path)
    assert_equal 3, lines.length

    spans = lines.map { |l| JSON.parse(l) }
    spans.each_with_index do |span, i|
      assert_equal "GET /api/test#{i}", span['label']
      assert_equal 'web-request', span['span_type']
      assert_equal 'GET', span['metadata']['http.method']
      assert_equal "/api/test#{i}", span['metadata']['http.url']
      assert_equal '200', span['metadata']['http.status_code']
      assert_equal 'ok', span['status']
      assert span['metadata'].key?('http.duration_ms'), 'expected duration_ms in metadata'
      assert span.key?('start_time'), 'expected start_time'
      assert span.key?('end_time'), 'expected end_time'
    end
  end

  def test_span_manifest_from_recording
    app = CodeTracer::Rack::Middleware.new(simple_app)

    # Mix of methods
    methods_paths = [
      ['GET', '/users'],
      ['POST', '/users'],
      ['DELETE', '/users/1']
    ]

    methods_paths.each do |method, path|
      env = Rack::MockRequest.env_for(path, method: method)
      app.call(env)
    end

    lines = File.readlines(@manifest_path)
    assert_equal 3, lines.length

    spans = lines.map { |l| JSON.parse(l) }
    assert_equal 'GET', spans[0]['metadata']['http.method']
    assert_equal 'POST', spans[1]['metadata']['http.method']
    assert_equal 'DELETE', spans[2]['metadata']['http.method']

    assert_equal '/users', spans[0]['metadata']['http.url']
    assert_equal '/users', spans[1]['metadata']['http.url']
    assert_equal '/users/1', spans[2]['metadata']['http.url']
  end

  def test_error_span
    app = CodeTracer::Rack::Middleware.new(error_app)
    env = Rack::MockRequest.env_for('/fail', method: 'POST')
    status, = app.call(env)
    assert_equal 500, status

    lines = File.readlines(@manifest_path)
    assert_equal 1, lines.length
    span = JSON.parse(lines[0])
    assert_equal 'error', span['status']
    assert_equal '500', span['metadata']['http.status_code']
    assert_equal 'POST /fail', span['label']
  end

  def test_exception_records_error_span_and_reraises
    app = CodeTracer::Rack::Middleware.new(raising_app)
    env = Rack::MockRequest.env_for('/boom', method: 'GET')

    assert_raises(RuntimeError) { app.call(env) }

    lines = File.readlines(@manifest_path)
    assert_equal 1, lines.length
    span = JSON.parse(lines[0])
    assert_equal 'error', span['status']
    assert_equal '500', span['metadata']['http.status_code']
    assert_equal 'GET /boom', span['label']
  end

  def test_span_has_valid_id
    app = CodeTracer::Rack::Middleware.new(simple_app)
    env = Rack::MockRequest.env_for('/check-id', method: 'GET')
    app.call(env)

    lines = File.readlines(@manifest_path)
    span = JSON.parse(lines[0])
    assert_match(/\Aspan_/, span['id'], 'span id should start with span_ prefix')
  end
end
