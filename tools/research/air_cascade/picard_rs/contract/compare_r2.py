#!/usr/bin/env python3
"""Compare two sets of R2 results: bitwise sameness of the solution path and speed ratio.

Usage: compare_r2.py <before_dir> <after_dir> [--case NAME] [--threads N]

For every R2 file present in both dirs (same file name): the solution path is "identical"
when iters, status, every history entry (except wall time t_s) and dev are exactly equal.
Prints one line per file, then summary lines:
  identical=<k>/<n>
  ratio_ms_per_iter=<after/before for --case at --threads>
  ratio_phase_<name>=<after/before> for each phase in time.phase_ms
Exit 1 when no common files.
"""
import json
import os
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def path_key(d):
    hist = [{k: v for k, v in h.items() if k != "t_s"} for h in d["history"]]
    return (d["iters"], d["status"], json.dumps(hist, sort_keys=True), json.dumps(d["dev"], sort_keys=True))


def main(argv):
    opts = dict(zip(argv, argv[1:]))
    args = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or not argv[i - 1].startswith("--"))]
    case = opts.get("--case", "ongudai_d400_u3_heat")
    threads = opts.get("--threads", "8")
    before, after = args[0], args[1]
    names = sorted(set(os.listdir(before)) & set(os.listdir(after)))
    names = [n for n in names if n.endswith(".json")]
    if not names:
        print("no common R2 files")
        return 1
    same = 0
    for n in names:
        a, b = load(os.path.join(before, n)), load(os.path.join(after, n))
        ok = path_key(a) == path_key(b)
        same += ok
        print(f"{n}: {'identical' if ok else 'DIFFERENT'} iters {a['iters']}->{b['iters']} "
              f"u_rel {a['dev']['u_rel']:.3e}->{b['dev']['u_rel']:.3e} "
              f"ms/it {a['time']['ms_per_iter']:.1f}->{b['time']['ms_per_iter']:.1f}")
    print(f"identical={same}/{len(names)}")
    ref = f"{case}_release_t{threads}.json"
    if ref in names:
        a, b = load(os.path.join(before, ref)), load(os.path.join(after, ref))
        print(f"ratio_ms_per_iter={b['time']['ms_per_iter'] / a['time']['ms_per_iter']:.4f}")
        for k, v in a["time"].get("phase_ms", {}).items():
            w = b["time"].get("phase_ms", {}).get(k)
            if w is not None and v > 0:
                print(f"ratio_phase_{k}={w / v:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
