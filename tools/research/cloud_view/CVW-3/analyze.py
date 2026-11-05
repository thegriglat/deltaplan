#!/usr/bin/env python3
"""CVW-3: after.json из m13.csv/m18.csv (после) и CVW-2 mv13/mv18 (до).
Окно — кадры с |cam_y_msl - cloud_base_msl| <= 50 м; шаг — между соседними кадрами прохода (x_mode game_vn)."""
import csv, json, sys, os

here = os.path.dirname(os.path.abspath(__file__))
before_dir = os.path.join(here, "..", "CVW-2")


def load(path, mode_prefix="game"):
    rows = [r for r in csv.DictReader(open(path, encoding="utf-8")) if r["x_mode"].startswith(mode_prefix)]
    return rows


def f(r, k):
    return float(r[k]) if r[k] != "" else float("nan")


def steps(rows):
    sky, oth, n = 0.0, 0.0, 0
    for a, b in zip(rows, rows[1:]):
        for r in (a, b):
            if abs(f(r, "cam_y_msl") - f(r, "cloud_base_msl")) > 50.0:
                break
        else:
            n += 1
            sky = max(sky, abs(f(b, "x_bg_g") - f(a, "x_bg_g")))
            for c in "rgb":
                oth = max(oth, abs(f(b, "x_other_" + c) - f(a, "x_other_" + c)))
    return sky, oth, n


res = {"hours": {}}
fog1 = 0.0
for tag, h, src in (("after", "13", "m13.csv"), ("after", "18", "m18.csv"), ("before", "13", "mv13.csv"), ("before", "18", "mv18.csv")):
    p = os.path.join(here if tag == "after" else before_dir, src)
    if not os.path.exists(p):
        continue
    rows = load(p)
    s, o, n = steps(rows)
    res["hours"][f"{tag}_{h}"] = {"sky_g_step_max": s, "other_rgb_step_max": o, "frames_in_window": n}
    if tag == "after":
        fd = [f(r, "fog_density") for r in rows if f(r, "whiteout_amount") >= 0.95]
        if fd:
            fog1 = max(fog1, max(fd))
for tag in ("after", "before"):
    v = [d for k, d in res["hours"].items() if k.startswith(tag)]
    res[tag] = {"sky_g_step_max": max((d["sky_g_step_max"] for d in v), default=None),
                "other_rgb_step_max": max((d["other_rgb_step_max"] for d in v), default=None)}
out = {"sky_g_step_max": res["after"]["sky_g_step_max"], "other_rgb_step_max": res["after"]["other_rgb_step_max"],
       "fog_density_at_amount1": json.load(open(os.path.join(here, "amount1.json")))["fog_density"], "before": res["before"], "per_hour": res["hours"]}
json.dump(out, open(os.path.join(here, "after.json"), "w"), indent=1)
print(json.dumps(out, indent=1))
