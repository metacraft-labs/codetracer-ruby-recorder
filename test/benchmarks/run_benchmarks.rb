#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'benchmark'
require 'optparse'

PROGRAMS_DIR = File.expand_path('programs', __dir__)
FIXTURES_DIR = File.expand_path('fixtures', __dir__)
TMP_DIR = File.expand_path('tmp', __dir__)
WRITE_REPORT_DEFAULT = 'console'

options = { write_report: WRITE_REPORT_DEFAULT }
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby run_benchmarks.rb BENCHMARK_DIR [options]'
  opts.on('--write-report=DEST', 'console or path to .json/.svg report') do |dest|
    options[:write_report] = dest
  end
end.parse!

benchmark_dir = ARGV.shift || abort('Usage: ruby run_benchmarks.rb BENCHMARK_DIR [options]')
unless Dir.exist?(benchmark_dir)
  abort("Benchmark directory not found: #{benchmark_dir}")
end

# Collect benchmark names (file basenames without extension)
benchmarks = Dir.glob(File.join(benchmark_dir, '*.rb')).map { |f| File.basename(f, '.rb') }
if benchmarks.empty?
  abort("No benchmark files (*.rb) found in directory: #{benchmark_dir}")
end

# Compare two files for identical content
def files_identical?(a, b)
  cmp_result = system('cmp', '-s', a, b)
  return $?.success? if !cmp_result.nil?
  File.binread(a) == File.binread(b)
end

# Run a single benchmark by name
def run_benchmark(name, benchmark_dir)
  program      = File.expand_path(File.join(benchmark_dir, "#{name}.rb"))
  fixture      = File.join(FIXTURES_DIR, "#{name}_trace.json")
  output_dir   = File.join(TMP_DIR, name)

  FileUtils.mkdir_p(output_dir)
  raise 'Reference trace unavailable' unless File.exist?(fixture)

  elapsed = Benchmark.realtime do
    system('ruby', File.expand_path('../../gems/pure-ruby-tracer/lib/trace.rb', __dir__),
           '--out-dir', output_dir,
           program)
    raise 'Trace failed' unless $?.success?
  end
  runtime_ms   = (elapsed * 1000).round
  output_trace = File.join(output_dir, 'trace.json')
  success      = files_identical?(fixture, output_trace)
  size_bytes   = File.size(output_trace)

  { name: name, runtime_ms: runtime_ms, trace_size: size_bytes, success: success }
end

# Execute all benchmarks
results = benchmarks.map { |b| run_benchmark(b, benchmark_dir) }

# Reporting
if options[:write_report] == 'console'
  # Determine column widths
  name_w = [ 'Benchmark'.length, *results.map { |r| r[:name].length } ].max
  rt_w   = [ 'Runtime'.length, *results.map { |r| r[:runtime_ms].to_s.length } ].max
  ts_w   = [ 'Trace Size'.length, *results.map { |r| r[:trace_size].to_s.length } ].max

  # Header
  printf "%-#{name_w}s  %#{rt_w}s  %#{ts_w}s  %s\n", 'Benchmark', 'Runtime', 'Trace Size', 'Status'
  puts '-' * (name_w + rt_w + ts_w + 10)

  # Rows
  results.each do |r|
    status = r[:success] ? 'OK' : 'FAIL'
    printf "%-#{name_w}s  %#{rt_w}d ms  %#{ts_w}d  %s\n", r[:name], r[:runtime_ms], r[:trace_size], status
  end

  # Exit with non-zero if any failed
  exit 1 unless results.all? { |r| r[:success] }
else
  dest = options[:write_report]
  FileUtils.mkdir_p(File.dirname(dest))

  case File.extname(dest)
  when '.json'
    data = results.map { |r| { benchmark: r[:name], runtime_ms: r[:runtime_ms], trace_bytes: r[:trace_size] } }
    File.write(dest, JSON.pretty_generate(data))
  when '.svg'
    row_height = 25
    height     = 40 + row_height * results.size
    svg = +"<svg xmlns='http://www.w3.org/2000/svg' width='500' height='\#{height}'>\n"
    svg << "  <foreignObject width='100%' height='100%'>\n"
    svg << "    <style>table{border-collapse:collapse;font-family:sans-serif;}td,th{border:1px solid #999;padding:4px;}</style>\n"
    svg << "    <table>\n"
    svg << "      <thead><tr><th>Benchmark</th><th>Runtime (ms)</th><th>Trace size (bytes)</th><th>Status</th></tr></thead>\n"
    svg << "      <tbody>\n"
    results.each do |r|
      status = r[:success] ? 'OK' : 'FAIL'
      svg << "        <tr><td>#{r[:name]}</td><td>#{r[:runtime_ms]}</td><td>#{r[:trace_size]}</td><td>#{status}</td></tr>\n"
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
  unless results.all? { |r| r[:success] }
    warn 'One or more traces differ from reference!'
    exit 1
  end
end
