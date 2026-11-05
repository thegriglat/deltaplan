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
    sky, oth, n, ter = 0.0, 0.0, 0, 0.0
    for a, b in zip(rows, rows[1:]):
        for r in (a, b):
            if abs(f(r, "cam_y_msl") - f(r, "cloud_base_msl")) > 50.0:
                break
        else:
            n += 1
            sky = max(sky, abs(f(b, "x_bg_g") - f(a, "x_bg_g")))
            if "x_terr_luma" in a and a["x_terr_luma"] != "" and b["x_terr_luma"] != "":
                ter = max(ter, abs(f(b, "x_terr_luma") - f(a, "x_terr_luma")))
            for c in "rgb":
                oth = max(oth, abs(f(b, "x_other_" + c) - f(a, "x_other_" + c)))
    return sky, oth, n, ter


res = {"hours": {}}
fog1 = 0.0
for tag, h, src in (("after", "13", "m13.csv"), ("after", "18", "m18.csv"), ("before", "13", "mv13.csv"), ("before", "18", "mv18.csv"),
                    ("geo", "13", "geo_m13.csv"), ("geo", "18", "geo_m18.csv")):
    p = os.path.join(before_dir if tag == "before" else here, src)
    if not os.path.exists(p):
        continue
    rows = load(p)
    s, o, n, t = steps(rows)
    res["hours"][f"{tag}_{h}"] = {"sky_g_step_max": s, "other_rgb_step_max": o, "frames_in_window": n, "terrain_step_max": t}
    if tag == "after":
        fd = [f(r, "fog_density") for r in rows if f(r, "whiteout_amount") >= 0.95]
        if fd:
            fog1 = max(fog1, max(fd))
for tag in ("after", "before", "geo"):
    v = [d for k, d in res["hours"].items() if k.startswith(tag)]
    res[tag] = {"sky_g_step_max": max((d["sky_g_step_max"] for d in v), default=None),
                "terrain_step_max": max((d["terrain_step_max"] for d in v), default=None),
                "frames_in_window_min": min((d["frames_in_window"] for d in v), default=None),
                "other_rgb_step_max": max((d["other_rgb_step_max"] for d in v), default=None)}
a1 = json.load(open(os.path.join(here, "amount1.json")))
import subprocess
code = subprocess.run(["git", "log", "-1", "--format=%h", "--", "scripts", "configs"], capture_output=True, text=True, cwd=os.path.join(here, "..", "..", "..", "..")).stdout.strip()
out = {"sky_g_step_max": res["after"]["sky_g_step_max"], "other_rgb_step_max": res["after"]["other_rgb_step_max"],
       "terrain_step_max": res["after"]["terrain_step_max"], "fog_frac_at_L_amount1": a1["fog_frac_at_L"],
       "fog_frac_at_20km_amount1": a1["fog_frac_at_20km"], "L_m": a1["L"], "frames_in_window_min": res["after"]["frames_in_window_min"],
       "code_commit": code, "before_linear_cvw2": res["before"], "before_geometric": res["geo"], "per_hour": res["hours"]}
json.dump(out, open(os.path.join(here, "after.json"), "w"), indent=1)
print(json.dumps(out, indent=1))
