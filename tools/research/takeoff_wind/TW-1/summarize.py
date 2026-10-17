#!/usr/bin/env python3
"""TW-1: сводка прогонов rec.gd.  summarize.py <runs.jsonl>... [--csv out.csv] [--by loc,tag]

Печатает таблицу «группа → прогонов, провалов (takeoff_failed/not_armed/no_takeoff), доля» и
средние по разбегу; --csv — плоская таблица строка-на-прогон (для README и статьи).
"""
import json
import sys
from collections import defaultdict

FIELDS = ["loc", "wing", "weather", "seed", "ap", "air", "tag", "flow", "result", "kind", "fail_reason",
          "took_off_at", "t_air", "max_agl", "dist", "touches", "max_bank_ground", "max_bank_air15",
          "max_hdg_dev_run", "max_dw_tips", "pitch_air15_min", "pitch_air15_max",
          "lo_ias", "lo_gs", "lo_alpha", "lo_pitch", "lo_bank", "lo_u", "lo_w", "lo_run_s",
          "w_run_mean", "w_run_min", "w_run_max", "u_run_mean", "u_run_min", "u_run_max", "steady_ms", "world_t"]


def flat(r):
    o = {k: r.get(k, "") for k in FIELDS}
    lo = r.get("liftoff") or {}
    for k, s in [("ias", "lo_ias"), ("gs", "lo_gs"), ("alpha_m", "lo_alpha"), ("pitch", "lo_pitch"),
                 ("bank", "lo_bank"), ("u", "lo_u"), ("w", "lo_w"), ("run_s", "lo_run_s")]:
        o[s] = lo.get(k, "")
    p = r.get("pitch_air15") or ["", ""]
    o["pitch_air15_min"], o["pitch_air15_max"] = p[0], p[1]
    for key in ("w_run", "u_run"):
        v = r.get(key) or ["", "", ""]
        o[key + "_mean"], o[key + "_min"], o[key + "_max"] = v
    return o


def main(argv):
    files, csv_out, by = [], None, ["loc", "tag"]
    i = 0
    while i < len(argv):
        if argv[i] == "--csv":
            csv_out = argv[i + 1]; i += 2; continue
        if argv[i] == "--by":
            by = argv[i + 1].split(","); i += 2; continue
        files.append(argv[i]); i += 1
    rows = []
    for f in files:
        for line in open(f):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    rows = [flat(r) for r in rows]
    if csv_out:
        with open(csv_out, "w") as fo:
            fo.write(",".join(FIELDS) + "\n")
            for r in rows:
                fo.write(",".join(str(r[k]) for k in FIELDS) + "\n")
    g = defaultdict(list)
    for r in rows:
        g[tuple(str(r[k]) for k in by)].append(r)
    print("| " + " | ".join(by) + " | прогонов | провал | нет отрыва | доля провала | IAS отрыва | w разбег | max крен земля | max крен 15 с | max AGL |")
    print("|" + "---|" * (len(by) + 9))
    for k in sorted(g):
        rs = g[k]
        n = len(rs)
        fail = sum(1 for r in rs if r["result"] in ("takeoff_failed", "not_armed"))
        nt = sum(1 for r in rs if r["result"] == "no_takeoff")

        def mean(key):
            v = [float(r[key]) for r in rs if r[key] not in ("", None)]
            return sum(v) / len(v) if v else float("nan")
        print("| " + " | ".join(k) + f" | {n} | {fail} | {nt} | {(fail + nt) / n:.2f} | {mean('lo_ias'):.1f} | "
              f"{mean('w_run_mean'):+.2f} | {mean('max_bank_ground'):.1f} | {mean('max_bank_air15'):.1f} | {mean('max_agl'):.1f} |")


if __name__ == "__main__":
    main(sys.argv[1:])
