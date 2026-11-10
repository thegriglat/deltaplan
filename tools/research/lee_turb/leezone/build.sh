#!/usr/bin/env bash
# build.sh <копия> <имя_цели>: dp-gd (tune) в копии, .so -> addons/dp_air/bin/libdp_air_tune.so
set -euo pipefail
wt=$1
export CARGO_TARGET_DIR=$HOME/.cache/dp-target/$2
cd "$wt/rust"
cargo build -p dp-gd --release --offline 2>&1 | tail -3
mkdir -p "$wt/addons/dp_air/bin"
rm -f "$wt/addons/dp_air/bin/libdp_air_tune.so"
cp "$CARGO_TARGET_DIR/release/libdp_gd.so" "$wt/addons/dp_air/bin/libdp_air_tune.so"
echo built
