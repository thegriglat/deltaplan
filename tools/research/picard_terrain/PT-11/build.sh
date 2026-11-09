#!/bin/bash
# сборка dp-stand: до (база) и после (своя копия)
set -e
B=$HOME/worktrees/deltaplan/picard-terrain-PT-11-base
A=$HOME/worktrees/deltaplan/picard-terrain-PT-11
CARGO_TARGET_DIR=$HOME/.cache/dp-target/PT-11-base cargo build --release --manifest-path $B/rust/Cargo.toml -p dp-stand
CARGO_TARGET_DIR=$HOME/.cache/dp-target/PT-11-after cargo build --release --manifest-path $A/rust/Cargo.toml -p dp-stand
