# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Metacraft Labs Ltd
# See LICENSE file in the project root for full license information.

require 'json'
require_relative 'recorder'

if ARGV[0].nil?
  $stderr.puts("ruby trace.rb <program>")
  exit(1)
end

program = ARGV[0]

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

$trace.register_call("", 1, "<top-level>", [])

$STEP_COUNT = 0

# override some of the IO methods to record them for event log
module Kernel
  alias :old_p :p
  alias :old_puts :puts

  def p(*args)
    if $trace.tracing
      # reason/effect are on different steps:
      # reason: before `p` is called;
      # effect: now, when the args are evaluated 
      # which can happen after many calls/steps;
      # maybe add a step for this call?
      begin
        location = caller[0].split[0].split(':')[0..1]
        path, line = location[0], location[1].to_i
        $trace.register_step(path, line)
      rescue
        # ignore for now: we'll just jump to last previous step 
        # which might be from args
      end
      # start is last step on this level: log for reason: the previous step on this level 
      $trace.events << [:Event, RecordEvent.new(EVENT_KIND_WRITE, args.join("\n"))]
    end
    old_p(*args)
  end

  def puts(*args)
    if $trace.tracing
      # reason/effect are on different steps:
      # reason before `p` is called; effect now, when the args are evaluated which
      # is after many calls/steps
      # maybe add a step for this call
      begin
        location = caller[0].split[0].split(':')[0..1]
        path, line = location[0], location[1].to_i
        $trace.register_step(path, line)
      rescue
        # ignore for now: we'll just jump to last previous step 
        # which might be from args
      end
      # start is last step on this level: log for reason: the previous step on this level 
      $trace.events << [:Event, RecordEvent.new(EVENT_KIND_WRITE, args.join("\n"))]
    end
    old_puts(*args)
  end
end


def load_variables(binding)
  if $trace.tracing
    # $stdout.write binding.local_variables
    # binding.local_variables.map do |name|
    #   v = binding.local_variable_get(name)
    #   out = to_value(v)
    #   [name, out]
    # end
    []
  else
    []
  end
end


$trace.t1 = TracePoint.new(:call, :c_call, :b_call) do |tp|
  if tp.path.end_with?('.rb') && !tp.path.include?('lib/ruby/') && !tp.path.include?('gems/') && !tp.path.end_with?("trace.rb") && !tp.path.end_with?("recorder.rb") && tp.event == :call
    # args_1 = tp.parameters.map do |(kind, name)|
    #   [name.to_sym, to_value(tp.binding.local_variable_get(name))]
    # end
    # can be class or module
    module_name = tp.self.class.name
    args = []
    # begin
    #   args = [[:self, raw_obj_value(tp.self.to_s, module_name)]] + args_1
    # rescue
    #   # $stderr.write("error args\n")
    #   args = []
    # end
    args.each do |(name, value)|
      $trace.register_variable(name, value)
    end

    arg_records = args.map do |(name, value)|
      [$trace.load_variable_id(name), value]
    end

    $trace.register_step(tp.path, tp.lineno)
    
    method_name_prefix = if module_name == 'Object'
        ''
      else 
        "#{module_name}#"
      end
    method_name = "#{method_name_prefix}#{tp.method_id}"
    $trace.register_call(tp.path, tp.lineno, method_name, arg_records)
  else
  end
end

$trace.t2 = TracePoint.new(:return) do |tp|
  if !tp.path.end_with?('.rb') || tp.path.include?('lib/ruby/') || tp.path.include?('gems/') || tp.path.end_with?("trace.rb") || tp.path.end_with?("recorder.rb")
    # TODO: is it possible that we match returns here
    # from functions we dont track: e.g. c_call?
    # ignore for now
  else
    return_value = NIL_VALUE # to_value(tp.return_value)
    $trace.register_step(tp.path, tp.lineno)
    # return value support inspired by existing IDE-s/envs like 
    # Visual Studio/JetBrains IIRC
    # (Nikola showed me some examples)
    $trace.register_variable("<return_value>", return_value)
    $trace.events << [:Return, ReturnRecord.new(return_value)]
  end
end


$trace.t3 = TracePoint.new(:line) do |tp|
  if !tp.path.end_with?("trace.rb") && !tp.path.end_with?("recorder.rb") && !tp.path.include?('lib/ruby/') && !tp.path.include?('gems/') && tp.path.end_with?('.rb')
    $trace.register_step(tp.path, tp.lineno)
    variables = load_variables(tp.binding)
    variables.each do |(name, value)|
      $trace.register_variable(name, value)
    end
  end
end

$trace.t4 =  TracePoint.new(:raise) do |tp|
  $trace.events << [:Event, RecordEvent.new(EVENT_KIND_ERROR, tp.raised_exception.to_s)]
end

$trace.t1.enable
$trace.t2.enable
$trace.t3.enable
$trace.t4.enable
$trace.tracing = true

trace_args = ARGV
ARGV = ARGV[1..-1]
begin
  Kernel.load(program)
rescue Exception => e
  # important: rescue Exception,
  # not just rescue as we originally did
  # because a simple `rescue` doesn't catch some errors
  # like SystemExit and others
  # (when we call `exit` in the trace program and others)
  # https://stackoverflow.com/questions/5118745/is-systemexit-a-special-kind-of-exception
  old_puts ""
  old_puts "==== trace.rb error while tracing program ==="
  old_puts "ERROR"
  old_puts e
  old_puts e.backtrace
  old_puts "====================="
  old_puts ""
end
ARGV = trace_args

$trace.tracing = false
$trace.t1.disable
$trace.t2.disable
$trace.t3.disable
$trace.t4.disable

if ENV["CODETRACER_RUBY_TRACER_DEBUG"] == "1"
  pp $trace.events
end

output = $trace.events.map { |kind, event| [[kind, event.to_data_for_json]].to_h }

metadata_output = {
  program: program,
  args: ARGV,
  workdir: Dir.pwd
}
# pp output

json_output = JSON.pretty_generate(output)
metadata_json_output = JSON.pretty_generate(metadata_output)
paths_json_output = JSON.pretty_generate($trace.paths)

trace_path = ENV["CODETRACER_DB_TRACE_PATH"] || "trace.json"
trace_folder = File.dirname(trace_path)
trace_metadata_path = File.join(trace_folder , "trace_metadata.json")
trace_paths_path = File.join(trace_folder , "trace_paths.json")

# p trace_path, json_output
File.write(trace_path, json_output)
File.write(trace_metadata_path, metadata_json_output)
File.write(trace_paths_path, paths_json_output)

$stderr.write("=================================================\n")
$stderr.write("codetracer ruby tracer: saved trace to #{trace_folder}\n")
