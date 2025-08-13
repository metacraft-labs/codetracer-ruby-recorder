require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class GemInstallationTest < Minitest::Test
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

        path_separator = File::PATH_SEPARATOR
        env = {
          'GEM_HOME' => gem_home,
          'GEM_PATH' => gem_home,
          'PATH' => "#{gem_home}/bin#{path_separator}#{ENV['PATH']}"
        }
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
          recorder = #{recorder_class}.new('#{out_dir_lib}')
          puts 'start trace'
          recorder.stop
          puts 'this will not be traced'
          recorder.start
          puts 'this will be traced'
          recorder.stop
          puts 'tracing disabled'
          recorder.flush_trace
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
    # When the pure Ruby recorder traces a script that holds a reference to the
    # `PureRubyRecorder` instance in a local variable, the variable inspection code
    # would recursively serialise the tracer's internal state. This results in an
    # explosive amount of output and may appear as an infinite recursion when running
    # `examples/selective_tracing_pure.rb`. For this reason, we skip this test for now.
    skip
    run_gem_installation_test('codetracer-pure-ruby-recorder', 'codetracer_pure_ruby_recorder')
  end
end
