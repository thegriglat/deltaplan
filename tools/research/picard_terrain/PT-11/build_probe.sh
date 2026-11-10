#!/bin/bash
# сборка probe для «до» и «после»: копия исходников в ~/.cache/dp-target/PT-11-probe-<вариант>/src
set -e
H=$(cd "$(dirname "$0")" && pwd)
for v in base after; do
  if [ $v = base ]; then R=$HOME/worktrees/deltaplan/picard-terrain-PT-11-base; else R=$HOME/worktrees/deltaplan/picard-terrain-PT-11; fi
  D=$HOME/.cache/dp-target/PT-11-probe-$v
  rm -rf $D/crate; mkdir -p $D/crate; cp -r $H/probe/src $H/probe/Cargo.toml $D/crate/
  sed -i "s#@ROOT@#$R#g" $D/crate/Cargo.toml
  cp $R/rust/Cargo.lock $D/crate/Cargo.lock
  CARGO_TARGET_DIR=$D/target cargo build --release --offline --manifest-path $D/crate/Cargo.toml
done
