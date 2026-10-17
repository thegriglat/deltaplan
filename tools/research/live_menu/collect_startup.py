#!/usr/bin/env python3
"""Сборка startup.json (LM-K1 v1) из raw/<variant>-<n>.{t0,log}: collect_startup.py <raw> <build> <out>."""
import json
import re
import sys
from pathlib import Path


def num(m, g=1, cast=float):
    return cast(m.group(g)) if m else None


def main(raw: Path, build: str, out: str) -> None:
    runs = []
    for variant in ("main", "proto"):
        for i in (1, 2, 3, 4, 5):
            lg, t0f = raw / f"{variant}-{i}.log", raw / f"{variant}-{i}.t0"
            if not lg.exists():
                continue
            t0 = float(t0f.read_text())
            txt = lg.read_text()
            menu = re.search(r"PERF menu_ms=\d+ unix=([0-9.]+)", txt)
            win = re.search(r"PERF menu_window s=\d+ frames=(\d+) median_ms=(\d+) worst_ms=(\d+) hitches=(\d+) total_ms=(\d+)", txt)
            wr = re.search(r"PERF menu_world_ready unix=([0-9.]+) baked=([01])", txt)
            fly = re.search(r"PERF fly_ms=(\d+)", txt)
            hit = re.search(r"PERF hitches=(\d+) total_ms=\d+ worst_ms=\d+ frames=\d+ median_ms=\d+ max_ms=(\d+)", txt)
            runs.append({
                "variant": variant, "run": i, "kind": "cold" if i == 1 else "warm",
                "menu_s": round(float(menu.group(1)) - t0, 2) if menu else None,
                "menu_frames": int(win.group(1)) if win else None,
                "menu_median_ms": int(win.group(2)) if win else None,
                "menu_worst_ms": int(win.group(3)) if win else None,
                "menu_hitches": int(win.group(4)) if win else None,
                "menu_hitch_total_ms": int(win.group(5)) if win else None,
                "world_ready_s": round(float(wr.group(1)) - t0, 2) if wr else None,
                "baked": (wr.group(2) == "1") if wr else None,
                "fly_ms": int(fly.group(1)) if fly else None,
                "fly_worst_ms": int(hit.group(2)) if hit else None,
                "fly_hitches": int(hit.group(1)) if hit else None,
            })
    json.dump({"version": 1, "build": build, "display": "1920x1080", "runs": runs},
              open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
