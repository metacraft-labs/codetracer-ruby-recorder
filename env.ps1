# codetracer-ruby-recorder Windows dev environment (PowerShell)
# Usage: . .\env.ps1

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$scriptDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "non-nix-build\windows"

# Parse toolchain versions
$toolchainFile = Join-Path $scriptDir "toolchain-versions.env"
$toolchain = @{}
Get-Content $toolchainFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        $toolchain[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$installRoot = if ($env:WINDOWS_DIY_INSTALL_ROOT) { $env:WINDOWS_DIY_INSTALL_ROOT }
               else { Join-Path $env:LOCALAPPDATA "codetracer/windows-diy" }
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

$arch = if ((Get-CimInstance Win32_ComputerSystem).SystemType -match "ARM") { "arm64" } else { "x64" }

# --- Ensure Rust ---
$rustupHome = Join-Path $installRoot "rustup"
$cargoHome = Join-Path $installRoot "cargo"
$env:RUSTUP_HOME = $rustupHome
$env:CARGO_HOME = $cargoHome
$rustcExe = Join-Path $cargoHome "bin/rustc.exe"
$rustupExe = Join-Path $cargoHome "bin/rustup.exe"
$rustToolchain = $toolchain["RUST_TOOLCHAIN_VERSION"]

$needRust = $true
if (Test-Path $rustcExe) {
    $rustcVer = (& $rustcExe --version 2>&1)
    if ($rustcVer -match "^rustc $([regex]::Escape($rustToolchain)) ") {
        Write-Host "Rust $rustToolchain already installed"
        $needRust = $false
    }
}
if ($needRust) {
    Write-Host "Installing Rust $rustToolchain..."
    New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null
    New-Item -ItemType Directory -Force -Path $cargoHome | Out-Null
    $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
    $target = if ($arch -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
    $rustupUrl = "https://static.rust-lang.org/rustup/dist/$target/rustup-init.exe"
    Invoke-WebRequest -Uri $rustupUrl -OutFile $rustupInit
    & $rustupInit --default-toolchain $rustToolchain --profile minimal -y --no-modify-path
    if ($LASTEXITCODE -ne 0) { throw "rustup-init failed" }
    Remove-Item $rustupInit -Force -ErrorAction SilentlyContinue
}
# GNU target for MSYS2 Ruby extension compilation.
#
# The native extension links MSYS2 MinGW Ruby and therefore builds for the
# `x86_64-pc-windows-gnu` Rust target.  The repo pins a Rust channel in
# `rust-toolchain.toml`; rustup auto-installs and uses *that* channel when
# cargo runs in the repo, so the windows-gnu std component must be added to
# the pinned channel -- not just to the env-provisioned default toolchain.
# Otherwise `cargo build --target x86_64-pc-windows-gnu` fails with
# "can't find crate for `core`".
& $rustupExe target add x86_64-pc-windows-gnu 2>&1 | Out-Null
& $rustupExe component add clippy 2>&1 | Out-Null

$rustToolchainToml = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "rust-toolchain.toml"
if (Test-Path $rustToolchainToml) {
    $channelLine = Get-Content $rustToolchainToml | Where-Object { $_ -match '^\s*channel\s*=' } | Select-Object -First 1
    if ($channelLine -and ($channelLine -match '"([^"]+)"')) {
        $pinnedChannel = $matches[1]
        Write-Host "Ensuring rustup channel $pinnedChannel + x86_64-pc-windows-gnu target (rust-toolchain.toml)"
        & $rustupExe toolchain install $pinnedChannel --profile minimal --no-self-update 2>&1 | Out-Null
        & $rustupExe target add --toolchain $pinnedChannel x86_64-pc-windows-gnu 2>&1 | Out-Null
    }
}

# --- Ensure Cap'n Proto ---
$capnpVersion = $toolchain["CAPNP_VERSION"]
$capnpDir = Join-Path $installRoot "capnp/$capnpVersion/prebuilt/capnproto-tools-win32-$capnpVersion"
$capnpExe = Join-Path $capnpDir "capnp.exe"

if (Test-Path $capnpExe) {
    Write-Host "Cap'n Proto $capnpVersion already installed"
} else {
    if ($arch -ne "x64") { throw "Cap'n Proto prebuilt only available for x64" }
    Write-Host "Installing Cap'n Proto $capnpVersion..."
    $capnpUrl = "https://capnproto.org/capnproto-c++-win32-$capnpVersion.zip"
    $capnpZip = Join-Path $env:TEMP "capnp-$capnpVersion.zip"
    Invoke-WebRequest -Uri $capnpUrl -OutFile $capnpZip
    $hash = (Get-FileHash -Path $capnpZip -Algorithm SHA256).Hash
    $expected = $toolchain["CAPNP_WIN_X64_SHA256"]
    if ($hash -ne $expected) { throw "Cap'n Proto SHA256 mismatch: got $hash, expected $expected" }
    $capnpParent = Split-Path -Parent $capnpDir
    New-Item -ItemType Directory -Force -Path $capnpParent | Out-Null
    Expand-Archive -Path $capnpZip -DestinationPath $capnpParent -Force
    Remove-Item $capnpZip
    Write-Host "Installed Cap'n Proto to $capnpDir"
}

# Rust GNU target for Ruby extension
$env:CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu"

# --- Ensure Nim ---
# The native extension's Rust crate depends on codetracer_trace_writer_nim,
# whose build script compiles a Nim static library. For the windows-gnu
# target that build runs `nim --cc:gcc`, so a MinGW gcc must be on PATH.
$nimVersion = $toolchain["NIM_VERSION"]
$nimDir = Join-Path $installRoot "nim/$nimVersion/nim-$nimVersion"
$nimExe = Join-Path $nimDir "bin/nim.exe"

if (Test-Path $nimExe) {
    Write-Host "Nim $nimVersion already installed"
} else {
    if ($arch -ne "x64") { throw "Nim provisioning in this script only supports x64." }
    Write-Host "Installing Nim $nimVersion..."
    $nimUrl = "https://nim-lang.org/download/nim-${nimVersion}_x64.zip"
    $nimZip = Join-Path $env:TEMP "nim-$nimVersion.zip"
    Invoke-WebRequest -Uri $nimUrl -OutFile $nimZip
    $nimParent = Split-Path -Parent $nimDir
    New-Item -ItemType Directory -Force -Path $nimParent | Out-Null
    Expand-Archive -Path $nimZip -DestinationPath $nimParent -Force
    Remove-Item $nimZip
    Write-Host "Installed Nim to $nimDir"
}

# --- Ensure just ---
$justVersion = $toolchain["JUST_VERSION"]
$justDir = Join-Path $installRoot "just/$justVersion"
$justExe = Join-Path $justDir "just.exe"

if (Test-Path $justExe) {
    Write-Host "just $justVersion already installed"
} else {
    Write-Host "Installing just $justVersion..."
    $justUrl = "https://github.com/casey/just/releases/download/$justVersion/just-$justVersion-x86_64-pc-windows-msvc.zip"
    $justZip = Join-Path $env:TEMP "just-$justVersion.zip"
    Invoke-WebRequest -Uri $justUrl -OutFile $justZip
    New-Item -ItemType Directory -Force -Path $justDir | Out-Null
    Expand-Archive -Path $justZip -DestinationPath $justDir -Force
    Remove-Item $justZip
    Write-Host "Installed just to $justDir"
}

# --- Ensure MSYS2 (MinGW64 Ruby + gcc + clang) ---
#
# The native extension links MSYS2 MinGW Ruby and builds for the
# x86_64-pc-windows-gnu Rust target.  Ruby therefore CANNOT come from
# RubyInstaller (that is MSVC ABI).  A MinGW gcc must also be on PATH:
# (a) the Rust windows-gnu target needs a MinGW linker and (b)
# codetracer_trace_writer_nim's build runs `nim --cc:gcc`.  The MinGW clang
# package supplies libclang.dll + clang resource headers, which rb-sys's
# bindgen build step needs to generate the Ruby C API bindings.
#
# MSYS2 is provisioned under the shared Windows dev-deps root
# (D:\metacraft-dev-deps by default) rather than $installRoot so it can be
# reused across sibling repos; override the location with
# $env:CODETRACER_DEV_DEPS_ROOT.
$devDepsRoot = if ($env:CODETRACER_DEV_DEPS_ROOT) { $env:CODETRACER_DEV_DEPS_ROOT }
               else { "D:\metacraft-dev-deps" }
$msysBaseDate = $toolchain["MSYS2_BASE_DATE"]
$msysRoot = Join-Path $devDepsRoot "msys2\msys64"
$msysBash = Join-Path $msysRoot "usr\bin\bash.exe"
$mingwBin = Join-Path $msysRoot "mingw64\bin"
$mingwRuby = Join-Path $mingwBin "ruby.exe"
$mingwGcc = Join-Path $mingwBin "gcc.exe"

if ((Test-Path $mingwRuby) -and (Test-Path $mingwGcc)) {
    Write-Host "MSYS2 MinGW Ruby + gcc already installed at $msysRoot"
} else {
    if ($arch -ne "x64") { throw "MSYS2 provisioning in this script only supports x64." }
    # 1. Extract the dated msys2-base self-extracting archive if absent.
    if (-not (Test-Path $msysBash)) {
        Write-Host "Installing MSYS2 base ($msysBaseDate)..."
        $msysParent = Join-Path $devDepsRoot "msys2"
        New-Item -ItemType Directory -Force -Path $msysParent | Out-Null
        $msysSfx = Join-Path $env:TEMP "msys2-base-$msysBaseDate.sfx.exe"
        $msysUrl = "https://repo.msys2.org/distrib/x86_64/msys2-base-x86_64-$msysBaseDate.sfx.exe"
        Invoke-WebRequest -Uri $msysUrl -OutFile $msysSfx
        $expectedMsys = $toolchain["MSYS2_BASE_SHA256"]
        if ($expectedMsys) {
            $hash = (Get-FileHash -Path $msysSfx -Algorithm SHA256).Hash
            if ($hash -ne $expectedMsys) {
                throw "MSYS2 base SHA256 mismatch: got $hash, expected $expectedMsys"
            }
        }
        # The sfx is a 7-zip self-extracting archive; it extracts a `msys64`
        # folder into the given output directory.
        & $msysSfx -y "-o$msysParent"
        if ($LASTEXITCODE -ne 0) { throw "MSYS2 base extraction failed" }
        Remove-Item $msysSfx -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $msysBash)) { throw "MSYS2 bash not found after extraction" }
        # First bash run initialises the pacman keyring.
        & $msysBash -lc "true" 2>&1 | Out-Null
    }
    # 2. Update the package database / core, then install the MinGW64
    #    toolchain.  `pacman -Syu` may need two passes (the first upgrades
    #    pacman/msys2-runtime itself); both are idempotent.
    Write-Host "Updating MSYS2 packages..."
    & $msysBash -lc "pacman -Syu --noconfirm --noprogressbar" 2>&1 | Out-Null
    & $msysBash -lc "pacman -Syu --noconfirm --noprogressbar" 2>&1 | Out-Null
    $mingwPackages = $toolchain["MSYS2_MINGW_PACKAGES"]
    Write-Host "Installing MSYS2 MinGW64 toolchain: $mingwPackages"
    & $msysBash -lc "pacman -S --noconfirm --noprogressbar --needed $mingwPackages" 2>&1 | Out-Null
    if (-not ((Test-Path $mingwRuby) -and (Test-Path $mingwGcc))) {
        throw "MSYS2 MinGW Ruby/gcc still missing after pacman install"
    }
    Write-Host "Installed MSYS2 MinGW64 toolchain to $msysRoot"
}

# libclang.dll lives in mingw64\bin; rb-sys's bindgen build step honours
# LIBCLANG_PATH to locate it.
$env:LIBCLANG_PATH = $mingwBin

# Set PATH.  MSYS2 mingw64\bin first (Ruby, gcc, clang), then MSYS2 usr\bin
# (a POSIX bash/sh + coreutils that `just` recipes need), then the rest.
$pathEntries = @($mingwBin, (Join-Path $msysRoot "usr\bin"),
                 "$cargoHome\bin", $capnpDir, (Join-Path $nimDir "bin"), $justDir)
foreach ($entry in $pathEntries) {
    if ($env:Path -notlike "*$entry*") {
        $env:Path = "$entry;$($env:Path)"
    }
}

Write-Host "rustc: $((& rustc --version) 2>&1)"
Write-Host "capnp: $((& capnp --version) 2>&1)"
Write-Host "nim: $(((& nim --version 2>&1) | Select-Object -First 1))"
Write-Host "just: $((& just --version) 2>&1)"
Write-Host "gcc: $(((& $mingwGcc --version 2>&1) | Select-Object -First 1))"
Write-Host "ruby: $((& $mingwRuby --version) 2>&1)"
