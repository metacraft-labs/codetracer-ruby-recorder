# frozen_string_literal: true

# M16a verification suite: Ruby Assignment events.
#
# These tests cover the M16a milestone deliverables for the pure-Ruby
# recorder.  See `Planned-Features/Value-Origin-Tracking.milestones.org`
# §M16a for the verification list.
#
# The production native recorder (codetracer-ruby-recorder) emits the
# same events through the trace writer's `add_event(BindVariable | Assignment)`
# API but the Nim CTFS backend currently no-ops both variants pending the
# M16-series Nim FFI extension; the unit-level tests here exercise the
# pure-Ruby reference implementation, which writes JSON and is the
# cross-validation oracle the native recorder is compared against.

require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class M16aAssignmentTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  TMP_DIR = File.expand_path('tmp/m16a', __dir__)

  def setup
    FileUtils.mkdir_p(TMP_DIR)
  end

  # Run the pure-Ruby recorder against the supplied program source and
  # return the parsed trace.
  def trace_program(source, name:)
    program_path = File.join(TMP_DIR, "#{name}.rb")
    File.write(program_path, source)
    out_dir = File.join(TMP_DIR, name)
    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)

    recorder = File.join(ROOT, 'gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder')
    cmd = [
      RbConfig.ruby,
      '-I', File.join(ROOT, 'gems/codetracer-pure-ruby-recorder/lib'),
      recorder,
      '-o', out_dir,
      '--',
      program_path
    ]
    stdout, stderr, status = Open3.capture3(*cmd)
    raise "tracer failed (#{status}): #{stderr}\nstdout: #{stdout}" unless status.success?

    trace_path = File.join(out_dir, 'trace.json')
    JSON.parse(File.read(trace_path))
  end

  # Walk the event stream and resolve every Assignment / BindVariable
  # back to its source name via the surrounding VariableName events.
  #
  # The pure-Ruby recorder uses a single counter for variable_ids
  # which it advances every time it sees a *fresh* name via
  # `load_variable_id`.  So we can rebuild a `var_id -> name` table
  # by counting VariableName events as we walk.
  def resolve_assignments(trace)
    var_table = []
    trace.each do |event|
      if event.key?('VariableName')
        var_table << event['VariableName']
      end
    end
    assignments = []
    trace.each do |event|
      next unless event.key?('Assignment')
      a = event['Assignment']
      target = var_table[a['to']] || "?#{a['to']}"
      rvalue = a['from']
      # Resolve the receiver id for Simple/FieldAccess/IndexAccess
      # back to a source name so the assertions stay readable.
      if rvalue.is_a?(Hash) && rvalue['kind'] == 'Simple'
        rvalue = rvalue.merge('source_name' => var_table[rvalue['data']] || "?#{rvalue['data']}")
      end
      assignments << [target, rvalue]
    end
    assignments
  end

  def bind_variable_names(trace)
    var_table = []
    binds = []
    trace.each do |event|
      if event.key?('VariableName')
        var_table << event['VariableName']
      elsif event.key?('BindVariable')
        id = event['BindVariable']['variable_id']
        binds << (var_table[id] || "?#{id}")
      end
    end
    binds
  end

  # -----------------------------------------------------------------
  # test_ruby_recorder_emits_assignment_for_local_copy
  # -----------------------------------------------------------------

  def test_ruby_recorder_emits_assignment_for_local_copy
    trace = trace_program(<<~RUBY, name: 'local_copy')
      a = 10
      b = a
      puts b
    RUBY
    assignments = resolve_assignments(trace)
    b_assign = assignments.find { |name, _| name == 'b' }
    refute_nil b_assign, "expected Assignment for `b`, got #{assignments.inspect}"

    rvalue = b_assign.last
    assert_equal 'Simple', rvalue['kind'],
                 "expected RValue::Simple for `b = a`, got #{rvalue.inspect}"
    assert_equal 'a', rvalue['source_name'],
                 "expected Simple to reference `a`, got #{rvalue.inspect}"

    binds = bind_variable_names(trace)
    assert_includes binds, 'b', "expected BindVariable for `b`, got #{binds.inspect}"
  end

  # -----------------------------------------------------------------
  # test_ruby_recorder_emits_block_arg_assignment
  # -----------------------------------------------------------------

  def test_ruby_recorder_emits_block_arg_assignment
    trace = trace_program(<<~RUBY, name: 'block_arg')
      xs = [10, 20, 30]
      xs.each do |x|
        puts x
      end
    RUBY
    assignments = resolve_assignments(trace)

    x_assigns = assignments.select { |name, _| name == 'x' }
    refute_empty x_assigns,
                 "expected at least one ParameterPass-style Assignment for `x`, got #{assignments.inspect}"

    binds = bind_variable_names(trace)
    assert_includes binds, 'x',
                    "expected BindVariable for block parameter `x`, got #{binds.inspect}"
  end

  # -----------------------------------------------------------------
  # test_origin_chain_path_a_confidence_one_ruby
  #
  # SKIP: gated on the M16-series db-backend Path A classifier
  # extension landing in the db-backend.  This test asserts the
  # *recorder's* half of that contract — every link in `a -> b -> c`
  # must surface as an Assignment with RValue::Simple (or Literal for
  # the chain root).  That's necessary for Path A activation in
  # `trace_processor.rs`; the db-backend's classifier-side
  # confidence-1.0 surfacing is the M16-series follow-on.
  # -----------------------------------------------------------------

  def test_origin_chain_path_a_confidence_one_ruby
    trace = trace_program(<<~RUBY, name: 'chain')
      a = 10
      b = a
      c = b
      puts c
    RUBY
    assignments = resolve_assignments(trace)

    a_assign = assignments.find { |name, _| name == 'a' }
    refute_nil a_assign, "Path A: expected Assignment for `a`, got #{assignments.inspect}"
    assert_equal 'Literal', a_assign.last['kind'],
                 "Path A: chain root must be Literal, got #{a_assign.last.inspect}"

    b_assign = assignments.find { |name, _| name == 'b' }
    refute_nil b_assign, "Path A: expected Assignment for `b`, got #{assignments.inspect}"
    assert_equal 'Simple', b_assign.last['kind'],
                 "Path A: `b = a` must be Simple, got #{b_assign.last.inspect}"
    assert_equal 'a', b_assign.last['source_name'],
                 "Path A: `b` Simple receiver must be `a`, got #{b_assign.last.inspect}"

    c_assign = assignments.find { |name, _| name == 'c' }
    refute_nil c_assign, "Path A: expected Assignment for `c`, got #{assignments.inspect}"
    assert_equal 'Simple', c_assign.last['kind'],
                 "Path A: `c = b` must be Simple, got #{c_assign.last.inspect}"
    assert_equal 'b', c_assign.last['source_name'],
                 "Path A: `c` Simple receiver must be `b`, got #{c_assign.last.inspect}"
  end
end
