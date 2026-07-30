# frozen_string_literal: true

# A minimal, SINGLE-THREADED HTTP server for a Rack app (RS-M6).
#
# Used by `serve.rb` to serve the demo apps under the recorder.  It exists
# instead of WEBrick / Puma for three reasons:
#
# 1. **One thread.**  Every request is accepted and handled on the MAIN thread,
#    so the recorded step timeline is a strict sequence of request handling and
#    a sequential client sees strictly disjoint span step ranges.  The recorder
#    hooks Ruby's LINE / CALL / RETURN events and serialises them through one
#    writer, so a thread-per-request server would interleave the timeline and
#    make every span's range meaningless.
# 2. **No dependency.**  The recorder's dev shell would otherwise need a server
#    gem purely to prove the middleware works.
# 3. **Explicit shutdown.**  The container is written only when the recording
#    stops, so a killed process yields no trace at all.  `POST /__shutdown`
#    (handled HERE, above the Rack app, so it never becomes a span) ends the
#    accept loop, `load` returns, and the recorder flushes.
#
# It implements only the HTTP/1.1 subset the tests and the demo need:
# a request line, headers, an optional `Content-Length` body, and a
# `Connection: close` response.

require 'socket'
require 'stringio'
require 'uri'

module CodeTracerDemo
  # Serves one Rack app on one thread until asked to stop.
  class RackServer
    CRLF = "\r\n"

    # The path that ends the accept loop.  Answered before the Rack app is
    # invoked, so shutting the server down does not add a span to the recording
    # (which would then have to be excluded from every assertion).
    SHUTDOWN_PATH = '/__shutdown'

    attr_reader :port

    # Binds the listening socket immediately, so a client that connects the
    # moment it sees the READY line is queued in the backlog and served rather
    # than refused.
    def initialize(app, host: '127.0.0.1', port: 0)
      @app = app
      @server = TCPServer.new(host, port)
      @port = @server.addr[1]
      @running = false
    end

    # Accept and handle connections until `POST /__shutdown` arrives or `stop`
    # is called (from a signal handler, say).
    #
    # `IO.select` with a timeout rather than a bare blocking `accept` so a
    # `stop` from a signal handler is noticed promptly without a second thread.
    def serve
      @running = true
      while @running
        ready = IO.select([@server], nil, nil, 0.1)
        next if ready.nil?

        client = begin
          @server.accept_nonblock
        rescue IO::WaitReadable, Errno::EINTR
          next
        rescue IOError, Errno::EBADF
          break
        end
        begin
          handle_connection(client)
        ensure
          begin
            client.close
          rescue StandardError
            nil
          end
        end
      end
    ensure
      begin
        @server.close
      rescue StandardError
        nil
      end
    end

    def stop
      @running = false
    end

    private

    def handle_connection(client)
      request_line = client.gets
      return if request_line.nil?

      http_method, target, = request_line.strip.split(' ', 3)
      return if http_method.nil? || target.nil?

      headers = read_headers(client)
      body = read_body(client, headers)
      uri = URI.parse(target)

      if uri.path == SHUTDOWN_PATH
        stop
        write_response(client, 200, { 'content-type' => 'text/plain' }, ['stopping'])
        return
      end

      env = build_env(http_method, uri, headers, body)
      begin
        status, response_headers, response_body = @app.call(env)
      rescue StandardError => e
        # The demo apps deliberately include a handler that raises, so that the
        # middleware's rescue path — and the `error.message` it records — is
        # exercised end to end.  The client still gets a well-formed 500.
        write_response(client, 500, { 'content-type' => 'text/plain' },
                       ["#{e.class}: #{e.message}"])
        return
      end
      write_response(client, status, response_headers, response_body)
    end

    def read_headers(client)
      headers = {}
      while (line = client.gets)
        break if line.strip.empty?

        key, value = line.split(':', 2)
        headers[key.strip.downcase] = value.strip if key && value
      end
      headers
    end

    def read_body(client, headers)
      length = headers['content-length'].to_i
      length.positive? ? client.read(length).to_s : ''
    end

    # A Rack environment with the keys the SPEC requires plus the ones the
    # demo apps and the middleware read.  See
    # https://github.com/rack/rack/blob/main/SPEC.rdoc
    def build_env(http_method, uri, headers, body)
      env = {
        'REQUEST_METHOD' => http_method,
        'SCRIPT_NAME' => '',
        'PATH_INFO' => uri.path,
        'REQUEST_PATH' => uri.path,
        'REQUEST_URI' => uri.to_s,
        'QUERY_STRING' => uri.query || '',
        'SERVER_NAME' => '127.0.0.1',
        'SERVER_PORT' => @port.to_s,
        'SERVER_PROTOCOL' => 'HTTP/1.1',
        'HTTP_HOST' => headers['host'] || "127.0.0.1:#{@port}",
        'REMOTE_ADDR' => '127.0.0.1',
        'rack.input' => StringIO.new(body),
        'rack.errors' => $stderr,
        'rack.url_scheme' => 'http'
      }
      headers.each do |key, value|
        env["HTTP_#{key.upcase.tr('-', '_')}"] = value
      end
      env['CONTENT_TYPE'] = headers['content-type'] if headers['content-type']
      env['CONTENT_LENGTH'] = headers['content-length'] if headers['content-length']
      env
    end

    def write_response(client, status, headers, body)
      chunks = []
      body.each { |chunk| chunks << chunk.to_s }
      payload = chunks.join
      client.write("HTTP/1.1 #{status}#{CRLF}")
      (headers || {}).each do |key, value|
        # Rack 3 allows an Array value for repeated headers.
        Array(value).each { |v| client.write("#{key}: #{v}#{CRLF}") }
      end
      client.write("content-length: #{payload.bytesize}#{CRLF}") unless has_content_length?(headers)
      client.write("connection: close#{CRLF}")
      client.write(CRLF)
      client.write(payload)
      body.close if body.respond_to?(:close)
    end

    def has_content_length?(headers)
      (headers || {}).any? { |key, _| key.to_s.downcase == 'content-length' }
    end
  end
end
