#!/usr/bin/env bash

CODEX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd $CODEX_DIR

pushd ..
  just build-extension
popd
