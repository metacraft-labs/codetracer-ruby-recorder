# Listing 001

This listing introduces the development environment for **codetracer-ruby-recorder**. We review documentation for installation and environment variables (`README.md`), project dependencies (`Gemfile`), build and test tasks (`Rakefile` and `Justfile`), and then walk through the primary `RubyRecorder` class that powers the native tracer.

**Project heading states this gem records Ruby programs to produce CodeTracer traces.**
```markdown
## codetracer-ruby-recorder

A recorder of Ruby programs that produces [CodeTracer](https://github.com/metacraft-labs/CodeTracer) traces.
```

**Installation instructions show gem installation and fallback to pure Ruby version.**
```bash
gem install codetracer-ruby-recorder
gem install codetracer-pure-ruby-recorder
```

**Environment variables toggle debug logging and specify trace output directory.**
```markdown
* if you pass `CODETRACER_RUBY_RECORDER_DEBUG=1`, you enable some additional debug-related logging
* `CODETRACER_RUBY_RECORDER_OUT_DIR` can be used to specify the directory for trace files
```

**Development setup suggests installing debugging gems and running tests manually.**
```bash
gem install debug pry
ruby -I lib -I test test/test_tracer.rb
```

**Gemfile sets source and references both native and pure-Ruby recorder gems locally.**
```ruby
# frozen_string_literal: true
source "https://rubygems.org"

gem "codetracer-ruby-recorder", path: "gems/codetracer-ruby-recorder"
gem "codetracer-pure-ruby-recorder", path: "gems/codetracer-pure-ruby-recorder"
```

**Optional development gems for debugging are commented out; rubocop is included for development.**
```ruby
# gem "debug", "~> 1.7"      # Ruby debugging with rdbg
# gem "pry", "~> 0.14"       # Interactive debugging and REPL
gem "rubocop", "~> 1.77", :group => :development
```

**Rakefile loads rb_sys extension task.**
```ruby
require 'rb_sys/extensiontask'
```

**Extension task configuration specifies build and library directories.**
```ruby
RbSys::ExtensionTask.new('codetracer_ruby_recorder') do |ext|
  ext.ext_dir = 'gems/codetracer-ruby-recorder/ext/native_tracer'
  ext.lib_dir = 'gems/codetracer-ruby-recorder/lib'
  ext.gem_spec = Gem::Specification.load('gems/codetracer-ruby-recorder/codetracer-ruby-recorder.gemspec')
end
```

**Alias for running tests and the test command executes installation checks and unit tests.**
```make
alias t := test
test:
    ruby -Itest test/gem_installation.rb
    ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'
```

**Benchmark task runs benchmarks with pattern and report options.**
```make
bench pattern="*" write_report="console":
    ruby test/benchmarks/run_benchmarks.rb '{{pattern}}' --write-report={{write_report}}
```

**Build native extension via Cargo.**
```make
build-extension:
    cargo build --release --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml
```

**Formatting tasks for Rust, Nix, and Ruby.**
```make
format-rust:
    cargo fmt --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml

format-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt; fi

format-ruby:
    if command -v bundle >/dev/null && bundle exec rubocop -v >/dev/null 2>&1; then bundle exec rubocop -A; else echo "Ruby formatter not available; skipping"; fi
```

**Aggregate formatting and linting tasks with an alias.**
```make
format:
    just format-rust
    just format-ruby
    just format-nix

lint-rust:
    cargo fmt --check --manifest-path gems/codetracer-ruby-recorder/ext/native_tracer/Cargo.toml

lint-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt --check; fi

lint-ruby:
    if command -v bundle >/dev/null && bundle exec rubocop -v >/dev/null 2>&1; then bundle exec rubocop; else echo "rubocop not available; skipping"; fi

lint:
    just lint-rust
    just lint-ruby
    just lint-nix

alias fmt := format
```

**Header comments declare license and purpose.**
```ruby
# SPDX-License-Identifier: MIT
# Library providing a helper method to execute the native tracer.
```

**Load option parsing, file utilities, configuration, and kernel patches.**
```ruby
require 'optparse'
require 'fileutils'
require 'rbconfig'
require_relative 'codetracer/kernel_patches'
```

**Define RubyRecorder inside CodeTracer module.**
```ruby
module CodeTracer
  class RubyRecorder
```

**Begin parsing CLI arguments and set up OptionParser.**
```ruby
    def self.parse_argv_and_trace_ruby_file(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = 'usage: codetracer-ruby-recorder [options] <program> [args]'
```

**Accept output directory and format options.**
```ruby
        opts.on('-o DIR', '--out-dir DIR', 'Directory to write trace files') do |dir|
          options[:out_dir] = dir
        end
        opts.on('-f FORMAT', '--format FORMAT', 'trace format: json or binary') do |fmt|
          options[:format] = fmt
        end
```

**Provide help flag and finalize option parsing.**
```ruby
        opts.on('-h', '--help', 'Print this help') do
          puts opts
          exit
        end
      end
      parser.order!(argv)
```

**Extract program argument and handle missing program.**
```ruby
      program = argv.shift
      if program.nil?
        $stderr.puts parser
        exit 1
      end
```

**Capture remaining program arguments and determine output directory and format.**
```ruby
      # Remaining arguments after the program name are passed to the traced program
      program_args = argv.dup

      out_dir = options[:out_dir] || ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] || Dir.pwd
      format = (options[:format] || 'json').to_sym
      trace_ruby_file(program, out_dir, program_args, format)
      0
    end
```

**Trace specified Ruby file with selected options.**
```ruby
    def self.trace_ruby_file(program, out_dir, program_args = [], format = :json)
      recorder = RubyRecorder.new(out_dir, format)
      return 1 unless recorder.available?

      ENV['CODETRACER_RUBY_RECORDER_OUT_DIR'] = out_dir
```

**Execute program under recorder, adjusting ARGV temporarily.**
```ruby
      recorder.start
      begin
        # Set ARGV to contain the program arguments
        original_argv = ARGV.dup
        ARGV.clear
        ARGV.concat(program_args)

        load program
      ensure
        # Restore original ARGV
        ARGV.clear
        ARGV.concat(original_argv)

        recorder.stop
        recorder.flush_trace
      end
      0
    end
```

**Entry point to run CLI logic.**
```ruby
    # Execute the native tracer CLI logic with the provided +argv+.
    def self.execute(argv)
      parse_argv_and_trace_ruby_file(argv)
    end
```

**Initialize recorder and load native implementation.**
```ruby
    def initialize(out_dir, format = :json)
      @recorder = nil
      @active = false
      load_native_recorder(out_dir, format)
    end
```

**Start recording and apply kernel patches if not already active.**
```ruby
    # Start the recorder and install kernel patches
    def start
      return if @active || @recorder.nil?

      @recorder.enable_tracing
      CodeTracer::KernelPatches.install(self)
      @active = true
    end
```

**Stop recording and remove patches.**
```ruby
    # Stop the recorder and remove kernel patches
    def stop
      return unless @active

      CodeTracer::KernelPatches.uninstall(self)
      @recorder.disable_tracing if @recorder
      @active = false
    end
```

**Delegate recording events to native recorder.**
```ruby
    # Record event for kernel patches integration
    def record_event(path, line, content)
      @recorder.record_event(path, line, content) if @recorder
    end
```

**Flush trace data and report availability.**
```ruby
    # Flush trace to output directory
    def flush_trace
      @recorder.flush_trace if @recorder
    end

    # Check if recorder is available
    def available?
      !@recorder.nil?
    end
```

**Mark following methods as private and begin loading native recorder.**
```ruby
    private

    def load_native_recorder(out_dir, format = :json)
      begin
        # Load native extension at module level
```

**Resolve extension directory and target library path based on platform.**
```ruby
        ext_dir = File.expand_path('../ext/native_tracer/target/release', __dir__)
        dlext = RbConfig::CONFIG['DLEXT']
        target_path = File.join(ext_dir, "codetracer_ruby_recorder.#{dlext}")
        unless File.exist?(target_path)
          extensions = %w[so bundle dylib dll]
```

**Search for alternative library names and create symlink or copy as needed.**
```ruby
          alt_path = extensions
                    .map { |ext| File.join(ext_dir, "libcodetracer_ruby_recorder.#{ext}") }
                    .find { |path| File.exist?(path) }
          if alt_path
            begin
              File.symlink(alt_path, target_path)
            rescue StandardError
              FileUtils.cp(alt_path, target_path)
            end
          end
        end
```

**Load library and build recorder instance.**
```ruby
        require target_path
        @recorder = CodeTracerNativeRecorder.new(out_dir, format)
```

**On errors, emit warning and fall back to nil recorder.**
```ruby
      rescue Exception => e
        warn "native tracer unavailable: #{e}"
        @recorder = nil
      end
    end
```

**Terminate the RubyRecorder class and CodeTracer module.**
```ruby
  end
end
```
