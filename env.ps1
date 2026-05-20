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
# GNU target for MSYS2 Ruby extension compilation
& $rustupExe target add x86_64-pc-windows-gnu 2>&1 | Out-Null
& $rustupExe component add clippy 2>&1 | Out-Null

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

# Set PATH
$pathEntries = @("$cargoHome\bin", $capnpDir, (Join-Path $nimDir "bin"), $justDir)
foreach ($entry in $pathEntries) {
    if ($env:Path -notlike "*$entry*") {
        $env:Path = "$entry;$($env:Path)"
    }
}

Write-Host "rustc: $((& rustc --version) 2>&1)"
Write-Host "capnp: $((& capnp --version) 2>&1)"
Write-Host "nim: $(((& nim --version 2>&1) | Select-Object -First 1))"
Write-Host "just: $((& just --version) 2>&1)"
# Probe for Ruby with Get-Command, not `& ruby`: under
# $ErrorActionPreference = "Stop", invoking a missing command throws a
# terminating CommandNotFoundException before $LASTEXITCODE is ever set,
# which aborted env.ps1 instead of warning.
$rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
if ($rubyCmd) {
    Write-Host "ruby: $((& $rubyCmd.Source --version) 2>&1)"
} else {
    Write-Host "WARNING: Ruby not found. Install via MSYS2: pacman -S mingw-w64-x86_64-ruby"
}
