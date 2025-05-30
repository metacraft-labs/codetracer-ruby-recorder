#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'benchmark'
require 'optparse'
require 'rbconfig'

PROGRAMS_DIR = File.expand_path('programs', __dir__)
FIXTURES_DIR = File.expand_path('fixtures', __dir__)
TMP_DIR = File.expand_path('tmp', __dir__)
WRITE_REPORT_DEFAULT = 'console'

options = { write_report: WRITE_REPORT_DEFAULT }
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby run_benchmarks.rb GLOB [options]'
  opts.on('--write-report=DEST', 'console or path to .json/.svg report') do |dest|
    options[:write_report] = dest
  end
end.parse!
pattern = ARGV.shift || abort('Usage: ruby run_benchmarks.rb GLOB [options]')

# Collect benchmark names and match against the provided glob
all_programs = Dir.glob(File.join(PROGRAMS_DIR, '*.rb')).map { |f| File.basename(f, '.rb') }
benchmarks = all_programs.select { |name| File.fnmatch?(pattern, name) }
if benchmarks.empty?
  abort("No benchmarks match pattern: #{pattern}")
end

# Compare two trace files structurally
def traces_equal?(a, b)
  JSON.parse(File.read(a)) == JSON.parse(File.read(b))
end

# Run a single benchmark by name
def run_benchmark(name)
  program = File.join(PROGRAMS_DIR, "#{name}.rb")
  fixture = File.join(FIXTURES_DIR, "#{name}_trace.json")
  raise 'Reference trace unavailable' unless File.exist?(fixture)

  base_dir = File.join(TMP_DIR, name)
  FileUtils.rm_rf(base_dir)

  results = { name: name }

  elapsed = Benchmark.realtime do
    system(RbConfig.ruby, program)
    raise 'Program failed' unless $?.success?
  end
  results[:ruby_ms] = (elapsed * 1000).round

  native_dir = File.join(TMP_DIR, name, 'native')
  FileUtils.mkdir_p(native_dir)
  elapsed = Benchmark.realtime do
    system(RbConfig.ruby, File.expand_path('../../gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder', __dir__),
           '--out-dir', native_dir, program)
    raise 'Native trace failed' unless $?.success?
  end
  results[:native_ms] = (elapsed * 1000).round
  native_trace = File.join(native_dir, 'trace.json')
  results[:native_ok] = traces_equal?(fixture, native_trace)

  pure_dir = File.join(TMP_DIR, name, 'pure')
  FileUtils.mkdir_p(pure_dir)
  elapsed = Benchmark.realtime do
    system(RbConfig.ruby, File.expand_path('../../gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder', __dir__),
           '--out-dir', pure_dir, program)
    raise 'Pure trace failed' unless $?.success?
  end
  results[:pure_ms] = (elapsed * 1000).round
  pure_trace = File.join(pure_dir, 'trace.json')
  results[:pure_ok] = traces_equal?(fixture, pure_trace)

  results
end

# Execute all benchmarks
results = benchmarks.map { |b| run_benchmark(b) }

# Reporting
if options[:write_report] == 'console'
  # Determine column widths
  name_w   = ['Benchmark'.length, *results.map { |r| r[:name].length }].max
  ruby_w   = ['Ruby'.length,     *results.map { |r| "#{r[:ruby_ms]}ms".length }].max
  native_w = ['Native'.length,   *results.map { |r| "#{r[:native_ok] ? 'OK' : 'FAIL'} #{r[:native_ms]}ms".length }].max
  pure_w   = ['Pure'.length,     *results.map { |r| "#{r[:pure_ok] ? 'OK' : 'FAIL'} #{r[:pure_ms]}ms".length }].max

  # Header
  printf "%-#{name_w}s  %-#{ruby_w}s  %-#{native_w}s  %-#{pure_w}s\n", 'Benchmark', 'Ruby', 'Native', 'Pure'
  puts '-' * (name_w + ruby_w + native_w + pure_w + 6)

  # Rows
  results.each do |r|
    ruby_s   = "#{r[:ruby_ms]}ms"
    native_s = "#{r[:native_ok] ? 'OK' : 'FAIL'} #{r[:native_ms]}ms"
    pure_s   = "#{r[:pure_ok] ? 'OK' : 'FAIL'} #{r[:pure_ms]}ms"
    printf "%-#{name_w}s  %-#{ruby_w}s  %-#{native_w}s  %-#{pure_w}s\n", r[:name], ruby_s, native_s, pure_s
  end

  # Exit with non-zero if any failed
  exit 1 unless results.all? { |r| r[:native_ok] && r[:pure_ok] }
else
  dest = options[:write_report]
  FileUtils.mkdir_p(File.dirname(dest))

  case File.extname(dest)
  when '.json'
    data = results.map do |r|
      {
        benchmark: r[:name],
        ruby_ms: r[:ruby_ms],
        native_ms: r[:native_ms],
        native_ok: r[:native_ok],
        pure_ms: r[:pure_ms],
        pure_ok: r[:pure_ok]
      }
    end
    File.write(dest, JSON.pretty_generate(data))
  when '.svg'
    row_height = 25
    height     = 40 + row_height * results.size
    svg = +"<svg xmlns='http://www.w3.org/2000/svg' width='500' height='\#{height}'>\n"
    svg << "  <foreignObject width='100%' height='100%'>\n"
    svg << "    <style>table{border-collapse:collapse;font-family:sans-serif;}td,th{border:1px solid #999;padding:4px;}</style>\n"
    svg << "    <table>\n"
    svg << "      <thead><tr><th>Benchmark</th><th>Ruby (ms)</th><th>Native</th><th>Pure</th></tr></thead>\n"
    svg << "      <tbody>\n"
    results.each do |r|
      native_s = r[:native_ok] ? 'OK' : 'FAIL'
      pure_s   = r[:pure_ok] ? 'OK' : 'FAIL'
      svg << "        <tr><td>#{r[:name]}</td><td>#{r[:ruby_ms]}</td><td>#{native_s} #{r[:native_ms]}</td><td>#{pure_s} #{r[:pure_ms]}</td></tr>\n"
    end
    svg << "      </tbody>\n"
    svg << "    </table>\n"
    svg << "  </foreignObject>\n"
    svg << "</svg>\n"
    File.write(dest, svg)
  else
    abort "Unknown report format '\#{dest}'"
  end

  # Warn and exit if any failures
  unless results.all? { |r| r[:native_ok] && r[:pure_ok] }
    warn 'One or more traces differ from reference!'
    exit 1
  end
end
