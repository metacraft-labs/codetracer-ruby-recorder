<#
.SYNOPSIS
  Bootstrap Windows DIY dev environment for codetracer-ruby-recorder.
  Installs: Rust toolchain with GNU target (via rustup), Cap'n Proto (prebuilt).
  Ruby is expected via MSYS2 (pacman -S mingw-w64-x86_64-ruby).

.DESCRIPTION
  Content-addressable, idempotent bootstrap. Safe to re-run.
  Install root: $env:LOCALAPPDATA/codetracer/windows-diy (shared with codetracer)
#>
param(
    [string]$InstallRoot = $(
        if ($env:WINDOWS_DIY_INSTALL_ROOT) { $env:WINDOWS_DIY_INSTALL_ROOT }
        else { Join-Path $env:LOCALAPPDATA "codetracer/windows-diy" }
    )
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$toolchainFile = Join-Path $scriptDir "toolchain-versions.env"

# Parse toolchain-versions.env
$toolchain = @{}
Get-Content $toolchainFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        $toolchain[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$resolvedRoot = (New-Item -ItemType Directory -Force -Path $InstallRoot).FullName
Write-Host "Install root: $resolvedRoot"

function Get-WindowsArch {
    $sys = (Get-CimInstance Win32_ComputerSystem).SystemType
    if ($sys -match "ARM") { return "arm64" }
    return "x64"
}
$arch = Get-WindowsArch
Write-Host "Architecture: $arch"

# --- Rust (via rustup, with GNU target) ---
$rustupHome = Join-Path $resolvedRoot "rustup"
$cargoHome = Join-Path $resolvedRoot "cargo"
$cargoExe = Join-Path $cargoHome "bin/cargo.exe"
$rustupExe = Join-Path $cargoHome "bin/rustup.exe"
$env:RUSTUP_HOME = $rustupHome
$env:CARGO_HOME = $cargoHome

if (Test-Path $cargoExe) {
    Write-Host "Rust already installed at $cargoHome"
} else {
    Write-Host "Installing Rust $($toolchain.RUST_TOOLCHAIN_VERSION)..."
    $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
    $rustupUrl = "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    if ($arch -eq "arm64") { $rustupUrl = "https://static.rust-lang.org/rustup/dist/aarch64-pc-windows-msvc/rustup-init.exe" }
    Invoke-WebRequest -Uri $rustupUrl -OutFile $rustupInit
    & $rustupInit --default-toolchain $toolchain.RUST_TOOLCHAIN_VERSION --profile minimal -y --no-modify-path
    if ($LASTEXITCODE -ne 0) { throw "rustup-init failed" }
}

# Add GNU target for MSYS2/MinGW Ruby extension compilation
Write-Host "Ensuring x86_64-pc-windows-gnu target..."
& $rustupExe target add x86_64-pc-windows-gnu
& $rustupExe component add clippy

# --- Cap'n Proto (prebuilt x64) ---
$capnpVersion = $toolchain.CAPNP_VERSION
$capnpDir = Join-Path $resolvedRoot "capnp/$capnpVersion/prebuilt/capnproto-tools-win32-$capnpVersion"
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
    $expected = $toolchain.CAPNP_WIN_X64_SHA256
    if ($hash -ne $expected) { throw "Cap'n Proto SHA256 mismatch: got $hash, expected $expected" }

    $capnpParent = Split-Path -Parent $capnpDir
    New-Item -ItemType Directory -Force -Path $capnpParent | Out-Null
    Expand-Archive -Path $capnpZip -DestinationPath $capnpParent -Force
    Remove-Item $capnpZip
    Write-Host "Installed Cap'n Proto to $capnpDir"
}

Write-Host ""
Write-Host "Bootstrap complete."
Write-Host "RUSTUP_HOME=$rustupHome"
Write-Host "CARGO_HOME=$cargoHome"
Write-Host "CAPNP_DIR=$capnpDir"
Write-Host ""
Write-Host "NOTE: Ruby must be installed separately via MSYS2:"
Write-Host "  pacman -S mingw-w64-x86_64-ruby"
