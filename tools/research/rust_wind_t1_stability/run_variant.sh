#!/usr/bin/env bash
# Один вариант опыта RW-6z: run_variant.sh <base|chunk1000|pert_u10|pert_t>
# chunk1000: перед запуском применить chunk1000.patch (git apply), после - git apply -R.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export RW6Z_VARIANT="$1" RW6Z_RAW="${RW6Z_RAW:-$HOME/data/rw6z}"
cargo test --release --manifest-path rust/Cargo.toml -p dp-air --test t1_stability stab_run -- --ignored --nocapture
