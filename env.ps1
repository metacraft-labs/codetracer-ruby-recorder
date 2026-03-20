# codetracer-ruby-recorder Windows dev environment (PowerShell)
# Usage: . .\env.ps1

$ErrorActionPreference = "Stop"
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

# Run bootstrap if needed
$cargoExe = Join-Path $installRoot "cargo/bin/cargo.exe"
if (-not (Test-Path $cargoExe)) {
    Write-Host "Running bootstrap..."
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "bootstrap-windows-diy.ps1")
}

# Set environment
$env:RUSTUP_HOME = Join-Path $installRoot "rustup"
$env:CARGO_HOME = Join-Path $installRoot "cargo"

$capnpDir = Join-Path $installRoot "capnp/$($toolchain.CAPNP_VERSION)/prebuilt/capnproto-tools-win32-$($toolchain.CAPNP_VERSION)"

# Rust GNU target for Ruby extension
$env:CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu"

# Idempotent PATH update: only prepend entries not already present
$pathEntries = @("$($env:CARGO_HOME)\bin", $capnpDir)
foreach ($entry in $pathEntries) {
    if ($env:Path -notlike "*$entry*") {
        $env:Path = "$entry;$($env:Path)"
    }
}

Write-Host "rustc: $((& rustc --version) 2>&1)"
Write-Host "capnp: $((& capnp --version) 2>&1)"
$rubyCheck = & ruby --version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "ruby: $rubyCheck"
} else {
    Write-Host "WARNING: Ruby not found. Install via MSYS2: pacman -S mingw-w64-x86_64-ruby"
}
