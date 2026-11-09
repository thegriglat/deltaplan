#!/usr/bin/env bash
# build_commit.sh <sha>: сборка dp-gd (tune) в копии picard-terrain-PT-14-<sha>, .so -> addons/dp_air/bin/libdp_air_tune.so
set -euo pipefail
sha=$1
wt=$HOME/worktrees/deltaplan/picard-terrain-PT-14-$sha
export CARGO_TARGET_DIR=$HOME/.cache/dp-target/PT-14-$sha
cd "$wt/rust"
cargo build -p dp-gd --release --offline 2>&1 | tail -3
mkdir -p "$wt/addons/dp_air/bin"
cp "$CARGO_TARGET_DIR/release/libdp_gd.so" "$wt/addons/dp_air/bin/libdp_air_tune.so"
echo built $sha
