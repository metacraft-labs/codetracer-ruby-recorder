# frozen_string_literal: true

# The pure recorder's exit status follows Recorder-CLI-Conventions.md §6:
# 0 only when the recording completed, the target program's own status
# passed through, and exit 1 for a recorder error. Each case runs a real
# Ruby subprocess under the real recorder CLI and, where the outcome
# belongs to the program, compares it with the same program run by plain
# `ruby`. Nothing is mocked.
#
# The failure this guards against: the recorder used to `rescue Exception`
# around `Kernel.load(program)` and discard what it caught, so an uncaught
# exception, an `exit N`, and an error inside the recorder's own TracePoint
# handlers all ended in exit 0 with a truncated trace and nothing on
# stderr. The recorder is a test oracle, and an oracle that hides an error
# that way compares as a shorter but valid reference.
require 'minitest/autorun'
require 'open3'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

class PureRecorderExitStatusTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  RECORDER = File.join(ROOT, 'gems', 'codetracer-pure-ruby-recorder', 'bin', 'codetracer-pure-ruby-recorder')

  def setup
    @root = Dir.mktmpdir('ct-pure-exit-')
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write_program(name, source)
    path = File.join(@root, name)
    File.write(path, source)
    path
  end

  def run_plain(program)
    Open3.capture3(RbConfig.ruby, program)
  end

  def run_recorded(program, out_dir = File.join(@root, 'out'))
    Open3.capture3(RbConfig.ruby, RECORDER, '--out-dir', out_dir, program)
  end

  def trace_events(out_dir = File.join(@root, 'out'))
    JSON.parse(File.read(File.join(out_dir, 'trace.json')))
  end

  def io_contents(events)
    events.filter_map { |e| e['Event'] && e['Event']['kind'].zero? ? e['Event']['content'] : nil }
  end

  def test_uncaught_exception_propagates_as_without_the_recorder
    program = write_program('raise.rb', <<~RUBY)
      puts 'before'
      raise ArgumentError, 'traced-program-boom'
    RUBY
    plain_out, plain_err, plain_status = run_plain(program)
    out, err, status = run_recorded(program)

    assert_equal 1, plain_status.exitstatus, 'control: plain ruby exits 1 on an uncaught exception'
    assert_equal plain_status.exitstatus, status.exitstatus, "recorder stderr:\n#{err}"
    assert_equal plain_out, out
    assert_includes plain_err, 'traced-program-boom (ArgumentError)'
    assert_includes err, 'traced-program-boom (ArgumentError)'
    # The trace recorded up to the exception is still written.
    assert_equal ["before\n"], io_contents(trace_events)
  end

  def test_exit_status_passes_through
    program = write_program('exit3.rb', <<~RUBY)
      puts 'leaving'
      exit 3
    RUBY
    plain_out, _plain_err, plain_status = run_plain(program)
    out, err, status = run_recorded(program)

    assert_equal 3, plain_status.exitstatus
    assert_equal 3, status.exitstatus, "recorder stderr:\n#{err}"
    assert_equal plain_out, out
    assert_equal '', err
    assert_equal ["leaving\n"], io_contents(trace_events)
  end

  def test_explicit_exit_zero_and_normal_completion_exit_zero
    explicit = write_program('exit0.rb', "puts 'a'\nexit\nputs 'unreached'\n")
    normal = write_program('normal.rb', "puts 'b'\n")

    [[explicit, "a\n"], [normal, "b\n"]].each do |program, expected|
      out_dir = File.join(@root, "out-#{File.basename(program, '.rb')}")
      out, err, status = run_recorded(program, out_dir)
      assert_equal 0, status.exitstatus, "#{program}: recorder stderr:\n#{err}"
      assert_equal expected, out
      assert_equal [expected], io_contents(trace_events(out_dir))
    end
  end

  # An error raised inside the recorder's own TracePoint handler. The
  # program replaces `String#end_with?`, which it never calls itself; the
  # recorder's `tracks_call?` calls it on the next line event and raises
  # from the recorder's frames. That must surface as a non-zero exit with
  # the error and a recorder frame on stderr.
  def test_internal_recorder_error_exits_non_zero_with_the_error_on_stderr
    program = write_program('poison.rb', <<~RUBY)
      puts 'before'
      class String
        def end_with?(*)
          raise 'recorder-internal-control'
        end
      end
      puts 'after'
    RUBY
    _plain_out, _plain_err, plain_status = run_plain(program)
    assert_equal 0, plain_status.exitstatus, 'control: the program succeeds without the recorder'

    _out, err, status = run_recorded(program)
    assert_equal 1, status.exitstatus, 'an internal recorder error is exit 1, never 0'
    assert_includes err, 'recorder-internal-control'
    assert_match(/codetracer_pure_ruby_recorder\.rb:\d+:in .*tracks_call\?/, err)
  end

  # Writing the trace is the recorder's job; when it fails the recorder
  # exits 1 whatever the program's status was (§6: "regardless of the
  # target program's exit code").
  def test_trace_write_failure_exits_one_even_when_the_program_exits_non_zero
    program = write_program('exit3.rb', "exit 3\n")
    blocker = File.join(@root, 'not-a-directory')
    File.write(blocker, '')

    _out, err, status = run_recorded(program, File.join(blocker, 'out'))
    assert_equal 1, status.exitstatus, "recorder stderr:\n#{err}"
    assert_match(/Errno::EEXIST|Errno::ENOTDIR/, err)
  end
end
