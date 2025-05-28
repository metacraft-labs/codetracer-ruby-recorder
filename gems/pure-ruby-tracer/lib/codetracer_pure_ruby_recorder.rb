require_relative 'trace'

# Ruby implementation of the RubyRecorder API used by the native tracer.
# Provides basic tracing controls and serialization using the pure Ruby tracer.
class RubyRecorder
  def initialize(debug: ENV['CODETRACER_RUBY_RECORDER_DEBUG'] == '1')
    @record = $codetracer_record
    @tracer = Tracer.new(@record, debug: debug)
    setup_defaults
  end

  # Enable tracing of Ruby code execution.
  def enable_tracing
    @tracer.activate
  end

  # Disable tracing without discarding collected data.
  def disable_tracing
    @tracer.deactivate
  end

  # Serialize the trace to +out_dir+.
  def flush_trace(out_dir)
    @tracer.stop_tracing
    @record.serialize('', out_dir)
  end

  # Record a custom event at +path+ and +line+ with +content+.
  def record_event(path, line, content)
    @tracer.record_event(["#{path}:#{line}"], content)
  end

  private

  def setup_defaults
    @record.register_call('', 1, '<top-level>', [])
    @tracer.ignore('lib/ruby')
    @tracer.ignore('trace.rb')
    @tracer.ignore('recorder.rb')
    @tracer.ignore('<internal:')
    @tracer.ignore('gems/')
  end
end
