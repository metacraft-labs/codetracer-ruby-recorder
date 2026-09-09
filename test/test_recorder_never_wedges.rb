# frozen_string_literal: true

# Regression suite: a Ruby exception raised *inside the recorder* must never
# wedge the recorded process.
#
# ## The failure this suite exists to catch
#
# The native recorder inspects every value it records by calling back into
# Ruby — `to_a`, `members`, `values`, `to_h`, `begin`, `end`, `source`,
# `instance_variables`, `instance_variable_get`, `to_s` — and by using MRI
# conversion helpers that raise (`rb_num2long` on a Bignum,
# `rb_string_value_cstr` on a String containing a NUL byte).  Any of those may
# raise, and a Ruby exception does not unwind the Rust stack: `rb_raise`
# `longjmp`s past every Rust frame WITHOUT running destructors.  A live
# `MutexGuard` on the trace writer is therefore never released, and the next
# `flush_trace` blocks forever.  The observed symptom is the worst kind: the
# process parks in `futex_wait_queue`, prints nothing, and never exits.
#
# See `ext/native_tracer/src/lib.rs`, module `tracer_lock`, for the structure
# that closes the hazard.
#
# ## Why the cases below, and not all twenty call sites
#
# Each case stands for a *shape* of the hazard, not for one `rb_funcall`:
#
# * `to_a` on a Hash subclass  — container expansion (shared with Set).
# * `members` on a Struct      — struct shape query (shared with `values`).
# * `instance_variable_get`    — the generic-object field walk.
# * a `to_s` returning a String with a NUL byte — the raise happens while
#   CONVERTING the result, so the `rb_protect` around the `to_s` call itself
#   never saw it.  This one is the reason "wrap each call site" is not a
#   sufficient fix.
# * `#class` overridden to raise — the CALL-event metadata path, outside the
#   value encoder entirely.
# * `2 ** 70` — `rb_num2long`'s `RangeError`, the one instance of this class
#   that was already fixed; kept here so it stays fixed and is covered by the
#   same harness as the rest.
# * a correlation marker whose `key:` is an object with an exploding `to_s`,
#   and one whose key is a String containing a NUL byte — the two shapes above,
#   reached through an entry point the traced program calls DIRECTLY rather
#   than through the event hook.
#
# **The rule this file states, and which the last two cases exist to honour:
# every new entry point that touches a Ruby value needs a case here.** An entry
# point called from user code is if anything more exposed than the hook: the
# values are chosen by the program, and the hook's own `in_event_hook` guard has
# to be armed and restored by hand on every path rather than by one caller.
#
# ## No mocks
#
# Nothing here is stubbed.  Each case runs the real `codetracer-ruby-recorder`
# CLI, in a real subprocess, over a real Ruby program, and decodes the
# resulting `.ct` container with the shipped `ct-print`.  A mock would have to
# model the MRI `longjmp` that IS the bug.
#
# ## Every case runs under an external timeout
#
# `record` supervises the recorder from the parent process and SIGKILLs it at
# the deadline.  A regression must surface as a FAILING test, never as a
# minitest run that hangs until CI's own timeout kills it with no attribution.

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require_relative 'ct_print_support'

class RecorderNeverWedgesTest < Minitest::Test
  include CtPrintSupport

  ROOT = File.expand_path('..', __dir__)
  RECORDER = File.join(ROOT, 'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder')

  # Generous enough that a slow machine never trips it, short enough that a
  # genuine wedge is reported in seconds rather than at the CI job limit.
  # Every program here records well under a second when the recorder is
  # healthy; a wedged recorder never finishes at all, so there is no value
  # between "slow" and "hung" that this has to discriminate.
  RECORD_TIMEOUT_SECONDS = Integer(ENV.fetch('CODETRACER_TEST_RECORD_TIMEOUT', '90'))

  # Printed by every program as its last statement: proof the traced program
  # itself ran to completion, independently of what the recorder wrote.
  COMPLETION_MARKER = 'PROGRAM-COMPLETED'

  def setup
    @tmp_dirs = []
  end

  def teardown
    @tmp_dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # Outcome of one supervised recording.
  Recording = Struct.new(:timed_out, :status, :output, :out_dir, keyword_init: true)

  # Record +source+ under the native recorder, killing the recorder if it does
  # not finish within +RECORD_TIMEOUT_SECONDS+.
  #
  # The watchdog lives HERE, in the parent, rather than in the recorder: the
  # whole point is to survive a child that can no longer make progress, and a
  # child cannot time itself out once its own trace writer is deadlocked.
  # `waitpid2(WNOHANG)` polling is used in preference to `Timeout.timeout`
  # around a blocking wait so the kill happens on a thread that is definitely
  # runnable.
  def record(source, name:)
    dir = Dir.mktmpdir("codetracer-wedge-#{name}-")
    @tmp_dirs << dir
    program = File.join(dir, "#{name}.rb")
    File.write(program, source)
    out_dir = File.join(dir, 'trace')
    FileUtils.mkdir_p(out_dir)
    log = File.join(dir, 'recorder.log')

    pid = Process.spawn(RbConfig.ruby, RECORDER, '--out-dir', out_dir, program,
                        out: log, err: [log, 'a'])
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RECORD_TIMEOUT_SECONDS
    status = nil
    timed_out = false
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        timed_out = true
        kill_and_reap(pid)
        break
      end
      sleep 0.05
    end

    Recording.new(timed_out: timed_out, status: status,
                  output: File.exist?(log) ? File.read(log) : '', out_dir: out_dir)
  end

  def kill_and_reap(pid)
    Process.kill('KILL', pid)
  rescue Errno::ESRCH
    # Already gone between the poll and the kill.
  ensure
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      # Nothing left to reap.
    end
  end

  # Assert that recording +source+ finished, and that what it produced is a
  # container a reader can actually use.
  #
  # `expect_locals` names locals whose values the recorder cannot read; the
  # assertion is that they are still PRESENT in the trace.  A recorder that
  # silently dropped them would look identical to one that never saw them.
  def assert_records_without_wedging(source, name:, expect_locals: [])
    recording = record(source, name: name)

    refute recording.timed_out,
           "recording #{name} did not finish within #{RECORD_TIMEOUT_SECONDS}s — the recorder " \
           "wedged (a Ruby exception raised inside it stranded the tracer lock).\n" \
           "Recorder output so far:\n#{recording.output}"
    assert_predicate recording.status, :success?,
                     "recorder exited with #{recording.status.inspect}\n#{recording.output}"
    assert_includes recording.output, COMPLETION_MARKER,
                    "the traced program did not run to completion\n#{recording.output}"

    ct_files = Dir.glob(File.join(recording.out_dir, '*.ct'))
    refute_empty ct_files, "no .ct container was written\n#{recording.output}"

    events = ct_print_events(ct_files.first)
    steps = events.count { |e| e['type'] == 'step' }
    assert_operator steps, :>, 0, "the container has no steps, so it is not a usable trace"

    recorded_names = events.select { |e| e['type'] == 'varname' }.map { |e| e['name'] }
    expect_locals.each do |local|
      assert_includes recorded_names, local,
                      "local `#{local}` is missing from the trace: the recorder dropped the " \
                      'variable instead of recording that it could not read its value'
    end
    events
  end

  # A Hash subclass whose `to_a` raises.
  #
  # The encoder expands every Hash through `to_a`; `Set` is expanded the same
  # way, so this case stands for both.
  def test_container_expansion_that_raises_does_not_wedge
    source = <<~RUBY
      class ExplodingHash < Hash
        def to_a
          raise 'to_a exploded'
        end
      end

      def probe
        h = ExplodingHash.new
        h[:a] = 1
        h
      end

      probe
      puts '#{COMPLETION_MARKER}'
    RUBY
    assert_records_without_wedging(source, name: 'hash_to_a', expect_locals: ['h'])
  end

  # A Struct whose `members` raises.
  #
  # The struct arm calls `members` and `values` before it can lay out the
  # tuple, so a raise there aborts the value halfway through a `begin_tuple`
  # — the case that also proves the encoder's nesting stack is reset rather
  # than left holding an unclosed compound.
  def test_struct_shape_query_that_raises_does_not_wedge
    source = <<~RUBY
      ExplodingStruct = Struct.new(:a) do
        def members
          raise 'members exploded'
        end
      end

      def probe
        s = ExplodingStruct.new(1)
        s
      end

      probe
      puts '#{COMPLETION_MARKER}'
    RUBY
    assert_records_without_wedging(source, name: 'struct_members', expect_locals: ['s'])
  end

  # A plain object whose `instance_variable_get` raises.
  #
  # This is the fallback arm every object without a more specific encoding
  # lands in, so it is the widest of the value-encoder shapes.
  def test_instance_variable_walk_that_raises_does_not_wedge
    source = <<~RUBY
      class ExplodingIvars
        def initialize
          @x = 1
        end

        def instance_variable_get(*)
          raise 'instance_variable_get exploded'
        end
      end

      def probe
        o = ExplodingIvars.new
        o
      end

      probe
      puts '#{COMPLETION_MARKER}'
    RUBY
    assert_records_without_wedging(source, name: 'object_ivars', expect_locals: ['o'])
  end

  # `to_s` succeeds but returns a String containing a NUL byte.
  #
  # `rb_string_value_cstr` raises `ArgumentError` for such a string, and it
  # runs while CONVERTING the result — after the `rb_protect` that guards the
  # `to_s` dispatch has already returned.  This is the case that shows why
  # protecting each known call site is not enough, and the value must still
  # come through: a NUL is perfectly valid UTF-8.
  def test_string_conversion_that_raises_does_not_wedge
    source = <<~'RUBY'
      class NulInToS
        def to_s
          "bad\0name"
        end
      end

      def probe
        o = NulInToS.new
        o
      end

      probe
      puts 'PROGRAM-COMPLETED'
    RUBY
    events = assert_records_without_wedging(source, name: 'nul_in_to_s', expect_locals: ['o'])
    blob = events.to_s
    assert_includes blob, 'bad', 'the NUL-containing to_s result was not recorded at all'
  end

  # An object that overrides `#class` to raise.
  #
  # Not a value-encoder site at all: the CALL event used to ask the receiver
  # for its class through ordinary Ruby dispatch in order to look up the
  # method's parameter list.  Included so the suite covers the hook's own
  # metadata path and not only the encoder.
  def test_call_metadata_lookup_that_raises_does_not_wedge
    source = <<~RUBY
      class LyingReceiver
        def class
          raise 'class exploded'
        end

        def run(value)
          value + 1
        end
      end

      LyingReceiver.new.run(41)
      puts '#{COMPLETION_MARKER}'
    RUBY
    events = assert_records_without_wedging(source, name: 'receiver_class')
    calls = events.count { |e| e['type'] == 'call' }
    assert_operator calls, :>, 0,
                    'the call record was lost even though the recorder survived'
  end

  # An Integer larger than a machine word.
  #
  # `rb_num2long` raises `RangeError` here.  This instance was fixed before
  # this suite existed (it was enough to hang Rails, which puts big integers
  # in the Rack `env`); the test keeps it fixed and puts it under the same
  # timeout supervision as its siblings.
  def test_bignum_does_not_wedge
    source = <<~RUBY
      def probe
        big = 2**70
        big
      end

      probe
      puts '#{COMPLETION_MARKER}'
    RUBY
    events = assert_records_without_wedging(source, name: 'bignum', expect_locals: ['big'])
    assert_includes events.to_s, (2**70).to_s,
                    'the out-of-word Integer should still be visible as its decimal text'
  end

  # A correlation marker whose boundary label and key are objects whose `to_s`
  # raises.
  #
  # `CodeTracer::Native.mark_correlation_send` is called BY THE TRACED PROGRAM,
  # so `key:` is an arbitrary object and rendering it is arbitrary user code.
  # Two things have to hold, and only the first is about hanging:
  #
  # 1. The raise must not escape into the writer lock (the wedge), and it must
  #    not escape into the traced program either — a program must not die
  #    because it annotated itself while being recorded.
  # 2. The marker must still be WRITTEN, with an empty key. A marker that was
  #    silently dropped would look exactly like one that was never declared,
  #    which is the invisible-failure mode the marker contract exists to
  #    eliminate.
  def test_correlation_marker_with_an_exploding_to_s_does_not_wedge
    source = <<~RUBY
      class ExplodingKey
        def to_s
          raise 'to_s exploded'
        end
      end

      def probe
        key = ExplodingKey.new
        CodeTracer::Native.mark_correlation_send(ExplodingKey.new, key: key,
                                                 show: ExplodingKey.new)
      end

      recorded = probe
      puts "MARKER-RECORDED \#{recorded}"
      puts '#{COMPLETION_MARKER}'
    RUBY
    recording = record(source, name: 'marker_to_s')
    assert_marker_survived(recording, name: 'marker_to_s')

    markers = ct_print_markers(single_container(recording))
    assert_equal 1, markers.length,
                 'the marker was dropped instead of being recorded with an unreadable key, ' \
                 'so it is indistinguishable from one that was never declared'
    assert_equal '', markers.first['key_value'],
                 'an unrenderable key must come through as empty, not as some guess'
    assert_equal 'send', markers.first['direction']
  end

  # A correlation-marker key that is a String containing a literal NUL byte.
  #
  # This is the `rb_string_value_cstr` shape (`ArgumentError` on an embedded
  # NUL) at a NEW entry point.  It is the specific hazard
  # `CTFS-Correlation-Marker-Contract.md` §11a.5 names — the reason the shared
  # library's marker entry points take pointer + length instead of a
  # NUL-terminated string, so the byte survives into the payload rather than
  # truncating the key or raising on the way there.
  def test_correlation_marker_with_a_nul_in_the_key_does_not_wedge
    source = <<~'RUBY'
      def probe
        CodeTracer::Native.mark_correlation_recv('queue', key: "bad\0key",
                                                 show: "bad\0body")
      end

      recorded = probe
      puts "MARKER-RECORDED #{recorded}"
      puts 'PROGRAM-COMPLETED'
    RUBY
    recording = record(source, name: 'marker_nul_key')
    assert_marker_survived(recording, name: 'marker_nul_key')

    markers = ct_print_markers(single_container(recording))
    assert_equal 1, markers.length, 'the NUL-containing marker was dropped'
    assert_equal "bad\0key", markers.first['key_value'],
                 'the key was truncated at the NUL byte instead of being carried whole'
    assert_equal 'queue', markers.first['boundary_id']
    assert_equal 'recv', markers.first['direction']
  end

  private

  # The wedge assertions shared by the two marker cases.
  #
  # Deliberately NOT `assert_records_without_wedging`: that helper asserts the
  # trace has steps and named locals, which is about the event hook. What
  # matters here is that the recorder survived, the program survived, and the
  # marker call reported success rather than an exception.
  def assert_marker_survived(recording, name:)
    refute recording.timed_out,
           "recording #{name} did not finish within #{RECORD_TIMEOUT_SECONDS}s — the recorder " \
           "wedged (a Ruby exception raised inside a marker entry point stranded the tracer " \
           "lock).\nRecorder output so far:\n#{recording.output}"
    assert_predicate recording.status, :success?,
                     "recorder exited with #{recording.status.inspect}\n#{recording.output}"
    assert_includes recording.output, COMPLETION_MARKER,
                    "the traced program did not run to completion — the exception raised " \
                    "inside the recorder escaped into the program\n#{recording.output}"
    assert_includes recording.output, 'MARKER-RECORDED true',
                    "the marker entry point reported failure\n#{recording.output}"
  end

  # The single `.ct` container a recording produced.
  def single_container(recording)
    containers = Dir.glob(File.join(recording.out_dir, '*.ct'))
    refute_empty containers, "no .ct container was written\n#{recording.output}"
    containers.first
  end
end
