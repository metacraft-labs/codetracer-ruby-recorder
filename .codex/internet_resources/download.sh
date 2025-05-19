#!/usr/bin/env bash

DOWNLOADS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd $DOWNLOADS_DIR

# Download the specification of the CodeTracer trace json format.
# Read the trace_json_spec.md file to understand what json records
# should be produced by the tracers in this repo.
wget https://raw.githubusercontent.com/metacraft-labs/runtime_tracing/refs/heads/master/docs/trace_json_spec.md
