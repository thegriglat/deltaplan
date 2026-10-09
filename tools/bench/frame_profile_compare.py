#!/usr/bin/env python3
"""Таблица до/после для PF-10: сравнение двух прогонов frame_profile.sh (PF-1 «до», PF-10 «после»).
   python3 tools/bench/frame_profile_compare.py <dir_до> <dir_после>   (оба — каталоги с *.jsonl)"""
import json, sys, os, statistics as st

CLOUD = "Process Post Transparent Compositor Effects"

def load(d, name):
    p = os.path.join(d, name + ".jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p) if l.strip()]

def rows(d, name, exp):
    return [r for r in load(d, name) if r.get("exp") == exp]

def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else None

def f(x, n=1):
    return "—" if x is None else f"{x:.{n}f}".replace(".", ",")

def base_gpu(d, p, loc, mark, nocloud=False):
    nm = f"{p}_{loc}_{mark}" + ("_noclouds" if nocloud else "")
    rs = rows(d, nm, "base") + rows(d, nm, "base2")
    return rs

def cloud_pass(r):
    for k, v in (r.get("passes") or {}).items():
        if CLOUD in k:
            return v
    return None

def fly_rows(d, p, loc):
    return rows(d, f"{p}_{loc}_fly", "fly")

def hitches(d, p, loc):
    h = rows(d, f"{p}_{loc}_fly", "_hitches")
    return h[0]["hitches"] if h else []

def main(a, b):
    out = []
    P = out.append
    P("| величина | пресет | до (PF-1) | после (PF-10) |")
    P("|---|---|---|---|")
    for p in ("medium", "low", "high"):
        for mark, lab in (("2", "кабина@2"), ("30", "сзади@30"), ("60", "сзади@60")):
            res = []
            for d in (a, b):
                rs = base_gpu(d, p, "ongudai", mark)
                res.append((mean([r["gpu_ms"] for r in rs]), mean([r["frame_ms"] for r in rs]),
                            mean([cloud_pass(r) for r in rs])))
            if res[0][0] is None and res[1][0] is None:
                continue
            P(f"| GPU / кадр по стене / проход облаков, мс, {lab} | {p} | "
              + " | ".join(f"{f(x[0])} / {f(x[1])} / {f(x[2])}" for x in res) + " |")
    for p in ("medium", "high"):
        res = []
        for d in (a, b):
            ds = []
            for mark in ("2", "30", "60"):
                bs = [r["gpu_ms"] for r in base_gpu(d, p, "ongudai", mark, True)]
                gs = [r["gpu_ms"] for r in rows(d, f"{p}_ongudai_{mark}_noclouds", "nograss")]
                if bs and gs:
                    ds.append(mean(bs) - mean(gs))
            res.append(mean(ds))
        P(f"| трава (base − nograss без облаков), среднее по отметкам, мс | {p} | {f(res[0],2)} | {f(res[1],2)} |")
    for p in ("medium", "low", "high"):
        res = []
        for d in (a, b):
            fr = fly_rows(d, p, "ongudai")
            res.append((min([r["frame_ms"] for r in fr], default=None), max([r["frame_ms"] for r in fr], default=None),
                        min([r["frame_ms_1pct"] for r in fr], default=None), max([r["frame_ms_1pct"] for r in fr], default=None)))
        P(f"| полёт: кадр мин–макс / 1 %-худших мин–макс, мс | {p} | "
          + " | ".join(f"{f(x[0])}–{f(x[1])} / {f(x[2])}–{f(x[3])}" for x in res) + " |")
    for p in ("medium", "low", "high"):
        res = []
        for d in (a, b):
            h = hitches(d, p, "ongudai")
            late = [x["ms"] for x in h if x["sim_t"] > 2.0]
            first = [x["ms"] for x in h if x["sim_t"] <= 0.05]
            res.append((max(late, default=None), max(first, default=None)))
        P(f"| рывки: максимум после 2 с / первый кадр, мс | {p} | "
          + " | ".join(f"{f(x[0],0)} / {f(x[1],0)}" for x in res) + " |")
    for p in ("medium", "low", "high"):
        res = []
        for d in (a, b):
            bz = rows(d, f"{p}_ongudai_fly", "air_busy")
            idl = rows(d, f"{p}_ongudai_fly", "air_idle")
            res.append((mean([r["frame_ms"] for r in bz]), mean([r["frame_ms"] for r in idl]),
                        mean([r["frame_ms_1pct"] for r in bz]), max([max(r.get("frames_list", [0])) for r in bz], default=None)))
        P(f"| кадр при пересчёте поля busy / idle, мс; 1 %-худших busy; худший кадр busy | {p} | "
          + " | ".join(f"{f(x[0])} / {f(x[1])}; {f(x[2])}; {f(x[3])}" for x in res) + " |")
    print("\n".join(out))

main(sys.argv[1], sys.argv[2])
