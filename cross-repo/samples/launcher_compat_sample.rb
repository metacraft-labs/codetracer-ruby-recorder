# frozen_string_literal: true
#
# Sample program for the launcher <-> recorder compatibility E2E.
#
# WHAT THIS IS FOR
#   `codetracer/ci/test/launcher-recorder-e2e.sh` records this file through the
#   REAL `ct` launcher binary:
#
#       ct record launcher_compat_sample.rb -o <trace-dir>
#         -> codetracer-launcher routes `.rb` from the codetracer-desktop
#            capability file and execv()s the desktop core
#            -> the core dispatches `ruby <recorder-script> --out-dir <dir> …`
#               -> codetracer-ruby-recorder writes a CTFS trace
#                  -> `ct-print` (codetracer-trace-format-nim) decodes it
#
#   The driver then asserts the DECODED trace against the expectations declared
#   in `cross-repo/launcher-compat.yml`, so everything this file prints or calls
#   is part of a checked contract.  Changing a method name or a printed line
#   here means changing that file in the same commit.
#
# WHY IT PRINTS `CODETRACER_COMPONENT_DIR`
#   `CODETRACER_COMPONENT_DIR` is exported by the LAUNCHER and by nothing else
#   on this path (codetracer-launcher/src/launcher.nim sets it right before
#   `execv`-ing the component's binary).  Seeing it inside the recorded trace's
#   stdout is therefore positive evidence that the recording really travelled
#   launcher -> desktop core -> recorder, rather than the driver having invoked
#   the core (or the recorder) directly.  A test that only checked "a trace
#   appeared" could not tell those apart.
#
# KEEP THIS PROGRAM BORING
#   Fixed inputs, deterministic output, no clock, no network, no randomness, no
#   gems beyond the stdlib.  The trace it produces is compared against exact
#   expectations; anything non-deterministic would make the gate flaky.

MARKER = 'launcher-recorder-e2e'

# Fixed inputs -- the expected sum below is asserted by the driver.
VALUES = [1, 2, 3, 4, 5].freeze

# Sum `values` with an explicit loop so the trace has real steps.
def accumulate(values)
  total = 0
  values.each do |value|
    total = total + value
  end
  total
end

# Report the component directory the launcher exported for this run.
def describe_launcher_route
  ENV.fetch('CODETRACER_COMPONENT_DIR', '<unset>')
end

def main
  total = accumulate(VALUES)
  puts "#{MARKER}: total=#{total}"
  puts "#{MARKER}: component-dir=#{describe_launcher_route}"
  total
end

main
