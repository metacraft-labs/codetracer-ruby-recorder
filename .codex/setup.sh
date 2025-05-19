#!/usr/bin/env bash

CODEX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd $CODEX_DIR

apt-get update
apt-get install -y --no-install-recommends just

pushd deps_src
  git clone https://github.com/metacraft-labs/runtime_tracing
popd

./build_all_targets.sh

