# frozen_string_literal: true

require 'open3'

# Locale-independent reading of text the recorders and `ct-print` produce.
#
# Every file and stream this suite reads back -- `ct-print`'s JSON, the pure
# recorder's `trace.json`, the fixtures, a traced program's stdout -- is
# UTF-8 (JSON is UTF-8: RFC 8259 §8.1,
# https://www.rfc-editor.org/rfc/rfc8259#section-8.1), except that
# `ct-print --json-events` embeds each value's raw CBOR bytes in a JSON
# string. Ruby, however, tags data read from a file or a pipe with
# `Encoding.default_external`, which it derives from the process locale
# (https://docs.ruby-lang.org/en/3.4/Encoding.html#class-Encoding-label-Default+External+Encoding).
# Under `LC_ALL=C`, or on a host with no UTF-8 locale such as the macOS CI
# runner, that is US-ASCII, and `JSON.parse` then fails to transcode the first
# byte above 0x7F (`Encoding::InvalidByteSequenceError: "\xA3" on US-ASCII`,
# the CBOR header of a three-entry map).
#
# The helpers below label the bytes as UTF-8 without transcoding, validating
# or repairing them, so every locale reads exactly what a UTF-8 locale reads.
# Files stay in text mode, so Windows newline conversion is unchanged.
module Utf8IO
  module_function

  # Contents of +path+, tagged UTF-8.
  def read(path)
    File.read(path, encoding: Encoding::UTF_8)
  end

  # Lines of +path+, tagged UTF-8 (same keyword arguments as `File.readlines`).
  def readlines(path, **opts)
    File.readlines(path, encoding: Encoding::UTF_8, **opts)
  end

  # A copy of +text+ (e.g. a subprocess's captured stdout) tagged UTF-8.
  def text(text)
    text.dup.force_encoding(Encoding::UTF_8)
  end

  # `Open3.capture3` with stdout and stderr tagged UTF-8.
  def capture3(*cmd, **opts)
    stdout, stderr, status = Open3.capture3(*cmd, **opts)
    [text(stdout), text(stderr), status]
  end
end
