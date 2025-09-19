# SPDX-License-Identifier: MIT

require 'minitest/autorun'
require_relative '../gems/codetracer-pure-ruby-recorder/lib/codetracer/kernel_patches'

class MockTracer
  attr_reader :events, :name

  def initialize(name = "tracer")
    @events = []
    @name = name
  end

  def record_event(path, lineno, content)
    @events << { path: path, lineno: lineno, content: content }
  end

  def clear_events
    @events = []
  end
end

class TestKernelPatches < Minitest::Test
  def setup
    @tracer1 = MockTracer.new("tracer1")
    @tracer2 = MockTracer.new("tracer2")
    CodeTracer::KernelPatches.reset
  end

  def teardown
    CodeTracer::KernelPatches.reset
    assert_empty CodeTracer::KernelPatches.class_variable_get(:@@tracers), "Tracers should be empty after teardown"
  end

  def test_patching_and_basic_event_recording
    CodeTracer::KernelPatches.install(@tracer1)

    expected_line_p = __LINE__; p 'hello'
    expected_line_puts = __LINE__; puts 'world'
    expected_line_print = __LINE__; print 'test'

    assert_equal 3, @tracer1.events.size

    event_p = @tracer1.events[0]
    assert_equal __FILE__, event_p[:path]
    assert_equal expected_line_p, event_p[:lineno]
    assert_equal "\"hello\"\n", event_p[:content] # p uses inspect

    event_puts = @tracer1.events[1]
    assert_equal __FILE__, event_puts[:path]
    assert_equal expected_line_puts, event_puts[:lineno]
    assert_equal "world\n", event_puts[:content]

    event_print = @tracer1.events[2]
    assert_equal __FILE__, event_print[:path]
    assert_equal expected_line_print, event_print[:lineno]
    assert_equal "test", event_print[:content]

    CodeTracer::KernelPatches.uninstall(@tracer1)
  end

  def test_multiple_tracers
    CodeTracer::KernelPatches.install(@tracer1)
    CodeTracer::KernelPatches.install(@tracer2)

    expected_line_multi = __LINE__; p 'multitest'

    assert_equal 1, @tracer1.events.size
    assert_equal 1, @tracer2.events.size

    event1_multi = @tracer1.events.first
    assert_equal __FILE__, event1_multi[:path]
    assert_equal expected_line_multi, event1_multi[:lineno]
    assert_equal "\"multitest\"\n", event1_multi[:content]

    event2_multi = @tracer2.events.first
    assert_equal __FILE__, event2_multi[:path]
    assert_equal expected_line_multi, event2_multi[:lineno]
    assert_equal "\"multitest\"\n", event2_multi[:content]

    CodeTracer::KernelPatches.uninstall(@tracer1)
    @tracer1.clear_events
    @tracer2.clear_events

    expected_line_one_left = __LINE__; p 'one left'

    assert_empty @tracer1.events, "Tracer1 should have no events after being uninstalled"
    assert_equal 1, @tracer2.events.size

    event2_one_left = @tracer2.events.first
    assert_equal __FILE__, event2_one_left[:path]
    assert_equal expected_line_one_left, event2_one_left[:lineno]
    assert_equal "\"one left\"\n", event2_one_left[:content]

    CodeTracer::KernelPatches.uninstall(@tracer2)
  end

  def test_restoration_of_original_methods
    CodeTracer::KernelPatches.install(@tracer1)
    CodeTracer::KernelPatches.uninstall(@tracer1)

    # To truly test restoration, we'd capture stdout. Here, we focus on the tracer not being called.
    # If KernelPatches is working, uninstalling the last tracer should remove the patches.
    p 'original restored' # This line's output will go to actual stdout

    assert_empty @tracer1.events, "Tracer should not record events after being uninstalled and patches removed"
  end

  def test_reset_removes_all_tracers_and_restores_methods
    CodeTracer::KernelPatches.install(@tracer1)
    CodeTracer::KernelPatches.install(@tracer2)

    CodeTracer::KernelPatches.reset

    assert_empty CodeTracer::KernelPatches.class_variable_get(:@@tracers), "No tracers should remain after reset"

    p 'after reset'

    assert_empty @tracer1.events, "Tracer1 should not record after reset"
    assert_empty @tracer2.events, "Tracer2 should not record after reset"

    assert_equal Kernel.instance_method(:codetracer_original_p), Kernel.instance_method(:p)
    assert_equal Kernel.instance_method(:codetracer_original_puts), Kernel.instance_method(:puts)
    assert_equal Kernel.instance_method(:codetracer_original_print), Kernel.instance_method(:print)
  end

  def test_correct_event_arguments
    CodeTracer::KernelPatches.install(@tracer1)

    arg_obj = { key: "value", number: 123 }

    expected_line_p_detailed = __LINE__; p "detailed_p", arg_obj
    expected_line_puts_detailed = __LINE__; puts "detailed_puts", arg_obj.to_s
    expected_line_print_detailed = __LINE__; print "detailed_print", arg_obj.to_s

    assert_equal 3, @tracer1.events.size

    event_p = @tracer1.events[0]
    assert_equal __FILE__, event_p[:path], "Path for p mismatch"
    assert_equal expected_line_p_detailed, event_p[:lineno], "Line number for p mismatch"
    # p calls inspect on each argument and joins with newline if multiple, but here it's one string then obj
    assert_equal "\"detailed_p\"\n{key: \"value\", number: 123}\n", event_p[:content], "Content for p mismatch"


    event_puts = @tracer1.events[1]
    assert_equal __FILE__, event_puts[:path], "Path for puts mismatch"
    assert_equal expected_line_puts_detailed, event_puts[:lineno], "Line number for puts mismatch"
    # puts calls to_s on each argument and prints each on a new line
    assert_equal "detailed_puts\n{key: \"value\", number: 123}\n", event_puts[:content], "Content for puts mismatch"


    event_print = @tracer1.events[2]
    assert_equal __FILE__, event_print[:path], "Path for print mismatch"
    assert_equal expected_line_print_detailed, event_print[:lineno], "Line number for print mismatch"
    # print calls to_s on each argument and prints them sequentially
    assert_equal "detailed_print{key: \"value\", number: 123}", event_print[:content], "Content for print mismatch"

    CodeTracer::KernelPatches.uninstall(@tracer1)
  end
end
