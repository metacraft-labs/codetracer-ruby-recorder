require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class TraceTest < Minitest::Test
  TMP_DIR = File.expand_path('tmp', __dir__)
  FIXTURE_DIR = File.expand_path('fixtures', __dir__)
  PROGRAM_ARGS = {
    'args_sum' => %w[1 2 3]
  }

  def setup
    FileUtils.mkdir_p(TMP_DIR)
  end

  def run_trace(tracer_script, program_name, *args)
    base = File.basename(program_name, '.rb')
    tracer_name = tracer_script.include?('pure') ? 'pure' : 'native'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join(TMP_DIR, base, tracer_name)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, tracer_script, '--out-dir', out_dir, program, *args)
      raise "trace failed: #{stderr}" unless status.success?
      trace_file = File.join(out_dir, 'trace.json')
      trace = JSON.parse(File.read(trace_file)) if File.exist?(trace_file)
      program_out = stdout.lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }.join
      [trace, program_out]
    end
  end

  def run_trace_with_separator(tracer_script, program_name, *args)
    base = File.basename(program_name, '.rb')
    tracer_name = tracer_script.include?('pure') ? 'pure' : 'native'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join(TMP_DIR, "#{base}_dashdash", tracer_name)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, tracer_script, '--out-dir', out_dir, '--', program, *args
      )
      raise "trace failed: #{stderr}" unless status.success?
      trace_file = File.join(out_dir, 'trace.json')
      trace = JSON.parse(File.read(trace_file)) if File.exist?(trace_file)
      program_out = stdout.lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }.join
      [trace, program_out]
    end
  end

  def expected_output(program_name)
    base = File.basename(program_name, '.rb')
    fixture = File.join(FIXTURE_DIR, "#{base}_output.txt")
    File.read(fixture)
  end

  def expected_trace(program_name)
    base = File.basename(program_name, '.rb')
    fixture = File.join(FIXTURE_DIR, "#{base}_trace.json")
    JSON.parse(File.read(fixture))
  end

  def program_args(base)
    PROGRAM_ARGS.fetch(base, [])
  end

  Dir.glob(File.join(FIXTURE_DIR, '*_trace.json')).each do |fixture|
    base = File.basename(fixture, '_trace.json')
    define_method("test_#{base}") do
      pure_trace, pure_out = run_trace('gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', "#{base}.rb", *program_args(base))
      native_trace, native_out = run_trace('gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder', "#{base}.rb", *program_args(base))

      expected = expected_trace("#{base}.rb")
      assert_equal expected, pure_trace
      assert_equal expected, native_trace
      expected = expected_output("#{base}.rb")
      assert_equal expected, pure_out
      assert_equal expected, native_out
    end
  end

  def test_args_sum_with_separator
    base = 'args_sum'
    pure_trace, pure_out = run_trace_with_separator('gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', "#{base}.rb", *program_args(base))
    native_trace, native_out = run_trace_with_separator('gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder', "#{base}.rb", *program_args(base))

    expected = expected_trace("#{base}.rb")
    assert_equal expected, pure_trace
    assert_equal expected, native_trace
    expected = expected_output("#{base}.rb")
    assert_equal expected, pure_out
    assert_equal expected, native_out
  end

  def test_pure_debug_smoke
    Dir.chdir(File.expand_path('..', __dir__)) do
      env = { 'CODETRACER_RUBY_RECORDER_DEBUG' => '1' }
      out_dir = File.join(TMP_DIR, 'debug_smoke')
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', '--out-dir', out_dir, File.join('test', 'programs', 'addition.rb'))
      raise "trace failed: #{stderr}" unless status.success?

      lines = stdout.lines.map(&:chomp)
      assert lines.any? { |l| l.start_with?('call ') }, 'missing debug output'
      assert lines.include?('3'), 'missing program output'
      assert File.exist?(File.join(out_dir, 'trace.json'))
    end
  end
end
