#!/usr/bin/env bash
# Timing of the descent and of the point query on the synthetic C1 parent (P400 -> 25 m).
# Run under `.dpcli/dpcli lock cpu <name> -- tools/research/cascade_2d/cascade_rs/bench.sh <scratch-dir>`.
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)/target/release/cascade"
S="${1:?scratch dir}"
mkdir -p "$S/fields/C1"
"$B" synth-parent --case C1 --dx 400 --u0 5 --noise 1 --out "$S/fields/C1/picard_none_d400.json"
for v in V0 V1 V2 V3 V3h; do
  for t in 1 8; do
    "$B" descend --parent "$S/fields/C1/picard_none_d400.json" --case C1 --variant "$v" --seed 5 \
      --threads "$t" --out-dir "$S/fields/C1" --geom synth-heated --runs-dir "$S/runs"
  done
  "$B" query --parent "$S/fields/C1/picard_none_d400.json" --case C1 --variant "$v" --seed 5 \
    --points 5000 --out-dir "$S/fields/C1" --geom synth-heated --runs-dir "$S/runs"
done
