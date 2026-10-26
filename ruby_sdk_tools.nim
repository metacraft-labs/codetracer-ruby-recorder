## Supported repo-owned SDK view; original Ruby and Gem executables remain in
## this immutable prefix for Cargo and real installation subprocesses.
import blake3
import repro_project_dsl

const sdkSourceBytes = staticRead("tools/ruby-sdk/default.nix") & "\0" & staticRead("flake.lock")
let sdkSourceIdentity = blake3.toHex(blake3.digest(sdkSourceBytes))

package `ruby-recorder-sdk`:
  provisioning:
    nixPackage "codetracer-ruby-recorder-sdk", executablePath = "bin/ruby",
      expressionFile = "tools/ruby-sdk/default.nix",
      lockIdentity = "owning-ruby-flake-lock:ruby3.4.8+minitest+rack+sinatra+rails:" & sdkSourceIdentity
