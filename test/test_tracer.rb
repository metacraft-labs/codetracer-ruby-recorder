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

  def run_trace(program_name, *args)
    base = File.basename(program_name, '.rb')
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join('test', 'tmp', base)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3('ruby', 'gems/pure-ruby-tracer/lib/trace.rb', '--out-dir', out_dir, program, *args)
      raise "trace failed: #{stderr}" unless status.success?
      trace = JSON.parse(File.read(File.join(out_dir, 'trace.json')))
      program_out = stdout.lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }.join
      [trace, program_out]
    end
  end

  def expected_trace(program_name)
    base = File.basename(program_name, '.rb')
    fixture = File.join(FIXTURE_DIR, "#{base}_trace.json")
    JSON.parse(File.read(fixture))
  end

  def expected_output(program_name)
    base = File.basename(program_name, '.rb')
    fixture = File.join(FIXTURE_DIR, "#{base}_output.txt")
    File.read(fixture)
  end

  def program_args(base)
    PROGRAM_ARGS.fetch(base, [])
  end

  Dir.glob(File.join(FIXTURE_DIR, '*_trace.json')).each do |fixture|
    base = File.basename(fixture, '_trace.json')
    define_method("test_#{base}") do
      trace, out = run_trace("#{base}.rb", *program_args(base))
      assert_equal expected_trace("#{base}.rb"), trace
      assert_equal expected_output("#{base}.rb"), out
    end
  end
end
