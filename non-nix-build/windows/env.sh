#!/usr/bin/env bash
# codetracer-ruby-recorder Windows dev environment (Git Bash / MSYS2)
# Usage: source non-nix-build/windows/env.sh

# Source-safe shell option handling: save caller's options and restore on RETURN.
# Do NOT use `set -euo pipefail` here -- this file is meant to be sourced into
# interactive shells where `-e` would cause the shell to exit on any failing
# command and `-u` would break on unset variables common in interactive sessions.
_ct_rbenv_was_sourced=0
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    _ct_rbenv_was_sourced=1
    _ct_rbenv_prev_shellopts=$(set +o)
    trap 'eval "$_ct_rbenv_prev_shellopts"; unset _ct_rbenv_prev_shellopts _ct_rbenv_was_sourced; trap - RETURN' RETURN
fi

set -uo pipefail
if [[ ${_ct_rbenv_was_sourced:-0} -eq 0 ]]; then
    set -e
fi

_ct_rbenv_error() {
    echo "ERROR: $1" >&2
    if [[ ${_ct_rbenv_was_sourced:-0} -eq 1 ]]; then
        return 1
    fi
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse toolchain versions
declare -A TOOLCHAIN
while IFS='=' read -r key value; do
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | tr -d '[:space:]')
    [[ -z "$key" || "$key" == \#* ]] && continue
    TOOLCHAIN[$key]="$value"
done < "$SCRIPT_DIR/toolchain-versions.env"

# Resolve install root with safe cygpath handling
if [[ -z ${WINDOWS_DIY_INSTALL_ROOT:-} ]]; then
    if [[ -n ${LOCALAPPDATA:-} ]]; then
        if command -v cygpath >/dev/null 2>&1; then
            _ct_rbenv_local_app_data=$(cygpath -u "$LOCALAPPDATA")
        else
            _ct_rbenv_local_app_data="$LOCALAPPDATA"
        fi
    else
        _ct_rbenv_local_app_data="$HOME/AppData/Local"
    fi
    INSTALL_ROOT="$_ct_rbenv_local_app_data/codetracer/windows-diy"
    unset _ct_rbenv_local_app_data
else
    INSTALL_ROOT="$WINDOWS_DIY_INSTALL_ROOT"
fi

# Run bootstrap if cargo not found
CARGO_EXE="$INSTALL_ROOT/cargo/bin/cargo.exe"
if [[ ! -f "$CARGO_EXE" ]]; then
    echo "Running bootstrap..." >&2
    if ! pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/bootstrap-windows-diy.ps1"; then
        _ct_rbenv_error "Bootstrap failed"
    fi
fi

export RUSTUP_HOME="$INSTALL_ROOT/rustup"
export CARGO_HOME="$INSTALL_ROOT/cargo"

CAPNP_DIR="$INSTALL_ROOT/capnp/${TOOLCHAIN[CAPNP_VERSION]}/prebuilt/capnproto-tools-win32-${TOOLCHAIN[CAPNP_VERSION]}"

# Use GNU target for MSYS2 Ruby extension compilation
export CARGO_BUILD_TARGET="x86_64-pc-windows-gnu"

# Idempotent PATH update: only prepend entries not already present
_ct_rbenv_path_prepend() {
    local dir="$1"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
}
_ct_rbenv_path_prepend "$CAPNP_DIR"
_ct_rbenv_path_prepend "$CARGO_HOME/bin"

echo "rustc: $(rustc --version 2>&1)"
echo "capnp: $(capnp --version 2>&1)"
if command -v ruby &>/dev/null; then
    echo "ruby: $(ruby --version 2>&1)"
else
    echo "WARNING: Ruby not found. Install via MSYS2: pacman -S mingw-w64-x86_64-ruby" >&2
fi
