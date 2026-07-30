# frozen_string_literal: true

# RS-M6 — the request-span lifecycle behind CodeTracer::Rack::Middleware.
#
# ## Where a span begins and ends
#
# One HTTP request is one span:
#
# * **begin** — before the wrapped application is invoked.  The span id is
#   allocated, `start_step` is read from the recorder (the index the *next*
#   recorded event will take, i.e. the first step executed inside the app), and
#   an OPEN record is appended so a live consumer sees an in-flight row.
# * **end** — after the application has produced its response, or raised.  A
#   second record with the SAME span id carries the status, the duration, the
#   response size and `end_step` (the last step recorded during the request).
#   Readers apply last-record-wins, so the pair settles into one span.
#
# ## How concurrent requests stay distinct
#
# All per-request state lives on the {PendingRequestSpan} returned by
# {RequestSpanRecorder#begin_request}, which the caller keeps in a local
# variable — a Rack worker thread's stack frame.  There is no thread-local and
# no "current span" global, so two requests being served at the same time
# cannot overwrite each other's state.  The middleware this replaced kept the
# in-flight span in `Thread.current[:codetracer_current_span]`, which silently
# lost a span whenever one request was handled inside another (a Rack app that
# mounts a sub-app, `Rack::Cascade`, or any middleware that re-enters).
#
# Because the recorder writes a single step timeline for the whole process,
# concurrently served requests genuinely OVERLAP in step space.  Spans say so
# rather than pretending otherwise: an overlapping span is marked
# `concurrent_with_siblings` and is not marked `contiguous_on_one_thread`
# (`Trace-Spans.md` § 2.4), and it carries the thread id the recorder itself
# uses, so the coordinate resolves against the recording's own thread events.
#
# ## No sidecar (RS-M12)
#
# Until RS-M6 this middleware wrote request metadata to a
# `codetracer_spans.jsonl` sidecar; RS-M6 moved it into the container's span
# stream and kept the sidecar writer one release behind an opt-in
# `CODETRACER_SPAN_MANIFEST`.  RS-M12 removed that writer: nothing here opens
# a file, and the environment variable is no longer read.  A sidecar row is
# not seekable — it names no coordinate in any recording — which is exactly
# what the span stream fixed, so there was nothing left for it to carry.
# Sessions recorded before the change are still readable through CodeTracer's
# db-backend shim (`src/db-backend/src/request_spans.rs`).

module CodeTracer
  module Rack
    # Wire values of a span record's `status` byte, duplicated here (rather
    # than referenced from `CodeTracer::Native`) because this gem must work
    # with the recorder absent — a Rack app may be deployed with the
    # middleware mounted and no recorder installed at all.
    SPAN_STATUS_UNKNOWN = 0
    SPAN_STATUS_OK = 1
    SPAN_STATUS_ERROR = 2

    SPAN_TYPE_WEB_REQUEST = 'web-request'

    # One in-flight request.  Created by {RequestSpanRecorder#begin_request}.
    class PendingRequestSpan
      attr_reader :span_id, :http_method, :url, :start_step

      def initialize(recorder, span_id, http_method, url, remote_addr, start_step, thread_id)
        @recorder = recorder
        @span_id = span_id
        @http_method = http_method
        @url = url
        @remote_addr = remote_addr
        # `nil` means "not being recorded"; step 0 is a real step index, so the
        # two must never be conflated.
        @start_step = start_step
        @thread_id = thread_id
        @start_wall_ns = (Time.now.to_r * 1_000_000_000).to_i
        @start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @settled = false
      end

      def label
        "#{@http_method} #{@url}"
      end

      # Append the OPEN record: the request has started, nothing else is known.
      def publish_open
        return false if @start_step.nil?

        CodeTracer::Native.register_span(
          span_id: @span_id,
          span_type: SPAN_TYPE_WEB_REQUEST,
          label: label,
          status: SPAN_STATUS_UNKNOWN,
          start_wall_ns: @start_wall_ns,
          start_step: @start_step,
          thread_id: @thread_id,
          is_open: true,
          shares_timeline: true,
          concurrent_with_siblings: @recorder.concurrent,
          metadata: metadata(0, 0, nil, nil, nil)
        )
      end

      # Append the settled record for this request.
      #
      # Idempotent: a middleware that both rescues an exception and runs an
      # `ensure` block cannot double-append.
      def finish(status_code, response_size: nil, route: nil, error_message: nil)
        return false if @settled

        @settled = true
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_monotonic
        duration_ms = (elapsed * 1000).round
        meta = metadata(status_code, duration_ms, response_size, route, error_message)

        recorded = false
        unless @start_step.nil?
          recorded = CodeTracer::Native.register_span(
            span_id: @span_id,
            span_type: SPAN_TYPE_WEB_REQUEST,
            label: label,
            status: self.class.status_for(status_code),
            start_wall_ns: @start_wall_ns,
            end_wall_ns: @start_wall_ns + (elapsed * 1_000_000_000).to_i,
            start_step: @start_step,
            end_step: end_step,
            thread_id: @thread_id,
            # A request that overlaps its siblings in step space is not
            # contiguous on one thread; saying so is what tells a UI it may not
            # render the range as a continuous call trace.
            contiguous_on_one_thread: !@recorder.concurrent,
            shares_timeline: true,
            concurrent_with_siblings: @recorder.concurrent,
            metadata: meta
          )
        end

        recorded
      end

      # Map an HTTP status to a span status.  `>= 400` is an error — the
      # mapping the Request Panel's colouring assumes.  A missing status stays
      # "unknown" rather than being guessed as 200.
      def self.status_for(status_code)
        return SPAN_STATUS_UNKNOWN if status_code.nil? || status_code <= 0

        status_code >= 400 ? SPAN_STATUS_ERROR : SPAN_STATUS_OK
      end

      private

      # The last step id INSIDE the span, which is one before the next index.
      #
      # A request during which nothing was recorded (a 404 that never entered
      # application code, a response served entirely from framework internals
      # the recorder ignores) collapses to the single step it started at,
      # rather than wrapping around to a huge range.
      def end_step
        nxt = CodeTracer::Native.next_step_index
        return @start_step if nxt.nil? || nxt <= @start_step

        nxt - 1
      end

      # The well-known `http.*` keys, in display order.
      #
      # Order is part of the wire contract (readers hand metadata back in
      # emission order), so this is built as an ordered Array of pairs and never
      # from a Hash whose iteration order is incidental.
      def metadata(status_code, duration_ms, response_size, route, error_message)
        pairs = [
          ['http.method', @http_method.to_s],
          ['http.url', @url.to_s],
          ['http.status_code', status_code.to_s],
          ['http.duration_ms', duration_ms.to_s]
        ]
        pairs << ['http.route', route.to_s] if route && !route.to_s.empty?
        pairs << ['http.response_size', response_size.to_s] unless response_size.nil?
        pairs << ['http.remote_addr', @remote_addr.to_s] if @remote_addr && !@remote_addr.to_s.empty?
        unless @recorder.framework.to_s.empty?
          pairs << ['framework', @recorder.framework.to_s]
        end
        pairs << ['error.message', error_message.to_s] if error_message && !error_message.to_s.empty?
        pairs
      end
    end

    # Allocates and publishes one span per HTTP request.
    #
    # `framework` is recorded as the `framework` metadata key (`rack` /
    # `sinatra` / `rails`).  `concurrent` marks the spans this recorder
    # produces as possibly overlapping their siblings — true for a
    # thread-per-request server.  `publish_open` controls whether an in-flight
    # record is appended at request start; on by default because it is what
    # makes a live panel show a request before it finishes.
    class RequestSpanRecorder
      attr_reader :framework, :concurrent

      def initialize(framework: '', concurrent: false, publish_open: true)
        @framework = framework
        @concurrent = concurrent
        @publish_open = publish_open
      end

      # Open a span for a request that is about to be handled.
      def begin_request(http_method, url, remote_addr = '')
        pending = PendingRequestSpan.new(
          self,
          allocate_span_id,
          http_method,
          url,
          remote_addr,
          next_step_index,
          current_thread_id
        )
        pending.publish_open if @publish_open
        pending
      end

      private

      # Span identity comes from the recorder when one is installed, so ids are
      # unique across every middleware instance in the container.  Without a
      # recorder nothing is written anywhere, so ids only have to be unique
      # within this process and a local counter suffices.
      def allocate_span_id
        return CodeTracer::Native.allocate_span_id if native_available?

        @fallback_span_id_mutex ||= Mutex.new
        @fallback_span_id_mutex.synchronize do
          @fallback_span_id = (@fallback_span_id || 0) + 1
        end
      end

      def next_step_index
        return nil unless native_available?

        CodeTracer::Native.next_step_index
      end

      def current_thread_id
        return 0 unless native_available?

        CodeTracer::Native.current_thread_id
      end

      # The recorder gem is an optional peer: this middleware ships separately
      # and must keep working — writing nothing — in a production app that has
      # no recorder installed.
      def native_available?
        defined?(CodeTracer::Native) && CodeTracer::Native.respond_to?(:register_span)
      end
    end
  end
end
