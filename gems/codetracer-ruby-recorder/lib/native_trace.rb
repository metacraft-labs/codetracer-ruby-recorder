# SPDX-License-Identifier: MIT
# Library providing a helper method to execute the native tracer.

require 'optparse'
require 'fileutils'
require 'rbconfig'
require_relative 'codetracer/kernel_patches'

module CodeTracer
  class RubyRecorder
    def self.parse_argv_and_trace_ruby_file(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = 'usage: codetracer-ruby-recorder [options] <program> [args]'
        opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') do |dir|
          options[:out_dir] = dir
        end
        opts.on('-h', '--help', 'Print this help') do
          puts opts
          exit
        end
      end
      parser.order!(argv)

      program = argv.shift
      if program.nil?
        $stderr.puts parser
        exit 1
      end

      # Remaining arguments after the program name are passed to the traced program
      program_args = argv.dup

      out_dir = options[:out_dir] || ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] || Dir.pwd
      trace_ruby_file(program, out_dir, program_args)
      0
    end

    def self.trace_ruby_file(program, out_dir, program_args = [])
      recorder = RubyRecorder.new
      return 1 unless recorder.available?

      ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] = out_dir

      recorder.activate
      begin
        # Set ARGV to contain the program arguments
        original_argv = ARGV.dup
        ARGV.clear
        ARGV.concat(program_args)

        load program
      ensure
        # Restore original ARGV
        ARGV.clear
        ARGV.concat(original_argv)

        recorder.deactivate
        recorder.flush_trace(out_dir)
      end
      0
    end

    # Execute the native tracer CLI logic with the provided +argv+.
    def self.execute(argv)
      parse_argv_and_trace_ruby_file(argv)
    end

    def initialize
      @recorder = nil
      @active = false
      load_native_recorder
    end

    # Activate the recorder and install kernel patches
    def activate
      return if @active || @recorder.nil?

      @recorder.enable_tracing
      Codetracer::KernelPatches.install(self)
      @active = true
    end

    # Deactivate the recorder and remove kernel patches
    def deactivate
      return unless @active

      Codetracer::KernelPatches.uninstall(self)
      @recorder.disable_tracing if @recorder
      @active = false
    end

    # Record event for kernel patches integration
    def record_event(path, line, content)
      @recorder.record_event(path, line, content) if @recorder
    end

    # Flush trace to output directory
    def flush_trace(out_dir)
      @recorder.flush_trace(out_dir) if @recorder
    end

    # Check if recorder is available
    def available?
      !@recorder.nil?
    end

    private

    def load_native_recorder
      begin
        # Load native extension at module level
        ext_dir = File.expand_path('../ext/native_tracer/target/release', __dir__)
        dlext = RbConfig::CONFIG['DLEXT']
        target_path = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
        unless File.exist?(target_path)
          extensions = %w[so bundle dylib dll]
          alt_path = extensions
                    .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
                    .find { |path| File.exist?(path) }
          if alt_path
            begin
              File.symlink(alt_path, target_path)path, target_path)
            rescue StandardError
              FileUtils.cp(alt_path, target_path)
            end
          end
        end

        require target_path
        @recorder = RubyRecorder.new
      rescue Exception => e
        warn "native tracer unavailable: #{e}"
        @recorder = nil
      end
    end
  end
end
