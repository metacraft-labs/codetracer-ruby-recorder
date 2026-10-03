# SPDX-License-Identifier: MIT

module CodeTracer
  module KernelPatches
    @@tracers = []
    STDOUT_CAPTURE_GUARD = :codetracer_stdout_capture_suppressed

    # Delegate to the real IO writer. Ruby puts/print pass their actual
    # converted chunks here, so newline/array formatting remains Ruby's own.
    module StdoutWrites
      def write(*values)
        return super unless equal?($stdout) && KernelPatches.capture_stdout?

        strings = values.map { |value| value.is_a?(String) ? value : format('%s', value) }
        result = super(*strings)
        location = caller_locations(1, 1).first
        KernelPatches.record_stdout(location, strings.join)
        result
      end
    end

    def self.capture_stdout?
      !@@tracers.empty? && !Thread.current.thread_variable_get(STDOUT_CAPTURE_GUARD)
    end

    def self.without_stdout_capture
      previous = Thread.current.thread_variable_get(STDOUT_CAPTURE_GUARD)
      Thread.current.thread_variable_set(STDOUT_CAPTURE_GUARD, true)
      yield
    ensure
      Thread.current.thread_variable_set(STDOUT_CAPTURE_GUARD, previous)
    end

    def self.record_stdout(location, content)
      # Snapshot registration before callbacks; no mutable iteration and no
      # lock held while recording. The guard is per-thread and exception-safe.
      tracers = @@tracers.dup
      without_stdout_capture do
        tracers.each { |tracer| tracer.record_event(location.path, location.lineno, content) }
      end
    end

    def self.install(tracer)
      return if @@tracers.include?(tracer)
      @@tracers << tracer
      IO.prepend(StdoutWrites) unless IO.ancestors.include?(StdoutWrites)

      if @@tracers.length == 1
        Kernel.module_eval do
          alias_method :codetracer_original_p, :p unless method_defined?(:codetracer_original_p)
          alias_method :codetracer_original_puts, :puts unless method_defined?(:codetracer_original_puts)
          alias_method :codetracer_original_print, :print unless method_defined?(:codetracer_original_print)

          define_method(:p) do |*args|
            loc = caller_locations(1, 1).first
            content = if args.length == 1 && args.first.is_a?(Array)
              args.first.map(&:inspect).join("\n") + "\n"
            else
              args.map(&:inspect).join("\n") + "\n"
            end
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, content)
            end
            KernelPatches.without_stdout_capture { codetracer_original_p(*args) }
          end

          define_method(:puts) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join("\n") + "\n")
            end
            KernelPatches.without_stdout_capture { codetracer_original_puts(*args) }
          end

          define_method(:print) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join)
            end
            KernelPatches.without_stdout_capture { codetracer_original_print(*args) }
          end
        end
      end
    end

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

    # Uninstall all active tracers and restore the original Kernel methods.
    def self.reset
      @@tracers.dup.each do |tracer|
        uninstall(tracer)
      end
    end
  end
end
