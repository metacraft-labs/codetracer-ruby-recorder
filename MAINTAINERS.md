# Maintainer Guide

This document collects notes and commands useful when maintaining
`codetracer-ruby-recorder`.

## Development environment

This repository provides a Nix flake for the development shell. With
`direnv` installed, the shell is loaded automatically when you enter the
repository directory. Run `direnv allow` once to enable it.

The same environment is configured for GitHub Codespaces via the
provided devcontainer configuration.

## Building the native extension

The tracer ships with a Rust extension located in `ext/native_tracer`.
To build it locally run:

```bash
just build-extension
```

This compiles the extension in release mode using Cargo. The resulting
shared library is placed under
`ext/native_tracer/target/release/` and is loaded by `gems/codetracer-ruby-recorder/lib/codetracer_ruby_recorder.rb`.

## Running tests

Execute the full test suite with:

```bash
just test
```


The tests run several sample programs from `test/programs` and compare
the generated traces with the fixtures under `test/fixtures`.

## Benchmarking

Run the heavy\_work benchmark with:

```bash
just bench heavy_work
```

Provide a path as a second argument to write a report instead of
printing the runtime:

```bash
just bench heavy_work reports/bench.svg
```

## Publishing gems

Two Ruby gems are published from this repository:

* **codetracer-ruby-recorder** – the tracer with the compiled native
  extension. Prebuilt gems are produced per target platform using
  [`rb_sys`](https://github.com/oxidize-rb/rb-sys).
* **codetracer-pure-ruby-recorder** – a pure Ruby fallback without the
  native extension.

A helper script is available to build and push all gems in one go:

```bash
ruby scripts/publish_gems.rb
```

The list of target triples used by the script lives in
`scripts/targets.txt`. You can override it by passing targets as
arguments to the helper script.

### Native extension gem

1. Install the development dependencies:

   ```bash
   bundle install
   ```

2. For each target platform set `RB_SYS_CARGO_TARGET` and build the gem:

   ```bash
   RB_SYS_CARGO_TARGET=x86_64-unknown-linux-gnu rake cross_native_gem
   ```

   Replace the target triple with the desired platform (for example
   `aarch64-apple-darwin`).

3. Push the generated gem found in `pkg/` to RubyGems:

   ```bash
   gem push pkg/codetracer-ruby-recorder-<version>-x86_64-linux.gem
   ```

Repeat these steps for each supported platform.

Afterwards build a generic gem for the `ruby` platform which installs the
extension at install time:

```bash
rake build
gem push pkg/codetracer-ruby-recorder-<version>.gem
```

### Pure Ruby gem

The pure Ruby tracer is packaged from the files under `src/`. Build and
publish it with:

```bash
gem build codetracer_pure_ruby_recorder.gemspec
gem push codetracer_pure_ruby_recorder-<version>.gem
```

Ensure the version matches the native extension gem so that both
packages can be used interchangeably.

All the above steps are automated by `scripts/publish_gems.rb` which
builds and publishes the pure Ruby gem and all native variants.

### Automated publishing via GitHub Actions

Gems are published automatically when a tag matching `v<version>` is
pushed. The workflow defined in `.github/workflows/publish.yml` checks
that the tag version equals the versions in both gemspecs and then runs
`scripts/publish_gems.rb`.

The workflow requires a RubyGems API key stored as a repository secret
named `RUBYGEMS_API_KEY`. Obtain the key with `gem signin` and copy the
`rubygems_api_key` value from `~/.gem/credentials`. Add it under
`Settings → Secrets and variables → Actions` in the repository so the
workflow can authenticate with RubyGems.

To release a new version:

1. Update the `version` field in both gemspecs.
2. Commit the changes and create an annotated tag `v<version>`.
3. Push the tag to GitHub. The workflow will build and publish the
   gems if the tag matches the versions.
