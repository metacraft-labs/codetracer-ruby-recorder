# frozen_string_literal: true

require 'json'
require 'tmpdir'

module CodeTracer
  module Rack
    # Rack middleware that wraps each HTTP request in a CodeTracer span.
    # Captures method, URL, status code, and duration as span metadata.
    #
    # Usage:
    #   use CodeTracer::Rack::Middleware
    #
    # In Rails:
    #   config.middleware.use CodeTracer::Rack::Middleware
    class Middleware
      def initialize(app, options = {})
        @app = app
        @options = options
      end

      def call(env)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO']

        # Record span start
        span_id = begin_span(method, path)

        status, headers, body = @app.call(env)

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        # Record span end with response metadata
        end_span(span_id, status, duration_ms, headers)

        [status, headers, body]
      rescue StandardError
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
        end_span(span_id, 500, duration_ms, {}) if span_id
        raise
      end

      private

      def begin_span(method, path)
        span = {
          id: generate_span_id,
          label: "#{method} #{path}",
          span_type: 'web-request',
          metadata: {
            'http.method' => method,
            'http.url' => path
          },
          start_time: Time.now.iso8601(3)
        }

        # Store in thread-local so end_span can access it
        Thread.current[:codetracer_current_span] = span

        # If the recorder native extension is available, call it
        if defined?(CodeTracer::Native) && CodeTracer::Native.respond_to?(:begin_span)
          CodeTracer::Native.begin_span(span.to_json)
        end

        span[:id]
      end

      def end_span(span_id, status, duration_ms, _headers)
        span = Thread.current[:codetracer_current_span]
        return unless span && span[:id] == span_id

        span[:metadata]['http.status_code'] = status.to_s
        span[:metadata]['http.duration_ms'] = duration_ms.to_s
        span[:end_time] = Time.now.iso8601(3)
        span[:status] = status >= 400 ? 'error' : 'ok'

        # Write span end marker via native extension if available
        if defined?(CodeTracer::Native) && CodeTracer::Native.respond_to?(:end_span)
          CodeTracer::Native.end_span(span.to_json)
        end

        # Write to manifest file (fallback when native extension not available)
        write_span_to_manifest(span)

        Thread.current[:codetracer_current_span] = nil
      end

      # Generates a unique span ID using thread identity and monotonic clock.
      def generate_span_id
        "span_#{Thread.current.object_id}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i}"
      end

      # Appends a completed span as a JSON line to the manifest file.
      # The manifest path is configurable via the CODETRACER_SPAN_MANIFEST
      # environment variable, defaulting to <tmpdir>/codetracer_spans.jsonl.
      def write_span_to_manifest(span)
        manifest_path = ENV['CODETRACER_SPAN_MANIFEST'] || File.join(Dir.tmpdir, 'codetracer_spans.jsonl')
        File.open(manifest_path, 'a') do |f|
          f.puts(span.to_json)
        end
      rescue StandardError => e
        # Don't crash the app if manifest writing fails
        warn "CodeTracer: failed to write span: #{e.message}"
      end
    end
  end
end
