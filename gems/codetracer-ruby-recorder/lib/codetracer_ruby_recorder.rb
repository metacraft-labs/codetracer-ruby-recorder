# SPDX-License-Identifier: MIT
# Library providing a helper method to execute the native tracer.
#
# CLI compliance: this recorder follows
# `codetracer-specs/Recorder-CLI-Conventions.md`. It is **CTFS-only** (§4):
# there is no `--format` flag and no `CODETRACER_FORMAT` environment
# variable.  Use `ct print` (shipped with `codetracer-trace-format-nim`) to
# convert recorded `*.ct` traces into JSON or human-readable text.
#
# Recognised environment variables (§5):
#
# * `CODETRACER_RUBY_RECORDER_OUT_DIR` — fallback for `--out-dir`.
# * `CODETRACER_RUBY_RECORDER_DISABLED` — set to `1` or `true` to skip
#   recording entirely (the target script still runs).

require 'optparse'
require 'fileutils'
require 'rbconfig'
require_relative 'codetracer/kernel_patches'

module CodeTracer
  class RubyRecorder
    # Parse the disabled environment variable, accepting `1` / `true`
    # (case-insensitive) as truthy.  Any other value (including unset)
    # leaves recording enabled.  Convention §5.
    def self.disabled_via_env?
      raw = ENV['CODETRACER_RUBY_RECORDER_DISABLED']
      return false if raw.nil?

      raw.strip.downcase == '1' || raw.strip.downcase == 'true'
    end

    def self.parse_argv_and_trace_ruby_file(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = 'usage: codetracer-ruby-recorder [options] <program> [args]'
        opts.separator ''
        opts.separator 'Options:'
        opts.on('-o DIR', '--out-dir DIR',
                'Directory to write the CTFS trace bundle ' \
                '(defaults to ./ct-traces, or $CODETRACER_RUBY_RECORDER_OUT_DIR when set).') do |dir|
          options[:out_dir] = dir
        end
        opts.on('-h', '--help', 'Print this help and exit') do
          puts opts
          puts ''
          puts 'Output format:'
          puts '  The recorder always writes the canonical CTFS trace bundle (a single'
          puts '  *.ct file).  There is no format-selector flag or environment variable.'
          puts '  To convert a recorded trace to JSON or human-readable text, run'
          puts '  `ct print` (shipped with codetracer-trace-format-nim) on the produced'
          puts '  *.ct file.'
          puts ''
          puts 'Environment variables:'
          puts '  CODETRACER_RUBY_RECORDER_OUT_DIR   Default output directory'
          puts '                                      (overridden by --out-dir).'
          puts '  CODETRACER_RUBY_RECORDER_DISABLED  Set to 1 or true to skip recording'
          puts '                                      entirely; the script still runs.'
          puts '  CODETRACER_RUBY_RECORDER_DEBUG     Enable additional debug logging.'
          exit
        end
        opts.on('-V', '--version', 'Print version and exit') do
          version_file = File.join(__dir__, '..', '..', 'version.txt')
          version = File.exist?(version_file) ? File.read(version_file).strip : 'unknown'
          puts "codetracer-ruby-recorder #{version}"
          exit
        end
      end

      # Reject the legacy --format flag explicitly so callers see a clear
      # failure rather than silently writing CTFS while believing they
      # asked for JSON or binary.  Convention §4: CTFS-only.
      if argv.any? { |a| a == '--format' || a == '-f' || a.start_with?('--format=') || a.start_with?('-f=') }
        $stderr.puts 'codetracer-ruby-recorder: error: the --format / -f flag has been removed.'
        $stderr.puts '  The recorder always writes CTFS.  Use `ct print` (shipped with'
        $stderr.puts '  codetracer-trace-format-nim) to convert the recorded *.ct file to JSON.'
        exit 2
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

      # CODETRACER_RUBY_RECORDER_DISABLED short-circuits the recorder
      # entirely: the target program still runs (so callers get the same
      # stdout / exit behaviour) but no trace is written.  Convention §5.
      if disabled_via_env?
        original_argv = ARGV.dup
        ARGV.clear
        ARGV.concat(program_args)
        begin
          load program
        ensure
          ARGV.clear
          ARGV.concat(original_argv)
        end
        return 0
      end

      trace_ruby_file(program, out_dir, program_args)
      0
    end

    # Trace the given Ruby program and write a CTFS bundle to `out_dir`.
    # The output format is hard-pinned to CTFS — see `Recorder-CLI-Conventions.md`
    # §4 (CTFS-only).
    def self.trace_ruby_file(program, out_dir, program_args = [])
      recorder = RubyRecorder.new(out_dir)
      return 1 unless recorder.available?

      ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] = out_dir

      recorder.start
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

        recorder.stop
        recorder.flush_trace
      end

      # Verify trace files were actually produced — the native extension can
      # load successfully but fail to capture events if built against a
      # different Ruby version (ABI mismatch).  CTFS-only: the recorder
      # writes a single *.ct file (no trace.json / trace.bin fallbacks).
      trace_produced = Dir.glob(File.join(out_dir, '*.ct')).any?
      unless trace_produced
        warn "codetracer-ruby-recorder: WARNING: no .ct trace file produced in #{out_dir}"
        warn "  The native extension may need to be rebuilt for Ruby #{RUBY_VERSION}."
        warn "  Run: cd #{File.expand_path('..', __dir__)} && just build-extension"
        return 1
      end
      0
    end

    # Execute the native tracer CLI logic with the provided +argv+.
    def self.execute(argv)
      parse_argv_and_trace_ruby_file(argv)
    end

    def initialize(out_dir)
      @recorder = nil
      @active = false
      load_native_recorder(out_dir)
    end

    # Start the recorder and install kernel patches
    def start
      return if @active || @recorder.nil?

      @recorder.enable_tracing
      CodeTracer::KernelPatches.install(self)
      @active = true
    end

    # Stop the recorder and remove kernel patches
    def stop
      return unless @active

      CodeTracer::KernelPatches.uninstall(self)
      @recorder.disable_tracing if @recorder
      @active = false
    end

    # Record event for kernel patches integration
    def record_event(path, line, content)
      @recorder.record_event(path, line, content) if @recorder
    end

    # Flush trace to output directory
    def flush_trace
      @recorder.flush_trace if @recorder
    end

    # Check if recorder is available
    def available?
      !@recorder.nil?
    end

    private

    def load_native_recorder(out_dir)
      begin
        # Load native extension at module level
        ext_dir = File.expand_path('../ext/native_tracer/target/release', __dir__)
        dlext = RbConfig::CONFIG['DLEXT']
        target_path = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
        extensions = %w[so bundle dylib dll]
        alt_path = extensions
                  .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
                  .find { |path| File.exist?(path) }
        if alt_path && (!File.exist?(target_path) || File.mtime(alt_path) > File.mtime(target_path))
          begin
            FileUtils.rm_f(target_path)
            File.symlink(alt_path, target_path)
          rescue StandardError
            FileUtils.cp(alt_path, target_path)
          end
        end

        require target_path
        # Format is hard-pinned to CTFS — the second positional argument
        # to the native `initialize` is kept for backward FFI compatibility
        # but every Ruby caller passes :ctfs.  See
        # ext/native_tracer/src/lib.rs::begin_trace which now writes only
        # the CTFS multi-stream container.
        @recorder = CodeTracerNativeRecorder.new(out_dir, :ctfs)
      rescue Exception => e
        warn "native tracer unavailable: #{e}"
        @recorder = nil
      end
    end
  end
end
