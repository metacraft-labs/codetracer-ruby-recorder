# SPDX-License-Identifier: MIT
# Library providing a helper method to execute the native tracer.

require 'optparse'
require 'fileutils'
require 'rbconfig'
require_relative 'codetracer/kernel_patches'

module NativeTrace
  # Execute the native tracer CLI logic with the provided +argv+.
  def self.execute(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'usage: codetracer-ruby-recorder [options] <program> [args]'
      opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') do |dir|
        options[:out_dir] = dir
      end
      opts.on('-h', '--help', 'Print this help') do
        puts opts
        return 0
      end
    end
    parser.order!(argv)

    if argv.empty?
      $stderr.puts parser
      return 1
    end

    out_dir = options[:out_dir] || ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] || Dir.pwd
    ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] = out_dir

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
          File.symlink(alt_path, target_path)
        rescue StandardError
          FileUtils.cp(alt_path, target_path)
        end
      end
    end

    recorder = nil
    begin
      require target_path
      recorder = RubyRecorder.new
      $recorder = recorder

      Kernel.module_eval do
        alias :old_p :p
        alias :old_puts :puts
        alias :old_print :print

        define_method(:p) do |*args|
          if $recorder
            loc = caller_locations(1,1).first
            $recorder.record_event(loc.path, loc.lineno, args.join("\n"))
          end
          old_p(*args)
        end

        define_method(:puts) do |*args|
          if $recorder
            loc = caller_locations(1,1).first
            $recorder.record_event(loc.path, loc.lineno, args.join("\n"))
          end
          old_puts(*args)
        end

        define_method(:print) do |*args|
          if $recorder
            loc = caller_locations(1,1).first
            $recorder.record_event(loc.path, loc.lineno, args.join("\n"))
          end
          old_print(*args)
        end
      end
    rescue Exception => e
      warn "native tracer unavailable: #{e}"
    end

    program = argv.shift
    recorder.enable_tracing if recorder
    load program
    if recorder
      recorder.disable_tracing
      recorder.flush_trace(out_dir)
    end
    0
  end
end
