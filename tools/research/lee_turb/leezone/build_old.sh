#!/usr/bin/env bash
# build_old.sh: dp-gd (tune) на main до срезанных клеток (470745ac8, копия lee-turb-LT-11-old)
set -euo pipefail
wt=$HOME/worktrees/deltaplan/lee-turb-LT-11-old
export CARGO_TARGET_DIR=$HOME/.cache/dp-target/LT-11-old
cd "$wt/rust"
cargo build -p dp-gd --release --offline 2>&1 | tail -3
mkdir -p "$wt/addons/dp_air/bin"
cp "$CARGO_TARGET_DIR/release/libdp_gd.so" "$wt/addons/dp_air/bin/libdp_air_tune.so"
echo built
