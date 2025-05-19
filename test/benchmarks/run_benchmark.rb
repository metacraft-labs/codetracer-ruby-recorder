require 'json'
require 'fileutils'
require 'digest'
require 'benchmark'

USAGE = "Usage: ruby run_benchmark.rb BENCHMARK_NAME"

BENCHMARK = ARGV.shift || abort(USAGE)
HASHES = {
  'heavy_work' => '912fc0347cb8a57abd94a7defd76b147f3a79e556745e45207b89529f8a59d8b'
}

unless HASHES.key?(BENCHMARK)
  abort("Unknown benchmark '#{BENCHMARK}'")
end

PROGRAM = File.join('test', 'benchmarks', 'programs', "#{BENCHMARK}.rb")
FIXTURE = File.expand_path("fixtures/#{BENCHMARK}_trace.json", __dir__)
TMP_DIR = File.expand_path('tmp', __dir__)
OUTPUT_DIR = File.join(TMP_DIR, BENCHMARK)
EXPECTED_HASH = HASHES[BENCHMARK]

FileUtils.mkdir_p(TMP_DIR)
FileUtils.mkdir_p(OUTPUT_DIR)

unless File.exist?(FIXTURE) && Digest::SHA256.file(FIXTURE).hexdigest == EXPECTED_HASH
  warn "Reference trace missing or corrupt. Attempting to fetch via git lfs..."
  system('git', 'lfs', 'pull', '--include', FIXTURE)
end

raise 'reference trace unavailable' unless File.exist?(FIXTURE)
raise 'reference trace hash mismatch' unless Digest::SHA256.file(FIXTURE).hexdigest == EXPECTED_HASH

elapsed = Benchmark.realtime do
  system('ruby', File.expand_path('../../gems/pure-ruby-tracer/lib/trace.rb', __dir__), '--out-dir', OUTPUT_DIR, PROGRAM)
  raise 'trace failed' unless $?.success?
end
puts "Benchmark runtime: #{(elapsed * 1000).round} ms"

def files_identical?(a, b)
  cmp_result = system('cmp', '-s', a, b)
  return $?.success? if !cmp_result.nil?
  File.binread(a) == File.binread(b)
end

OUTPUT_TRACE = File.join(OUTPUT_DIR, 'trace.json')
if files_identical?(FIXTURE, OUTPUT_TRACE)
  puts 'Trace matches reference.'
else
  warn 'Trace differs from reference!'
  exit 1
end
