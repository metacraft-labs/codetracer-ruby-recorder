# frozen_string_literal: true

# Integration test for the CodeTracer Rack middleware over a real socket.
#
# Starts a real TCP-based HTTP server (no WEBrick/Puma dependency) and sends
# actual HTTP requests over the network, with **no recorder installed** — the
# configuration a Rack app is in when it mounts the middleware and the native
# extension is absent.  What must hold there is that the middleware is
# invisible: every response reaches the client byte for byte as the wrapped
# app produced it.
#
# ## What changed in RS-M12
#
# This test used to point `CODETRACER_SPAN_MANIFEST` at a temporary file and
# assert the JSONL rows the middleware appended to it.  RS-M12 removed that
# writer (see `gems/codetracer-rack/lib/codetracer/rack/span_recorder.rb`).
#
# The span content those rows carried is asserted by `test_request_spans.rb`
# against a REAL recorded container, over real HTTP, against a real Sinatra
# and a real Rails app — including the span type, the status mapping, the
# metadata order, the open/settled pairing and the step range, which a
# sidecar row never carried at all.  So nothing here is lost; what is added is
# a direct guard that setting the retired opt-in produces no file.

require 'English'
require 'minitest/autorun'
require 'net/http'
require 'socket'
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
    # Deliberately switched ON: RS-M12 removed the writer, so this asserts the
    # removal rather than today's default.
    @manifest_path = File.join(Dir.tmpdir, "codetracer_rack_integration_#{$PROCESS_ID}.jsonl")
    @saved_manifest = ENV['CODETRACER_SPAN_MANIFEST']
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
    if @saved_manifest
      ENV['CODETRACER_SPAN_MANIFEST'] = @saved_manifest
    else
      ENV.delete('CODETRACER_SPAN_MANIFEST')
    end
  end

  # Sends 5 HTTP requests (GET, POST, GET, DELETE, GET) over TCP and verifies
  # that the middleware passes every response through untouched and writes no
  # sidecar manifest, even with the retired opt-in switched on.
  def test_e2e_rack_5_requests
    base = "http://127.0.0.1:#{@port}"

    # 1. GET /api/users -> 200
    res1 = Net::HTTP.get_response(URI("#{base}/api/users"))
    assert_equal '200', res1.code
    assert_equal '[{"id":1},{"id":2}]', res1.body

    # 2. POST /api/users -> 201
    res2 = Net::HTTP.post(URI("#{base}/api/users"), '{"name":"Alice"}',
                          'Content-Type' => 'application/json')
    assert_equal '201', res2.code
    assert_equal '{"id":3}', res2.body

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
    assert_equal 'ok', res5.body

    # RS-M12: the opt-in that used to switch the sidecar writer back on is
    # SET for this test (see `setup`).  Nothing may appear at that path, nor
    # at the pre-RS-M6 default — asserted after five real requests over a real
    # socket, which is the only configuration in which a stray write would
    # have happened.
    refute File.exist?(@manifest_path),
           'CODETRACER_SPAN_MANIFEST must no longer produce a JSONL sidecar'
    refute File.exist?(File.join(Dir.tmpdir, 'codetracer_spans.jsonl')),
           'no sidecar may be written to the pre-RS-M6 default path'
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
