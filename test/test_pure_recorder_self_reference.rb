# frozen_string_literal: true

# The pure recorder used as a library (`PureRubyRecorder.new` + `start`) runs
# its own methods on the traced program's thread: the patched `puts` calls
# straight into the recorder. Those frames are not part of the program and
# must not be recorded -- recording them also records their return values,
# the recorder's event log, which grows with every step. And a recorder the
# program can reach through its own data is recorded as an opaque value, not
# expanded field by field.
#
# No mocks: the real pure recorder library records a real Ruby subprocess and
# the assertions read the trace.json it writes.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'timeout'

class PureRecorderSelfReferenceTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  TMP_DIR = File.join(__dir__, 'tmp', 'pure_recorder_self_reference')
  LIB = File.join(ROOT, 'gems', 'codetracer-pure-ruby-recorder', 'lib', 'codetracer_pure_ruby_recorder')

  # Generous for a handful of traced lines; the unbounded expansion this
  # guards against does not finish within hours.
  DEADLINE_SECONDS = 60

  def setup
    FileUtils.rm_rf(TMP_DIR)
    FileUtils.mkdir_p(TMP_DIR)
  end

  def run_with_deadline(script_path)
    out_path = File.join(TMP_DIR, 'stdout.txt')
    err_path = File.join(TMP_DIR, 'stderr.txt')
    pid = Process.spawn(RbConfig.ruby, script_path, out: out_path, err: err_path)
    begin
      Timeout.timeout(DEADLINE_SECONDS) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill('KILL', pid)
      Process.wait(pid)
      flunk "recording did not finish within #{DEADLINE_SECONDS}s"
    end
    assert $?.success?, "traced script failed: #{File.read(err_path)}"
    File.read(out_path)
  end

  def each_hash(node, &block)
    case node
    when Hash
      yield node
      node.each_value { |v| each_hash(v, &block) }
    when Array
      node.each { |v| each_hash(v, &block) }
    end
  end

  def record_script(body)
    trace_dir = File.join(TMP_DIR, 'trace')
    script_path = File.join(TMP_DIR, 'script.rb')
    File.write(script_path, <<~RUBY)
      require #{LIB.inspect}
      recorder = CodeTracer::PureRubyRecorder.new(#{trace_dir.inspect})
      recorder.start
      #{body}
      recorder.stop
      recorder.flush_trace
    RUBY
    stdout = run_with_deadline(script_path)
    [stdout, JSON.parse(File.read(File.join(trace_dir, 'trace.json')))]
  end

  def test_library_use_does_not_record_the_recorders_own_frames
    stdout, trace = record_script(<<~RUBY)
      total = 0
      3.times { |i| total += i }
      puts total
      puts total + 1
    RUBY

    assert_equal "3\n4\n", stdout
    names = trace.filter_map { |e| e.dig('Function', 'name') }
    own = names.grep(/PureRubyRecorder|TraceRecord|AssignmentReconstructor|KernelPatches/)
    assert_empty own, "the recorder's own methods were recorded as program calls"
    writes = trace.filter_map { |e| e.dig('Event', 'content') }
    assert_equal ["3\n", "4\n"], writes
  end

  def test_recorder_reachable_from_program_data_is_recorded_opaquely
    stdout, trace = record_script(<<~RUBY)
      holder = Struct.new(:rec).new(recorder)
      puts holder.rec.class
    RUBY

    assert_equal "CodeTracer::PureRubyRecorder\n", stdout
    recorder_values = []
    each_hash(trace) do |h|
      recorder_values << h if h['kind'] == 'Raw' && h['r'] == '#<CodeTracer::PureRubyRecorder>'
    end
    refute_empty recorder_values, '`holder.rec` should be recorded as an opaque Raw value'
  end
end
