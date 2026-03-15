# codetracer-ruby-recorder Windows Dev Environment

Standalone Windows dev environment for the Ruby recorder.

## Prerequisites

- MSYS2 with MinGW64 toolchain (for GCC and Ruby)

## Quick start

### Bootstrap (first time)
```powershell
pwsh -File non-nix-build\windows\bootstrap-windows-diy.ps1
```

### Install Ruby via MSYS2
```sh
pacman -S mingw-w64-x86_64-ruby
```

### Activate environment

**Git Bash / MSYS2:**
```sh
source non-nix-build/windows/env.sh
```

**PowerShell:**
```powershell
. .\non-nix-build\windows\env.ps1
```

### Build & test
```sh
just build-extension   # compile Rust native extension
just test              # run tests
```

## Required tools

| Tool | Version | Source |
|------|---------|--------|
| Rust | 1.92.0 (GNU target) | bootstrap script |
| Cap'n Proto | 1.3.0 | bootstrap script |
| Ruby | 3.3+ | MSYS2 pacman |

## Notes

- Rust is configured with `x86_64-pc-windows-gnu` target to match MSYS2 Ruby
- Cap'n Proto uses the prebuilt Windows binary
- Install root: `%LOCALAPPDATA%\codetracer\windows-diy` (shared cache)
