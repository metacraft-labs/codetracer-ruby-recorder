require 'minitest/autorun'
require 'json'
require 'fileutils'

class TraceTest < Minitest::Test
  TMP_DIR = File.expand_path('tmp', __dir__)
  FIXTURE_DIR = File.expand_path('fixtures', __dir__)

  def setup
    FileUtils.mkdir_p(TMP_DIR)
  end

  def run_trace(program_name)
    base = File.basename(program_name, '.rb')
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join('test', 'tmp', base)
      FileUtils.mkdir_p(out_dir)
      system('ruby', 'gems/pure-ruby-tracer/lib/trace.rb', '--out-dir', out_dir, program)
      raise "trace failed" unless $?.success?
      JSON.parse(File.read(File.join(out_dir, 'trace.json')))
    end
  end

  def expected_trace(program_name)
    base = File.basename(program_name, '.rb')
    fixture = File.join(FIXTURE_DIR, "#{base}_trace.json")
    JSON.parse(File.read(fixture))
  end

  Dir.glob(File.join(FIXTURE_DIR, '*_trace.json')).each do |fixture|
    base = File.basename(fixture, '_trace.json')
    define_method("test_#{base}") do
      assert_equal expected_trace("#{base}.rb"), run_trace("#{base}.rb")
    end
  end
end
