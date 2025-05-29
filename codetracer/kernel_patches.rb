# SPDX-License-Identifier: MIT

module Codetracer
  module KernelPatches
    @@tracers = []
    @@original_methods = {}

    def self.install(tracer)
      @@tracers << tracer

      if @@original_methods.empty?
        @@original_methods[:p] = Kernel.instance_method(:p)
        @@original_methods[:puts] = Kernel.instance_method(:puts)
        @@original_methods[:print] = Kernel.instance_method(:print)

        Kernel.module_eval do
          define_method(:p) do |*args|
            loc = caller_locations(1,1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.map(&:inspect).join("\n"))
            end
            @@original_methods[:p].bind(self).call(*args)
          end

          define_method(:puts) do |*args|
            loc = caller_locations(1,1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join("\n"))
            end
            @@original_methods[:puts].bind(self).call(*args)
          end

          define_method(:print) do |*args|
            loc = caller_locations(1,1).first
            @@tracers.each do |t|
              t.record_event(loc.path, loc.lineno, args.join("\n"))
            end
            @@original_methods[:print].bind(self).call(*args)
          end
        end
      end
    end

    def self.uninstall(tracer)
      @@tracers.delete(tracer)

      if @@tracers.empty? && !@@original_methods.empty?
        Kernel.module_eval do
          define_method(:p, @@original_methods[:p])
          define_method(:puts, @@original_methods[:puts])
          define_method(:print, @@original_methods[:print])
        end
        @@original_methods.clear
      end
    end
  end
end
