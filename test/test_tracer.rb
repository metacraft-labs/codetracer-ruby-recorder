# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
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

    # ct-print's `--json-events` (post-2026-05-12) emits every interned
    # path/function/varname/type as a dedicated declaration event before
    # any step/call/value events.  The event-type discriminator is the
    # lowercase `'type'` field — `path`, `function`, `varname`, `type`,
    # `step`, `value`, `call`, `io`.

    # First pass: build ct-print → normalised mappings from declarations.
    ct_type_id_to_norm = {} # ct-print type_id -> normalised type_id
    ct_varname_id_to_name = {} # ct-print varname_id -> name string

    raw_events.each do |ev|
      case ev['type']
      when 'path'
        name = ev['name'] || ''
        ct_pid = ev['path_id']
        unless path_index.values.any? { |info| info[:name] == name }
          norm_id = path_index.size
          path_index[ct_pid] = { id: norm_id, name: name }
          path_names[norm_id] = name
        end
      when 'varname'
        name = ev['name'] || ''
        ct_vid = ev['varname_id']
        ct_varname_id_to_name[ct_vid] = name
        unless var_index.key?(name)
          var_index[name] = next_var_id
          next_var_id += 1
        end
      when 'type'
        # ct-print only emits the type *name* per ID; pure recorder has
        # (kind, lang_type) pairs.  We can't fully reconstruct the kind
        # without more reader API, so map known names to their kinds.
        # The most-common names have well-known kinds in the Ruby
        # recorder (see PURE_RUBY_TYPE_KIND_FOR_NAME below).
        ct_tid = ev['type_id']
        name = ev['name'] || ''
        kind_int = ruby_type_kind_for(name)
        ct_type_id_to_norm[ct_tid] = next_type_id
        type_index["#{kind_int}:#{name}"] = next_type_id
        next_type_id += 1
      end
    end

    # Second pass: emit declaration events in fixture-equivalent shape,
    # then walk steps/calls/values in stream order.
    result = []
    type_index.each do |key, _norm_id|
      kind_int_str, lang_type = key.split(':', 2)
      result << { 'Type' => {
        'kind' => kind_int_str.to_i,
        'lang_type' => lang_type,
        'specific_info' => { 'kind' => 'None' }
      } }
    end
    path_names.keys.sort.each do |norm_id|
      result << { 'Path' => path_names[norm_id] }
    end

    pending_function = nil
    pending_function_args = []
    func_index_local = func_index

    raw_events.each do |ev|
      case ev['type']
      when 'function'
        name = ev['name'] || ''
        unless func_index_local.key?(name)
          func_index_local[name] = next_func_id
          next_func_id += 1
          # ct-print's path/line for the function declaration isn't yet
          # included in the declaration event — fall back to the path
          # of the first call site (best effort).
          result << { 'Function' => { 'path_id' => 0, 'line' => 0, 'name' => name } }
        end
      when 'step'
        # ThreadSwitch steps are synthetic thread-tracking events the
        # native recorder emits at thread boundaries; the pure recorder
        # has no thread model and emits no such events.  Skip them so
        # the step sequences line up.
        next if ev['kind'] == 'sekThreadSwitch'

        ct_pid = ev['path_id']
        info = path_index[ct_pid]
        norm_pid = info ? info[:id] : ct_pid
        # Emit any pending Call before the step that follows it.
        if pending_function
          result << { 'Call' => {
            'function_id' => pending_function,
            'args' => pending_function_args
          } }
          pending_function = nil
          pending_function_args = []
        end
        result << { 'Step' => { 'path_id' => norm_pid, 'line' => ev['line'] } }
      when 'value'
        ct_vid = ev['varname_id']
        name = ct_varname_id_to_name[ct_vid] || ev['varname'] || ''
        unless var_index.key?(name)
          var_index[name] = next_var_id
          next_var_id += 1
        end
        vid = var_index[name]
        # Emit a VariableName event the first time we see this name.
        unless ct_varname_id_to_name.key?(:"emitted_#{ct_vid}")
          result << { 'VariableName' => name }
          ct_varname_id_to_name[:"emitted_#{ct_vid}"] = true
        end
        value = normalise_ct_value(ev['value'], ct_type_id_to_norm, type_kind_map)
        result << { 'Value' => { 'variable_id' => vid, 'value' => value } }
        # The pure recorder ALSO emits a synthetic Return event for the
        # `<return_value>` variable.  Mirror that here so the snapshot
        # diff matches.
        if name == '<return_value>'
          result << { 'Return' => { 'return_value' => value } }
        end
        if pending_function
          pending_function_args << { 'variable_id' => vid, 'value' => value }
        end
      when 'call'
        # ct-print emits call events at the call's entry step.  We hold
        # onto the function_id and emit the actual {'Call'} event after
        # the next step (so the args we collect from values in between
        # land in pending_function_args).
        pending_function = ev['function_id']
        pending_function_args = []
      when 'return'
        value = normalise_ct_value(ev['value'], ct_type_id_to_norm, type_kind_map)
        result << { 'Return' => { 'return_value' => value } }
      when 'io', 'event'
        kind = case ev['kind']
               when 'elkWrite', 'ioStdout' then 0
               when 'elkError', 'ioStderr' then 11
               else 0
               end
        result << { 'Event' => {
          'kind' => kind,
          'content' => ev['data'] || ev['content'] || '',
          'metadata' => ev['metadata'] || ''
        } }
      end
    end

    result
  end

  # Map a ct-print type-name string back to the integer kind the pure
  # recorder uses.  Mirrors the kind constants in
  # gems/codetracer-pure-ruby-recorder/lib/recorder.rb.  Unknown names
  # default to RAW (16) — they will still produce a valid Type event,
  # just with a possibly-wrong kind, which the snapshot diff will catch.
  PURE_RUBY_TYPE_KIND_FOR_NAME = {
    'Integer' => 7,    # INT
    'Float'   => 8,    # FLOAT
    'String'  => 9,    # STRING
    'Symbol'  => 9,    # STRING (Symbols round-trip as strings)
    'Bool'    => 12,   # BOOL
    'TrueClass' => 12,
    'FalseClass' => 12,
    'NilClass' => 30,  # NONE
    'Array'   => 0,    # SEQ
    'Hash'    => 6,    # STRUCT
    'No type' => 24,   # ERROR
  }.freeze

  def ruby_type_kind_for(name)
    PURE_RUBY_TYPE_KIND_FOR_NAME[name] || 16 # default RAW
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
    # ct-print's --json-events emits a value event for `<return_value>`
    # at the call's exit step, which the normaliser turns into a Return
    # event.  Some traces emit the value once per inner-frame (so the
    # native trace ends up with more Return events than the pure trace).
    # Require that every expected return is matched, but allow extras.
    assert expected_returns.size <= actual_returns.size,
           "#{msg_prefix}return value count: expected at least " \
           "#{expected_returns.size}, got #{actual_returns.size}"
    expected_returns.each_with_index do |er, i|
      ar = actual_returns[i]
      next if ar.nil? # tolerate sparse alignment
      next if er == ar
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

  # Regression test for the empty-calltrace bug.
  #
  # The native (Nim-backed CTFS) recorder previously emitted call entries via
  # `TraceWriter::add_event(TraceLowLevelEvent::Call(..))`, which the
  # `NimTraceWriter` silently drops because it has no in-memory event buffer.
  # The fix uses `register_call(function_id, args)` which routes through the
  # FFI `trace_writer_register_call` hook and into the multi-stream call
  # writer.  This regression test asserts that the native recorder produces
  # at least one call event for a program that contains a function call.
  #
  # Reproduction of the upstream symptom: the codetracer GUI's
  # `[PIPELINE] syncCalltraceData` log reported `received 0 lines,
  # totalCalls=0` for `rb_sudoku_solver` because `call_count` returned 0
  # despite the program having dozens of method invocations.
  def test_native_calltrace_non_empty
    base = 'addition'
    Dir.chdir(File.expand_path('..', __dir__)) do
      out_dir = File.join(TMP_DIR, "#{base}_native_calls")
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      program = File.join('test', 'programs', "#{base}.rb")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder',
        '--out-dir', out_dir, program
      )
      assert status.success?, "trace failed: #{stderr}"

      ct_files = Dir.glob(File.join(out_dir, '*.ct'))
      refute_empty ct_files, 'native recorder did not produce a .ct trace'

      # ct-print --summary reports the call count from the multi-stream
      # call writer.  A working recorder must emit at least one Call entry
      # for the addition.rb program (the `add(1, 2)` invocation).
      assert File.exist?(CT_PRINT), "ct-print binary not found at #{CT_PRINT}"
      stdout, stderr, status = Open3.capture3(CT_PRINT, '--summary', ct_files.first)
      assert status.success?, "ct-print --summary failed: #{stderr}"

      calls_line = stdout.lines.find { |l| l =~ /^\s*calls:\s*(\d+)/ }
      refute_nil calls_line, "ct-print --summary did not report a calls line:\n#{stdout}"
      call_count = calls_line[/^\s*calls:\s*(\d+)/, 1].to_i
      assert_operator call_count, :>=, 1,
                      "expected native recorder to emit >=1 call for addition.rb, got #{call_count}.\n#{stdout}"
    end
  end

  # Stronger version of the test above: assert that named user-defined
  # methods reach the call stream.  This guards against regressions where
  # the recorder emits Call events for the implicit top-level frame but
  # not for user-defined methods (which the rb_sudoku_solver fixture
  # exercises heavily).
  def test_native_calltrace_includes_user_methods
    base = 'array_sum'
    Dir.chdir(File.expand_path('..', __dir__)) do
      out_dir = File.join(TMP_DIR, "#{base}_native_user_calls")
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      program = File.join('test', 'programs', "#{base}.rb")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder',
        '--out-dir', out_dir, program
      )
      assert status.success?, "trace failed: #{stderr}"

      ct_files = Dir.glob(File.join(out_dir, '*.ct'))
      refute_empty ct_files, 'native recorder did not produce a .ct trace'

      stdout, stderr, status = Open3.capture3(CT_PRINT, '--json-events', ct_files.first)
      assert status.success?, "ct-print --json-events failed: #{stderr}"

      # Parse only the `call` events out of the JSON stream.  We can't
      # JSON.parse the whole document because CBOR value bytes contain
      # invalid UTF-8; instead grep for type=call entries with their
      # `function` name on the next-but-2 line.  Force binary encoding
      # so the regex engine doesn't choke on raw CBOR bytes embedded in
      # `data` fields.
      stdout.force_encoding(Encoding::ASCII_8BIT)
      function_names = stdout.scan(/"type":\s*"call",[\s\S]*?"function":\s*"([^"]+)"/).flatten
      assert function_names.include?('sum'),
             "expected `sum` to appear in native call stream; got #{function_names.inspect}"
    end
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

  # ---------------------------------------------------------------------------
  # CTFS-only convention tests (mirror the python / cairo precedent).
  # See `codetracer-specs/Recorder-CLI-Conventions.md` §4 (CTFS-only) and
  # §5 (env vars), and `AUDIT-CTFS-2026-05.md` for the recorder-side
  # follow-up record.
  # ---------------------------------------------------------------------------

  NATIVE_RECORDER_BIN = 'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder'
  PURE_RECORDER_BIN   = 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder'

  # Record `addition.rb` with the native recorder and pipe the produced
  # *.ct bundle through `ct-print --full --strip-paths`, then assert exact
  # decoded values.  This mirrors the cairo / cardano / circom / flow /
  # fuel / leo / miden / move / polkavm / solana / ton (Int round-trip),
  # evm (Raw byte), js (String / Raw) and python (String / None)
  # precedents — record a real program, then convert the produced CTFS
  # bundle through `ct print` and assert on the decoded representation.
  # See `Recorder-CLI-Conventions.md` §4 — CTFS-only output, with
  # `ct print` as the canonical conversion tool.
  #
  # Why exact-value assertions matter: the previous `--json` layer only
  # checked for substring presence ("does the trace mention `add`
  # somewhere"), so a recorder regression that silently dropped or
  # corrupted a value would not be caught.  The `--full` layer pins:
  #
  #   - **Strict `value.kind` invariant** — every step var, call arg,
  #     and return value must decode to one of the known ValueRecord
  #     variants (Int / Float / String / Bool / Raw / None / Void /
  #     Sequence / Struct / Tuple).  A new variant fires the test
  #     loudly so the next maintainer can extend the assertion rather
  #     than silently weakening it.  The check recurses through
  #     Sequence.elements and Struct.field_values so nested values are
  #     validated too.
  #   - **Exact (varname, value) pair assertions** — e.g. `add`'s `a`
  #     and `b` parameters decode back to `ValueRecord::Int { i: 1 }`
  #     and `ValueRecord::Int { i: 2 }`, and its return value decodes
  #     to `ValueRecord::Int { i: 3 }`.  The `<top-level>` synthetic
  #     frame returns `ValueRecord::Void`.
  #   - **Function / path / counts / call-sequence anchors** —
  #     7 steps, 2 calls, 1 io; calls are `<top-level>` then `add`;
  #     path table contains `addition.rb`; function table contains
  #     `<top-level>` and `add` (`end_with?` checks for tolerance to
  #     future namespacing like `Object#add`).
  #   - **IO event** — a single `ioStdout` write of `"3\n"` (the
  #     `puts add(1, 2)` output, including the trailing newline that
  #     `puts` appends).
  #
  # The canonical fixture (`test/programs/addition.rb`) is:
  #
  #     def add(a, b)        # line 1
  #       a + b              # line 2
  #     end                  # line 3
  #
  #     puts add(1, 2)       # line 5
  #
  # Each binding must surface in the trace as a step / call_entry event
  # with a decoded ValueRecord.  The Ruby native recorder uses
  # ValueRecord::Int for typed integer args / locals / return values
  # and ValueRecord::Raw for opaque self pointers (e.g. `"main"`); both
  # are valid current behaviour.  The strict invariant fires if a
  # brand-new variant appears (e.g. BigInt / Bignum support lands).
  def test_recorded_trace_via_ct_print_json
    skip 'native recorder extension not built' unless native_extension_built?
    skip 'ct-print not available' unless File.exist?(CT_PRINT)

    Dir.chdir(File.expand_path('..', __dir__)) do
      out_dir = File.join(TMP_DIR, 'ct_print_json')
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      program = File.join('test', 'programs', 'addition.rb')

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, NATIVE_RECORDER_BIN, '--out-dir', out_dir, program
      )
      assert status.success?, "trace failed: #{stderr}"

      ct_files = Dir.glob(File.join(out_dir, '*.ct'))
      refute_empty ct_files, "expected a *.ct bundle in #{out_dir}, got #{Dir.entries(out_dir).inspect}"

      # ----------------------------------------------------------------
      # Layer 1 (legacy): ct-print --json — substring presence checks.
      # Kept as a safety net so a regression in the textual rendering
      # is caught even if --full's JSON shape evolves.
      # ----------------------------------------------------------------
      json_stdout, json_stderr, json_status = Open3.capture3(CT_PRINT, '--json', ct_files.first)
      assert json_status.success?, "ct-print --json failed: #{json_stderr}"

      digest = JSON.parse(json_stdout)

      # Structural anchors that don't depend on type-id assignment order.
      assert_kind_of Hash, digest['metadata'], 'expected ct-print --json to expose metadata block'
      assert_equal 'ruby', digest['metadata']['program'], 'metadata.program should be "ruby"'

      # Functions: must contain at least the implicit top-level frame
      # and the user-defined `add` method.
      function_names = digest['functions'] || []
      assert_includes function_names, '<top-level>',
                      "expected `<top-level>` in functions: #{function_names.inspect}"
      assert function_names.any? { |n| n == 'add' || n.end_with?('#add') },
             "expected `add` (or Object#add) in functions: #{function_names.inspect}"

      # Steps: addition.rb has at least the `puts add(1, 2)` step plus
      # the body of `add`; require >= 2 to guard against an empty trace.
      steps = digest['steps'] || []
      assert_operator steps.size, :>=, 2,
                      "expected >= 2 steps in addition.rb trace, got #{steps.size}"

      # Paths: must reference addition.rb.
      paths = digest['paths'] || []
      assert paths.any? { |p| p.include?('addition.rb') },
             "expected addition.rb in paths: #{paths.inspect}"

      # ----------------------------------------------------------------
      # Layer 2 (the upgrade): ct-print --full — exact decoded values.
      # `--strip-paths` rewrites absolute workdir / tmp prefixes to
      # placeholders so JSON stays diff-stable across machines.  `--full`
      # decodes every CBOR ValueRecord back to a structured JSON object
      # (e.g. `{"kind":"Int","i":3,"type_id":0}`) — without it, values
      # would be opaque blobs we could only substring-match against.
      # ----------------------------------------------------------------
      full_stdout, full_stderr, full_status = Open3.capture3(
        CT_PRINT, '--full', '--strip-paths', ct_files.first
      )
      assert full_status.success?, "ct-print --full failed: #{full_stderr}"

      bundle = JSON.parse(full_stdout)

      # ---- Function table: <top-level> + add -----------------------
      # The Ruby native recorder names the synthetic top-level frame
      # `<top-level>` (mirrors python's `<__main__>` and js's
      # `<module>`).  `end_with?` checks stay tolerant of any future
      # namespacing prefix the recorder might add (e.g.
      # `Object#add`).
      assert bundle['functions'].any? { |f| f.end_with?('<top-level>') },
             "missing <top-level> in functions: #{bundle['functions'].inspect}"
      assert bundle['functions'].any? { |f| f.end_with?('add') && !f.end_with?('<top-level>') },
             "missing add in functions: #{bundle['functions'].inspect}"

      # ---- Path table: the canonical fixture path ------------------
      # `--strip-paths` rewrites absolute prefixes; the trailing
      # component is the only stable assertion.
      assert bundle['paths'].any? { |p| p.end_with?('addition.rb') },
             "missing addition.rb in paths: #{bundle['paths'].inspect}"

      # ---- Counts — stable for the canonical fixture ---------------
      # The Ruby native recorder produces a deterministic event count
      # for this fixture under TracePoint instrumentation:
      #   - 7 step events (1 sekThreadSwitch synthetic, plus 6
      #     sekDeltaStep events covering the `def add` line,
      #     the `puts add(1, 2)` call site, the `add` body's `a + b`
      #     return-edge, and the post-call top-level steps)
      #   - 2 call entries (synthetic <top-level> wrapper + add)
      #   - 1 io event (the `puts add(1, 2)` write to stdout)
      # If these change, that's a real regression to investigate, not
      # a flake — pin the values strictly.
      assert_equal 7, bundle['counts']['steps'],
                   "expected 7 steps, got #{bundle['counts']['steps']}; " \
                   "full counts: #{bundle['counts'].inspect}"
      assert_equal 2, bundle['counts']['calls'],
                   "expected 2 calls, got #{bundle['counts']['calls']}; " \
                   "full counts: #{bundle['counts'].inspect}"
      assert_equal 1, bundle['counts']['io_events'],
                   "expected 1 io_event, got #{bundle['counts']['io_events']}; " \
                   "full counts: #{bundle['counts'].inspect}"

      # ---- Call sequence: <top-level> first, then add --------------
      call_sequence = bundle['events']
                      .select { |e| e['kind'] == 'call_entry' }
                      .map { |e| e['function'] }
      assert_equal 2, call_sequence.size,
                   "expected 2 call_entry events, got #{call_sequence.size}: #{call_sequence.inspect}"
      assert call_sequence[0].end_with?('<top-level>'),
             "first call must enter <top-level>, got #{call_sequence[0].inspect}"
      assert call_sequence[1].end_with?('add'),
             "second call must enter add, got #{call_sequence[1].inspect}"

      # ---- Strict ValueRecord variant invariant --------------------
      # Every step var / call arg / return value that surfaces must
      # carry a `value.kind` field belonging to the expected, finite
      # set of known ValueRecord variants.  If a brand-new variant
      # appears (e.g. BigInt support lands), this fires loudly so the
      # next maintainer extends the exact-value layer rather than
      # silently accepting it.  The check recurses through nested
      # Sequence.elements and Struct.field_values too.
      allowed_kinds = %w[Int Float String Bool Raw None Void Sequence Struct Tuple].to_set

      check_kinds = lambda do |value, ctx|
        kind = value['kind']
        assert_includes allowed_kinds, kind,
                        "#{ctx}: unknown ValueRecord kind=#{kind.inspect}; " \
                        'if a new variant has landed for the Ruby recorder, ' \
                        'extend this test to assert on it explicitly rather ' \
                        'than weakening the check'
        Array(value['elements']).each_with_index do |nested, i|
          check_kinds.call(nested, "#{ctx}.elements[#{i}]")
        end
        Array(value['field_values']).each_with_index do |nested, i|
          check_kinds.call(nested, "#{ctx}.field_values[#{i}]")
        end
      end

      bundle['events'].each do |ev|
        case ev['kind']
        when 'step'
          ev['vars'].each do |v|
            check_kinds.call(v['value'], "step #{ev['step_index']} var #{v['varname'].inspect}")
          end
        when 'call_entry'
          ev['args'].each do |a|
            check_kinds.call(a['value'],
                             "call_entry #{ev['function'].inspect} arg #{a['varname'].inspect}")
          end
        when 'call_exit'
          check_kinds.call(ev['return_value'],
                           "call_exit #{ev['function'].inspect} return_value")
        end
      end

      # ---- Exact decoded call-arg values: add(a=1, b=2) ------------
      # The Ruby native recorder uses ValueRecord::Int for typed
      # integer call arguments — ct-print --full decodes it to
      # `{"kind":"Int","i":1,...}`.  This is the Ruby analogue of
      # cairo's `(a, 10)` Int round-trip and the cardano / circom /
      # ... family.
      add_call = bundle['events'].find do |e|
        e['kind'] == 'call_entry' && e['function'].end_with?('add') && !e['function'].end_with?('<top-level>')
      end
      refute_nil add_call, 'no call_entry for add'

      a_arg = add_call['args'].find { |a| a['varname'] == 'a' }
      refute_nil a_arg, "add call_entry missing `a` arg; args=#{add_call['args'].inspect}"
      assert_equal 'Int', a_arg['value']['kind'],
                   "add(a=...) should decode as Int, got #{a_arg['value']['kind'].inspect}"
      assert_equal 1, a_arg['value']['i'],
                   "add(a=...) should be 1, got #{a_arg['value']['i'].inspect}"

      b_arg = add_call['args'].find { |a| a['varname'] == 'b' }
      refute_nil b_arg, "add call_entry missing `b` arg; args=#{add_call['args'].inspect}"
      assert_equal 'Int', b_arg['value']['kind'],
                   "add(b=...) should decode as Int, got #{b_arg['value']['kind'].inspect}"
      assert_equal 2, b_arg['value']['i'],
                   "add(b=...) should be 2, got #{b_arg['value']['i'].inspect}"

      # The Ruby recorder also surfaces an implicit `self` pseudo-arg
      # for the top-level Object context.  At top-level, `self` is the
      # `main` object — encoded as ValueRecord::Raw { r: "main" } (no
      # typed Object variant exists in the recorder's value schema).
      # If that ever changes (e.g. self gets dropped or upgraded to a
      # typed Struct variant), the strict kind invariant above fires
      # and this assertion has to be revised.
      self_arg = add_call['args'].find { |a| a['varname'] == 'self' }
      refute_nil self_arg, "add call_entry missing `self` arg; args=#{add_call['args'].inspect}"
      assert_equal 'Raw', self_arg['value']['kind'],
                   "add(self=...) should decode as Raw, got #{self_arg['value']['kind'].inspect}"
      assert_equal 'main', self_arg['value']['r'],
                   "add(self=...) should be \"main\", got #{self_arg['value']['r'].inspect}"

      # ---- Exact decoded return value: add returns 3 ---------------
      # `1 + 2` returns `3`.  The Ruby native recorder snapshots the
      # typed integer return value via ValueRecord::Int.  The strict
      # `kind == "Int"` invariant means: if a future recorder upgrade
      # emits a different variant, this fails loudly.
      add_exit = bundle['events'].find do |e|
        e['kind'] == 'call_exit' && e['function'].end_with?('add') && !e['function'].end_with?('<top-level>')
      end
      refute_nil add_exit, 'no call_exit for add'
      assert_equal 'Int', add_exit['return_value']['kind'],
                   "add return_value should decode as Int, got #{add_exit['return_value']['kind'].inspect}"
      assert_equal 3, add_exit['return_value']['i'],
                   "add should return 3, got #{add_exit['return_value']['i'].inspect}"

      # ---- <top-level> returns Void --------------------------------
      # The synthetic top-level frame has no explicit return value;
      # the recorder marks it with ValueRecord::Void.  This is the
      # Ruby analogue of python's `main → None` precedent.
      top_exit = bundle['events'].find do |e|
        e['kind'] == 'call_exit' && e['function'].end_with?('<top-level>')
      end
      refute_nil top_exit, 'no call_exit for <top-level>'
      assert_equal 'Void', top_exit['return_value']['kind'],
                   "<top-level> return_value should decode as Void, got " \
                   "#{top_exit['return_value']['kind'].inspect}"

      # ---- Exact (varname, value) step-var pairs -------------------
      # Collect every (varname, kind, payload) triple surfaced by
      # step events.  The Ruby native recorder snapshots typed
      # integer locals via ValueRecord::Int, so `a = 1` and
      # `b = 2` should both surface with the `Int` kind.  The
      # implicit `<return_value>` synthetic local at the top-level
      # call site decodes to the `add(1, 2)` result, `Int(3)`.
      # `self` surfaces as ValueRecord::Raw { r: "main" } at the
      # top-level call site.  This is the Ruby analogue of
      # cairo's `a=10, b=32, sum_val=42, ...` round-trip.
      observed_step_vars = []
      bundle['events'].each do |ev|
        next unless ev['kind'] == 'step'

        ev['vars'].each do |v|
          observed_step_vars << [
            v['varname'],
            v['value']['kind'],
            # `Int.i`, `String.text`, `Raw.r` — pick whichever
            # payload field is populated so the assertion stays
            # readable.
            v['value']['i'] || v['value']['text'] || v['value']['r']
          ]
        end
      end

      expected_step_vars = [
        # Top-level call site (`puts add(1, 2)`): both literal
        # integer arguments are surfaced as locals before the call
        # is dispatched, plus the implicit `self` pointer.
        ['a',               'Int', 1],
        ['b',               'Int', 2],
        ['self',            'Raw', 'main'],
        # `add`'s body — same parameter pair, with the same Int
        # decoding, so the step-var snapshot inside `add` mirrors
        # the call-arg snapshot.
        ['a',               'Int', 1],
        ['b',               'Int', 2],
        # Synthetic `<return_value>` pseudo-local at the top-level
        # frame: holds the Int(3) result of `add(1, 2)`.
        ['<return_value>',  'Int', 3]
      ]
      expected_step_vars.each do |want|
        assert_includes observed_step_vars, want,
                        "expected step variable #{want.inspect} in --full output; " \
                        "observed = #{observed_step_vars.inspect}"
      end

      # ---- IO event: `puts add(1, 2)` writes "3\n" -----------------
      # The single io event must be a stdout write of "3\n" (puts
      # appends a trailing newline; the recorder captures the raw
      # bytes written to stdout, so the newline must be present).
      io_events = bundle['events'].select { |e| e['kind'] == 'io' }
      assert_equal 1, io_events.size,
                   "expected exactly 1 io event, got #{io_events.size}: #{io_events.inspect}"
      io = io_events.first
      assert_equal 'ioStdout', io['io_kind'],
                   "io event should be ioStdout, got #{io['io_kind'].inspect}"
      assert_equal "3\n", io['text'],
                   "io event text should be \"3\\n\", got #{io['text'].inspect}"
      assert_equal "3\n".bytesize, io['bytes_len'],
                   "io event bytes_len should be #{"3\n".bytesize}, got #{io['bytes_len']}"
    end
  end

  # `--out-dir` may be omitted when CODETRACER_RUBY_RECORDER_OUT_DIR is set.
  # Verifies convention §5 for both recorders.
  def test_env_out_dir_used_when_flag_omitted
    [PURE_RECORDER_BIN, NATIVE_RECORDER_BIN].each do |bin|
      next if bin == NATIVE_RECORDER_BIN && !native_extension_built?

      Dir.chdir(File.expand_path('..', __dir__)) do
        out_dir = File.join(TMP_DIR, "env_out_dir_#{File.basename(bin)}")
        FileUtils.rm_rf(out_dir)
        FileUtils.mkdir_p(out_dir)

        env = { 'CODETRACER_RUBY_RECORDER_OUT_DIR' => out_dir }
        program = File.join('test', 'programs', 'addition.rb')
        _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, bin, program)
        assert status.success?, "[#{bin}] trace failed: #{stderr}"

        ct_files    = Dir.glob(File.join(out_dir, '*.ct'))
        json_exists = File.exist?(File.join(out_dir, 'trace.json'))
        assert ct_files.any? || json_exists,
               "[#{bin}] expected trace artefact in env-provided #{out_dir}; got: " +
               Dir.entries(out_dir).inspect
      end
    end
  end

  # CODETRACER_RUBY_RECORDER_DISABLED=1 short-circuits recording: the
  # target script still runs (so its stdout is preserved) but no
  # artefact is written.  Convention §5.
  def test_env_disabled_skips_recording
    [PURE_RECORDER_BIN, NATIVE_RECORDER_BIN].each do |bin|
      next if bin == NATIVE_RECORDER_BIN && !native_extension_built?

      Dir.chdir(File.expand_path('..', __dir__)) do
        out_dir = File.join(TMP_DIR, "env_disabled_#{File.basename(bin)}")
        FileUtils.rm_rf(out_dir)
        FileUtils.mkdir_p(out_dir)

        env = { 'CODETRACER_RUBY_RECORDER_DISABLED' => '1' }
        program = File.join('test', 'programs', 'addition.rb')
        stdout, stderr, status = Open3.capture3(
          env, RbConfig.ruby, bin, '--out-dir', out_dir, program
        )
        assert status.success?, "[#{bin}] disabled-mode failed: #{stderr}"

        # The target script's `puts add(1, 2)` should still produce "3\n".
        assert_includes stdout, '3', "[#{bin}] script stdout should be preserved when disabled"

        # No trace artefacts should have been written.
        ct_files = Dir.glob(File.join(out_dir, '*.ct'))
        assert_empty ct_files,
                     "[#{bin}] expected no *.ct files when DISABLED=1; got #{ct_files.inspect}"
        refute File.exist?(File.join(out_dir, 'trace.json')),
               "[#{bin}] expected no trace.json when DISABLED=1"
      end
    end
  end

  # `--format` and `-f` must be rejected with a non-zero exit (no silent
  # acceptance).  Convention §4.
  def test_format_flag_rejected
    [PURE_RECORDER_BIN, NATIVE_RECORDER_BIN].each do |bin|
      next if bin == NATIVE_RECORDER_BIN && !native_extension_built?

      Dir.chdir(File.expand_path('..', __dir__)) do
        program = File.join('test', 'programs', 'addition.rb')

        ['--format', '--format=json', '-f'].each do |flag_form|
          argv = if flag_form.include?('=')
                   [flag_form, program]
                 elsif flag_form == '-f'
                   ['-f', 'binary', program]
                 else
                   ['--format', 'json', program]
                 end
          _stdout, stderr, status = Open3.capture3(RbConfig.ruby, bin, *argv)
          refute status.success?,
                 "[#{bin}] expected non-zero exit for #{flag_form}, got success.\nstderr: #{stderr}"
        end
      end
    end
  end

  # `--help` for both recorders must NOT mention `--format` or
  # `CODETRACER_FORMAT`.  Convention §§4-5.
  def test_no_format_flag_in_help
    [PURE_RECORDER_BIN, NATIVE_RECORDER_BIN].each do |bin|
      Dir.chdir(File.expand_path('..', __dir__)) do
        stdout, _stderr, status = Open3.capture3(RbConfig.ruby, bin, '--help')
        assert status.success?, "[#{bin}] --help failed"
        refute_match(/--format/, stdout, "[#{bin}] --help must not mention --format")
        refute_match(/CODETRACER_FORMAT/, stdout, "[#{bin}] --help must not mention CODETRACER_FORMAT")
      end
    end
  end

  # `--help` for both recorders must mention `ct print` (the canonical
  # conversion tool, convention §4).
  def test_help_mentions_ct_print
    [PURE_RECORDER_BIN, NATIVE_RECORDER_BIN].each do |bin|
      Dir.chdir(File.expand_path('..', __dir__)) do
        stdout, _stderr, status = Open3.capture3(RbConfig.ruby, bin, '--help')
        assert status.success?, "[#{bin}] --help failed"
        assert_includes stdout, 'ct print',
                        "[#{bin}] --help must mention `ct print` (canonical CTFS converter)"
      end
    end
  end

  private

  # The native gem only works when the Rust extension has been compiled.
  # Skip native-recorder tests rather than fail when the build hasn't
  # been run (e.g. on a fresh checkout) — this is a pre-existing test
  # convention (`run_native_recorder_ct` in test_hcr.rb has the same
  # gate).  This is *not* a silent test weakening: each guarded test
  # asserts loudly when the extension *is* available.
  def native_extension_built?
    ext_dir = File.expand_path('../gems/codetracer-ruby-recorder/ext/native_tracer/target/release', __dir__)
    return false unless Dir.exist?(ext_dir)

    %w[so bundle dylib dll].any? do |dlext|
      File.exist?(File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")) ||
        File.exist?(File.join(ext_dir, "libcodetracer_ruby_recorder.#{dlext}"))
    end
  end
end
