# frozen_string_literal: true

# Real Ruby execution and the production ct-print decoder cross the native
# extension/CTFS boundary. No mocks are used: enclosing array siblings and
# method arguments must survive actual streaming of empty Proc values.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'
require_relative 'ct_print_support'

class EmptyProcValuesTest < Minitest::Test
  def test_empty_proc_values_keep_local_argument_and_nested_array_siblings
    assert File.executable?(CtPrintSupport::CT_PRINT), 'real ct-print prerequisite missing'
    Dir.mktmpdir('ruby-empty-proc-') do |scratch|
      program = File.join(scratch, 'empty_procs.rb')
      File.write(program, <<~RUBY)
        def accept_proc(proc_argument, lambda_argument, nested_argument)
          local_proc = proc_argument
          local_lambda = lambda_argument
          nested_local = nested_argument
          puts [local_proc.call, local_lambda.call, nested_local.first, nested_local.last].join(':')
        end
        empty_proc = proc { 17 }
        empty_lambda = -> { 23 }
        nested = [11, empty_proc, empty_lambda, 29]
        accept_proc(empty_proc, empty_lambda, nested)
      RUBY
      recorder = File.expand_path('../gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder', __dir__)
      out = File.join(scratch, 'recording')
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, recorder, '--out-dir', out, program)
      assert status.success?, stderr
      assert_equal "17:23:11:29\n", stdout
      files = Dir.glob(File.join(out, '*.ct'))
      assert_equal 1, files.length, 'expected one real recording'
      decoded, decoder_error, decoder_status = Open3.capture3(CtPrintSupport::CT_PRINT, '--full', files.fetch(0))
      assert decoder_status.success?, decoder_error
      bundle = JSON.parse(decoded)
      call = bundle.fetch('events').find { |event| event['kind'] == 'call_entry' && event.fetch('function').end_with?('accept_proc') }
      refute_nil call, 'missing real accept_proc call'
      arguments = call.fetch('args').to_h { |argument| [argument.fetch('varname'), argument.fetch('value')] }
      %w[proc_argument lambda_argument].each { |name| assert_empty_proc(bundle, arguments.fetch(name)) }
      assert_sandwich(bundle, arguments.fetch('nested_argument'))
      locals = bundle.fetch('events').select { |event| event['kind'] == 'step' }.flat_map { |event| event.fetch('vars') }
      %w[local_proc local_lambda].each do |name|
        values = locals.select { |variable| variable['varname'] == name }.map { |variable| variable.fetch('value') }
        refute_empty values, "missing local #{name}"
        assert_empty_proc(bundle, values.last)
      end
      nested_values = locals.select { |variable| variable['varname'] == 'nested_local' }.map { |variable| variable.fetch('value') }
      refute_empty nested_values, 'missing nested local'
      assert_sandwich(bundle, nested_values.last)
    end
  end

  def assert_empty_proc(bundle, value)
    assert_equal 'Struct', value.fetch('kind')
    assert_equal [], value.fetch('field_values')
    assert_equal 'Proc', bundle.fetch('types').fetch(value.fetch('type_id'))
    refute_match(/0x[0-9a-f]+/i, JSON.generate(value))
  end

  def assert_sandwich(bundle, value)
    assert_equal 'Sequence', value.fetch('kind')
    elements = value.fetch('elements')
    assert_equal 4, elements.length
    assert_equal ['Int', 11], [elements.fetch(0).fetch('kind'), elements.fetch(0).fetch('i')]
    assert_empty_proc(bundle, elements.fetch(1))
    assert_empty_proc(bundle, elements.fetch(2))
    assert_equal ['Int', 29], [elements.fetch(3).fetch('kind'), elements.fetch(3).fetch('i')]
  end
end
