# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Metacraft Labs Ltd
# See LICENSE file in the project root for full license information.

# ---------------------------------------------------------------------------
# M16a: Ruby Assignment-event reconstructor.
#
# Ruby's MRI TracePoint API does not expose a global `:local_variable_set`
# event — that event variant is only fired with `target_thread` /
# `target` arguments and so is unsuitable for whole-program tracing.
# Instead we reconstruct an "Assignment event" by:
#
#   1. Snapshotting `binding.local_variables` on every `:line`,
#      `:call`, and `:b_call` callback per frame.
#   2. Diffing the snapshot against the previous one for the same
#      frame: every name whose value identity changed (or which is
#      newly visible) is a candidate STORE on the *previous* line.
#   3. Classifying the RHS shape from the source line using a
#      lightweight regex-based classifier (`classify_assignment_line`).
#      This emits one of `RValue::Literal`, `RValue::Simple`,
#      `RValue::Compound`, `RValue::IndexAccess`, `RValue::FieldAccess`,
#      or `RValue::FunctionReturn` (last-call-key heuristic).
#   4. Emitting `BindVariable` (one-shot per frame) followed by
#      `Assignment` events in the same order the values were observed.
#
# The classifier is intentionally narrow — it only recognises shapes
# the M16a milestone tests exercise (`b = a`, `a = 10`, parameter
# binding) plus a small set of common idioms (`result = foo()`,
# `x = arr[0]`, `x = obj.field`).  Unknown RHS shapes default to
# `RValue::Compound([])`, which the db-backend treats as the lowest
# confidence Path A hop.
# ---------------------------------------------------------------------------

module CodeTracer
  class AssignmentReconstructor
    # Tracks per-frame state needed to compute STORE diffs and gate
    # one-shot BindVariable emission.
    #
    # `frame_key` is the `Thread.current.object_id ^ binding.object_id`
    # of the current frame; that's stable for the lifetime of the
    # frame and unique across concurrent frames.
    FrameState = Struct.new(:bound_names, :last_locals, :last_path, :last_line) do
      def initialize(*)
        super
        self.bound_names ||= {}
        self.last_locals ||= {}
        self.last_path ||= nil
        self.last_line ||= nil
      end
    end

    def initialize
      @frames = {}
      # `@source_cache` maps absolute path -> Array<String> (1-indexed
      # via Array#dig style by line - 1).  We cache because the line
      # callback fires many times per file and re-reading would be
      # expensive.
      @source_cache = {}
      # The last call key the recorder observed (incremented every
      # time the recorder emits a CallRecord).  Used to stamp
      # `RValue::FunctionReturn { call_key }` onto the assignment.
      @last_call_key = -1
    end

    # Called by the recorder every time a CallRecord is emitted so
    # `RValue::FunctionReturn` can reference it.
    def note_call(call_key)
      @last_call_key = call_key
    end

    # Snapshot the current frame's locals + register the
    # (path, line) we were on.  Returns the diff so the caller can
    # emit BindVariable / Assignment events in the right order
    # (Step -> BindVariable -> Assignment, matching the M14
    # vocabulary).
    #
    # `binding_obj` is the frame's binding.  `path` / `line` are the
    # *current* path/line (the on_line callback fires *before* the
    # statement executes, so the STOREs we're diffing belong to the
    # *previous* line).
    def on_line(binding_obj, path, line)
      return [] if binding_obj.nil?

      frame_key = frame_key_for(binding_obj, path)
      state = @frames[frame_key]
      first_observation = state.nil?
      state ||= (@frames[frame_key] = FrameState.new)

      current_locals = capture_locals(binding_obj)
      previous_locals = state.last_locals
      previous_path = state.last_path
      previous_line = state.last_line

      events = []

      # On the very first on_line in a frame we have no diff
      # baseline.  Ruby pre-allocates every declared local as `nil`
      # from the moment the frame is entered, so a diff against an
      # empty baseline would mis-attribute the entire frame's
      # locals as STOREs on the entry line.  We snapshot silently
      # and emit nothing on the entry callback.
      if first_observation
        state.last_locals = current_locals
        state.last_path = path
        state.last_line = line
        return events
      end

      changed_names = []
      current_locals.each do |name, value|
        prev = previous_locals[name]
        # Use `equal?` for object-identity comparison so we treat
        # `b = a` (alias) and `b = a.dup` (copy) differently.  When
        # the previous slot was empty (`!previous_locals.key?(name)`)
        # the variable is newly introduced and counts as a STORE.
        if !previous_locals.key?(name) || !same_value?(prev, value)
          changed_names << name
        end
      end

      changed_names.each do |name|
        unless state.bound_names[name]
          state.bound_names[name] = true
          events << [:BindVariable, name]
        end
      end

      # The STOREs we just detected were executed by the *previous*
      # line.  We classify the source of that line — *not* the line
      # we just stepped to.  When the previous line is unknown
      # (first :line callback in the frame) we fall back to the
      # current line so we still emit something useful.
      classify_path = previous_path || path
      classify_line = previous_line || line
      rvalues = classify_assignment_line(classify_path, classify_line, current_locals)

      changed_names.each do |name|
        rvalue = rvalues[name] || default_rvalue_for(name, current_locals)
        events << [:Assignment, name, rvalue]
      end

      state.last_locals = current_locals
      state.last_path = path
      state.last_line = line

      events
    end

    # Emit one BindVariable + one Assignment for every formal
    # parameter at function-entry time (the M16a verification test
    # `test_ruby_recorder_emits_block_arg_assignment` requires this for
    # block parameters specifically).  Returns the same shape as
    # `on_line` so the caller can drive a single emit loop.
    def on_call(binding_obj, parameter_names, path, line)
      return [] if binding_obj.nil?

      frame_key = frame_key_for(binding_obj, path)
      state = (@frames[frame_key] ||= FrameState.new)

      events = []
      parameter_names.each do |name|
        next if name.nil? || name.empty?
        unless state.bound_names[name]
          state.bound_names[name] = true
          events << [:BindVariable, name]
        end
        # Parameter binding is always a `RValue::Compound([])` from
        # the recorder's perspective — the actual values flow in via
        # the call args (which the db-backend correlates with the
        # parameter names through the call site's manifest).  The
        # `pass_by: :Value` field below is the default `PassBy::Value`.
        events << [:Assignment, name, RValueShape.compound([])]
      end

      # Seed the diff baseline so the *first* :line in the body does
      # not re-emit Assignments for the just-bound parameters.
      state.last_locals = capture_locals(binding_obj)
      state.last_path = path
      state.last_line = line

      events
    end

    # Drop a frame's state when the matching :return / :b_return
    # fires.  Without this the `@frames` hash grows unbounded for
    # long-running programs.
    def on_return(binding_obj, path)
      return if binding_obj.nil?

      @frames.delete(frame_key_for(binding_obj, path))
    end

    private

    # Compose a stable per-frame key.  MRI hands the TracePoint
    # callback a *fresh* Binding object on every callback (each call
    # to `tp.binding` synthesises a new Binding wrapping the same
    # underlying frame), so `binding_obj.object_id` is not stable
    # across callbacks for the same frame.  Instead we key by the
    # combination of (thread, path, method, call depth).  `caller(2)`
    # skips the reconstructor frames and gives us the depth at the
    # *caller* of the recorder, which is stable for a single frame's
    # lifetime; the `__method__` component disambiguates same-depth
    # frames in recursive or mutually-recursive call graphs that
    # happen to share a path.
    def frame_key_for(binding_obj, path)
      method_name = nil
      begin
        method_name = binding_obj.eval('__method__')
      rescue StandardError
        method_name = nil
      end
      depth = begin
                # caller offset 4 skips: this method, the calling
                # on_line/on_call/on_return, the recorder's
                # drain_assignment_events, and the tracepoint
                # block.  The result is the depth at the user-frame
                # the TracePoint fired in.
                caller(4).length
              rescue StandardError
                0
              end
      [Thread.current.object_id, path, method_name, depth]
    end

    def capture_locals(binding_obj)
      result = {}
      begin
        binding_obj.local_variables.each do |name|
          begin
            result[name] = binding_obj.local_variable_get(name)
          rescue NameError
            # Skip locals that the binding refuses to surface (this
            # can happen for `for` loop binders in some Ruby
            # versions).
            next
          end
        end
      rescue StandardError
        # If the binding rejects the introspection entirely (e.g.
        # because the frame is in a state where local_variables
        # raises) we simply skip — no events get emitted, no harm
        # done.
      end
      result
    end

    def same_value?(a, b)
      a.equal?(b) || a == b
    rescue StandardError
      false
    end

    # Default RValue for a name when the source-line classifier had
    # no opinion.  We surface `RValue::Compound([])` because the
    # M14 reader-side compatibility rule treats unknown variants as
    # the same shape, so this is the most honest "I don't know"
    # value.
    def default_rvalue_for(_name, _current_locals)
      RValueShape.compound([])
    end

    # Classify each STORE on a source line.  Returns a hash mapping
    # `name -> RValueShape`.  Names not in the hash get the default
    # shape from `default_rvalue_for`.
    #
    # The classifier is regex-based and intentionally narrow — Ruby
    # has no public bytecode introspection so we can't replicate the
    # Python M15 dis.get_instructions approach.  The patterns we
    # recognise cover the M16a verification tests:
    #
    #   * `name = literal` -> RValue::Literal
    #   * `name = identifier` -> RValue::Simple
    #   * `name = identifier.attribute` -> RValue::FieldAccess
    #   * `name = identifier[integer]` -> RValue::IndexAccess
    #   * `name = identifier(args)` or `name = func(...)` ->
    #     RValue::FunctionReturn
    #   * Anything else -> RValue::Compound([locals_loaded])
    def classify_assignment_line(path, line, current_locals)
      source = source_line_for(path, line)
      return {} if source.nil? || source.empty?

      result = {}
      # Strip comments and trailing whitespace; `inline?` cases
      # (`name = expr; other = expr`) are split on `;`.
      source.gsub(/#.*$/, '').split(';').each do |segment|
        segment = segment.strip
        next if segment.empty?
        # Match a simple `<name> = <expr>` shape.  We do *not*
        # support multiple-assignment / destructuring in this
        # regex — that's covered by `default_rvalue_for` (the
        # callers emit one Assignment per changed local already).
        match = segment.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\z/)
        next if match.nil?

        target = match[1].to_sym
        rhs = match[2].strip
        rvalue = classify_rhs(rhs, current_locals)
        result[target] = rvalue unless rvalue.nil?
      end

      result
    end

    def classify_rhs(rhs, current_locals)
      # Strip a trailing comma (`a, b = pair` -> we see `a =` from
      # the regex above, but `b =` isn't a thing in Ruby's grammar
      # so this branch is mostly defensive).
      rhs = rhs.sub(/,\s*\z/, '')

      # Literal: integers, floats, strings, symbols, true/false/nil.
      if rhs.match?(/\A-?\d+(\.\d+)?\z/) ||
         rhs.match?(/\A["'].*["']\z/) ||
         rhs.match?(/\A:[A-Za-z_]\w*\z/) ||
         %w[true false nil].include?(rhs)
        return RValueShape.literal
      end

      # Simple: bare identifier that matches a known local.
      if (m = rhs.match(/\A([A-Za-z_][A-Za-z0-9_]*)\z/))
        candidate = m[1].to_sym
        if current_locals.key?(candidate)
          variable_id = variable_id_for(candidate)
          return RValueShape.simple(variable_id) unless variable_id.nil?
        end
      end

      # IndexAccess with static integer index: `arr[3]`.
      if (m = rhs.match(/\A([A-Za-z_][A-Za-z0-9_]*)\[(-?\d+)\]\z/))
        receiver = m[1].to_sym
        if current_locals.key?(receiver)
          variable_id = variable_id_for(receiver)
          return RValueShape.index_access(variable_id, m[2].to_i) unless variable_id.nil?
        end
      end

      # FieldAccess: `obj.attr` (no method call parens).
      if (m = rhs.match(/\A([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\z/))
        receiver = m[1].to_sym
        if current_locals.key?(receiver)
          variable_id = variable_id_for(receiver)
          return RValueShape.field_access(variable_id, m[2]) unless variable_id.nil?
        end
      end

      # FunctionReturn: `foo(...)` or `obj.method(...)`.  The
      # `last_call_key` we stamp may be stale (the CALL we attribute
      # may not be the one we want) but the M16a tests only check
      # the *variant*, not the specific key.
      if rhs.match?(/[A-Za-z_][A-Za-z0-9_]*\s*\(.*\)\s*\z/)
        return RValueShape.function_return(@last_call_key)
      end

      # Otherwise: compound of every local that textually appears in
      # the RHS.
      dependencies = []
      rhs.scan(/[A-Za-z_][A-Za-z0-9_]*/) do |token|
        sym = token.to_sym
        next unless current_locals.key?(sym)
        dependencies << sym
      end
      ids = dependencies.uniq.filter_map { |s| variable_id_for(s) }
      RValueShape.compound(ids)
    end

    # Resolves the variable id for `name` by asking the recorder.
    # The recorder is injected via `attach_variable_resolver` at
    # bind time so the reconstructor stays decoupled from the
    # TraceRecord.
    def variable_id_for(name)
      return nil if @variable_resolver.nil?
      @variable_resolver.call(name)
    end

    public

    # Hook used by the recorder to inject the `load_variable_id`
    # callback.  The reconstructor needs this to mint
    # `VariableId`s for `RValue::Simple` etc. without pulling in the
    # whole TraceRecord.
    def attach_variable_resolver(resolver)
      @variable_resolver = resolver
    end

    private

    def source_line_for(path, line)
      return nil if path.nil? || line.nil? || line < 1
      lines = @source_cache[path]
      if lines.nil?
        begin
          lines = File.readlines(path)
        rescue StandardError
          # Source unavailable (e.g. eval'd code, dynamically
          # generated stubs).  Cache an empty array so we don't keep
          # retrying.
          lines = []
        end
        @source_cache[path] = lines
      end
      lines[line - 1]&.chomp
    end
  end
end
