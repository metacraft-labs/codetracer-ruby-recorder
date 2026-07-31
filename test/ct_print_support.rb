# frozen_string_literal: true

# Locating `ct-print`, shared by every suite that needs to read a `.ct`
# container back.
#
# `ct-print` ships with codetracer-trace-format-nim and is the CANONICAL
# decoder for CTFS containers.  Tests decode through it (rather than through a
# test-local reader) so a writer bug cannot be confirmed by a second
# implementation that happens to agree with it.
module CtPrintSupport
  # Path to the `ct-print` binary: an explicit `CT_PRINT`, else the first one
  # on `PATH`, else the sibling checkout.  `RbConfig`'s `EXEEXT` is "" on Unix
  # and ".exe" on Windows so the fallback resolves on every platform.
  CT_PRINT = ENV['CT_PRINT'] ||
             ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
                        .map { |dir| File.join(dir, "ct-print#{RbConfig::CONFIG['EXEEXT']}") }
                        .find { |path| File.executable?(path) } ||
             File.expand_path("../../codetracer-trace-format-nim/ct-print#{RbConfig::CONFIG['EXEEXT']}",
                              __dir__)

  # Decode the event stream of the container at +ct_file+.
  #
  # The output is read as bytes and scrubbed before parsing: `ct-print`
  # embeds each value's raw CBOR blob as a JSON string, so its stdout is not
  # guaranteed to be valid UTF-8.
  def ct_print_events(ct_file)
    stdout, stderr, status = Open3.capture3(CT_PRINT, '--json-events', ct_file)
    raise "ct-print failed for #{ct_file}: #{stderr}" unless status.success?

    JSON.parse(stdout.dup.force_encoding(Encoding::BINARY).scrub('?'))
  end
end
