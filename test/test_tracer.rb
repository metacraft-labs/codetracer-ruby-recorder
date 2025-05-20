require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'

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
    tracer_name = tracer_script.include?('native') ? 'native' : 'pure'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join('test', 'tmp', base, tracer_name)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3('ruby', tracer_script, '--out-dir', out_dir, program, *args)
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
      pure_trace, pure_out = run_trace('gems/pure-ruby-tracer/lib/trace.rb', "#{base}.rb", *program_args(base))
      native_trace, native_out = run_trace('gems/native-tracer/lib/native_trace.rb', "#{base}.rb", *program_args(base))

      expected = expected_trace("#{base}.rb")
      assert_equal expected, pure_trace
      assert_equal expected, native_trace
      expected = expected_output("#{base}.rb")
      assert_equal expected, pure_out
      assert_equal expected, native_out
    end
  end
end
