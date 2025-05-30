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
    tracer_name = tracer_script.include?('native') ? 'native' : 'pure'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join('test', 'tmp', base, tracer_name)
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
    tracer_name = tracer_script.include?('native') ? 'native' : 'pure'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join('test', 'tmp', "#{base}_dashdash", tracer_name)
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

  def run_gem_installation_test(gem_bin, gem_module)
    Dir.chdir(File.expand_path('..', __dir__)) do
      gem_dir = File.join('gems', gem_bin)

      if gem_bin == 'codetracer-ruby-recorder'
        system('just', 'build-extension', exception: true)
        dlext = RbConfig::CONFIG['DLEXT']
        ext_path = File.join(gem_dir, 'ext', 'native_tracer', 'target', 'release', "codetracer_ruby_recorder.#{dlext}")
        FileUtils.rm_f(ext_path)
      end

      Dir.mktmpdir('gemhome') do |gem_home|
        gemspec = Dir[File.join(gem_dir, '*.gemspec')].first
        gem_build = IO.popen(%W[gem -C #{gem_dir} build #{File.basename(gemspec)}], err: [:child, :out]) { |io| io.read }
        gem_file = gem_build.lines.grep(/File:/).first.split.last
        gem_file = File.expand_path(File.join(gem_dir, gem_file))

        env = { 'GEM_HOME' => gem_home, 'GEM_PATH' => gem_home, 'PATH' => "#{gem_home}/bin:#{ENV['PATH']}" }
        system(env, 'gem', 'install', '--local', gem_file, exception: true)

        out_dir = File.join('test', 'tmp', "gem_install_#{gem_bin.tr('-', '_')}")
        FileUtils.rm_rf(out_dir)
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-S', gem_bin, '--out-dir', out_dir, File.join('test', 'programs', 'addition.rb'))
        raise "#{gem_bin} failed: #{stderr}" unless status.success?
        assert_equal "3\n", stdout
        assert File.exist?(File.join(out_dir, 'trace.json'))

        out_dir_lib = File.join('test', 'tmp', "gem_install_#{gem_bin.tr('-', '_')}_lib")
        FileUtils.rm_rf(out_dir_lib)

        recorder_class = if gem_bin == 'codetracer-ruby-recorder'
          "CodeTracer::RubyRecorder"
        else
          "CodeTracer::PureRubyRecorder"
        end

        script = <<~RUBY
          require '#{gem_module}'
          recorder = #{recorder_class}.new
          puts 'start trace'
          recorder.stop
          puts 'this will not be traced'
          recorder.start
          puts 'this will be traced'
          recorder.stop
          puts 'tracing disabled'
          recorder.flush_trace('#{out_dir_lib}')
        RUBY
        script_path = File.join('test', 'tmp', "use_#{gem_bin.tr('-', '_')}.rb")
        File.write(script_path, script)
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script_path)
        raise "#{gem_module} library failed: #{stderr}" unless status.success?
        expected_out = <<~OUT
          start trace
          this will not be traced
          this will be traced
          tracing disabled
        OUT
        assert_equal expected_out, stdout
        assert File.exist?(File.join(out_dir_lib, 'trace.json'))
      end
    end
  end

  def test_gem_installation
    run_gem_installation_test('codetracer-ruby-recorder', 'codetracer_ruby_recorder')
  end

  def test_pure_gem_installation
    skip
    run_gem_installation_test('codetracer-pure-ruby-recorder', 'codetracer_pure_ruby_recorder')
  end

  def test_pure_debug_smoke
    Dir.chdir(File.expand_path('..', __dir__)) do
      env = { 'CODETRACER_RUBY_RECORDER_DEBUG' => '1' }
      out_dir = File.join('test', 'tmp', 'debug_smoke')
      FileUtils.rm_rf(out_dir)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', '--out-dir', out_dir, File.join('test', 'programs', 'addition.rb'))
      raise "trace failed: #{stderr}" unless status.success?

      lines = stdout.lines.map(&:chomp)
      assert lines.any? { |l| l.start_with?('call ') }, 'missing debug output'
      assert lines.include?('3'), 'missing program output'
      assert File.exist?(File.join(out_dir, 'trace.json'))
    end
  end
end
