# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Metacraft Labs Ltd
# See LICENSE file in the project root for full license information.

require 'json'
require 'optparse'
require_relative 'recorder'
require_relative 'codetracer/kernel_patches'

module CodeTracer
  class PureRubyRecorder
    attr_accessor :calls_tracepoint, :return_tracepoint,
                  :line_tracepoint, :raise_tracepoint, :tracing

    attr_reader :ignore_list, :record, :debug

    def self.parse_argv_and_trace_ruby_file(argv)
      require 'optparse'
      lib_dir = File.expand_path('../lib', __dir__)
      $LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "usage: codetracer-pure-ruby-recorder [options] <program> [<program args>]"
        opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') { |dir| options[:out_dir] = dir }
        opts.on('-h', '--help', 'Print this help') { puts opts; exit }
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
      tracer = PureRubyRecorder.new(debug: ENV['CODETRACER_RUBY_RECORDER_DEBUG'] == '1')

      tracer.record.register_call('', 1, '<top-level>', [])
      tracer.ignore('lib/ruby')
      tracer.ignore('codetracer_pure_ruby_recoreder.rb')
      tracer.ignore('recorder.rb')
      tracer.ignore('<internal:')
      tracer.ignore('gems/')

      tracer.trace_block do
        begin
          # Set ARGV to contain the program arguments
          original_argv = ARGV.dup
          ARGV.clear
          ARGV.concat(program_args)

          Kernel.load(program)
        rescue Exception => e
          if tracer.debug
            codetracer_original_puts ''
            codetracer_original_puts '==== trace.rb error while tracing program ==='
            codetracer_original_puts 'ERROR'
            codetracer_original_puts e
            codetracer_original_puts e.backtrace
            codetracer_original_puts '====================='
            codetracer_original_puts ''
          end
        ensure
          # Restore original ARGV
          ARGV.clear
          ARGV.concat(original_argv)
        end
      end

      tracer.record.serialize(program, out_dir)
      0
    end

    def initialize(debug: false)
      @tracing = false
      @record = TraceRecord.new
      @ignore_list = []
      @debug = debug
      @record.debug = debug if @record.respond_to?(:debug=)
      setup_tracepoints
    end

    def tracks_call?(tp)
      tp.path.end_with?('.rb') && !@ignore_list.any? { |path| tp.path.include?(path) }
    end

    def ignore(path)
      @ignore_list << path
    end

    def setup_tracepoints
      @calls_tracepoint = TracePoint.new(:call) do |tp|
        disable_tracepoints
        record_call(tp)
        enable_tracepoints
      end

      @return_tracepoint = TracePoint.new(:return) do |tp|
        disable_tracepoints
        record_return(tp)
        enable_tracepoints
      end

      @line_tracepoint = TracePoint.new(:line) do |tp|
        disable_tracepoints
        record_step(tp)
        enable_tracepoints
      end

      @raise_tracepoint = TracePoint.new(:raise) do |tp|
        disable_tracepoints
        record_exception(tp)
        enable_tracepoints
      end
    end

    def prepare_args(tp)
      args_after_self = tp.parameters.map do |(kind, name)|
        value = if tp.binding.nil? || name.nil?
            @record.nil_value
          else
            begin
              @record.to_value(tp.binding.local_variable_get(name))
            rescue
              @record.nil_value
            end
          end
        [name.to_sym, value]
      end

      # can be class or module
      module_name = tp.self.class.name
      begin
        args = [[:self, @record.raw_obj_value(tp.self.to_s, module_name)]] + args_after_self
      rescue
        # $stderr.write("error args\n")
        args = []
      end

      args.each do |(name, value)|
        @record.register_variable(name, value)
      end

      arg_records = args.map do |(name, value)|
        [@record.load_variable_id(name), value]
      end

      arg_records
    end

    def record_call(tp)
      if self.tracks_call?(tp)
        module_name = tp.self.class.name
        method_name_prefix = module_name == 'Object' ? '' :  "#{module_name}#"
        method_name = "#{method_name_prefix}#{tp.method_id}"
        if @debug
          codetracer_original_puts "call #{method_name} with #{tp.parameters}"
        end
        arg_records = prepare_args(tp)
        @record.register_step(tp.path, tp.lineno)
        @record.register_call(tp.path, tp.lineno, method_name, arg_records)
      else
      end
    end

    def record_return(tp)
      if self.tracks_call?(tp)
        if @debug
          codetracer_original_puts 'return'
        end
        return_value = @record.to_value(tp.return_value)
        @record.register_step(tp.path, tp.lineno)
        # return value support inspired by existing IDE-s/envs like
        # Visual Studio/JetBrains IIRC
        # (Nikola Gamzakov showed me some examples)
        @record.register_variable("<return_value>", return_value)
        @record.events << [:Return, ReturnRecord.new(return_value)]
      end
    end

    def record_step(tp)
      if self.tracks_call?(tp)
        @record.register_step(tp.path, tp.lineno)
        variables = self.load_variables(tp.binding)
        variables.each do |(name, value)|
          @record.register_variable(name, value)
        end
      end
    end

    def record_event(*args)
      if args.length == 2
        caller, content = args
        begin
          location = caller[0].split[0].split(':')[0..1]
          path, line = location[0], location[1].to_i
          @record.register_step(path, line)
        rescue
          # ignore for now
        end
        @record.events << [:Event, RecordEvent.new(EVENT_KIND_WRITE, content, "")]
      elsif args.length == 3
        path, line, content = args
        record_event(["#{path}:#{line}"], content)
      else
        raise ArgumentError, "wrong number of arguments"
      end
    end

    def record_exception(tp)
      @record.events << [:Event, RecordEvent.new(EVENT_KIND_ERROR, tp.raised_exception.to_s, "")]
    end

    def start
      ::CodeTracer::KernelPatches.install(self)
      enable_tracepoints
    end

    def stop
      disable_tracepoints
      ::CodeTracer::KernelPatches.uninstall(self)
    end

    def trace_block(&block)
      raise ArgumentError, "no block given" unless block_given?

      start
      begin
        yield
      ensure
        stop
      end
    end

    # Flush trace to output directory - compatible with native recorder API
    def flush_trace(out_dir)
      @record.serialize('', out_dir)
    end

    private

    def enable_tracepoints
      @calls_tracepoint.enable
      @return_tracepoint.enable
      @raise_tracepoint.enable
      @tracing = true
      # We intentionally enable the line tracepoint after the other tracepoints
      # to avoid recording the initial activation call as a line event.
      @line_tracepoint.enable
    end

    def disable_tracepoints
      # We disable the line tracepoint first to avoid recording the deactivation
      # call as a line event.
      @line_tracepoint.disable
      @calls_tracepoint.disable
      @return_tracepoint.disable
      @raise_tracepoint.disable
      @tracing = false
    end

    def load_variables(binding)
      if !binding.nil?
        # $stdout.write binding.local_variables
        binding.local_variables.map do |name|
          v = binding.local_variable_get(name)
          out = @record.to_value(v)
          [name, out]
        end
      else
        []
      end
    end
  end
end
