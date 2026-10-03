# frozen_string_literal: true

# Real Ruby subprocesses, production native/pure recorders and production
# ct-print exercise standard IO. No runtime, IO or recorder is mocked.
require 'minitest/autorun'
require 'open3'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

class StdoutCaptureTest < Minitest::Test
  def test_real_stdio_preserves_conversion_returns_errors_and_thread_guards
    Dir.mktmpdir('ct-stdout-control-') do |root|
      program = File.join(root, 'stdio.rb')
      File.write(program, <<~'RUBY')
        class OutputValue
          def identity_probe(label)
            identity = Object.instance_method(:to_s).bind_call(self)
            File.write(File.join(__dir__, 'identities.txt'), "#{label}\t#{identity}\n", mode: 'a')
            label
          end

          def self.check_identities
            @@first = new
            @@second = new
            @@first.identity_probe('first')
            @@second.identity_probe('second')
            @@first.identity_probe('first-again')
          end

          def to_s
            $stderr.write "CONVERSION\n"
            'coerced'
          end
        end
        File.write(File.join(__dir__, 'identities.txt'), '')
        OutputValue.check_identities
        class ReceiverOverride < OutputValue
          def class
            raise 'user receiver.class was invoked'
          end
          def self.name
            raise 'user class.name was invoked'
          end
        end
        ReceiverOverride.new.identity_probe('override')
        def identity_probe(label)
          actual_main = Binding.instance_method(:receiver).bind_call(TOPLEVEL_BINDING)
          raise 'main identity changed' unless BasicObject.instance_method(:equal?).bind_call(self, actual_main)
          File.write(File.join(__dir__, 'identities.txt'), "#{label}\tmain\n", mode: 'a')
          label
        end
        GC.start
        GC.compact
        identity_probe('main-after-gc')
        class BadOutputValue
          def to_s
            raise 'conversion-control'
          end
        end
        puts 'kernel'
        $stdout.puts ['array-a', 'array-b']
        $stdout.print 'prefix:'
        raise 'write return changed' unless $stdout.write(OutputValue.new) == 7
        $stdout.write "\n"
        begin
          $stdout.write(BadOutputValue.new)
          raise 'missing conversion error'
        rescue RuntimeError => error
          raise unless error.message == 'conversion-control'
        end
        first = Thread.new { $stdout.write "thread-a\n" }
        first.join
        second = Thread.new { $stdout.write "thread-b\n" }
        second.join
        File.open(File.join(__dir__, 'other-stream.txt'), 'w') { |file| file.write 'not-stdout' }
        $stderr.write "STDERR-CONTROL\n"
      RUBY
      baseline, baseline_error, status = Open3.capture3(RbConfig.ruby, program)
      assert status.success?, baseline_error
      assert_equal "kernel\narray-a\narray-b\nprefix:coerced\nthread-a\nthread-b\n", baseline
      %w[pure native].each do |backend|
        gem = backend == 'pure' ? 'codetracer-pure-ruby-recorder' : 'codetracer-ruby-recorder'
        recorder = File.expand_path("../gems/#{gem}/bin/#{gem}", __dir__)
        output_dir = File.join(root, backend)
        stdout, stderr, result = Open3.capture3(RbConfig.ruby, recorder, '--out-dir', output_dir, program)
        assert result.success?, "#{backend}: #{stderr}"
        assert_equal baseline, stdout, "#{backend}: original output and no duplicate delegation"
        assert_equal 1, stderr.lines.count { |line| line.chomp == 'CONVERSION' }, "#{backend}: one conversion"
        assert_equal 1, stderr.lines.count { |line| line.chomp == 'STDERR-CONTROL' }, "#{backend}: stderr unchanged"
        identities = File.readlines(File.join(root, 'identities.txt'), chomp: true).map { |line| line.split("\t", 2) }.to_h
        assert_equal identities.fetch('first'), identities.fetch('first-again'), 'same receiver alias'
        refute_equal identities.fetch('first'), identities.fetch('second'), 'distinct receivers retain identity'
        if backend == 'pure'
          events = JSON.parse(File.read(File.join(output_dir, 'trace.json')))
          assert_identity_renderings(events, identities, backend)
          writes = events.filter_map { |event| event['Event'] }.select { |event| event['kind'] == 0 }
          assert_equal baseline, writes.map { |event| event.fetch('content') }.join
          assert writes.all? { |event| event.fetch('metadata') == '' }
        else
          ct_print = ENV['CT_PRINT'] || File.expand_path('../../codetracer-trace-format-nim/ct-print', __dir__)
          container = Dir[File.join(output_dir, '**', '*.ct')].fetch(0)
          decoded, diagnostics, decoded_status = Open3.capture3(ct_print, '--full', container)
          assert decoded_status.success?, diagnostics
          bundle = JSON.parse(decoded)
          assert_identity_renderings(bundle, identities, backend)
          writes = bundle.fetch('events').select { |event| event['kind'] == 'io' && event['io_kind'] == 'Write' }
          assert_equal baseline, writes.map { |event| event.fetch('text') }.join
          # Canonical full JSON omits precisely empty metadata (Nim addEventMetadata).
          # Any emitted metadata field here signals unexpected nonempty recorder data.
          assert writes.all? { |event| !event.key?('metadata') }
        end
        assert_equal 'not-stdout', File.read(File.join(root, 'other-stream.txt'))
      end
    end
  end

  # Compare unprojected production data to actual trusted-core identities
  # captured in the same application process, independently of the recorder.
  def assert_identity_renderings(data, expected, backend)
    calls = []
    if backend == 'pure'
      functions = []
      variables = []
      types = []
      data.each do |event|
        functions << event.fetch('Function').fetch('name') if event.key?('Function')
        variables << event.fetch('VariableName') if event.key?('VariableName')
        types << event.fetch('Type').fetch('lang_type') if event.key?('Type')
        next unless event.key?('Call')
        call = event.fetch('Call')
        next unless functions.fetch(call.fetch('function_id')).split('#').last == 'identity_probe'
        arguments = call.fetch('args').to_h { |argument| [variables.fetch(argument.fetch('variable_id')), argument.fetch('value')] }
        calls << [arguments.fetch('label'), arguments.fetch('self'), types]
      end
    else
      data.fetch('events').each do |event|
        next unless event['kind'] == 'call_entry' && event.fetch('function').split('#').last == 'identity_probe'
        arguments = event.fetch('args').to_h { |argument| [argument.fetch('varname'), argument.fetch('value')] }
        calls << [arguments.fetch('label'), arguments.fetch('self'), data.fetch('types')]
      end
    end
    assert_equal expected.keys, calls.map { |label, _receiver, _types| label.fetch('text') },
                 "#{backend}: exact probe call order and labels"
    calls.each do |label, receiver, types|
      assert_equal 'String', label.fetch('kind')
      assert_equal 'Raw', receiver.fetch('kind')
      rendering = expected.fetch(label.fetch('text'))
      expected_class = rendering == 'main' ? 'Object' : rendering.match(/\A#<(OutputValue|ReceiverOverride):0x[0-9a-f]+>\z/)&.captures&.fetch(0)
      refute_nil expected_class, 'independent actual core identity has a complete supported shape'
      assert_equal expected_class, types.fetch(receiver.fetch('type_id'))
      assert_equal expected.fetch(label.fetch('text')), receiver.fetch('r'),
                   "#{backend}: exact implicit receiver for this labeled call, without golden projection"
    end
  end
end
