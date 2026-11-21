#!/usr/bin/env bash
# repro.nim reads this project's files through activeProviderProjectRoot(),
# never through the working directory.
#
# A consumer such as CodeTracer evaluates this recipe as a cross-repo producer
# from its own root, so a bare `readFile("version.txt")` in the build: body read
# the consumer's directory and failed: every CodeTracer build printed
# "repro project provider: startup body failed: codetracer_ruby_recorder:
# cannot open: version.txt". Asserted:
#
#   1. No file-reading call in repro.nim names a literal relative path.
#   2. Negative control: the same matcher flags the line that failed, so a
#      green leg 1 is not a matcher that flags nothing.
#
# A static check, not a provider run: this repository has no Nim harness that
# compiles the recipe in provider mode, and the provider's startup pass is what
# the failure came from. The read itself is exercised by every `repro build`.
#
#   bash tests/test_recipe_reads_project_files_from_its_root.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# A call that reads or probes a file, given a string literal that is not absolute.
pattern='(readFile|readLines|lines|fileExists|dirExists|symlinkExists|getFileInfo|getLastModificationTime|open)\("[^/"]'

if hits="$(grep -nE "$pattern" "$REPO/repro.nim")"; then
  fail "repro.nim reads files relative to the working directory; join them onto activeProviderProjectRoot():
$hits"
fi
echo "ok: repro.nim reads no file relative to the working directory"

failed_line='outputs = @["gems/codetracer-ruby-recorder/codetracer-ruby-recorder-" & readFile("version.txt").strip & ".gem",'
grep -qE "$pattern" <<<"$failed_line" || fail "the matcher does not flag the line that failed"
echo "ok: the matcher flags a working-directory read"
