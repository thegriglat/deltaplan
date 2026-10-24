#!/usr/bin/env bash
# PR-8: all solver runs (8 threads, under the cpu lock) + summary.json. Run from the repo copy root, in the background.
set -euo pipefail
P=tools/research/air_cascade/picard_rs
O=$P/out/residual/PR-8
D=$HOME/data/air_cascade/ongudai
S=$HOME/data/air_cascade/picard_rs/residual/PR-8   # snapshots and states (tens of MB each) stay out of git
mkdir -p $O/r2 $S

run() { # name, then picard solve arguments
  local name=$1; shift
  .dpcli/dpcli lock cpu PR-8 --no-tmux -- tools/research/air_cascade/picard_rs/target/release/picard solve "$@" --threads 8 --out $O/r2/${name}_t8.json > $S/$name.log
}

# cold series: reference with snapshots at N, then tol_scale 3, 5, 7, 10, 30 (5 and 7 are extra, between the contract points)
for c in u3_heat u3_mech u0_heat u6_heat; do
  n=ongudai_d400_$c
  run ${n}_ref $D/$n.json --save-state $S/${n}_ref.json --snap-at 30,50,100,150 --snap-dir $S/${n}_snap
  # clean timing run of the reference path: snapshot writes (tens of MB) are inside the iteration clock of the run above
  run ${n}_time $D/$n.json
  for t in 3 5 7 10 30; do
    run ${n}_tol$t $D/$n.json --tol-scale $t --save-state $S/${n}_tol$t.json
  done
done

# warm series (R5): converged cold h1200 -> start field of h1215; reference = cold converged h1215
a=ongudai_d400_u3_heat_h1200; b=ongudai_d400_u3_heat_h1215
run ${a}_ref $D/$a.json --save-state $S/${a}_ref.json
run ${b}_ref $D/$b.json --save-state $S/${b}_ref.json
run ${b}_warm_ref $D/$b.json --init $S/${a}_ref.json --save-state $S/${b}_warm_ref.json
# the warm start converges in 20 iterations; to read the field after 30 and 50 iterations the criterion is tightened
# (tol_scale 0.001, stop by max_iters 50): the solution path up to 20 iterations is the same
run ${b}_warm_ext $D/$b.json --init $S/${a}_ref.json --tol-scale 0.001 --max-iters 50 --snap-at 2,4,6,8,10,20,30,50 --snap-dir $S/${b}_warm_snap
run ${b}_warm_time $D/$b.json --init $S/${a}_ref.json --tol-scale 0.001 --max-iters 50   # same path as _warm_ext, no snapshots: clean times
for t in 3 10 30; do
  run ${b}_warm_tol$t $D/$b.json --init $S/${a}_ref.json --tol-scale $t --save-state $S/${b}_warm_tol$t.json
done

# "deep" fields: criterion tightened 10x (tol_scale 0.1, up to 1500 iterations) to see how far the criterion stop is from the fixed point
for n in ongudai_d400_u3_heat ongudai_d400_u3_mech ongudai_d400_u0_heat ongudai_d400_u6_heat ongudai_d400_u3_heat_h1215; do
  run ${n}_deep $D/$n.json --tol-scale 0.1 --max-iters 1500 --save-state $S/${n}_deep.json
done

python3 -I $P/residual/summarize.py --out $O/summary.json
python3 $P/contract/check_residual.py $O/summary.json
