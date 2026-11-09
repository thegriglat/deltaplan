#!/usr/bin/env bash
# build.sh <sha>: собирает зонд против dp-air копии picard-terrain-PT-14-<sha> (отдельный CARGO_TARGET_DIR)
set -euo pipefail
sha=$1
here=$(cd "$(dirname "$0")" && pwd)
wt=$HOME/worktrees/deltaplan/picard-terrain-PT-14-$sha
d=$HOME/.cache/dp-probe/PT-14-$sha
mkdir -p "$d/src"; cp "$here/src/main.rs" "$d/src/"
sed "s#@DPAIR@#$wt/rust/dp-air#" "$here/Cargo.toml.in" > "$d/Cargo.toml"
cp "$wt/rust/Cargo.lock" "$d/Cargo.lock"
cd "$d"
CARGO_TARGET_DIR=$HOME/.cache/dp-target/PT-14-probe-$sha cargo build --release --offline --bin pt14-probe 2>&1 | tail -15
