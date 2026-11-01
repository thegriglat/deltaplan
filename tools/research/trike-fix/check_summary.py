#!/usr/bin/env python3
"""Контрактный тест TKF-К1 v1: схема и единицы summary.json. Использование: check_summary.py <summary.json>."""
import json, math, sys
from pathlib import Path

REQ = ["trim_full", "push_full", "pull_full", "throttle_step", "turn30_half", "turn30_idle", "turn45_half",
       "turn45_idle", "reversal45", "roll_pump", "pitch_pump"]
RANGES = ["airspeed_kmh", "bar_deg_vis", "bar_deg_phys", "roll_rel_deg_vis", "roll_rel_deg_phys",
          "yaw_rel_deg_vis", "yaw_rel_deg_phys"]
SCALARS = ["duration_s", "mast_normal_deg_max_vis", "mast_normal_deg_max_phys", "vis_lag_deg_max"]


def main(path: str) -> int:
    err = []
    s = json.load(open(path))
    if s.get("version") != 1:
        err.append("version != 1")
    for k in ("dt_s", "git", "limits", "scenarios"):
        if k not in s:
            err.append("нет ключа " + k)
    if err:
        print("\n".join(err)); return 1
    if not (0 < s["dt_s"] < 0.1):
        err.append("dt_s вне (0; 0,1)")
    root = Path(__file__).resolve().parents[3]
    tp = json.load(open(root / "tools/blender/trike_params.json"))["bar"]
    for k, kk in (("push_deg", "push_deg"), ("pull_deg", "pull_deg")):
        if abs(s["limits"].get(k, math.nan) - tp[kk]) > 0.01:
            err.append(f"limits.{k} {s['limits'].get(k)} != trike_params.json {tp[kk]}")
    sc = s["scenarios"]
    for n in REQ:
        if n not in sc:
            err.append("нет сценария " + n); continue
        v = sc[n]
        if not isinstance(v.get("throttle"), str):
            err.append(f"{n}: throttle не строка")
        for k in SCALARS:
            x = v.get(k)
            if not isinstance(x, (int, float)) or not math.isfinite(x):
                err.append(f"{n}.{k}: не число")
        for k in RANGES:
            r = v.get(k)
            if not (isinstance(r, list) and len(r) == 2 and all(isinstance(x, (int, float)) and math.isfinite(x) for x in r)):
                err.append(f"{n}.{k}: не [min, max] конечных"); continue
            if r[0] > r[1]:
                err.append(f"{n}.{k}: min > max")
        if v.get("vis_lag_deg_max", 0) < 0 or v.get("mast_normal_deg_max_vis", 0) < 0:
            err.append(f"{n}: отрицательный угол")
        if not (Path(path).parent / f"{n}.csv").exists():
            err.append(f"нет {n}.csv")
    print("\n".join(err) if err else "OK")
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
