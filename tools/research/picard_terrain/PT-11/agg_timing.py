"""PT-11 (1): свод timing -> timing.csv, timing.json (load_ratio_max и т.д.)."""
import csv, json, statistics as st
from pathlib import Path
import sys
OUT = Path(__file__).resolve().parents[1] / "out/PT-11"
PLACES = ["ongudai", "synthetic", "training_island", "volcano_island"]


def passes_sum(r, key):
    def v(x):
        return sum(x) if isinstance(x, list) else (x or 0)
    return sum(v(p.get(key)) for p in r["passes"])


def secs4(r):
    s = [0.0] * 4
    for p in r["passes"]:
        for i, v in enumerate(p["secs"][:4]):
            s[i] += v
    return s


def main():
    recs = {}
    nan = {"base": 0, "after": 0}

    def count_bad(o, var):
        if isinstance(o, float) and (o != o or o in (float("inf"), float("-inf"))):
            nan[var] += 1
        elif isinstance(o, dict):
            [count_bad(v, var) for v in o.values()]
        elif isinstance(o, list):
            [count_bad(v, var) for v in o]

    for f in sorted((OUT / "timing").glob("*.jsonl")):
        var, place_t = f.stem.split("_", 1)
        parts = place_t.rsplit("_", 2)
        place, thr, rep = parts[0], int(parts[1][1:]), int(parts[2][1:])
        for k, line in enumerate(f.read_text().splitlines()):
            r = json.loads(line)
            count_bad(r, var)
            recs.setdefault((place, thr, var, k), []).append(r)
    rows = []
    for place in PLACES:
        for thr in (8, 2):
            ks = sorted({k for (p, t, v, k) in recs if p == place and t == thr})
            for k in ks:
                for var in ("base", "after"):
                    rs = recs.get((place, thr, var, k))
                    if not rs:
                        continue
                    med = lambda xs: statistics_med(xs)
                    row = dict(place=place, threads=thr, moment=k, t=rs[0]["t"], kind=rs[0]["kind"], variant=var, reps=len(rs),
                               wall_s=med([r["wall_s"] for r in rs]),
                               wall_all=";".join(f"{r['wall_s']:.2f}" for r in rs),
                               iters=med([passes_sum(r, "iters") for r in rs]),
                               coarse_iters=med([passes_sum(r, "coarse_iters") for r in rs]),
                               passes=len(rs[0]["passes"]),
                               prep_s=med([secs4(r)[0] for r in rs]), coarse_s=med([secs4(r)[1] for r in rs]),
                               solve_s=med([secs4(r)[2] for r in rs]), build_s=med([secs4(r)[3] for r in rs]),
                               phase_s=med([passes_sum(r, "phase_s") for r in rs]),
                               win_s=med([passes_sum(r, "win_s") for r in rs]))
                    rows.append(row)
    with open(OUT / "timing.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    idx = {(r["place"], r["threads"], r["moment"], r["variant"]): r for r in rows}
    ratios = {}
    for (p, t, m, v), r in idx.items():
        if v == "after" and (p, t, m, "base") in idx:
            b = idx[(p, t, m, "base")]
            ratios[f"{p}|t{t}|m{m}"] = dict(kind=r["kind"], wall_ratio=r["wall_s"] / b["wall_s"], prep_after=r["prep_s"], prep_before=b["prep_s"],
                                           iters_after=r["iters"], iters_before=b["iters"])
    load8 = {k: v["wall_ratio"] for k, v in ratios.items() if v["kind"] == "load" and "|t8|" in k}
    out = dict(load_ratio_by_place_t8=load8, load_ratio_max=max(load8.values()), ratios=ratios, nan_timing=nan)
    json.dump(out, open(OUT / "timing.json", "w"), indent=1)
    print(json.dumps(out, indent=1))


def statistics_med(xs):
    return float(st.median(xs))


main()
