#!/bin/bash
# WF-1: поле у старта в режимах start/inflow на Rust (dp-air без Godot). run.sh <метка> [имя…] → out/<метка>.json
# Под замком CPU: .dpcli/dpcli job --lock cpu start wf1-scan 3600 tools/research/wind_forecast/run.sh before
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
TAG=${1:?метка}; shift
mkdir -p "$HERE/out"
CARGO_TARGET_DIR="$HERE/out/target" cargo build --release --manifest-path "$HERE/rs/Cargo.toml" 2>&1 | tail -2
"$HERE/out/target/release/wf1-scan" "$ROOT" "$HERE/out/$TAG.json" "$@"
