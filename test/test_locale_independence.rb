# frozen_string_literal: true

# Both recorders must record a program whose source and data are non-ASCII
# the same way in every locale.
#
# Ruby tags what it reads from files with `Encoding.default_external`, which
# follows the locale (https://docs.ruby-lang.org/en/3.4/Encoding.html#class-Encoding-label-Default+External+Encoding).
# Under `LC_ALL=C`, or on a host with no UTF-8 locale such as the macOS CI
# runner, that is US-ASCII. The pure recorder used to read the traced
# program's source that way, and the first non-ASCII byte made its assignment
# classifier raise `ArgumentError`: the traced program stopped at that line,
# printed nothing, and the recorder still exited 0 with a truncated trace.
#
# The control is the same run under `RUBYOPT=-EUTF-8`, which fixes
# `default_external` to UTF-8 regardless of the locale
# (https://docs.ruby-lang.org/en/3.4/ruby/options_md.html#label-Option+-E), so
# the two runs differ only in the locale-derived encoding. No mocks: the real
# recorders record a real Ruby subprocess, and the native recording is read
# back with the shipped `ct-print`.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative 'ct_print_support'
require_relative 'utf8_io'

class LocaleIndependenceTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  PURE_RECORDER = File.join(ROOT, 'gems', 'codetracer-pure-ruby-recorder', 'bin', 'codetracer-pure-ruby-recorder')
  NATIVE_RECORDER = File.join(ROOT, 'gems', 'codetracer-ruby-recorder', 'bin', 'codetracer-ruby-recorder')

  # Non-ASCII in a string literal, in an interpolated argument and in a
  # comment on the assignment line the pure recorder classifies.
  PROGRAM = <<~RUBY
    def greet(name)
      greeting = "héllo \#{name}" # café
      greeting
    end
    puts greet('wörld')
  RUBY

  EXPECTED_OUTPUT = "héllo wörld\n"

  # A US-ASCII locale. `LANG` and `LC_CTYPE` are removed so that only
  # `LC_ALL` decides, whatever the caller's environment holds.
  ASCII_LOCALE = { 'LANG' => nil, 'LC_CTYPE' => nil, 'LC_ALL' => 'C' }.freeze

  def with_program
    Dir.mktmpdir('codetracer-locale-') do |scratch|
      program = File.join(scratch, 'greet.rb')
      File.write(program, PROGRAM, mode: 'wb')
      yield scratch, program
    end
  end

  def record(recorder, program, out_dir, env)
    stdout, stderr, status = Utf8IO.capture3(env, RbConfig.ruby, recorder, '--out-dir', out_dir, program)
    assert status.success?, "#{File.basename(recorder)} failed under #{env.inspect}: #{stderr}"
    assert_equal EXPECTED_OUTPUT, stdout,
                 "#{File.basename(recorder)} under #{env.inspect}: the traced program's output changed"
  end

  def test_pure_recorder_trace_does_not_depend_on_locale
    with_program do |scratch, program|
      ascii_out = File.join(scratch, 'ascii')
      utf8_out = File.join(scratch, 'utf8')
      record(PURE_RECORDER, program, ascii_out, ASCII_LOCALE)
      record(PURE_RECORDER, program, utf8_out, ASCII_LOCALE.merge('RUBYOPT' => '-EUTF-8'))

      ascii_trace = JSON.parse(Utf8IO.read(File.join(ascii_out, 'trace.json')))
      utf8_trace = JSON.parse(Utf8IO.read(File.join(utf8_out, 'trace.json')))
      texts = utf8_trace.filter_map { |event| event.dig('Value', 'value', 'text') }
      assert_includes texts, "héllo wörld", 'control run did not record the greeting'
      assert_equal utf8_trace, ascii_trace, 'the pure trace depends on the locale'
    end
  end

  def test_native_recorder_records_non_ascii_under_an_ascii_locale
    with_program do |scratch, program|
      out_dir = File.join(scratch, 'native')
      record(NATIVE_RECORDER, program, out_dir, ASCII_LOCALE)

      containers = Dir.glob(File.join(out_dir, '*.ct'))
      assert_equal 1, containers.length, 'expected one .ct recording'
      decoded, diagnostics, status = Utf8IO.capture3(CtPrintSupport::CT_PRINT, '--full', containers.first)
      assert status.success?, diagnostics
      strings = []
      collect = lambda do |node|
        case node
        when Hash
          strings << node['text'] if node['kind'] == 'String'
          node.each_value(&collect)
        when Array then node.each(&collect)
        end
      end
      collect.call(JSON.parse(decoded))
      assert_includes strings, "héllo wörld"
      assert_includes strings, "wörld"
    end
  end
end
