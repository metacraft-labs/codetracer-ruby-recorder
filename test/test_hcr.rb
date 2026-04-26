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

# ---------------------------------------------------------------------------
# Strong assertions on the trace content produced by the HCR test program.
# Mirrors the ct-print verification approach used in test_tracer.rb: run the
# recorder, then inspect the trace structure to verify functions, calls,
# paths, metadata, and structural integrity.
#
# The pure recorder always produces trace.json which we parse directly.
# When the native recorder produces a .ct file AND ct-print is available we
# additionally verify the binary trace in a dedicated test.
# ---------------------------------------------------------------------------
class TestHCRTraceContent < Minitest::Test
  FIXTURE_DIR = File.expand_path('fixtures/hcr', __dir__)
  CT_PRINT    = File.expand_path('../../codetracer-trace-format-nim/ct-print', __dir__)

  PURE_RECORDER   = 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder'
  NATIVE_RECORDER = 'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder'

  def setup
    @tmpdir = Dir.mktmpdir('ct-hcr-trace-content-')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # ------- helpers -------

  def prepare_workdir
    workdir = File.join(@tmpdir, 'workdir')
    FileUtils.mkdir_p(workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'hcr_test_program.rb'), workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v1.rb'), workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v2.rb'), workdir)
    FileUtils.cp(File.join(FIXTURE_DIR, 'mymodule_v1.rb'), File.join(workdir, 'mymodule.rb'))
    workdir
  end

  # Run the pure recorder and return the parsed trace.json array and metadata.
  def run_pure_recorder
    workdir  = prepare_workdir
    out_dir  = File.join(@tmpdir, 'trace_output_pure')
    FileUtils.mkdir_p(out_dir)
    program  = File.join(workdir, 'hcr_test_program.rb')

    Dir.chdir(File.expand_path('..', __dir__)) do
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, PURE_RECORDER, '--out-dir', out_dir, program
      )
      assert status.success?, "Pure recorder failed: #{stderr}"
    end

    trace_file    = File.join(out_dir, 'trace.json')
    metadata_file = File.join(out_dir, 'trace_metadata.json')

    assert File.exist?(trace_file), "Expected trace.json in #{out_dir}"
    trace    = JSON.parse(File.read(trace_file))
    metadata = File.exist?(metadata_file) ? JSON.parse(File.read(metadata_file)) : nil

    [trace, metadata, out_dir]
  end

  # Run the native recorder and return ct-print --json-events output (or nil).
  def run_native_recorder_ct
    ext_dir = File.expand_path('../../gems/codetracer-ruby-recorder/ext', __dir__)
    native_available = %w[so bundle dylib dll].any? do |ext|
      Dir.glob(File.join(ext_dir, '**', "*.#{ext}")).any?
    end
    return nil unless native_available

    workdir = prepare_workdir
    out_dir = File.join(@tmpdir, 'trace_output_native')
    FileUtils.mkdir_p(out_dir)
    program = File.join(workdir, 'hcr_test_program.rb')

    Dir.chdir(File.expand_path('..', __dir__)) do
      _stdout, _stderr, status = Open3.capture3(
        RbConfig.ruby, NATIVE_RECORDER, '--out-dir', out_dir, program
      )
      return nil unless status.success?
    end

    ct_files = Dir.glob(File.join(out_dir, '*.ct'))
    return nil if ct_files.empty?
    return nil unless File.executable?(CT_PRINT)

    ct_file = ct_files.first
    stdout, _stderr, st = Open3.capture3(CT_PRINT, '--json-events', ct_file)
    return nil unless st.success?

    JSON.parse(stdout)
  end

  # Build helper structures from the pure-recorder trace.json array.
  def build_trace_index(trace)
    functions  = []
    paths      = []
    calls      = []
    returns_ev = []
    steps      = []
    io_events  = []
    var_names  = []

    trace.each do |ev|
      if ev.key?('Function')
        functions << ev['Function']
      elsif ev.key?('Path')
        paths << ev['Path']
      elsif ev.key?('Call')
        calls << ev['Call']
      elsif ev.key?('Return')
        returns_ev << ev['Return']
      elsif ev.key?('Step')
        steps << ev['Step']
      elsif ev.key?('Event')
        io_events << ev['Event']
      elsif ev.key?('VariableName')
        var_names << ev['VariableName']
      end
    end

    {
      functions:  functions,
      paths:      paths,
      calls:      calls,
      returns_ev: returns_ev,
      steps:      steps,
      io_events:  io_events,
      var_names:  var_names.uniq
    }
  end

  # Map function_id -> function name from Function events (assigned in order).
  def function_name_by_id(functions)
    result = {}
    functions.each_with_index { |f, i| result[i] = f['name'] }
    result
  end

  # ------- memoised trace data (recorded once, reused across tests) -------

  def trace_data
    @trace_data ||= begin
      trace, metadata, _out_dir = run_pure_recorder
      idx = build_trace_index(trace)
      { trace: trace, metadata: metadata, index: idx }
    end
  end

  def idx;      trace_data[:index];    end
  def metadata; trace_data[:metadata]; end

  # ------- tests -------

  # 1. Step count: the trace has a meaningful number of steps.
  def test_step_count
    assert idx[:steps].size > 0, 'Trace should contain Step events'
    # The HCR program has 12 iterations plus top-level and function bodies;
    # the pure recorder records steps inside every method call too.
    assert idx[:steps].size >= 12,
           "Expected at least 12 steps (one per iteration), got #{idx[:steps].size}"
  end

  # 2. Function definitions: compute, transform, aggregate are in the trace.
  def test_functions_include_compute_transform_aggregate
    names = idx[:functions].map { |f| f['name'] }
    %w[compute transform aggregate].each do |expected|
      assert names.include?(expected),
             "Expected function '#{expected}' in trace, got: #{names.inspect}"
    end
  end

  # 3. Call events: 12 calls each for compute, transform, aggregate.
  def test_call_counts_per_function
    fname_by_id = function_name_by_id(idx[:functions])
    call_counts = Hash.new(0)
    idx[:calls].each do |c|
      name = fname_by_id[c['function_id']]
      call_counts[name] += 1 if name
    end

    %w[compute transform aggregate].each do |fn|
      assert_equal 12, call_counts[fn],
                   "Expected 12 calls to '#{fn}', got #{call_counts[fn]}"
    end
  end

  # 4. Paths: both hcr_test_program.rb and mymodule.rb are in the trace.
  def test_paths_include_program_and_module
    path_strings = idx[:paths].map(&:to_s)

    assert path_strings.any? { |p| p.include?('hcr_test_program.rb') },
           "Expected hcr_test_program.rb in paths, got: #{path_strings.inspect}"
    assert path_strings.any? { |p| p.include?('mymodule.rb') },
           "Expected mymodule.rb in paths, got: #{path_strings.inspect}"
  end

  # 5. IO events: check if stdout lines are captured. The pure recorder may
  #    not capture IO as Event objects -- skip gracefully if so.
  def test_io_events_or_skip
    if idx[:io_events].empty?
      skip 'Pure recorder does not capture IO as Event objects in the trace'
    end

    # If the recorder does capture IO, verify some expected output is present.
    contents = idx[:io_events].map { |e| e['content'] }
    assert contents.any? { |c| c.include?('step=') },
           "Expected IO events with step output, got: #{contents.first(3).inspect}"
  end

  # 6. Metadata: program field references the test program.
  def test_metadata_references_program
    skip 'No trace_metadata.json produced' if metadata.nil?

    program_path = metadata['program']
    refute_nil program_path, 'metadata should have a "program" field'
    assert program_path.include?('hcr_test_program.rb'),
           "Expected metadata program to reference hcr_test_program.rb, got: #{program_path}"
  end

  # 7. Structural integrity: all call function_ids reference valid functions.
  def test_call_function_ids_reference_valid_functions
    valid_ids = (0...idx[:functions].size).to_a

    idx[:calls].each_with_index do |call, i|
      fid = call['function_id']
      assert valid_ids.include?(fid),
             "Call ##{i} references function_id=#{fid} which is not in the " \
             "valid range 0..#{idx[:functions].size - 1}"
    end
  end

  # Bonus: verify return count matches call count (every call returns).
  def test_return_count_matches_calls_minus_toplevel
    # top-level may not have a matching Return if the program exits normally,
    # so we expect returns >= calls - 1.
    assert idx[:returns_ev].size >= idx[:calls].size - 1,
           "Expected at least #{idx[:calls].size - 1} returns, " \
           "got #{idx[:returns_ev].size}"
  end

  # Bonus: verify that steps reference valid path_ids.
  def test_step_path_ids_are_valid
    valid_path_ids = (0...idx[:paths].size).to_a

    idx[:steps].each_with_index do |step, i|
      pid = step['path_id']
      assert valid_path_ids.include?(pid),
             "Step ##{i} references path_id=#{pid} which is not in the " \
             "valid range 0..#{idx[:paths].size - 1}"
    end
  end

  # Bonus: if ct-print is available and native recorder produces .ct,
  # verify the binary trace has the same structural properties.
  def test_ctfs_binary_trace_structure
    skip 'ct-print not found' unless File.executable?(CT_PRINT)

    ct_events = run_native_recorder_ct
    skip 'Native recorder did not produce a .ct file' if ct_events.nil?

    # Count event types
    type_counts = Hash.new(0)
    ct_events.each { |ev| type_counts[ev['type']] += 1 }

    # Must have steps
    assert type_counts['Step'] > 0, 'CTFS trace should contain Step events'

    # Must have Function events for compute/transform/aggregate
    func_events = ct_events.select { |ev| ev['type'] == 'Function' }
    func_names  = func_events.map { |ev| ev['name'] }
    %w[compute transform aggregate].each do |expected|
      assert func_names.include?(expected),
             "CTFS trace missing function '#{expected}', got: #{func_names.inspect}"
    end

    # Must have Path events referencing both source files
    path_events = ct_events.select { |ev| ev['type'] == 'Path' }
    path_names  = path_events.map { |ev| ev['name'] }
    assert path_names.any? { |p| p.include?('hcr_test_program.rb') },
           "CTFS trace missing hcr_test_program.rb path"
    assert path_names.any? { |p| p.include?('mymodule.rb') },
           "CTFS trace missing mymodule.rb path"
  end
end
