# frozen_string_literal: true

# Correlation markers in the recorded `.ct` container.
#
# Spec: `codetracer-specs/Testing/CTFS-Correlation-Marker-Contract.md` §§10,
# 11a, 11b and `codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md`
# §2.4 (the programmatic API — the ONLY record-time authoring path; the
# comment / TOML paths are replay-time mechanisms and cannot be indexed while
# recording).
#
# ## No mocks
#
# Every test here records a REAL Ruby program with the REAL recorder CLI in a
# REAL subprocess, and reads the result back through the SHIPPED `ct-print`.
# Nothing is stubbed, and in particular the markers are not read by a
# test-local decoder: `ct print --markers` parses the `MarkerPayload` out of the
# IO event's metadata slot exactly as the debugger's own consumer does, so a
# writer that emitted a payload with drifted field names would show up here as
# *zero markers* rather than as a passing test. That failure mode — a marker
# that is invisible rather than broken — is the reason the shared writer owns
# the payload and the reason this suite reads it through the canonical tool.
#
# ## The three properties pinned here
#
# 1. **A marker round-trips with its payload hoisted** — `correlation_marker`,
#    and `boundary_id` / `direction` / `key_value` at the top level. `show_text`
#    survives when the caller passes one; it is load-bearing rather than
#    cosmetic, because a cross-process origin chain resumes its walk on that
#    NAME in the sending recording, so a marker that dropped it would be visible
#    with its history unreachable.
# 2. **A marker mints NO step** (§11a.6). The marker attaches to the enclosing
#    step. Minting one would insert an exec-stream event that no user code
#    executed and shift every later step index — and spans' `start_step` /
#    `end_step`, and every other step-addressed coordinate, are measured in
#    those indices. Pinned by recording the SAME source twice and comparing
#    step counts; see {MARKER_PROGRAM} for how the two runs are made
#    line-for-line identical.
# 3. **The API is a no-op when nothing is recording.** User code calls these
#    unconditionally and is only sometimes recorded, so "not recording" must be
#    a `false` return and never an exception or a load error.

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require_relative 'ct_print_support'

class CorrelationMarkersTest < Minitest::Test
  include CtPrintSupport

  ROOT = File.expand_path('..', __dir__)
  RECORDER = File.join(ROOT, 'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder')
  GEM_LIB = File.join(ROOT, 'gems/codetracer-ruby-recorder/lib')

  BOUNDARY = 'order-processing'
  KEY = 'msg-42'
  SHOW = '{"item":"widget"}'
  DESCRIPTION = 'Outbound order'
  # A real W3C trace-context pair (the example from the traceparent spec), used
  # because `mark_span_coverage` validates the hex and would reject a
  # made-up-looking id of the wrong length.
  TRACE_ID = '0af7651916cd43dd8448eb211c80319c'
  SPAN_ID = 'b7ad6b7169203331'

  # Printed by the program as its last statement: proof it ran to completion,
  # independently of what the recorder wrote.
  COMPLETION_MARKER = 'PROGRAM-COMPLETED'

  # The program every test in this file records.
  #
  # It is ONE source text used for three runs — marked, unmarked, and not
  # recorded at all — because the step-count comparison is only meaningful if
  # the two recorded runs execute the identical lines. Deleting the marker
  # calls for the unmarked run would remove their LINES too, and the step counts
  # would differ for a reason that has nothing to do with markers.
  #
  # So the switch is `CodeTracer::Native.uninstall`, which unbinds the facade
  # from the live recorder without touching the event hook: the same call sites
  # run in both recordings and take the same number of steps, but in the
  # unmarked run the facade returns `false` before it reaches the writer. The
  # recording itself is unaffected — the recorder object owns the hook, not the
  # facade — which is exactly why the two runs remain comparable.
  MARKER_PROGRAM = <<~RUBY
    require 'codetracer/native'

    CodeTracer::Native.uninstall unless ENV['CT_MARK'] == '1'

    order_id = '#{KEY}'
    body = '#{SHOW}'
    sent = CodeTracer::Native.mark_correlation_send('#{BOUNDARY}', key: order_id,
                                                    show: body, desc: '#{DESCRIPTION}')
    received = CodeTracer::Native.mark_correlation_recv('#{BOUNDARY}', key: order_id,
                                                        show: body, show_text: 'envelope')
    covered = CodeTracer::Native.mark_span_coverage('#{TRACE_ID}', '#{SPAN_ID}',
                                                    1_700_000_000_000_000_000, 42)
    rejected = CodeTracer::Native.mark_span_coverage('not-hex', '#{SPAN_ID}', 0, 0)
    puts "RESULTS sent=\#{sent} received=\#{received} covered=\#{covered} rejected=\#{rejected}"
    puts '#{COMPLETION_MARKER}'
  RUBY

  def setup
    @tmp_dirs = []
  end

  def teardown
    @tmp_dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # Record MARKER_PROGRAM and return `[container_path, stdout]`.
  #
  # `marking` selects whether the facade stays bound to the live recorder.
  def record(name:, marking:)
    dir = Dir.mktmpdir("codetracer-markers-#{name}-")
    @tmp_dirs << dir
    program = File.join(dir, 'marked.rb')
    File.write(program, MARKER_PROGRAM)
    out_dir = File.join(dir, 'trace')
    FileUtils.mkdir_p(out_dir)

    stdout, stderr, status = Open3.capture3(
      { 'CT_MARK' => marking ? '1' : '0' },
      RbConfig.ruby, RECORDER, '--out-dir', out_dir, program
    )
    assert_predicate status, :success?, "recorder failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, COMPLETION_MARKER,
                    "the traced program did not run to completion\n#{stdout}\n#{stderr}"

    containers = Dir.glob(File.join(out_dir, '*.ct'))
    refute_empty containers, "no .ct container was written\n#{stdout}\n#{stderr}"
    [containers.first, stdout]
  end

  def step_count(container)
    ct_print_events(container).count { |event| event['type'] == 'step' }
  end

  # The declared marker survives the container round-trip with its payload
  # decodable — which is what makes it findable at all.
  def test_declared_markers_round_trip_through_ct_print
    container, stdout = record(name: 'roundtrip', marking: true)

    assert_includes stdout, 'sent=true received=true covered=true',
                    "the recorder refused a marker it should have accepted\n#{stdout}"

    markers = ct_print_markers(container)
    assert_equal 2, markers.length,
                 "expected the send and the recv marker, got #{markers.inspect}"

    send_marker, recv_marker = markers

    # The hoisted top-level fields: what a consumer selects on without having
    # to parse the metadata slot itself.
    assert_equal BOUNDARY, send_marker['boundary_id']
    assert_equal 'send', send_marker['direction']
    assert_equal KEY, send_marker['key_value']
    assert_equal BOUNDARY, recv_marker['boundary_id']
    assert_equal 'recv', recv_marker['direction']
    assert_equal KEY, recv_marker['key_value']

    # ... and the full payload underneath them, which is what the debugger
    # renders and what a cross-process chain walks.
    payload = send_marker['correlation_marker']
    refute_nil payload, "the marker payload did not decode: #{send_marker.inspect}"
    assert_equal BOUNDARY, payload['boundary_id']
    assert_equal 'send', payload['direction']
    assert_equal KEY, payload['key_value']
    assert_equal SHOW, payload['show_value']
    assert_equal DESCRIPTION, payload['description']

    # `show_text` is the NAME the shown value was read under. The send marker
    # passed none and takes the library's default; the recv marker passed
    # `envelope` and must keep it — a chain resuming its walk in the sending
    # recording looks the value up by that name.
    assert_equal 'show', payload['show_text']
    assert_equal 'envelope', recv_marker['correlation_marker']['show_text'],
                 'show_text was dropped, so a cross-process origin chain would ' \
                 'reach this marker with its history unreachable'

    # Both markers name a real step in this very container: the marker attaches
    # to the enclosing step rather than floating free.
    steps = step_count(container)
    markers.each do |marker|
      assert_operator marker['step_id'], :>=, 0
      assert_operator marker['step_id'], :<, steps,
                      "marker step_id #{marker['step_id']} is outside the container's " \
                      "#{steps} steps, so it is not a usable coordinate"
    end
  end

  # §11a.6 — a marker attaches to the enclosing step and mints none of its own.
  def test_a_marker_mints_no_step
    marked_container, = record(name: 'steps-marked', marking: true)
    unmarked_container, = record(name: 'steps-unmarked', marking: false)

    # The comparison is only worth anything if the two runs really did differ in
    # the one respect under test.
    assert_equal 2, ct_print_markers(marked_container).length
    assert_empty ct_print_markers(unmarked_container),
                 'the unmarked run wrote markers, so the step comparison below ' \
                 'would compare two identical recordings and pass vacuously'

    assert_equal step_count(unmarked_container), step_count(marked_container),
                 'declaring a correlation marker changed the number of steps. A marker ' \
                 'must attach to the enclosing step: minting one inserts an exec-stream ' \
                 'event no user code executed and shifts every later step index, which is ' \
                 "what spans' start_step/end_step are measured in."
  end

  # The whole API is a no-op — not an error — outside a recording.
  #
  # Run with plain `ruby`, no recorder anywhere: user code calls these
  # unconditionally and is only sometimes recorded, so an exception (or a
  # failure to even load the facade) would make the API unusable in production.
  def test_the_api_is_a_no_op_when_not_recording
    dir = Dir.mktmpdir('codetracer-markers-norecording-')
    @tmp_dirs << dir
    program = File.join(dir, 'marked.rb')
    File.write(program, MARKER_PROGRAM)

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', GEM_LIB, program)

    assert_predicate status, :success?,
                     "the program failed when it was not being recorded:\n#{stdout}\n#{stderr}"
    assert_includes stdout, COMPLETION_MARKER, "#{stdout}\n#{stderr}"
    assert_includes stdout, 'sent=false received=false covered=false rejected=false',
                    "the marker API must report `false` (nothing was recorded) rather " \
                    "than claim success when no recording is active\n#{stdout}"
  end

  # `mark_span_coverage` really reaches the shared library's hex validation.
  #
  # Without this the `covered=true` above could be produced by a binding that
  # accepted anything, and the resulting index would be keyed on bytes no
  # consumer ever computes — present, correct-looking and permanently
  # unqueryable.
  def test_span_coverage_rejects_ids_that_are_not_wire_hex
    _, stdout = record(name: 'coverage', marking: true)

    assert_includes stdout, 'covered=true rejected=false',
                    "a valid (trace_id, span_id) pair must be accepted and a malformed " \
                    "one refused; got:\n#{stdout}"
  end
end
