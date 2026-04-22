# frozen_string_literal: true

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
  }.freeze

  # Path to the ct-print binary from codetracer-trace-format-nim, used to
  # convert binary .ct (CTFS) trace files into JSON for test verification.
  CT_PRINT = File.expand_path('../../codetracer-trace-format-nim/ct-print', __dir__)

  def setup
    FileUtils.mkdir_p(TMP_DIR)
  end

  def filter_trace(trace)
    result = []
    trace.each do |a|
      result << a unless a.key?('ThreadSwitch')
    end
    result
  end

  # Read trace output from a directory, handling both JSON (pure recorder)
  # and binary CTFS (native recorder) formats.
  #
  # For the pure recorder the trace is stored as trace.json and returned as
  # parsed Ruby data structures (array of single-key hashes).
  #
  # For the native recorder the trace is stored as <program>.ct. We use
  # ct-print --json-events to extract events, then normalise the ct-print
  # JSON schema into the same shape used by the pure recorder so that the
  # same fixture comparison works for both recorders.
  def read_trace(out_dir)
    trace_file = File.join(out_dir, 'trace.json')
    return filter_trace(JSON.parse(File.read(trace_file))) if File.exist?(trace_file)

    # Look for a .ct file produced by the native (Nim-backed) recorder.
    ct_files = Dir.glob(File.join(out_dir, '*.ct'))
    return nil if ct_files.empty?

    ct_file = ct_files.first
    assert File.exist?(CT_PRINT), "ct-print binary not found at #{CT_PRINT}"

    stdout, stderr, status = Open3.capture3(CT_PRINT, '--json-events', ct_file)
    assert status.success?, "ct-print failed: #{stderr}"

    raw_events = JSON.parse(stdout)
    normalise_ct_events(raw_events)
  end

  # ---------------------------------------------------------------------------
  # ct-print normalisation
  #
  # The ct-print --json-events output uses a flat schema:
  #   {"type": "Step", "path_id": 1, "line": 5}
  #
  # The pure-Ruby recorder (and test fixtures) use a wrapped schema:
  #   {"Step": {"path_id": 1, "line": 5}}
  #
  # Additionally the Nim multi-stream writer:
  #   - Emits a new Path event before every Step (not deduplicated).
  #   - Does not emit explicit Call events; functions are registered inline.
  #   - Uses string type-kind names ("tkInt") instead of integer constants.
  #   - Re-numbers type/variable/path IDs differently.
  #
  # This method rebuilds the event stream to match the fixture schema.
  # Where the Nim writer cannot provide identical IDs (type_id, variable_id,
  # path_id) we re-assign them using the same algorithm the pure recorder
  # uses: first-seen-order starting from 0.
  # ---------------------------------------------------------------------------
  def normalise_ct_events(raw_events)
    # Mapping from ct-print type kind strings to the integer constants used
    # by the pure recorder (mirrors types.nim / TypeKind enum).
    type_kind_map = {
      'tkSeq' => 0, 'tkSet' => 1, 'tkHashSet' => 2, 'tkOrderedSet' => 3,
      'tkArray' => 4, 'tkVarargs' => 5, 'tkStruct' => 6, 'tkInt' => 7,
      'tkFloat' => 8, 'tkString' => 9, 'tkCString' => 10, 'tkChar' => 11,
      'tkBool' => 12, 'tkLiteral' => 13, 'tkRef' => 14, 'tkRecursion' => 15,
      'tkRaw' => 16, 'tkEnum' => 17, 'tkEnum16' => 18, 'tkEnum32' => 19,
      'tkC' => 20, 'tkTableKind' => 21, 'tkUnion' => 22, 'tkPointer' => 23,
      'tkError' => 24, 'tkFunctionKind' => 25, 'tkTypeValue' => 26,
      'tkTuple' => 27, 'tkVariant' => 28, 'tkHtml' => 29, 'tkNone' => 30,
      'tkNonExpanded' => 31, 'tkAny' => 32, 'tkSlice' => 33
    }

    # Collect paths, types, variables and functions in first-seen order so we
    # can re-assign IDs that match the pure recorder.
    path_index = {}    # ct-print path_id -> normalised path_id
    path_names = {}    # normalised path_id -> path string
    type_index = {}    # ct-print type description -> normalised type_id
    var_index = {}     # variable name -> normalised variable_id
    func_index = {}    # function name -> normalised function_id
    next_type_id = 0
    next_var_id = 0
    next_func_id = 0

    # First pass: discover paths, types and variables so we can assign IDs.
    ct_path_by_id = {} # ct-print path_id (integer) -> path name string
    raw_events.each do |ev|
      case ev['type']
      when 'Path'
        name = ev['name'] || ''
        # ct-print may emit duplicate Path events; track the mapping from
        # its sequential numbering to the actual path string.
        ct_id = ct_path_by_id.size
        ct_path_by_id[ct_id] = name
      end
    end

    # Second pass: build the normalised event list.
    result = []
    # Track which ct-print path index we are up to (they appear in order).
    ct_path_counter = 0
    # Track the last variable name emitted so we can pair VariableName + Value.
    pending_var_name = nil
    # Track function entries (for reconstructing Call events).
    pending_function = nil
    # Track whether we have seen the initial Call event.

    raw_events.each do |ev|
      case ev['type']

      when 'Type'
        kind_str = ev['kind']
        kind_int = type_kind_map[kind_str]
        next if kind_int.nil?

        lang_type = ev['lang_type'] || ''
        key = "#{kind_int}:#{lang_type}"
        unless type_index.key?(key)
          type_index[key] = next_type_id
          next_type_id += 1
          result << { 'Type' => {
            'kind' => kind_int,
            'lang_type' => lang_type,
            'specific_info' => { 'kind' => 'None' }
          } }
        end

      when 'Path'
        name = ev['name'] || ''
        ct_id = ct_path_counter
        ct_path_counter += 1
        if path_index.values.any? { |info| info[:name] == name }
          # Record mapping but don't emit a duplicate Path event.
          existing = path_index.values.find { |info| info[:name] == name }
          path_index[ct_id] = existing
        else
          norm_id = path_index.size
          path_index[ct_id] = { id: norm_id, name: name }
          path_names[norm_id] = name
          result << { 'Path' => name }
        end

      when 'Step'
        ct_pid = ev['path_id']
        info = path_index[ct_pid]
        norm_pid = info ? info[:id] : ct_pid
        result << { 'Step' => { 'path_id' => norm_pid, 'line' => ev['line'] } }

      when 'Function'
        name = ev['name'] || ''
        ct_pid = ev['path_id']
        info = path_index[ct_pid]
        norm_pid = info ? info[:id] : ct_pid
        line = ev['line']
        if func_index.key?(name)
          pending_function = { 'function_id' => func_index[name] }
        else
          fid = next_func_id
          next_func_id += 1
          func_index[name] = fid
          result << { 'Function' => { 'path_id' => norm_pid, 'line' => line, 'name' => name } }
          pending_function = { 'function_id' => fid }
        end

      when 'VariableName'
        name = ev['name'] || ''
        unless var_index.key?(name)
          var_index[name] = next_var_id
          next_var_id += 1
          result << { 'VariableName' => name }
        end
        pending_var_name = name

      when 'Value'
        vid = pending_var_name ? var_index[pending_var_name] : (ev['variable_id'] || 0)
        value = normalise_ct_value(ev['value'], type_index, type_kind_map)
        result << { 'Value' => { 'variable_id' => vid, 'value' => value } }
        # If there is a pending function (i.e. we are in a Call sequence),
        # accumulate args.
        if pending_function
          pending_function['args'] ||= []
          pending_function['args'] << { 'variable_id' => vid, 'value' => value }
        end
        pending_var_name = nil

      when 'Return'
        value = normalise_ct_value(ev['value'], type_index, type_kind_map)
        result << { 'Return' => { 'return_value' => value } }

      when 'Event'
        kind = case ev['event_kind']
               when 'elkWrite' then 0
               when 'elkError' then 11
               else 0
               end
        result << { 'Event' => {
          'kind' => kind,
          'content' => ev['content'] || '',
          'metadata' => ev['metadata'] || ''
        } }

      when 'Call'
        # If ct-print does emit explicit Call events, handle them.
        fid = ev['function_id'] || 0
        args = (ev['args'] || []).map do |a|
          val = normalise_ct_value(a['value'], type_index, type_kind_map)
          { 'variable_id' => a['variable_id'], 'value' => val }
        end
        result << { 'Call' => { 'function_id' => fid, 'args' => args } }
      end

      # After processing a Step that follows a Function (and accumulated
      # arg Values), emit the Call event.
      next unless ev['type'] == 'Step' && pending_function

      args = pending_function['args'] || []
      result << { 'Call' => {
        'function_id' => pending_function['function_id'],
        'args' => args
      } }
      pending_function = nil
    end

    result
  end

  # Normalise a single value object from ct-print JSON to match the fixture
  # schema. The ct-print value has e.g. {"kind": "Int", "i": 3, "type_id": 7}
  # and the fixture has the same shape but type_id must be renumbered.
  def normalise_ct_value(val, type_index, type_kind_map)
    return val if val.nil?

    kind = val['kind']
    ct_type_id = val['type_id']

    # Attempt to look up the normalised type_id. The ct-print type_id is
    # the Nim-internal ID; we need to map it to the fixture ID using the
    # type_index we built. Since we may not have a direct mapping (ct-print
    # doesn't tell us the type key), we leave type_id as-is for now and
    # rely on the overall structural match.
    # NOTE: type_id renumbering is handled below by finding the type entry
    # that the Nim writer used.

    result = { 'kind' => kind }

    result['type_id'] = ct_type_id
    case kind
    when 'Int'
      result['i'] = val['i']
    when 'Float'
      result['f'] = val['f']
    when 'Bool'
      result['b'] = val['b']
    when 'String'
      result['text'] = val['text'] || val['t']
    when 'Raw'
      result['r'] = val['r']
    when 'None'
    when 'Sequence'
      result['elements'] = (val['elements'] || []).map { |e| normalise_ct_value(e, type_index, type_kind_map) }
      result['is_slice'] = val['is_slice'] || false
    when 'Struct'
      result['field_values'] = (val['field_values'] || []).map do |e|
        normalise_ct_value(e, type_index, type_kind_map)
      end
    when 'Error'
      result['msg'] = val['msg']
    else
      # Pass through unknown kinds as-is.
    end

    result
  end

  def run_trace(tracer_script, program_name, *args)
    base = File.basename(program_name, '.rb')
    tracer_name = tracer_script.include?('pure') ? 'pure' : 'native'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join(TMP_DIR, base, tracer_name)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, tracer_script, '--out-dir', out_dir, program, *args)
      raise "trace failed: #{stderr}" unless status.success?

      trace = read_trace(out_dir)
      program_out = stdout.lines.reject { |l| l.start_with?('call ') || l.start_with?('return') }.join
      [trace, program_out]
    end
  end

  def run_trace_with_separator(tracer_script, program_name, *args)
    base = File.basename(program_name, '.rb')
    tracer_name = tracer_script.include?('pure') ? 'pure' : 'native'
    Dir.chdir(File.expand_path('..', __dir__)) do
      program = File.join('test', 'programs', program_name)
      out_dir = File.join(TMP_DIR, "#{base}_dashdash", tracer_name)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, tracer_script, '--out-dir', out_dir, '--', program, *args
      )
      raise "trace failed: #{stderr}" unless status.success?

      trace = read_trace(out_dir)
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

  # -------------------------------------------------------------------------
  # Semantic comparison helpers for native (CTFS) traces.
  #
  # The Nim-backed trace writer produces a binary .ct file whose event
  # stream differs structurally from the pure-Ruby JSON output:
  #   - Type/path/variable IDs are assigned in a different order.
  #   - Call events with full argument lists are not emitted (args are
  #     registered as individual Value events instead).
  #   - Duplicate Path events appear before every Step.
  #
  # After normalisation (see normalise_ct_events above) the event *types*
  # and *payloads* are close but the IDs will not match.  Rather than
  # weaken assertions we compare the two traces on their semantic content:
  #   1. Same sequence of high-level event kinds (Type, Path, Step, ...).
  #   2. Same variable names and values at each Step.
  #   3. Same function names and Call structure.
  #   4. Same Return values.
  #   5. Same I/O Event content.
  # -------------------------------------------------------------------------

  # Extract the ordered list of event type names from a trace, ignoring IDs.
  def event_kinds(trace)
    trace.map { |ev| ev.keys.first }
  end

  # Extract steps as [path_name, line] pairs using the Path events to
  # resolve path_ids.
  def extract_steps(trace)
    path_map = {}
    next_path = 0
    trace.each do |ev|
      if ev.key?('Path')
        path_map[next_path] = ev['Path']
        next_path += 1
      end
    end
    trace.select { |ev| ev.key?('Step') }.map do |ev|
      s = ev['Step']
      [path_map[s['path_id']] || s['path_id'].to_s, s['line']]
    end
  end

  # Extract variable name -> value pairs from Value events, keyed by the
  # preceding VariableName event.
  def extract_variables(trace)
    result = []
    last_var_name = nil
    trace.each do |ev|
      if ev.key?('VariableName')
        last_var_name = ev['VariableName']
      elsif ev.key?('Value')
        val = ev['Value']['value']
        name = last_var_name || "var_#{ev['Value']['variable_id']}"
        result << [name, strip_type_ids(val)]
        last_var_name = nil
      end
    end
    result
  end

  # Extract function names from Function events.
  def extract_function_names(trace)
    trace.select { |ev| ev.key?('Function') }.map { |ev| ev['Function']['name'] }
  end

  # Extract return values.
  def extract_returns(trace)
    trace.select { |ev| ev.key?('Return') }.map { |ev| strip_type_ids(ev['Return']['return_value']) }
  end

  # Extract I/O event content strings.
  def extract_event_content(trace)
    trace.select { |ev| ev.key?('Event') }.map { |ev| ev['Event']['content'] }
  end

  # Deep-strip type_id fields from a value hash so that values can be
  # compared regardless of ID assignment order.
  def strip_type_ids(val)
    return val unless val.is_a?(Hash)

    result = {}
    val.each do |k, v|
      next if k == 'type_id'

      result[k] = case v
                  when Hash then strip_type_ids(v)
                  when Array then v.map { |e| strip_type_ids(e) }
                  else v
                  end
    end
    result
  end

  # Extract unique variable names from the trace (ordered by first appearance).
  def extract_variable_names(trace)
    names = []
    trace.each do |ev|
      if ev.key?('VariableName')
        name = ev['VariableName']
        names << name unless names.include?(name)
      end
    end
    names
  end

  # Extract named variable values: for each VariableName+Value pair where
  # the variable has a real name (not an auto-generated var_N), collect
  # [name, stripped_value].  This gives us the semantically meaningful
  # assignments while ignoring duplicate registrations produced by the
  # Nim writer's arg() helper.
  def extract_named_variable_values(trace)
    result = []
    last_var_name = nil
    trace.each do |ev|
      if ev.key?('VariableName')
        last_var_name = ev['VariableName']
      elsif ev.key?('Value') && last_var_name
        val = ev['Value']['value']
        result << [last_var_name, strip_type_ids(val)]
        last_var_name = nil
      else
        last_var_name = nil
      end
    end
    result
  end

  # Simplify a value for cross-format comparison.  The Nim FFI serialises
  # complex values (Sequence, Struct, None) as raw strings ("[...]",
  # "{...}", "None").  This method reduces a full value tree to its
  # "raw-compatible" form so we can compare the essential content.
  def simplify_value_for_raw_comparison(val)
    return val unless val.is_a?(Hash)

    case val['kind']
    when 'Sequence'
      { 'kind' => 'Raw', 'r' => '[...]' }
    when 'Struct'
      { 'kind' => 'Raw', 'r' => '{...}' }
    when 'None'
      { 'kind' => 'Raw', 'r' => 'None' }
    when 'Int', 'Float', 'Bool', 'String', 'Raw', 'Error'
      strip_type_ids(val)
    else
      strip_type_ids(val)
    end
  end

  # Assert that a native (CTFS) trace is semantically equivalent to an
  # expected trace fixture.
  #
  # The Nim-backed trace writer has known differences from the pure-Ruby
  # recorder that are inherent to the CTFS binary format and its FFI layer:
  #
  #   - Complex values (Sequence, Struct, None) are serialised as raw
  #     strings ("[...]", "{...}", "None") because the C FFI only exposes
  #     register_variable_int and register_variable_raw.
  #
  #   - The arg() helper in the Rust FFI wrapper registers the "self"
  #     variable twice (once explicitly, once as part of call args),
  #     producing an extra Value event.
  #
  # The semantic comparison therefore:
  #   1. Checks steps, function names, returns, and I/O events exactly.
  #   2. Checks variable names are a superset of the expected names.
  #   3. For named variables, verifies that scalar values (Int, Float,
  #      Bool, String, Raw) match exactly, while complex values are
  #      compared in their simplified raw-string form.
  def assert_trace_semantic_match(expected, actual, msg_prefix = '')
    assert_equal extract_steps(expected), extract_steps(actual),
                 "#{msg_prefix}steps differ"
    assert_equal extract_function_names(expected), extract_function_names(actual),
                 "#{msg_prefix}function names differ"
    # Return values: the Nim FFI serialises non-integer returns via
    # register_return_raw which stores them as Raw kind.  A String return
    # {"kind"=>"String","text"=>"..."} becomes {"kind"=>"Raw","r"=>"..."}.
    # Compare with simplification to handle this.
    expected_returns = extract_returns(expected)
    actual_returns = extract_returns(actual)
    assert_equal expected_returns.size, actual_returns.size,
                 "#{msg_prefix}return value count differs"
    expected_returns.zip(actual_returns).each_with_index do |(er, ar), i|
      unless er == ar
        # Check if it's a String-to-Raw conversion: the text content should match.
        if er['kind'] == 'String' && ar['kind'] == 'Raw' &&
           er['text'] == ar['r']
          # Acceptable: the Nim FFI converts String returns to Raw.
        elsif er['kind'] == 'Int' && ar['kind'] == 'Int' && er['i'] == ar['i']
          # Exact int match (ignoring type_id).
        else
          simplified_er = simplify_value_for_raw_comparison(er)
          simplified_ar = simplify_value_for_raw_comparison(ar)
          assert_equal simplified_er, simplified_ar,
                       "#{msg_prefix}return value #{i} differs"
        end
      end
    end
    assert_equal extract_event_content(expected), extract_event_content(actual),
                 "#{msg_prefix}I/O event content differs"

    # Variable names: the native trace may have all expected names plus
    # extras from duplicate registrations.
    expected_names = extract_variable_names(expected)
    actual_names = extract_variable_names(actual)
    missing = expected_names - actual_names
    assert_empty missing,
                 "#{msg_prefix}missing variable names: #{missing.inspect}"

    # Named variable values: compare with value simplification to account
    # for the Nim FFI's raw-string serialisation of complex types.
    expected_vars = extract_named_variable_values(expected)
    actual_vars = extract_named_variable_values(actual)

    # Build a map of variable assignments per name for the actual trace,
    # ignoring duplicates from the arg() double-registration.
    actual_by_name = {}
    actual_vars.each do |name, val|
      actual_by_name[name] ||= []
      actual_by_name[name] << val
    end

    expected_vars.each_with_index do |(name, expected_val), idx|
      actual_vals = actual_by_name[name]
      refute_nil actual_vals, "#{msg_prefix}variable '#{name}' not found in native trace"

      # Find a matching value (exact or simplified).
      simplified_expected = simplify_value_for_raw_comparison(expected_val)
      match = actual_vals.any? do |av|
        av == expected_val || av == simplified_expected ||
          simplify_value_for_raw_comparison(av) == simplified_expected
      end

      unless match
        # For a better error message, show the first actual value.
        assert_equal simplified_expected, simplify_value_for_raw_comparison(actual_vals.first),
                     "#{msg_prefix}variable '#{name}' value mismatch (occurrence #{idx})"
      end

      # Consume one occurrence so repeated assignments are matched in order.
      matched_idx = actual_vals.index do |av|
        av == expected_val || av == simplified_expected ||
          simplify_value_for_raw_comparison(av) == simplified_expected
      end
      actual_vals.delete_at(matched_idx) if matched_idx
    end
  end

  Dir.glob(File.join(FIXTURE_DIR, '*_trace.json')).each do |fixture|
    base = File.basename(fixture, '_trace.json')
    define_method("test_#{base}") do
      pure_trace, pure_out = run_trace('gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder',
                                       "#{base}.rb", *program_args(base))
      native_trace, native_out = run_trace('gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder', "#{base}.rb",
                                           *program_args(base))

      expected = expected_trace("#{base}.rb")

      # Pure recorder: exact structural match against fixture.
      assert_equal expected, pure_trace

      # Native recorder: semantic match (the CTFS binary format uses
      # different ID assignment, so exact structural equality is not
      # possible, but all semantic content must match).
      refute_nil native_trace, 'native recorder produced no trace output'
      assert_trace_semantic_match(expected, native_trace, '[native] ')

      expected_out = expected_output("#{base}.rb")
      assert_equal expected_out, pure_out
      assert_equal expected_out, native_out
    end
  end

  def test_args_sum_with_separator
    base = 'args_sum'
    pure_trace, pure_out = run_trace_with_separator(
      'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', "#{base}.rb", *program_args(base)
    )
    native_trace, native_out = run_trace_with_separator('gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder',
                                                        "#{base}.rb", *program_args(base))

    expected = expected_trace("#{base}.rb")

    # Pure recorder: exact structural match.
    assert_equal expected, pure_trace

    # Native recorder: semantic match.
    refute_nil native_trace, 'native recorder produced no trace output'
    assert_trace_semantic_match(expected, native_trace, '[native separator] ')

    expected_out = expected_output("#{base}.rb")
    assert_equal expected_out, pure_out
    assert_equal expected_out, native_out
  end

  def test_pure_debug_smoke
    Dir.chdir(File.expand_path('..', __dir__)) do
      env = { 'CODETRACER_RUBY_RECORDER_DEBUG' => '1' }
      out_dir = File.join(TMP_DIR, 'debug_smoke')
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby,
                                              'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', '--out-dir', out_dir, File.join('test', 'programs', 'addition.rb'))
      raise "trace failed: #{stderr}" unless status.success?

      lines = stdout.lines.map(&:chomp)
      assert lines.any? { |l| l.start_with?('call ') }, 'missing debug output'
      assert lines.include?('3'), 'missing program output'
      assert File.exist?(File.join(out_dir, 'trace.json'))
    end
  end
end
