#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'benchmark'
require 'optparse'

HASHES = {
  'heavy_work' => '912fc0347cb8a57abd94a7defd76b147f3a79e556745e45207b89529f8a59d8b'
}.freeze

PROGRAMS_DIR = File.expand_path('programs', __dir__)
FIXTURES_DIR = File.expand_path('fixtures', __dir__)
TMP_DIR = File.expand_path('tmp', __dir__)

WRITE_REPORT_DEFAULT = 'console'

options = { write_report: WRITE_REPORT_DEFAULT }
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby run_benchmark.rb BENCHMARK_NAME [options]'
  opts.on('--write-report=DEST', 'console or path to .json/.svg report') do |dest|
    options[:write_report] = dest
  end
end.parse!

def files_identical?(a, b)
  cmp_result = system('cmp', '-s', a, b)
  return $?.success? if !cmp_result.nil?
  File.binread(a) == File.binread(b)
end

def run_benchmark(name)
  program = File.join('test', 'benchmarks', 'programs', "#{name}.rb")
  fixture = File.expand_path("fixtures/#{name}_trace.json", __dir__)
  output_dir = File.join(TMP_DIR, name)
  expected_hash = HASHES[name]

  FileUtils.mkdir_p(TMP_DIR)
  FileUtils.mkdir_p(output_dir)

  unless File.exist?(fixture) && Digest::SHA256.file(fixture).hexdigest == expected_hash
    warn 'Reference trace missing or corrupt. Attempting to fetch via git lfs...'
    system('git', 'lfs', 'pull', '--include', fixture)
  end

  raise 'reference trace unavailable' unless File.exist?(fixture)
  raise 'reference trace hash mismatch' unless Digest::SHA256.file(fixture).hexdigest == expected_hash

  elapsed = Benchmark.realtime do
    system('ruby', File.expand_path('../../gems/pure-ruby-tracer/lib/trace.rb', __dir__), '--out-dir', output_dir, program)
    raise 'trace failed' unless $?.success?
  end
  runtime_ms = (elapsed * 1000).round

  output_trace = File.join(output_dir, 'trace.json')
  success = files_identical?(fixture, output_trace)
  size_bytes = File.size(output_trace)

  { name: name, runtime_ms: runtime_ms, trace_size: size_bytes, success: success }
end

if options[:write_report] == 'console'
  bench = ARGV.shift || abort('Usage: ruby run_benchmark.rb BENCHMARK_NAME [options]')
  abort("Unknown benchmark '#{bench}'") unless HASHES.key?(bench)
  result = run_benchmark(bench)
  puts "Benchmark runtime: #{result[:runtime_ms]} ms"
  if result[:success]
    puts 'Trace matches reference.'
  else
    warn 'Trace differs from reference!'
    exit 1
  end
else
  benches = ARGV.empty? ? HASHES.keys.sort : ARGV
  benches.each { |b| abort("Unknown benchmark '#{b}'") unless HASHES.key?(b) }
  results = benches.map { |b| run_benchmark(b) }

  dest = options[:write_report]
  FileUtils.mkdir_p(File.dirname(dest))
  case File.extname(dest)
  when '.json'
    data = results.map { |r| { benchmark: r[:name], runtime_ms: r[:runtime_ms], trace_bytes: r[:trace_size] } }
    File.write(dest, JSON.pretty_generate(data))
  when '.svg'
    row_height = 25
    height = 40 + row_height * results.size
    svg = +"<svg xmlns='http://www.w3.org/2000/svg' width='500' height='#{height}'>\n"
    svg << "  <foreignObject width='100%' height='100%'>\n"
    svg << "    <style>table{border-collapse:collapse;font-family:sans-serif;}td,th{border:1px solid #999;padding:4px;}</style>\n"
    svg << "    <table>\n"
    svg << "      <thead><tr><th>Benchmark</th><th>Runtime (ms)</th><th>Trace size (bytes)</th></tr></thead>\n"
    svg << "      <tbody>\n"
    results.each do |r|
      svg << "        <tr><td>#{r[:name]}</td><td>#{r[:runtime_ms]}</td><td>#{r[:trace_size]}</td></tr>\n"
    end
    svg << "      </tbody>\n"
    svg << "    </table>\n"
    svg << "  </foreignObject>\n"
    svg << "</svg>\n"
    File.write(dest, svg)
  else
    abort "Unknown report format '#{dest}'"
  end

  unless results.all? { |r| r[:success] }
    warn 'One or more traces differ from reference!'
    exit 1
  end
end

