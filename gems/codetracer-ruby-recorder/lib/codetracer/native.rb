# frozen_string_literal: true

# RS-M6 — span emission into the recorded `.ct` container.
#
# A *span* is a bounded, labeled interval of execution — an HTTP request, a
# process, a test.  Since RS-M1 the trace container carries them in its own
# `spans.dat` / `spans.idx` stream (spec:
# `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`), and since this
# milestone `CodeTracer::Rack::Middleware` writes there instead of appending to
# a `codetracer_spans.jsonl` sidecar.
#
# The difference that matters is *binding*: a sidecar span was a row of HTTP
# metadata with no way back into the recording, while a span record names a
# `(process, thread, step range)` coordinate INSIDE the container being
# recorded.  That is what lets CodeTracer's Request Panel seek from a request
# row to the first step of that request's handler.
#
# ## Why a process-wide facade
#
# The middleware lives in a DIFFERENT gem (`codetracer-rack`) from the recorder
# (`codetracer-ruby-recorder`), and a Rack app never sees the recorder object:
# it is constructed by `bin/codetracer-ruby-recorder` before the application is
# even loaded.  This module is the seam.  `install` is called by
# `CodeTracer::RubyRecorder` when a recording starts, and every entry point is a
# no-op-with-a-signal when nothing is installed — `next_step_index` returns
# `nil` and `register_span` returns `false` — so the middleware can be mounted
# unconditionally in an app that is only sometimes recorded.
#
# The reference is held as a plain Ruby object reference, not a raw pointer, so
# the recorder cannot be collected out from under a span registration.
#
# ## What is NOT here
#
# Request-shaped policy — which `http.*` keys, in which order, what counts as an
# error — belongs to the middleware
# (`CodeTracer::Rack::RequestSpanRecorder`).  This module knows only about
# spans in general, so a future test-span or process-span emitter reuses it
# unchanged.

require 'rbconfig'
require 'fileutils'

module CodeTracer
  module Native
    # Wire values of a span record's `status` byte
    # (`CTFS-Request-Span-Streams.md` §"Record Model").
    SPAN_STATUS_UNKNOWN = 0
    SPAN_STATUS_OK = 1
    SPAN_STATUS_ERROR = 2

    # `span_type` of an HTTP request span.  The Request Panel selects rows by
    # this exact string (via the container's `spantype.ns` index), so it is a
    # wire constant and not a display label.
    SPAN_TYPE_WEB_REQUEST = 'web-request'

    # Guards the installed recorder and the span-id counter.  Both are
    # process-wide, and Rack servers are routinely multi-threaded even when the
    # recorder's own event hook is not.
    @mutex = Mutex.new
    @recorder = nil
    @next_span_id = 1

    class << self
      # Bind this process's span entry points to `recorder`, a live
      # `CodeTracerNativeRecorder`.  Rewinds the span-id sequence: span ids are
      # 1-based and monotonic *within a container*, so a second recording in the
      # same process must start from 1 again.
      def install(recorder)
        @mutex.synchronize do
          @recorder = recorder
          @next_span_id = 1
        end
      end

      # Unbind.  After this every entry point reports "not recording" again.
      def uninstall
        @mutex.synchronize { @recorder = nil }
      end

      # True while a recording is active and able to accept spans.
      def active?
        !@recorder.nil?
      end

      # The next container-unique, 1-based, monotonic span id.
      #
      # Allocated here rather than per-middleware so a process running several
      # middleware instances (a Rails app that also mounts a Rack sub-app, say)
      # cannot mint colliding ids.
      def allocate_span_id
        @mutex.synchronize do
          id = @next_span_id
          @next_span_id += 1
          id
        end
      end

      # The step index the next recorded event will occupy, or `nil` when no
      # recording is active.
      #
      # `nil` must be distinguished from step `0`, which is a real step index —
      # hence a nil return rather than a sentinel number.
      #
      # The value comes from the trace WRITER's own step counter, which advances
      # for every exec-stream event (steps, column deltas, raise / catch, thread
      # events).  It is that counter which defines the step ids a reader walks,
      # so a recorder-side count of `register_step` calls would drift from it —
      # immediately, in this recorder's case, since it emits a thread-switch
      # event before the first step of every thread.
      def next_step_index
        recorder = @recorder
        return nil if recorder.nil?

        recorder.next_step_index
      end

      # The thread id THIS RECORDER uses for the calling thread, or 0 when no
      # recording is active.
      #
      # Deliberately not `Thread#object_id` and not an OS tid: the recorder's
      # event hook identifies threads by the `VALUE` of `Thread.current` and
      # emits its thread-switch events with exactly that number.  A span whose
      # `thread_id` came from anywhere else would name a thread the container
      # has never heard of, and the coordinate would be unresolvable.
      def current_thread_id
        recorder = @recorder
        return 0 if recorder.nil?

        recorder.current_thread_id
      end

      # Append one span record to the active recording's span stream.
      #
      # Returns `true` when the span was recorded and `false` when no recording
      # is active (nothing to record into — not an error).  Raises when a
      # recording IS active and the writer cannot store the span, so a recorded
      # run never loses requests silently.
      #
      # `metadata` is an ordered Array of `[key, value]` pairs and never a Hash:
      # metadata order is part of the wire contract and consumers render it in
      # emission order.
      #
      # Publishing an in-flight interval is two calls with the same `span_id` —
      # one with `is_open: true`, then the settled one.  Readers apply
      # last-record-wins.
      def register_span(span_id:, span_type:, label:,
                        status: SPAN_STATUS_UNKNOWN,
                        start_wall_ns: 0, end_wall_ns: 0,
                        start_step: 0, end_step: 0,
                        thread_id: 0, process_ord: 0, parent_span_id: 0,
                        is_open: false,
                        contiguous_on_one_thread: false,
                        shares_timeline: true,
                        concurrent_with_siblings: false,
                        metadata: [])
        recorder = @recorder
        return false if recorder.nil?

        recorder.register_span(
          span_id: span_id,
          span_type: span_type,
          label: label,
          status: status,
          start_wall_ns: start_wall_ns,
          end_wall_ns: end_wall_ns,
          start_step: start_step,
          end_step: end_step,
          thread_id: thread_id,
          process_ord: process_ord,
          parent_span_id: parent_span_id,
          is_open: is_open,
          contiguous_on_one_thread: contiguous_on_one_thread,
          shares_timeline: shares_timeline,
          concurrent_with_siblings: concurrent_with_siblings,
          metadata: metadata.map { |key, value| [key.to_s, value.to_s] }
        )
      end

      # Decode the span stream of the `.ct` container at `path`.
      #
      # Goes through the canonical Nim decoder — the same one `ct print -f http`
      # uses — so a caller verifying emitted spans is not reading them back
      # through a second decoder that could share a bug with the writer.
      #
      # `settled: true` applies last-record-wins per `span_id` and sorts
      # ascending by `span_id` (what a panel displays).  `settled: false`
      # returns every record in append order, open records included.
      #
      # Each returned Hash uses the spec's wire field names; `metadata` is an
      # Array of `[key, value]` pairs, because metadata order is part of the
      # contract.
      def read_span_stream(path, settled: true)
        require 'json'
        load_extension!
        JSON.parse(CodeTracerNativeRecorder.span_stream_json(path.to_s, settled))
      end

      # The number of steps recorded in the `.ct` container at `path`.
      #
      # Lets a consumer check that a span's `[start_step, end_step]` really is a
      # coordinate INSIDE that container — the property that distinguishes an
      # inline-bound span from the sidecar rows it replaces.
      def trace_step_count(path)
        load_extension!
        CodeTracerNativeRecorder.trace_step_count(path.to_s)
      end

      # Look one metadata key up in a span decoded by {read_span_stream}.
      #
      # Metadata arrives as an ordered Array of pairs (order is a wire
      # guarantee), so a lookup is a scan.  Provided here so every consumer
      # scans it the same way instead of rebuilding a Hash and losing the order.
      def span_metadata_value(span, key, default = '')
        pairs = span['metadata'] || []
        found = pairs.find { |pair| pair[0] == key }
        found ? found[1] : default
      end

      # Load the compiled extension into this process, idempotently.
      #
      # Shared by {CodeTracer::RubyRecorder} (which then constructs a recorder)
      # and by the read-side helpers above (which must not): a test that only
      # wants to decode a finished container has no business starting a
      # recording to do it.
      #
      # Cargo names a cdylib `libcodetracer_ruby_recorder.<ext>` while Ruby's
      # `require` wants `codetracer_ruby_recorder.<ext>`, so the freshly built
      # artifact is linked (or copied, on filesystems without symlinks) under
      # the name `require` expects.
      def load_extension!
        return true if defined?(::CodeTracerNativeRecorder)

        ext_dir = File.expand_path('../../ext/native_tracer/target/release', __dir__)
        dlext = RbConfig::CONFIG['DLEXT']
        target_path = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
        alt_path = %w[so bundle dylib dll]
                   .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
                   .find { |path| File.exist?(path) }
        if alt_path && (!File.exist?(target_path) || File.mtime(alt_path) > File.mtime(target_path))
          begin
            FileUtils.rm_f(target_path)
            File.symlink(alt_path, target_path)
          rescue StandardError
            FileUtils.cp(alt_path, target_path)
          end
        end

        require target_path
        true
      end
    end
  end
end
