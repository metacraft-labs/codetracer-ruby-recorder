# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Metacraft Labs Ltd
# See LICENSE file in the project root for full license information.

require 'fileutils'
require 'set'
require 'ostruct'
require 'pp'

CallRecord = Struct.new(:function_id, :args) do
  def to_data_for_json
    res = to_h
    res[:args] = res[:args].map { |(variable_id, value)| {variable_id: variable_id, value: value.to_data_for_json} }
    res
  end
end

FunctionRecord = Struct.new(:path_id, :line, :name) do
  def to_data_for_json
    to_h
  end
end

ReturnRecord = Struct.new(:return_value) do
  def to_data_for_json
    res = {return_value: self.return_value.to_data_for_json}
    res
  end
end

StepRecord = Struct.new(:path_id, :line) do
  def to_data_for_json
    to_h
  end
end

RecordEvent = Struct.new(:kind, :content, :metadata) do
  def to_data_for_json
    to_h
  end
end

FullValueRecord = Struct.new(:variable_id, :value) do
  def to_data_for_json
    {variable_id: self.variable_id, value: value.to_data_for_json}
  end
end


ValueRecord = Struct.new(:kind, :type_id, :i, :f, :b, :text, :r, :msg, :elements, :is_slice, :field_values, keyword_init: true) do
  def to_data_for_json
    res = to_h.compact
    if !res[:elements].nil?
      res[:elements] = res[:elements].map(&:to_data_for_json)
    end
    if !res[:field_values].nil?
      res[:field_values] = res[:field_values].map(&:to_data_for_json)
    end

    # p res
    res
  end
end

TypeRecord = Struct.new(:kind, :lang_type, :specific_info) do
  def to_data_for_json
    to_h
  end
end

class Object
  def to_data_for_json
    self
  end
end

# based on  src/gdb/debug_values.py and src/types.nim's TypeKind enum
# TODO: improve

# sync with types.nim, runtime_tracing crate
SEQ = 0
STRUCT = 6
# TODO others Set
# HashSet,
# OrderedSet,
# Array,
# Varargs,
# # seq, HashSet, OrderedSet, set and array in Nim
# # vector and array in C++
# # list in Python
# # Array in Ruby
# Instance,
# # object in Nim
# # struct, class in C++
# # object in Python
# # object in Ruby
INT = 7
FLOAT = 8
STRING = 9
CSTRING = 10
CHAR = 11
BOOL = 12
RAW = 16
ERROR = 24
NONE = 30

NONE_TYPE_SPECIFIC_INFO = {kind: 'None'}

class TraceRecord
  # part of the final trace
  attr_accessor :steps, :calls, :variables, :events, :types, :flow, :paths

  # internal helpers
  attr_accessor :stack, :step_stack, :exprs, :tracing
  attr_accessor :t1, :t2, :t3, :t4 # tracepoints
  attr_accessor :codetracer_id
  attr_accessor :debug

  def initialize
    @events = []

    @steps = []
    @calls = []
    @variables = []
    @types = []
    @flow = []
    @paths = []

    @path_map = {}
    @function_map = {}
    @variable_map = {}
    @type_map = {}
    @struct_type_versions = {}
    @stack = []
    @step_stack = []
    @exprs = {}
    @tracing = false
    @t1 = nil
    @t2 = nil
    @t3 = nil
    @codetracer_id = 0
    @debug = false

    @step_count = 0
    @value_count = 0

    # Initialize type indices for this record instance
    @int_type_index = load_type_id(INT, "Integer")
    @string_type_index = load_type_id(STRING, "String")
    @bool_type_index = load_type_id(BOOL, "Bool")
    @symbol_type_index = load_type_id(STRING, "Symbol")
    @no_type_index = load_type_id(ERROR, "No type")
  end

  def load_flow(path, line, binding)
    unless @exprs.key?(path)
      @exprs[path] = load_exprs(path)
    end
    path_exprs = @exprs[path]
    line_exprs = path_exprs[line]
    if !line_exprs.nil?
      line_exprs.map do |name|
        [name, binding.eval(name)]
      end
    else
      []
    end
  end

  def path_id(path)
    existing_id = @path_map[path]
    unless existing_id.nil?
      existing_id
    else
      @events << [:Path, path]
      path_id = @path_map.count
      @path_map[path] = path_id
      @paths << path
      path_id
    end
  end

  def register_step(path, line)
    step_record = StepRecord.new(self.path_id(path), line)
    @events << [:Step, step_record] # because we convert later to {Step: step-record}: default enum json format in serde/rust
    # $stderr.write path, "\n"
    if @debug
      @step_count += 1
      $stdout.write "steps ", @step_count, "\n" if @step_count % 1_000 == 0
    end
  end

  def register_call(path, line, name, args)
    function_id = self.load_function_id(path, line, name)
    @events << [:Call, CallRecord.new(function_id, args)]
  end

  def load_function_id(path, line, name)
    function_id = @function_map[name]
    if function_id.nil?
      function_id = @function_map.count
      @function_map[name] = function_id
      @events << [:Function, FunctionRecord.new(self.path_id(path), line, name)]
    end
    function_id
  end

  def register_variable(name, value)
    @events << [:Value, FullValueRecord.new(load_variable_id(name), value)]
  end

  def register_type(kind, name, specific_info)
    # would lead to wrong type_id: different from the one before
    raise "#{name} already in type map for register_type!" unless @type_map[name].nil?

    type_id = @type_map.count
    @type_map[name] = type_id
    @events << [:Type, TypeRecord.new(kind, name, specific_info)]
    type_id
  end

  def register_struct_type(name, specific_info)
    if @struct_type_versions[name].nil?
      @struct_type_versions[name] = 0
    else
      @struct_type_versions[name] += 1
    end
    struct_name_index = @struct_type_versions[name]
    name_version = "#{name} (##{struct_name_index})"
    register_type(STRUCT, name_version, specific_info)
  end

  def drop_last_step
    @events << [:DropLastStep]
  end

  def load_type_id(kind, name)
    type_id = @type_map[name]
    if type_id.nil?
      type_id = register_type(kind, name, NONE_TYPE_SPECIFIC_INFO)
    end
    type_id
  end

  def type_id_for(name)
    @type_map[name]
  end

  def load_variable_id(name)
    variable_id = @variable_map[name]
    if variable_id.nil?
      variable_id = @variable_map.count
      @variable_map[name] = variable_id
      @events << [:VariableName, name]
    end
    variable_id
  end

  def load_exprs(path)
    # TODO: eventually, if we implement recorder support for flow
    # for now this logic is handled by db-backend based on recorded locals
    {}
  end

  def serialize(program, out_dir = nil)
    pp @events if @debug

    output = @events.map { |kind, event| [[kind, event.to_data_for_json]].to_h }

    metadata_output = {
      program: program,
      args: ARGV,
      workdir: Dir.pwd
    }
    # pp output

    json_output = JSON.pretty_generate(output)
    metadata_json_output = JSON.pretty_generate(metadata_output)
    paths_json_output = JSON.pretty_generate(@paths)

    out_dir = out_dir.nil? || out_dir.empty? ?
      (ENV["CODETRACER_RUBY_RECORDER_OUT_DIR"] || ".") : out_dir

    trace_folder = out_dir
    FileUtils.mkdir_p(trace_folder)
    trace_path = File.join(trace_folder, "trace.json")
    trace_metadata_path = File.join(trace_folder, "trace_metadata.json")
    trace_paths_path = File.join(trace_folder, "trace_paths.json")

    # p trace_path, json_output
    File.write(trace_path, json_output)
    File.write(trace_metadata_path, metadata_json_output)
    File.write(trace_paths_path, paths_json_output)

    if @debug
      $stderr.write("=================================================\n")
      $stderr.write("codetracer ruby tracer: saved trace to #{trace_folder}\n")
    end
  end

  # Value creation methods - now instance methods
  def int_value(i)
    ValueRecord.new(kind: 'Int', type_id: @int_type_index, i: i)
  end

  def float_value(f)
    ti = load_type_id(FLOAT, 'Float')
    ValueRecord.new(kind: 'Float', type_id: ti, f: f)
  end

  def string_value(text)
    ValueRecord.new(kind: 'String', type_id: @string_type_index, text: text)
  end

  def symbol_value(text)
     # TODO store symbol in a more special way?
     ValueRecord.new(kind: 'String', type_id: @symbol_type_index, text: text)
  end

  def raw_obj_value(raw, class_name)
    ti = load_type_id(RAW, class_name)
    ValueRecord.new(kind: 'Raw', type_id: ti, r: raw)
  end

  def sequence_value(elements, class_name = "Array")
    ti = load_type_id(SEQ, class_name)
    ValueRecord.new(kind: 'Sequence', type_id: ti, elements: elements, is_slice: false)
  end

  # fields: Array of [String, TypeRecord]
  def struct_value(class_name, field_names, field_values, depth)
    field_ct_values = field_values.map { |value| to_value(value, depth - 1) }
    ti = type_id_for(class_name)
    if ti.nil?
      specific_info = {
        kind: "Struct",
        fields: field_names.zip(field_ct_values).map do |(name, value)|
          {name: name, type_id: value.type_id}
        end
      }
      ti = register_struct_type(class_name, specific_info)
    end
    ValueRecord.new(kind: 'Struct', type_id: ti, field_values: field_ct_values)
  end

  def true_value
    @true_value ||= ValueRecord.new(kind: 'Bool', type_id: @bool_type_index, b: true)
  end

  def false_value
    @false_value ||= ValueRecord.new(kind: 'Bool', type_id: @bool_type_index, b: false)
  end

  def not_supported_value
    @not_supported_value ||= ValueRecord.new(kind: 'Error', type_id: @no_type_index, msg: "not supported")
  end

  def nil_value
    @nil_value ||= ValueRecord.new(kind: 'None', type_id: @no_type_index)
  end

  MAX_COUNT = 5000

  def to_value(v, depth=10)
    codetracer_original_p v
    if depth <= 0
      return nil_value
    end
    @value_count += 1
    if @value_count % 10_000 == 0
      $stderr.write("value #{@value_count}\n") if @debug
    end
    case v
    when Integer
      int_value(v)
    when Float
      float_value(v)
    when String
      string_value(v)
    when Symbol
      symbol_value(v)
    when true
      true_value
    when false
      false_value
    when nil
      nil_value
    when Array
      if v.count > MAX_COUNT
        # $stderr.write "array count ", v.count, "\n"
        not_supported_value # TODO: non-expanded/other hint?
      else
        sequence_value(v.map do |element|
          to_value(element, depth - 1)
        end)
      end
    when Hash
      if true or v.count > MAX_COUNT
        not_supported_value
      else
        pairs = v.map do |k, val|
          struct_value('Pair', ['k', 'v'], [k, val], depth)
        end
        sequence_value(pairs, 'Hash')
      end
    when Range
      struct_value('Range', ['begin', 'end'], [v.begin, v.end], depth)
    when ->(o) { defined?(Set) && o.is_a?(Set) }
      if v.size > MAX_COUNT
        not_supported_value
      else
        sequence_value(v.to_a.map { |e| to_value(e, depth - 1) }, 'Set')
      end
    when Time
      struct_value('Time', ['sec', 'nsec'], [v.to_i, v.nsec], depth)
    when Regexp
      struct_value('Regexp', ['source', 'options'], [v.source, v.options], depth)
    when Struct
      struct_value(v.class.name, v.members.map(&:to_s), v.values, depth)
    when ->(o) { defined?(OpenStruct) && o.is_a?(OpenStruct) }
      h = v.to_h
      pairs = h.map do |k, val|
        struct_value('Pair', ['k', 'v'], [k, val], depth)
      end
      sequence_value(pairs, 'Hash')
    when Object
      # not_supported_value
      class_name = v.class.name
      field_values = v.instance_variables.map do |name|
        v.instance_variable_get(name)
      end
      field_names = nil
      if type_id_for(class_name).nil?
        field_names = v.instance_variables.map { |name| name.to_s[1..] }
      else
        field_names = []
      end
      struct_value(class_name, field_names, field_values, depth)
    else
      not_supported_value
    end
  end
end

##################

# IMPORTANT: sync with common_types.nim / runtime_tracing EventLogKind
EVENT_KIND_WRITE = 0
EVENT_KIND_ERROR = 11

NO_KEY = -1
NO_STEP = -1
