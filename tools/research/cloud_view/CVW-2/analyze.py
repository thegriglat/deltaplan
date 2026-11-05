#!/usr/bin/env python3
"""CVW-2: сводные таблицы из measures.csv (stdlib). Запуск: python3 analyze.py [measures.csv]"""
import csv, sys, collections, math, json

path = sys.argv[1] if len(sys.argv) > 1 else "measures.csv"
rows = list(csv.DictReader(open(path, encoding="utf-8")))


def f(r, k):
    v = r.get(k, "")
    return float(v) if v not in ("", None) else math.nan


groups = collections.OrderedDict()
for r in rows:
    groups.setdefault((r["hour"], r["x_mode"]), []).append(r)

out = {}
print("hour mode n | amount(min..max) fog_d(min..max) sky_aff(max) | luma_mean(min..max) | other_luma bg_luma nc_luma_mean")
for (h, m), rs in groups.items():
    def rng(k):
        v = [f(r, k) for r in rs if not math.isnan(f(r, k))]
        return (min(v), max(v)) if v else (math.nan, math.nan)
    a, fd, sa, lm = rng("whiteout_amount"), rng("fog_density"), rng("fog_sky_affect"), rng("luma_mean")
    ol, bl, nc = rng("x_other_luma"), rng("x_bg_luma"), rng("x_nc_luma_mean")
    print(f"{h} {m} {len(rs)} | {a[0]:.3f}..{a[1]:.3f} {fd[0]:.5f}..{fd[1]:.5f} {sa[1]:.2f} | {lm[0]:.3f}..{lm[1]:.3f} | {ol[0]:.3f}..{ol[1]:.3f} {bl[0]:.3f}..{bl[1]:.3f} {nc[0]:.3f}..{nc[1]:.3f}")
    out[f"{h}/{m}"] = {"n": len(rs), "amount": a, "fog_density": fd, "luma_mean": lm}
json.dump(out, open("summary_numbers.json", "w"), indent=1)
