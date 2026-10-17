#!/usr/bin/env python3
"""VI-7: источники термиков над водой до/после правки — три места у моря.

  python3 tools/research/sea_thermals/report.py --run before   # прогон (окно DISPLAY=:0, поле GPU), код без правки
  python3 tools/research/sea_thermals/report.py --run after    # то же с правкой
  python3 tools/research/sea_thermals/report.py --show         # строки '<место> water_sources_after=M water_sources_before=N total=T …'

Сырые прогоны — out/<место>_<тег>.json (не в git), сводка — summary.json (в git).
Вода в точке — как Terrain.is_sea: класс WATER или (класс NONE и высота ≤ 0,5 м).
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out"
SUMMARY = HERE / "summary.json"
PROFILE = Path.home() / ".cache/dp-xdg" / ROOT.name
WATER, NONE, SEA_H = 6, 0, 0.5

CASES = {
    "training_island": ["--loc=training_island", "--site=thermal_plain"],
    "volcano_island": ["--loc=volcano_island", "--site=plateau_landing", "--month=1", "--day=15", "--hour=12",
                       "--sky=clear", "--temp=28", "--wind=2", "--from=110"],
    "pt_-27.700_-048.800": ["--loc=pt_-27.700_-048.800", "--latlon=-27.7176,-48.7799", "--month=1", "--day=15", "--hour=12", "--sky=clear",
                            "--temp=28", "--wind=2", "--from=90"],
}


def is_water(cls, h):
    return cls == WATER or (cls == NONE and h <= SEA_H)


def p(vals, q):
    if not vals:
        return None
    v = sorted(vals)
    return round(v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))], 3)


def summarize(d):
    src, cells = d["sources"], d["cells"]
    ws = [r for r in src if is_water(r[3], r[2])]
    wc = [r for r in cells if is_water(r[3], r[2])]
    land_w0 = [r[4] for r in src if not is_water(r[3], r[2])]
    return {
        "total": len(src) + len(cells), "water": len(ws) + len(wc),
        "sources": len(src), "sources_water": len(ws), "sources_water_class": len([r for r in ws if r[3] == WATER]),
        "cells": len(cells), "cells_water": len(wc),
        "land_w0_p50": p(land_w0, 0.5), "land_w0_p90": p(land_w0, 0.9),
        "water_w0_p90": p([r[4] for r in ws], 0.9), "water_heat_p50": p([r[5] for r in ws], 0.5),
        "air_field_on": d["info"].get("air_field_on"), "level_dx": d["info"].get("level_dx"), "land_ms": d["info"].get("land_ms"),
        "air_runtime": d["info"].get("air_runtime"), "cond": d["cond"],
    }


def run(tag, only):
    OUT.mkdir(exist_ok=True)
    s = json.loads(SUMMARY.read_text()) if SUMMARY.exists() else {}
    env = dict(os.environ, XDG_DATA_HOME=str(PROFILE), DISPLAY=os.environ.get("DISPLAY", ":0"))
    for name, args in CASES.items():
        if only and name not in only:
            continue
        raw = OUT / f"{name}_{tag}.json"
        log = OUT / f"{name}_{tag}.log"
        cmd = ["timeout", "1200", "godot", "--path", str(ROOT), "--audio-driver", "Dummy", "--resolution", "1280x720",
               "--disable-vsync", "res://tools/research/sea_thermals/sea_run.tscn", "--", *args, f"--out={raw}"]
        with open(log, "w") as f:
            r = subprocess.run(cmd, env=env, stdout=f, stderr=subprocess.STDOUT, check=False)
        if r.returncode != 0 or not raw.exists():
            sys.exit(f"{name}: код {r.returncode}, лог {log}")
        d = summarize(json.loads(raw.read_text()))
        if not d["air_field_on"]:
            sys.exit(f"{name}: поле воздуха не посчитано (аналитика), лог {log}")
        s.setdefault(name, {})[tag] = d
        print(name, tag, {k: d[k] for k in ("total", "water", "sources", "sources_water", "cells_water", "land_w0_p90")})
        SUMMARY.write_text(json.dumps(s, ensure_ascii=False, indent=1))


def show():
    s = json.loads(SUMMARY.read_text())
    for name in CASES:
        b, a = s.get(name, {}).get("before", {}), s.get(name, {}).get("after", {})
        print(f"{name} water_sources_after={a.get('water')} water_sources_before={b.get('water')} total={a.get('total')}"
              f" total_before={b.get('total')} land_w0_p90_before={b.get('land_w0_p90')}"
              f" land_w0_p90_after={a.get('land_w0_p90')}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", choices=["before", "after"])
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    if a.run:
        run(a.run, a.only)
    if a.show or not a.run:
        show()
