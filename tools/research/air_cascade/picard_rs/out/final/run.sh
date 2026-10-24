#!/usr/bin/env bash
# PR-12: final measurements (cold, warm chain, cold h1215/h1230) on 2/3/6/8 threads, tol_scale 1 and 5, then summary.json.
# Run from the repo copy root, in the background (hours of wall clock are not needed: ~40 min). Every solver run is under the cpu lock.
# States (R4, tens of MB) stay in ~/data/air_cascade/picard_rs/final/, not in git. Re-runs skip finished outputs.
set -euo pipefail
P=tools/research/air_cascade/picard_rs
O=$P/out/final
D=$HOME/data/air_cascade/ongudai
S=$HOME/data/air_cascade/picard_rs/final
BIN=tools/research/air_cascade/picard_rs/target/release/picard
mkdir -p $S
for d in cold_tol1 cold_tol5 warm_tol1 warm_tol5 coldh_tol1 coldh_tol5; do mkdir -p $O/$d; done

run() { # out_json, then picard solve arguments (threads and tol are in them)
  local out=$1; shift
  [ -s "$out" ] && return 0
  .dpcli/dpcli lock cpu PR-12 --no-tmux -- $BIN solve "$@" --out "$out" > $S/$(basename "$out" .json).log
}

for X in 1 5; do
  TS=(); [ $X != 1 ] && TS=(--tol-scale $X)
  # cold: 4 cases x threads
  for c in u3_heat u3_mech u0_heat u6_heat; do
    n=ongudai_d400_$c
    for t in 2 3 6 8; do run $O/cold_tol$X/${n}_release_t$t.json $D/$n.json --threads $t "${TS[@]}"; done
  done
  # chain h1200 (cold, saves S1200) -> h1215 (warm from S1200, saves W1215) -> h1230 (warm from W1215, saves W1230)
  a=ongudai_d400_u3_heat_h1200; b=ongudai_d400_u3_heat_h1215; c=ongudai_d400_u3_heat_h1230
  run $O/coldh_tol$X/${a}_release_t8.json $D/$a.json --threads 8 "${TS[@]}" --save-state $S/S1200_$X.json
  run $O/coldh_tol$X/${b}_release_t8.json $D/$b.json --threads 8 "${TS[@]}" --save-state $S/C1215_$X.json
  run $O/coldh_tol$X/${c}_release_t8.json $D/$c.json --threads 8 "${TS[@]}" --save-state $S/C1230_$X.json
  run $O/warm_tol$X/${b}_release_t8.json $D/$b.json --threads 8 "${TS[@]}" --init $S/S1200_$X.json --save-state $S/W1215_$X.json
  run $O/warm_tol$X/${c}_release_t8.json $D/$c.json --threads 8 "${TS[@]}" --init $S/W1215_$X.json --save-state $S/W1230_$X.json
  for t in 2 3 6; do
    run $O/coldh_tol$X/${b}_release_t$t.json $D/$b.json --threads $t "${TS[@]}"
    run $O/coldh_tol$X/${c}_release_t$t.json $D/$c.json --threads $t "${TS[@]}"
    run $O/warm_tol$X/${b}_release_t$t.json $D/$b.json --threads $t "${TS[@]}" --init $S/S1200_$X.json
    run $O/warm_tol$X/${c}_release_t$t.json $D/$c.json --threads $t "${TS[@]}" --init $S/W1215_$X.json
  done
done

python3 -I $P/residual/summarize_final.py --out $O/summary.json
