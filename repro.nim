## Native Ruby shipping and complete integration graph.
## Approved contract: codetracer-pm/spec/Testing/Ruby-Repro-Graph-Equivalence.md.
## Test interpreters execute unchanged real suites; compilation uses typed Cargo
## and owning Nim producer actions, with a typed filesystem artifact transform.
import std/[os, strutils]
import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import ruby_sdk_tools
import "../codetracer-trace-format-nim/build_writer_artifacts"

proc rubyAction(tool, id: string; args: seq[string];
                after: seq[BuildActionDef]; inputs: seq[string];
                outputs: seq[string] = @[];
                extraEnv: seq[(string, string)] = @[];
                refs: seq[string] = @[]): BuildActionDef =
  let call = publicCliCall(tool, tool, "", id & ".invoke", @[
    cliArgSeq("args", args, kind = cpkPositional)])
  result = buildAction(id, call, deps = combineActionDeps([], after),
    inputs = inputs, outputs = outputs, declaredOutputs = outputs,
    toolIdentityRefs = @[tool] & refs,
    dependencyPolicy = automaticMonitorPolicy(), env = extraEnv,
    scratchDirs = @["test/tmp", ".repro/build/ruby-test-tmp"],
    cacheable = false)

package codetracer_ruby_recorder:
  uses:
    "rustc >=1.85"
    "cargo >=1.85"
    "ruby-recorder-sdk"
    "nim >=2.2 <3.0"
    "nimble"
    "git"
    "bash"
    "just"
    "cp"
    "mv"
    "rm"
    "readlink"
    "dirname"
    "grep"
    "capnp"
    "zstd"
    when defined(linux):
      "gcc"
      "clang"
    elif defined(macosx):
      "clang"
    when not defined(windows):
      "pkg-config"
      "openssl"
    when defined(windows):
      "gcc"
      "chocolatey"

  library codetracerRubyRecorder

  devEnv:
    when not defined(windows):
      useFlakeDevShell()
    activity "default"

  build:
    const root = "gems/codetracer-ruby-recorder/ext/native_tracer"
    const manifest = root / "Cargo.toml"
    const releaseRoot = root / "target/release"
    const rawBinary =
      when defined(windows): root / "target/x86_64-pc-windows-gnu/release/codetracer_ruby_recorder.dll"
      elif defined(macosx): releaseRoot / "libcodetracer_ruby_recorder.dylib"
      else: releaseRoot / "libcodetracer_ruby_recorder.so"
    # Actual Ruby platform ABI is checked below rather than silently falling
    # back to .so. Darwin's Ruby loader uses .bundle; Cargo emits .dylib.
    const dlext = (when defined(macosx): "bundle" else: "so")
    const extension = releaseRoot / ("codetracer_ruby_recorder." & dlext)
    const nimRoot = "../codetracer-trace-format-nim"
    let cargoInputs = @[manifest, root / "Cargo.lock", root / "src",
      "../codetracer-trace-format/Cargo.toml", "../codetracer-trace-format/src",
      "../codetracer-trace-format/codetracer_trace_writer_nim",
      nimRoot / "src", nimRoot / "include", nimRoot / "build_ffi.nims",
      nimRoot / "build_ffi_flags.nim"]
    let buildEnv =
      when defined(windows): @[("CARGO_BUILD_TARGET", "x86_64-pc-windows-gnu")]
      else: newSeq[(string, string)]()
    let extensionBuild = cargo.build(release = true, manifestPath = manifest,
      actionId = "codetracer-ruby-recorder.cargo-build",
      extraInputs = cargoInputs, extraOutputs = @[rawBinary], extraEnv = buildEnv)
    for action in [extensionBuild]:
      appendRegisteredActionToolIdentityRefs(action.id,
        ["cargo", "rustc", "ruby-recorder-sdk", "nim", "nimble", "git", "capnp", "zstd"])
      when defined(linux):
        appendRegisteredActionToolIdentityRefs(action.id, ["gcc", "clang", "pkg-config", "openssl"])
      elif defined(macosx):
        appendRegisteredActionToolIdentityRefs(action.id, ["clang", "pkg-config", "openssl"])
      else:
        appendRegisteredActionToolIdentityRefs(action.id, ["gcc"])
    let extensionCopy = fs.copyFile(source = rawBinary, output = extension,
      actionId = "codetracer-ruby-recorder.ruby-extension-artifact",
      after = @[extensionBuild])
    discard collect("default", @[extensionCopy])

    let testsBuild = cargo.test(noRun = true, manifestPath = manifest,
      actionId = "codetracer-ruby-recorder.cargo-test-build",
      after = @[extensionBuild], extraInputs = cargoInputs,
      extraOutputs = @[root / "target/debug/deps"])
    let testsRun = cargo.test(manifestPath = manifest,
      actionId = "codetracer-ruby-recorder.cargo-test-run",
      after = @[testsBuild.action],
      extraInputs = cargoInputs & @[root / "target/debug/deps"])
    for action in [testsBuild.action, testsRun.action]:
      appendRegisteredActionToolIdentityRefs(action.id,
        ["cargo", "rustc", "ruby-recorder-sdk", "nim", "nimble", "git", "capnp", "zstd"])
      when defined(linux):
        appendRegisteredActionToolIdentityRefs(action.id, ["gcc", "clang", "pkg-config", "openssl"])
      elif defined(macosx):
        appendRegisteredActionToolIdentityRefs(action.id, ["clang", "pkg-config", "openssl"])
      else:
        appendRegisteredActionToolIdentityRefs(action.id, ["gcc"])

    let decoder = buildCtPrint(nimRoot)
    let testInputs = @["test/*.rb", "test/programs", "test/fixtures",
      "gems/*/*.gemspec", "gems/*/lib", "gems/*/bin",
      "gems/*/README.md", "gems/codetracer-ruby-recorder/ext/native_tracer/extconf.rb",
      "tests", "Justfile", "version.txt",
      "Gemfile", "Gemfile.lock", extension, ctPrintPath(nimRoot)]
    let testEnv = @[("TMPDIR", activeProviderProjectRoot() / ".repro/build/ruby-test-tmp")]
    # This checks the actual supplied Ruby ABI; a mismatch is an explicit
    # provisioning failure, never an ambient Ruby fallback or skipped suite.
    let abi = rubyAction("ruby-recorder-sdk", "codetracer-ruby-recorder.ruby-abi", @[
      "-rrbconfig", "-e", "abort('Ruby version mismatch') unless RUBY_VERSION == '3.4.8'; abort('Ruby DLEXT mismatch') unless RbConfig::CONFIG.fetch('DLEXT') == '" & dlext & "'"],
      @[extensionCopy, decoder], @[extension, ctPrintPath(nimRoot)])
    let gemCompilerRefs =
      when defined(linux): @["gcc", "clang", "pkg-config", "openssl"]
      elif defined(macosx): @["clang", "pkg-config", "openssl"]
      else: @["gcc"]
    let gemInstall = rubyAction("ruby-recorder-sdk", "codetracer-ruby-recorder.gem-installation",
      @["-Itest", "test/gem_installation.rb"], @[abi, testsRun.action], testInputs,
      outputs = @["gems/codetracer-ruby-recorder/codetracer-ruby-recorder-" & readFile("version.txt").strip & ".gem",
        "gems/codetracer-pure-ruby-recorder/codetracer-pure-ruby-recorder-" & readFile("version.txt").strip & ".gem"],
      extraEnv = testEnv,
      refs = @["just", "cargo", "rustc", "nim", "nimble", "git", "bash",
        "capnp", "zstd", "cp", "mv", "rm", "readlink"] & gemCompilerRefs)
    let fullRuby = rubyAction("ruby-recorder-sdk", "codetracer-ruby-recorder.ruby-full-suite",
      @["-Itest", "-e", "Dir[\"test/test_*.rb\"].each { |f| require File.expand_path(f) }"],
      @[gemInstall], testInputs, extraEnv = testEnv)
    let guard = rubyAction("bash", "codetracer-ruby-recorder.cli-convention",
      @["tests/verify-cli-convention-no-silent-skip.sh"], @[fullRuby], testInputs,
      refs = @["ruby-recorder-sdk", "dirname", "grep"])
    discard collect("test", @[guard])
    # Preserve the previously published Cargo-only alias for existing callers.
    # The full canonical named collection remains .#test, unshadowed by test/.
    discard collect("cargo-test", @[testsRun.action])
