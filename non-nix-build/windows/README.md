# codetracer-ruby-recorder Windows Dev Environment

Standalone Windows dev environment for the Ruby recorder.

## Prerequisites

- MSYS2 with MinGW64 toolchain (for GCC and Ruby)

## Quick start

### Install Ruby via MSYS2
```sh
pacman -S mingw-w64-x86_64-ruby
```

### Activate environment (auto-installs Rust & Cap'n Proto on first run)

**Git Bash / MSYS2:**
```sh
source env.sh
```

**PowerShell:**
```powershell
. .\env.ps1
```

### Build & test
```sh
just build-extension   # compile Rust native extension
just test              # run tests
```

## Required tools

| Tool | Version | Source |
|------|---------|--------|
| Rust | 1.92.0 (GNU target) | env.ps1 / env.sh (auto-installed) |
| Cap'n Proto | 1.3.0 | env.ps1 / env.sh (auto-installed) |
| Ruby | 3.3+ | MSYS2 pacman |

## Notes

- Rust is configured with `x86_64-pc-windows-gnu` target to match MSYS2 Ruby
- Cap'n Proto uses the prebuilt Windows binary
- Install root: `%LOCALAPPDATA%\codetracer\windows-diy` (shared cache)
