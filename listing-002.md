# Listing 002

This listing continues the inspection by detailing how runtime I/O is captured and how the gem is packaged. We review the output-hooking helpers in `gems/codetracer-ruby-recorder/lib/codetracer/kernel_patches.rb`, the CLI entry script `gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder`, and the gem specification `gems/codetracer-ruby-recorder/codetracer-ruby-recorder.gemspec`.

**File declares MIT license and begins KernelPatches module tracking installed tracers.**
```ruby
# SPDX-License-Identifier: MIT

module CodeTracer
  module KernelPatches
    @@tracers = []
```

**Add a tracer unless already present and store it in the class variable.**
```ruby
    def self.install(tracer)
      return if @@tracers.include?(tracer)
      @@tracers << tracer
```

**When the first tracer is installed, patch Kernel methods.**
```ruby
      if @@tracers.length == 1
        Kernel.module_eval do
```

**Alias original I/O methods so they can be restored later.**
```ruby
          alias_method :codetracer_original_p, :p unless method_defined?(:codetracer_original_p)
          alias_method :codetracer_original_puts, :puts unless method_defined?(:codetracer_original_puts)
          alias_method :codetracer_original_print, :print unless method_defined?(:codetracer_original_print)
```

**Redefine `p` to compute a printable representation and log it.**
```ruby
          define_method(:p) do |*args|
            loc = caller_locations(1, 1).first
            content = if args.length == 1 && args.first.is_a?(Array)
```

**Handle array arguments or multiple values uniformly.**
```ruby
              args.first.map(&:inspect).join("\n")
            else
              args.map(&:inspect).join("\n")
            end
```

**Record the event with all active tracers before delegating.**
```ruby
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, content)
            end
            codetracer_original_p(*args)
          end
```

**Redefine `puts` to capture line-oriented output.**
```ruby
          define_method(:puts) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join("\n"))
            end
```

**Forward `puts` after logging the captured lines.**
```ruby
            codetracer_original_puts(*args)
          end
```

**Redefine `print` to intercept raw output without newlines.**
```ruby
          define_method(:print) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join)
            end
```

**Delegate `print` to the original implementation afterward.**
```ruby
            codetracer_original_print(*args)
          end
        end
      end
    end
```

**Remove a tracer and restore Kernel methods when none remain.**
```ruby
    def self.uninstall(tracer)
      @@tracers.delete(tracer)

      if @@tracers.empty? && Kernel.private_method_defined?(:codetracer_original_p)
        Kernel.module_eval do
          alias_method :p, :codetracer_original_p
          alias_method :puts, :codetracer_original_puts
          alias_method :print, :codetracer_original_print
        end
      end
    end
```

**Provide helper to uninstall every active tracer.**
```ruby
    # Uninstall all active tracers and restore the original Kernel methods.
    def self.reset
      @@tracers.dup.each do |tracer|
        uninstall(tracer)
      end
    end
  end
end
```

**Shebang, license, and comment establish the CLI script.**
```ruby
#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# CLI wrapper for the native tracer
```

**Load the library path and require the main recorder.**
```ruby
lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require 'codetracer_ruby_recorder'
```

**Invoke the argument parser and exit with its status.**
```ruby
exit CodeTracer::RubyRecorder.parse_argv_and_trace_ruby_file(ARGV)
```

**Begin gem specification and compute version from file.**
```ruby
Gem::Specification.new do |spec|
  spec.name          = 'codetracer-ruby-recorder'
  version_file = File.expand_path('../../version.txt', __dir__)
  spec.version       = File.read(version_file).strip
```

**Define authorship metadata for the gem.**
```ruby
  spec.authors       = ['Metacraft Labs']
  spec.email         = ['info@metacraft-labs.com']
```

**Provide summary, description, license, and homepage.**
```ruby
  spec.summary       = 'CodeTracer Ruby recorder with native extension'
  spec.description   = 'Ruby tracer that records execution steps via a Rust native extension.'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/metacraft-labs/codetracer-ruby-recorder'
```

**Enumerate files to include in the gem package.**
```ruby
  spec.files         = Dir[
    'lib/**/*',
    'ext/native_tracer/**/{Cargo.toml,*.rs}',
```

**List native extension build scripts and compiled targets.**
```ruby
    'ext/native_tracer/extconf.rb',
    'ext/native_tracer/target/release/*'
  ]
```

**Configure load paths, extensions, and executable entrypoint.**
```ruby
  spec.require_paths = ['lib']
  spec.extensions    = []
  spec.bindir        = 'bin'
  spec.executables   = ['codetracer-ruby-recorder']
```

**Add development dependency on rb_sys and close specification.**
```ruby
  spec.add_development_dependency 'rb_sys', '~> 0.9'
end
```
