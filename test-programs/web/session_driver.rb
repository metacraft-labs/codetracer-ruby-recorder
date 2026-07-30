# frozen_string_literal: true

# Drive a recorded web session (RS-M6) — shared by the tests and the demo.
#
# Everything here is real: a real server subprocess started by `serve.rb` with
# the recorder active, real HTTP over loopback, a real `.ct` container decoded
# by the canonical Nim span reader.
#
# Two users:
#
# * `test/test_request_spans.rb` uses {ServerUnderRecorder} directly, so each
#   test chooses its own request schedule.
# * `just demo-request-panel-ruby` (and the codetracer-side fixture
#   regeneration) runs this file as a script, which records {DEMO_REQUESTS} — a
#   schedule covering every status bucket the Request Panel colours — and prints
#   the resulting spans.
#
# Run it standalone with:
#
#     ruby test-programs/web/session_driver.rb --framework sinatra \
#         --trace-dir /tmp/ct-demo-ruby --print-spans

require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'uri'

module CodeTracerDemo
  REPO_ROOT = File.expand_path('../..', __dir__)
  SERVE_SCRIPT = File.join(__dir__, 'serve.rb')
  FRAMEWORKS = %w[sinatra rails].freeze

  # Kept in step with `rack_server.rb`'s own constant.  `serve.rb` answers this
  # path ABOVE the Rack app, so shutting the server down produces no span and
  # every assertion can talk about the requests the schedule issued.
  SHUTDOWN_PATH = '/__shutdown'

  # The demo request schedule: `[method, path, body]`.
  #
  # Chosen so a panel opened on the resulting container shows something worth
  # looking at: every status bucket it colours (2xx, 3xx, 4xx, 5xx), two
  # methods, a parameterised route, a duration on each side of the "instant"
  # boundary, a handler that raises, and a shared `/api/users` prefix for the
  # search box to narrow.
  DEMO_REQUESTS = [
    ['GET', '/api/users', nil],
    ['POST', '/api/users', '{"name":"Carol"}'],
    ['GET', '/api/users/2', nil],
    ['GET', '/static/app.css', nil],
    ['GET', '/api/users/999', nil],
    ['GET', '/api/reports/slow', nil],
    ['GET', '/api/boom', nil],
    ['GET', '/api/users', nil]
  ].freeze

  # A real server subprocess, recorded, driven over real HTTP.
  #
  # The subprocess is `serve.rb` run under `bin/codetracer-ruby-recorder`: it
  # starts a recording, serves the chosen demo app, and on `POST /__shutdown`
  # (or `SIGTERM`) stops so the container — span stream included — is written.
  # {#stop} performs that shutdown and asserts the process exited cleanly.
  class ServerUnderRecorder
    attr_reader :framework, :trace_dir, :port, :base, :output

    def initialize(framework, trace_dir, ready_timeout: 300, stop_timeout: 180,
                   request_timeout: 120)
      raise ArgumentError, "unknown framework #{framework}" unless FRAMEWORKS.include?(framework)

      @framework = framework
      @trace_dir = trace_dir
      # Every wait is bounded so a stuck server fails the caller instead of
      # hanging it.  The defaults are generous — a recorded server loads its
      # framework before it listens — and a caller that EXPECTS trouble should
      # shorten them rather than wait the defaults out.
      @ready_timeout = ready_timeout
      @stop_timeout = stop_timeout
      @request_timeout = request_timeout
      @output = []
    end

    # Start the recorded server and block until it prints `READY <port>`.
    def start
      FileUtils.mkdir_p(@trace_dir)

      env = {
        # A stray manifest variable from the developer's shell would re-enable
        # the sidecar this milestone took off the recorded path.
        'CODETRACER_SPAN_MANIFEST' => nil,
        'CODETRACER_RUBY_RECORDER_OUT_DIR' => @trace_dir
      }
      # `serve.rb` drives the recorder as a LIBRARY rather than running under
      # `bin/codetracer-ruby-recorder`, so that the framework is loaded before
      # the event hook is armed; see that file's header for why that is the
      # difference between a two-second demo and one that never finishes.
      argv = [RbConfig.ruby, SERVE_SCRIPT,
              '--framework', @framework, '--trace-dir', @trace_dir, '--port', '0']
      @stdin, @stdout, @wait_thread = Open3.popen2e(env, *argv, chdir: REPO_ROOT)
      @stdin.close

      # The READY line carries the port the server actually bound, so the
      # driver never has to guess a free one or race another test for it.
      deadline = Time.now + @ready_timeout
      @port = nil
      until @port
        raise "#{@framework} server never became ready in #{@ready_timeout}s:\n#{log}" if Time.now > deadline

        line = read_line_with_deadline(deadline)
        if line.nil?
          raise "#{@framework} server exited before serving:\n#{log}" unless @wait_thread.alive?

          next
        end
        @output << line.chomp
        @port = Regexp.last_match(1).to_i if line =~ /\AREADY (\d+)/
      end
      @base = "http://127.0.0.1:#{@port}"
      self
    end

    # Issue one real HTTP request and return `[status, body]`.
    #
    # A 4xx / 5xx is a legitimate outcome (the schedules deliberately provoke
    # both), so an error response is returned rather than raised.
    def request(path, method: 'GET', body: nil)
      uri = URI("#{@base}#{path}")
      klass = Net::HTTP.const_get(method.capitalize)
      req = klass.new(uri)
      if body
        req.body = body
        req['Content-Type'] = 'application/json'
      end
      res = Net::HTTP.start(uri.hostname, uri.port,
                            read_timeout: @request_timeout,
                            open_timeout: @request_timeout) do |http|
        http.request(req)
      end
      [res.code.to_i, res.body.to_s]
    end

    # Ask the server to stop, then wait for the recording to be written.
    def stop
      return if @stopped

      @stopped = true
      begin
        request(CodeTracerDemo::SHUTDOWN_PATH, method: 'Post')
      rescue StandardError
        # The server may already be gone; the exit-status check below is what
        # actually decides whether the run was clean.
        nil
      end
      unless @wait_thread.join(@stop_timeout)
        Process.kill('KILL', @wait_thread.pid)
        @wait_thread.join
        raise "#{@framework} server did not stop within #{@stop_timeout}s:\n#{log}"
      end
      drain_output
      status = @wait_thread.value
      raise "#{@framework} server exited with #{status.exitstatus}:\n#{log}" unless status.success?
    end

    # The single `.ct` container the recording produced.
    def container
      containers = Dir.glob(File.join(@trace_dir, '*.ct')).sort
      raise "no .ct container in #{@trace_dir}:\n#{log}" if containers.empty?
      raise "expected one container, got #{containers.inspect}" unless containers.length == 1

      containers.first
    end

    def log
      @output.join("\n")
    end

    private

    def read_line_with_deadline(deadline)
      remaining = deadline - Time.now
      return nil if remaining <= 0
      return nil if IO.select([@stdout], nil, nil, [remaining, 0.5].min).nil?

      @stdout.gets
    rescue IOError, Errno::EBADF
      nil
    end

    def drain_output
      while (line = @stdout.gets)
        @output << line.chomp
      end
    rescue IOError, Errno::EBADF
      nil
    ensure
      begin
        @stdout.close
      rescue StandardError
        nil
      end
    end
  end

  # Record {DEMO_REQUESTS} against `framework` into `trace_dir`.
  #
  # Returns `[container_path, statuses]`, so a caller can report what the
  # session actually served.
  def self.record_demo_session(framework, trace_dir)
    server = ServerUnderRecorder.new(framework, trace_dir)
    server.start
    statuses = DEMO_REQUESTS.map do |method, path, body|
      status, = server.request(path, method: method.capitalize, body: body)
      status
    end
    server.stop
    [server.container, statuses]
  end
end

if __FILE__ == $PROGRAM_NAME
  require 'optparse'

  opts = { framework: 'sinatra', print_spans: false }
  OptionParser.new do |parser|
    parser.on('--framework NAME', CodeTracerDemo::FRAMEWORKS) { |v| opts[:framework] = v }
    parser.on('--trace-dir DIR') { |v| opts[:trace_dir] = v }
    parser.on('--print-spans') { opts[:print_spans] = true }
  end.parse!

  abort('--trace-dir is required') unless opts[:trace_dir]

  FileUtils.rm_rf(opts[:trace_dir])
  FileUtils.mkdir_p(opts[:trace_dir])
  container, statuses = CodeTracerDemo.record_demo_session(opts[:framework], opts[:trace_dir])
  puts "recorded #{statuses.length} requests -> #{container}"

  if opts[:print_spans]
    $LOAD_PATH.unshift(File.join(CodeTracerDemo::REPO_ROOT, 'gems', 'codetracer-ruby-recorder', 'lib'))
    require 'codetracer/native'
    CodeTracer::Native.read_span_stream(container).each do |span|
      meta = span['metadata'].to_h
      printf("  span %3d  %-28s status=%3s %5sms steps %d..%d route=%s\n",
             span['span_id'], span['label'],
             meta.fetch('http.status_code', '?'), meta.fetch('http.duration_ms', '?'),
             span['start_step'], span['end_step'], meta.fetch('http.route', '-'))
    end
  end
end
