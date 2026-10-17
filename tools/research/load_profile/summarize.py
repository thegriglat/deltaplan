#!/usr/bin/env python3
"""Сводка логов зонда: этапы ([load]) и метки ([lp]) по запускам → table_stages.csv, table_lp.csv, results.json."""
import csv
import json
import re
import sys
from pathlib import Path

here = Path(__file__).parent
logs = sorted((here / "logs").glob("*.log"))
runs = {}
for p in logs:
    tag = p.stem
    stages, lp, extra = {}, {}, {}
    for line in p.read_text(errors="replace").splitlines():
        m = re.match(r"load_probe: этап (\S+)\s+([\d.]+) с", line)
        if m:
            stages[m[1]] = round(stages.get(m[1], 0.0) + float(m[2]), 3)
        m = re.match(r"\[lp\] (\S+) ([\d.]+) @", line)
        if m:
            lp.setdefault(m[1], []).append(float(m[2]))
        m = re.match(r"load_probe: итог (\S+) за ([\d.]+) с", line)
        if m:
            extra["outcome"], extra["total_s"] = m[1], float(m[2])
        m = re.match(r"\[lpfly\] FLYING @[\d.]+ \(от нажатия ([\d.]+) с\)", line)
        if m:
            extra["to_flying_s"] = float(m[1])
        m = re.match(r"\[lpfly\] после старта \d+ с: кадров (\d+), макс. интервал (\d+) мс", line)
        if m:
            extra["after_frames"], extra["after_max_gap_ms"] = int(m[1]), int(m[2])
        m = re.match(r"Terrain: место \S+ загружено за ([\d.]+) с", line)
        if m:
            extra["terrain_loaded_s"] = float(m[1])
        m = re.match(r"WorldObjects: '\S+' за [\d.]+ с — .*домов (\d+), OSM тайлов (\d+)/(\d+)", line)
        if m:
            extra["houses"], extra["osm_tiles"] = int(m[1]), f"{m[2]}/{m[3]}"
    runs[tag] = {"stages_s": stages, "lp_ms": {k: round(sum(v), 1) for k, v in lp.items()}, **extra}
(here / "results.json").write_text(json.dumps(runs, ensure_ascii=False, indent=1))
tags = list(runs)
keys_s = []
for r in runs.values():
    keys_s += [k for k in r["stages_s"] if k not in keys_s]
with open(here / "table_stages.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["stage_s"] + tags)
    for k in keys_s + ["terrain_loaded_s", "to_flying_s", "after_max_gap_ms"]:
        w.writerow([k] + [runs[t]["stages_s"].get(k, runs[t].get(k, "")) for t in tags])
keys = []
for r in runs.values():
    keys += [k for k in r["lp_ms"] if k not in keys]
with open(here / "table_lp.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["label_ms"] + tags)
    for k in keys:
        w.writerow([k] + [runs[t]["lp_ms"].get(k, "") for t in tags])
print((here / "table_stages.csv").read_text())
