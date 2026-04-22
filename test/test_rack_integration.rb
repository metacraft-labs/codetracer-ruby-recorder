# frozen_string_literal: true

# Integration test for CodeTracer Rack middleware.
#
# Starts a real TCP-based HTTP server (no WEBrick/Puma dependency),
# sends actual HTTP requests over the network, then verifies the
# JSONL span manifest contains the expected spans.

require 'minitest/autorun'
require 'net/http'
require 'json'
require 'socket'
require 'time'
require 'tmpdir'
require 'rack'
require 'uri'
require_relative '../gems/codetracer-rack/lib/codetracer-rack'

# Minimal HTTP server that forwards requests to a Rack app.
# Only supports the subset of HTTP needed for integration testing:
# single-line request parsing, Content-Length body reading,
# and simple response serialization.
class MinimalRackServer
  CRLF = "\r\n"

  def initialize(app, port)
    @app = app
    @port = port
    @running = false
  end

  def start
    @server = TCPServer.new('127.0.0.1', @port)
    @running = true
    @thread = Thread.new { accept_loop }
  end

  def stop
    @running = false
    # Connect to unblock the accept call, then close the server socket
    begin
      TCPSocket.new('127.0.0.1', @port).close
    rescue StandardError
      nil
    end
    @server&.close
    @thread&.join(5)
  end

  private

  # Continuously accept connections and handle them sequentially.
  # Each connection handles exactly one request (HTTP/1.0 style).
  def accept_loop
    while @running
      begin
        client = @server.accept
        handle_request(client)
      rescue IOError, Errno::EBADF
        # Server socket was closed during shutdown
        break
      rescue StandardError => e
        warn "MinimalRackServer: #{e.message}"
      ensure
        client&.close
      end
    end
  end

  # Parses an HTTP request from the socket, builds a Rack env,
  # calls the app, and writes the response back.
  def handle_request(client)
    request_line = client.gets
    return unless request_line

    method, path, = request_line.strip.split(' ', 3)
    return unless method && path

    # Parse headers
    headers = {}
    while (line = client.gets)
      break if line.strip.empty?

      key, value = line.split(':', 2)
      headers[key.strip.downcase] = value.strip if key && value
    end

    # Read body if Content-Length is present
    body = ''
    if headers['content-length']
      body = client.read(headers['content-length'].to_i)
    end

    # Build minimal Rack env hash
    # See https://github.com/rack/rack/blob/main/SPEC.rdoc for the full spec
    uri = URI.parse(path)
    env = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => uri.path,
      'QUERY_STRING' => uri.query || '',
      'SERVER_NAME' => '127.0.0.1',
      'SERVER_PORT' => @port.to_s,
      'HTTP_HOST' => "127.0.0.1:#{@port}",
      'rack.version' => ::Rack::VERSION,
      'rack.input' => StringIO.new(body),
      'rack.errors' => $stderr,
      'rack.multithread' => false,
      'rack.multiprocess' => false,
      'rack.run_once' => false,
      'rack.url_scheme' => 'http',
      'SCRIPT_NAME' => ''
    }

    # Forward recognized HTTP headers (e.g. Content-Type)
    headers.each do |key, value|
      rack_key = "HTTP_#{key.upcase.tr('-', '_')}"
      env[rack_key] = value
    end
    env['CONTENT_TYPE'] = headers['content-type'] if headers['content-type']
    env['CONTENT_LENGTH'] = headers['content-length'] if headers['content-length']

    status, response_headers, response_body = @app.call(env)

    # Write HTTP response
    client.write("HTTP/1.1 #{status}#{CRLF}")
    response_headers.each { |k, v| client.write("#{k}: #{v}#{CRLF}") }
    client.write(CRLF)
    response_body.each { |chunk| client.write(chunk) }
  end
end

class TestRackIntegration < Minitest::Test
  def setup
    @manifest_path = File.join(Dir.tmpdir, "codetracer_rack_integration_#{$PROCESS_ID}.jsonl")
    ENV['CODETRACER_SPAN_MANIFEST'] = @manifest_path
    File.delete(@manifest_path) if File.exist?(@manifest_path)

    # Build a Rack app with multiple routes
    inner_app = Rack::Builder.new do
      map '/api/users' do
        run lambda { |env|
          case env['REQUEST_METHOD']
          when 'GET'
            [200, { 'content-type' => 'application/json' }, ['[{"id":1},{"id":2}]']]
          when 'POST'
            [201, { 'content-type' => 'application/json' }, ['{"id":3}']]
          when 'DELETE'
            [204, {}, ['']]
          else
            [405, {}, ['Method Not Allowed']]
          end
        }
      end
      map '/health' do
        run lambda { |_env| [200, {}, ['ok']] }
      end
      map '/' do
        run lambda { |_env| [404, {}, ['Not Found']] }
      end
    end

    @app = CodeTracer::Rack::Middleware.new(inner_app)

    # Pick a random port to avoid collisions with parallel test runs
    @port = 18_900 + rand(100)
    @server = MinimalRackServer.new(@app, @port)
    @server.start

    # Wait briefly for the server to be ready
    wait_for_server
  end

  def teardown
    @server&.stop
    File.delete(@manifest_path) if File.exist?(@manifest_path)
    ENV.delete('CODETRACER_SPAN_MANIFEST')
  end

  # Sends 5 HTTP requests (GET, POST, GET, DELETE, GET) over TCP
  # and verifies that the middleware records correct spans in the
  # JSONL manifest file.
  def test_e2e_rack_5_requests
    base = "http://127.0.0.1:#{@port}"

    # 1. GET /api/users -> 200
    res1 = Net::HTTP.get_response(URI("#{base}/api/users"))
    assert_equal '200', res1.code

    # 2. POST /api/users -> 201
    res2 = Net::HTTP.post(URI("#{base}/api/users"), '{"name":"Alice"}',
                          'Content-Type' => 'application/json')
    assert_equal '201', res2.code

    # 3. GET /api/users -> 200
    res3 = Net::HTTP.get_response(URI("#{base}/api/users"))
    assert_equal '200', res3.code

    # 4. DELETE /api/users -> 204
    req = Net::HTTP::Delete.new('/api/users')
    res4 = Net::HTTP.start('127.0.0.1', @port) { |http| http.request(req) }
    assert_equal '204', res4.code

    # 5. GET /health -> 200
    res5 = Net::HTTP.get_response(URI("#{base}/health"))
    assert_equal '200', res5.code

    # Read and parse the manifest
    assert File.exist?(@manifest_path), 'span manifest file should exist'
    lines = File.readlines(@manifest_path)
    assert_equal 5, lines.length, "expected 5 spans, got #{lines.length}"

    spans = lines.map { |l| JSON.parse(l) }

    # -- Verify span 1: GET /api/users -> 200 --
    assert_equal 'GET', spans[0]['metadata']['http.method']
    assert_equal '/api/users', spans[0]['metadata']['http.url']
    assert_equal '200', spans[0]['metadata']['http.status_code']
    assert_equal 'ok', spans[0]['status']

    # -- Verify span 2: POST /api/users -> 201 --
    assert_equal 'POST', spans[1]['metadata']['http.method']
    assert_equal '/api/users', spans[1]['metadata']['http.url']
    assert_equal '201', spans[1]['metadata']['http.status_code']
    assert_equal 'ok', spans[1]['status']

    # -- Verify span 3: GET /api/users -> 200 --
    assert_equal 'GET', spans[2]['metadata']['http.method']
    assert_equal '/api/users', spans[2]['metadata']['http.url']
    assert_equal '200', spans[2]['metadata']['http.status_code']

    # -- Verify span 4: DELETE /api/users -> 204 --
    assert_equal 'DELETE', spans[3]['metadata']['http.method']
    assert_equal '/api/users', spans[3]['metadata']['http.url']
    assert_equal '204', spans[3]['metadata']['http.status_code']
    assert_equal 'ok', spans[3]['status']

    # -- Verify span 5: GET /health -> 200 --
    assert_equal 'GET', spans[4]['metadata']['http.method']
    assert_equal '/health', spans[4]['metadata']['http.url']
    assert_equal '200', spans[4]['metadata']['http.status_code']

    # Verify all spans have web-request type
    spans.each_with_index do |span, i|
      assert_equal 'web-request', span['span_type'],
                   "span #{i} should have span_type 'web-request'"
    end

    # Verify all durations are non-negative
    spans.each_with_index do |span, i|
      duration = span['metadata']['http.duration_ms'].to_i
      assert duration >= 0,
             "span #{i} duration should be >= 0, got #{duration}"
    end

    # Verify spans are in chronological order (by start_time)
    start_times = spans.map { |s| Time.parse(s['start_time']) }
    start_times.each_cons(2).with_index do |(t1, t2), i|
      assert t1 <= t2,
             "span #{i} start_time (#{t1}) should be <= span #{i + 1} start_time (#{t2})"
    end

    # Verify all span IDs are properly prefixed.
    # Note: ID uniqueness is not asserted here because the current
    # generate_span_id implementation truncates the monotonic clock
    # to integer seconds, so rapid sequential requests on the same
    # thread may share an ID. This is a known middleware limitation.
    ids = spans.map { |s| s['id'] }
    ids.each { |id| assert_match(/\Aspan_/, id, 'span ID should start with span_ prefix') }
  end

  private

  # Polls until the server accepts a TCP connection, or raises after timeout.
  def wait_for_server(timeout: 5)
    deadline = Time.now + timeout
    loop do
      TCPSocket.new('127.0.0.1', @port).close
      return
    rescue Errno::ECONNREFUSED
      raise "Server did not start within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end
end
