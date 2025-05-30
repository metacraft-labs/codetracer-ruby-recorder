# SPDX-License-Identifier: MIT

module Codetracer
  module KernelPatches
    @@tracers = []

    def self.install(tracer)
      @@tracers << tracer

      if @@tracers.length == 1
        Kernel.module_eval do
          alias_method :codetracer_original_p, :p unless method_defined?(:codetracer_original_p)
          alias_method :codetracer_original_puts, :puts unless method_defined?(:codetracer_original_puts)
          alias_method :codetracer_original_print, :print unless method_defined?(:codetracer_original_print)

          define_method(:p) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.map(&:inspect).join("\n"))
            end
            codetracer_original_p(*args)
          end

          define_method(:puts) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join("\n"))
            end
            codetracer_original_puts(*args)
          end

          define_method(:print) do |*args|
            loc = caller_locations(1, 1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join)
            end
            codetracer_original_print(*args)
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

          remove_method :codetracer_original_p
          remove_method :codetracer_original_puts
          remove_method :codetracer_original_print
        end
      end
    end
  end
end
