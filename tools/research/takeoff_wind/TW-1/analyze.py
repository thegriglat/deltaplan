#!/usr/bin/env python3
"""TW-1: разбор провалов взлёта по трассам rec.gd.  analyze.py <out_dir>... [--csv fails.csv]

Для каждого прогона с итогом не ok ищет трассу trace_<loc>_<seed>.csv в той же part_* и
относит провал к механизму:
  roll_over_ground — на разбеге крен > 60° (консоль в землю, крыло перевернулось), отрыва нет;
  gust_hop         — отрыв в первые 0,6 с разбега (поднял порыв, не скорость), затем касание;
  low_hop          — отрыв, потом касание ниже 10 м и ближе 50 м (не взведён);
  other.
По участку полёта до первого касания: средняя путевая скорость, средняя и min воздушная, max α,
max |крен|, средний w у крыла, средний встречный ветер u, доля времени с α > 16°.
"""
import csv
import glob
import json
import os
import sys


def load_trace(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def f(r, k):
    try:
        return float(r[k])
    except (KeyError, ValueError):
        return float("nan")


def classify(run, tr):
    out = {"mech": "other"}
    if run["result"] == "no_takeoff":
        out["mech"] = "roll_over_ground" if run.get("max_bank_ground", 0) > 60 else "no_takeoff"
        return out
    if run["took_off_at"] >= 0 and run["took_off_at"] - max(run.get("run_start", 0), 0) < 0.6:
        out["mech"] = "gust_hop"
    else:
        out["mech"] = "low_hop"
    if not tr:
        return out
    air = []
    started = False
    for r in tr:
        if r["phase"] == "flying":
            started = True
            air.append(r)
        elif started:
            break
    if not air:
        return out
    n = len(air)
    out.update({
        "air_s": round(f(air[-1], "t") - f(air[0], "t"), 2),
        "gs_mean": round(sum(f(r, "gs") for r in air) / n, 2),
        "ias_mean": round(sum(f(r, "ias") for r in air) / n, 2),
        "ias_min": round(min(f(r, "ias") for r in air), 2),
        "alpha_max": round(max(f(r, "alpha_m") for r in air), 1),
        "alpha_gt16": round(sum(1 for r in air if f(r, "alpha_m") > 16) / n, 2),
        "bank_absmax": round(max(abs(f(r, "bank")) for r in air), 1),
        "w_mean": round(sum(f(r, "ww") for r in air) / n, 2),
        "u_mean": round(sum((f(r, "wu") ** 2 + f(r, "wv") ** 2) ** 0.5 for r in air) / n, 2),
        "agl_max": round(max(f(r, "agl") for r in air), 2),
    })
    return out


def main(argv):
    csv_out = None
    dirs = []
    i = 0
    while i < len(argv):
        if argv[i] == "--csv":
            csv_out = argv[i + 1]; i += 2; continue
        dirs.append(argv[i]); i += 1
    rows = []
    for d in dirs:
        for part in sorted(glob.glob(os.path.join(d, "part_*"))):
            rj = os.path.join(part, "runs.jsonl")
            if not os.path.exists(rj):
                continue
            for line in open(rj):
                run = json.loads(line)
                if run["result"] in ("ok", "error"):
                    continue
                tp = os.path.join(part, "trace_%s_%d.csv" % (run["loc"], run["seed"]))
                tr = load_trace(tp) if os.path.exists(tp) else []
                c = classify(run, tr)
                c.update({k: run[k] for k in ("loc", "wing", "weather", "seed", "tag", "result")})
                rows.append(c)
    keys = ["loc", "wing", "weather", "tag", "seed", "result", "mech", "air_s", "gs_mean", "ias_mean",
            "ias_min", "alpha_max", "alpha_gt16", "bank_absmax", "w_mean", "u_mean", "agl_max"]
    if csv_out:
        with open(csv_out, "w") as fo:
            w = csv.DictWriter(fo, keys, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow(r)
    from collections import Counter, defaultdict
    by = defaultdict(Counter)
    for r in rows:
        by[(r["loc"], r["wing"], r["weather"], r["tag"])][r["mech"]] += 1
    print("| место | крыло | погода | вариант | roll_over_ground | gust_hop | low_hop | прочее |")
    print("|---|---|---|---|---|---|---|---|")
    for k in sorted(by):
        c = by[k]
        print("| %s | %s | %s | %s | %d | %d | %d | %d |" % (k[0], k[1] or "—", k[2] or "—", k[3], c["roll_over_ground"],
              c["gust_hop"], c["low_hop"], c["other"] + c["no_takeoff"]))
    lows = [r for r in rows if r["mech"] == "low_hop" and "gs_mean" in r]
    if lows:
        def m(k):
            v = [r[k] for r in lows]
            return sum(v) / len(v)
        print("\nlow_hop (n=%d): полёт %.1f с, путевая %.2f м/с, воздушная %.2f (min %.2f), α max %.1f°, доля α>16° %.2f, "
              "|крен| max %.1f°, w %.2f, встречный %.2f, AGL max %.2f" % (len(lows), m("air_s"), m("gs_mean"), m("ias_mean"),
              m("ias_min"), m("alpha_max"), m("alpha_gt16"), m("bank_absmax"), m("w_mean"), m("u_mean"), m("agl_max")))


if __name__ == "__main__":
    main(sys.argv[1:])
