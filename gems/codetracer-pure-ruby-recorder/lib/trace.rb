# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Metacraft Labs Ltd
# See LICENSE file in the project root for full license information.

require 'json'
require 'optparse'
require_relative 'recorder'
require_relative 'codetracer/kernel_patches'

# Helper to access the original +puts+ implementation when kernel
# methods are patched by {Codetracer::KernelPatches}. This avoids
# tracing debug output while still functioning even if the patches
# are not installed.
def codetracer_puts_no_trace(*args)
  if Kernel.private_method_defined?(:codetracer_original_puts)
    Kernel.send(:codetracer_original_puts, *args)
  else
    Kernel.puts(*args)
  end
end


# Warning:
# probably related to our development env:
# if we hit an `incompatible library version` error, like
# `<internal:/nix/store/w8r0c0l4i8383dr0w7iiy390dgrp6ws8-ruby-3.1.5/lib/ruby/3.1.0/rubygems/core_ext/kernel_require.rb>:136:in `require': incompatible library version - /home/alexander92/.local/share/gem/ruby/3.1.0/gems/strscan-3.1.0/lib/strscan.so (LoadError)
# or
# `<internal:/nix/store/w8r0c0l4i8383dr0w7iiy390dgrp6ws8-ruby-3.1.5/lib/ruby/3.1.0/rubygems/core_ext/kernel_require.rb>:136:in `require': incompatible library version - /home/alexander92/.local/share/gem/ruby/3.1.0/gems/json-2.7.2/lib/json/ext/parser.so (LoadError)`
#
# it seems clearing `~/.local/share/gem` fixes things up
# however this seems as a risky solution, as it clears global gem state!
# BE CAREFUL if you have other ruby projects/data there!

# class IO
#   alias :old_write :write

#   def write(name, content="", offset=0, opt=nil)
#     if $tracer.tracing
#       $tracer.deactivate
#       $tracer.record_event(caller, content)
#       $tracer.activate
#     end
#     old_write(name, content, offset, opt)
#   end
# end

class Tracer
  attr_accessor :calls_tracepoint, :return_tracepoint,
                :line_tracepoint, :raise_tracepoint, :tracing

  attr_reader :ignore_list, :record, :debug

  def initialize(record, debug: false)
    @tracing = false
    @trace_stopped = false
    @record = record
    @ignore_list = []
    @debug = debug
    @record.debug = debug if @record.respond_to?(:debug=)
    setup_tracepoints
  end

  def stop_tracing
    @trace_stopped = true
    @tracing = false
  end

  def tracks_call?(tp)
    tp.path.end_with?('.rb') && !@ignore_list.any? { |path| tp.path.include?(path) }
  end

  def ignore(path)
    @ignore_list << path
  end

  def setup_tracepoints
    @calls_tracepoint = TracePoint.new(:call) do |tp|
      deactivate
      record_call(tp)
      activate
    end

    @return_tracepoint = TracePoint.new(:return) do |tp|
      deactivate
      record_return(tp)
      activate
    end

    @line_tracepoint = TracePoint.new(:line) do |tp|
      deactivate
      record_step(tp)
      activate
    end

    @raise_tracepoint = TracePoint.new(:raise) do |tp|
      deactivate
      record_exception(tp)
      activate
    end
  end

  def prepare_args(tp)
    args_after_self = tp.parameters.map do |(kind, name)|
      value = if tp.binding.nil? || name.nil?
          NIL_VALUE
        else
          begin
            to_value(tp.binding.local_variable_get(name))
          rescue
            NIL_VALUE
          end
        end
      [name.to_sym, value]
    end

    # can be class or module
    module_name = tp.self.class.name
    begin
      args = [[:self, raw_obj_value(tp.self.to_s, module_name)]] + args_after_self
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

      codetracer_puts_no_trace "call #{method_name} with #{tp.parameters}" if $tracer.debug

      arg_records = prepare_args(tp)

      @record.register_step(tp.path, tp.lineno)
      @record.register_call(tp.path, tp.lineno, method_name, arg_records)
    else
    end
  end

  def record_return(tp)
    if self.tracks_call?(tp)
      codetracer_puts_no_trace "return" if $tracer.debug
      return_value = to_value(tp.return_value)
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

  def activate
    if !@trace_stopped
      @calls_tracepoint.enable
      @return_tracepoint.enable
      @line_tracepoint.enable
      @raise_tracepoint.enable
      @tracing = true
    end
  end

  def deactivate
    @tracing = false
    @calls_tracepoint.disable
    @return_tracepoint.disable
    @line_tracepoint.disable
    @raise_tracepoint.disable
  end

  private

  def load_variables(binding)
    if !binding.nil?
      # $stdout.write binding.local_variables
      binding.local_variables.map do |name|
        v = binding.local_variable_get(name)
        out = to_value(v)
        [name, out]
      end
    else
      []
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  $tracer = Tracer.new($codetracer_record, debug: ENV['CODETRACER_RUBY_RECORDER_DEBUG'] == '1')
  ::Codetracer::KernelPatches.install($tracer)

  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "usage: ruby trace.rb [options] <program> [args]"
    opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') do |dir|
      options[:out_dir] = dir
    end
    opts.on('-h', '--help', 'Print this help') do
      puts opts
      exit
    end
  end
  parser.order!

  program = ARGV.shift
  if program.nil?
    $stderr.puts parser
    exit 1
  end

  $tracer.record.register_call('', 1, '<top-level>', [])
  $tracer.ignore('lib/ruby')
  $tracer.ignore('trace.rb')
  $tracer.ignore('recorder.rb')
  $tracer.ignore('<internal:')
  $tracer.ignore('gems/')

  $tracer.activate
  at_exit do
    ::Codetracer::KernelPatches.uninstall($tracer)
  end
  begin
    Kernel.load(program)
  rescue Exception => e
    if $tracer.debug
      codetracer_puts_no_trace ''
      codetracer_puts_no_trace '==== trace.rb error while tracing program ==='
      codetracer_puts_no_trace 'ERROR'
      codetracer_puts_no_trace e
      codetracer_puts_no_trace e.backtrace
      codetracer_puts_no_trace '====================='
      codetracer_puts_no_trace ''
    end
  end

  $tracer.stop_tracing

  out_dir = options[:out_dir] || ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] || Dir.pwd
  $tracer.record.serialize(program, out_dir)
end
