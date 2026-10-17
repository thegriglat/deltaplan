#!/usr/bin/env python3
"""Цена прохода облаков (CLF-5) из прогона tools/bench/frame_profile.sh <run> "<пресет>" ongudai:
среднее по строкам base/base2 каждой отметки, затем максимум по отметкам (как frame_profile_compare).
   python3 tools/shots/cloud_field/cost.py <run_medium> [<run_high>] > cost.json"""
import glob, json, os, statistics, sys

CLOUD = "Process Post Transparent Compositor Effects"


def marks(run, preset):
    out = {}
    for f in sorted(glob.glob(os.path.join(run, f"{preset}_ongudai_*.jsonl"))):
        name = os.path.basename(f)[:-6]
        if name.endswith(("_fly", "_air_chunks")):
            continue
        vals = []
        for line in open(f):
            if not line.strip():
                continue
            r = json.loads(line)
            if r.get("exp") not in ("base", "base2"):
                continue
            for k, v in (r.get("passes") or {}).items():
                if CLOUD in k and v is not None:
                    vals.append(v)
        if vals:
            out[name] = round(statistics.mean(vals), 3)
    return out


res = {}
m = marks(sys.argv[1], "medium")
res["cloud_pass_ms_medium_marks"] = m
res["cloud_pass_ms_medium_max"] = max(m.values()) if m else None
if len(sys.argv) > 2:
    h = marks(sys.argv[2], "high")
    res["cloud_pass_ms_high_marks"] = h
    res["high_max"] = max(h.values()) if h else None
print(json.dumps(res, ensure_ascii=False, indent=1))
