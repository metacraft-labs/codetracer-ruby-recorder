# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class HCRTest < Minitest::Test
  FIXTURE_DIR = File.expand_path('fixtures/hcr', __dir__)

  # Path to the ct-print binary from codetracer-trace-format-nim, used to
  # inspect binary .ct (CTFS) trace files.
  CT_PRINT = File.expand_path('../../codetracer-trace-format-nim/ct-print', __dir__)

  PURE_RECORDER = 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder'
  NATIVE_RECORDER = 'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder'

  # Expected output lines for the 12-step HCR program.
  # Steps 1-6 use v1: compute=n*2, transform=value+n (delta=3n), aggregate=sum
  # Steps 7-12 use v2: compute=n*3, transform=value-n (delta=2n), aggregate=max
  EXPECTED_LINES = [
    'step=1 value=2 delta=3 total=3',
    'step=2 value=4 delta=6 total=9',
    'step=3 value=6 delta=9 total=18',
    'step=4 value=8 delta=12 total=30',
    'step=5 value=10 delta=15 total=45',
    'step=6 value=12 delta=18 total=63',
    'RELOAD_APPLIED',
    'step=7 value=21 delta=14 total=18',
    'step=8 value=24 delta=16 total=18',
    'step=9 value=27 delta=18 total=18',
    'step=10 value=30 delta=20 total=20',
    'step=11 value=33 delta=22 total=22',
    'step=12 value=36 delta=24 total=24',
  ].freeze

  def setup
    @tmpdir = Dir.mktmpdir('ct-hcr-ruby-')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # Copy all HCR fixtures into a working directory so the test program can
  # overwrite mymodule.rb without affecting the source tree.
  def prepare_workdir
    workdir = File.join(@tmpdir, 'workdir')
    FileUtils.mkdir_p(workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'hcr_test_program.rb'), workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v1.rb'), workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v2.rb'), workdir)
    # Start with v1 as the active module.
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v1.rb'), File.join(workdir, 'mymodule.rb'))
    workdir
  end

  def run_hcr(recorder_script)
    workdir = prepare_workdir
    tracer_name = recorder_script.include?('pure') ? 'pure' : 'native'
    out_dir = File.join(@tmpdir, "trace_output_#{tracer_name}")
    FileUtils.mkdir_p(out_dir)

    program = File.join(workdir, 'hcr_test_program.rb')

    Dir.chdir(File.expand_path('..', __dir__)) do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, recorder_script, '--out-dir', out_dir, program
      )
      [stdout, stderr, status, out_dir]
    end
  end

  # Returns true if the native recorder is available (native extension built).
  def native_recorder_available?
    ext_dir = File.expand_path('../../gems/codetracer-ruby-recorder/ext', __dir__)
    %w[so bundle dylib dll].any? do |ext|
      Dir.glob(File.join(ext_dir, '**', "*.#{ext}")).any?
    end
  end

  def test_hcr_pure_recorder_output
    stdout, stderr, status, _out_dir = run_hcr(PURE_RECORDER)
    assert status.success?, "Pure recorder failed: #{stderr}"

    lines = stdout.lines.map(&:chomp).reject(&:empty?)
    # Filter out any debug/recorder lines (keep only program output)
    program_lines = lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }

    assert_equal 13, program_lines.size, "Expected 13 output lines (12 steps + 1 RELOAD_APPLIED), got #{program_lines.size}"
    assert_includes program_lines, 'RELOAD_APPLIED', 'Missing RELOAD_APPLIED marker'

    # Verify each expected line is present and in order.
    EXPECTED_LINES.each_with_index do |expected, i|
      assert_equal expected, program_lines[i], "Line #{i} mismatch"
    end
  end

  def test_hcr_native_recorder_output
    skip 'native recorder not available' unless native_recorder_available?

    stdout, stderr, status, _out_dir = run_hcr(NATIVE_RECORDER)
    assert status.success?, "Native recorder failed: #{stderr}"

    lines = stdout.lines.map(&:chomp).reject(&:empty?)
    program_lines = lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }

    assert_equal 13, program_lines.size, "Expected 13 output lines, got #{program_lines.size}"
    assert_includes program_lines, 'RELOAD_APPLIED', 'Missing RELOAD_APPLIED marker'

    EXPECTED_LINES.each_with_index do |expected, i|
      assert_equal expected, program_lines[i], "Line #{i} mismatch"
    end
  end

  def test_hcr_pure_recorder_produces_trace
    _stdout, stderr, status, out_dir = run_hcr(PURE_RECORDER)
    assert status.success?, "Pure recorder failed: #{stderr}"

    trace_file = File.join(out_dir, 'trace.json')
    assert File.exist?(trace_file), "Expected trace.json in #{out_dir}"

    trace = JSON.parse(File.read(trace_file))
    step_events = trace.select { |ev| ev.key?('Step') }
    assert step_events.size > 0, 'Trace should contain Step events'
  end

  def test_hcr_native_recorder_produces_trace
    skip 'native recorder not available' unless native_recorder_available?

    _stdout, stderr, status, out_dir = run_hcr(NATIVE_RECORDER)
    assert status.success?, "Native recorder failed: #{stderr}"

    # The native recorder produces .ct files.
    ct_files = Dir.glob(File.join(out_dir, '*.ct'))

    if ct_files.empty?
      # Fall back to checking for trace.json (some configurations may use it).
      trace_file = File.join(out_dir, 'trace.json')
      assert File.exist?(trace_file), "Expected .ct or trace.json in #{out_dir}"
    else
      ct_file = ct_files.first
      assert File.size(ct_file) > 0, "#{ct_file} should not be empty"

      # If ct-print is available, verify the trace has non-zero step count.
      if File.exist?(CT_PRINT)
        stdout, stderr, st = Open3.capture3(CT_PRINT, '--json-events', ct_file)
        assert st.success?, "ct-print failed: #{stderr}"
        events = JSON.parse(stdout)
        step_events = events.select { |ev| ev['type'] == 'Step' }
        assert step_events.size > 0, 'CTFS trace should contain Step events'
      end
    end
  end

  def test_hcr_v1_formulas_before_reload
    stdout, _stderr, status, _out_dir = run_hcr(PURE_RECORDER)
    assert status.success?

    lines = stdout.lines.map(&:chomp).reject(&:empty?)
    program_lines = lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }

    # Before reload (steps 1-6): compute = n*2, transform = value+n, aggregate = sum
    (1..6).each do |step|
      line = program_lines[step - 1]
      assert_match(/^step=#{step} /, line, "Step #{step} missing")
      parts = line.scan(/\d+/).map(&:to_i)
      # parts: [step, value, delta, total]
      assert_equal step * 2, parts[1], "Step #{step}: expected value=#{step * 2}"
      assert_equal step * 2 + step, parts[2], "Step #{step}: expected delta=#{step * 2 + step}"
    end
  end

  def test_hcr_v2_formulas_after_reload
    stdout, _stderr, status, _out_dir = run_hcr(PURE_RECORDER)
    assert status.success?

    lines = stdout.lines.map(&:chomp).reject(&:empty?)
    program_lines = lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }

    # After reload (steps 7-12): compute = n*3, transform = value-n, aggregate = max
    # RELOAD_APPLIED is at index 6, step=7 is at index 7
    (7..12).each do |step|
      line = program_lines[step] # offset by 1 for RELOAD_APPLIED line
      assert_match(/^step=#{step} /, line, "Step #{step} missing")
      parts = line.scan(/\d+/).map(&:to_i)
      assert_equal step * 3, parts[1], "Step #{step}: expected value=#{step * 3}"
      assert_equal step * 3 - step, parts[2], "Step #{step}: expected delta=#{step * 3 - step}"
    end
  end
end
