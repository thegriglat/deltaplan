#!/usr/bin/env python3
"""CVW-1: сводка measures.csv -> summary.json и таблицы (stdout, markdown). Только stdlib.

    python3 analyze.py measures.csv summary.json
"""
import csv
import json
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
F = lambda r, k: float(r[k])
out = {"n_frames": len(rows), "series": {}}
for r in rows:
    key = "%s_h%02d_p%d" % (r["x_flags"], F(r, "hour"), -F(r, "pitch_deg"))
    out["series"].setdefault(key, []).append(
        {
            "agl": F(r, "cam_agl"),
            "msl": F(r, "cam_y_msl"),
            "density": F(r, "density_cam"),
            "whiteout": F(r, "whiteout_amount"),
            "fog_density": F(r, "fog_density"),
            "fog_sky_affect": F(r, "fog_sky_affect"),
            "luma": F(r, "luma_mean"),
            "luma_std": F(r, "luma_std"),
            "sky_rgb": [F(r, "x_sky_r"), F(r, "x_sky_g"), F(r, "x_sky_b")],
        }
    )
json.dump(out, open(sys.argv[2], "w"), indent=1)
for key, s in out["series"].items():
    print("\n### %s" % key)
    print("| AGL, м | плотность | whiteout | fog_density | luma | std | небо R,G,B (верх 1/4) |")
    print("|---|---|---|---|---|---|---|")
    for e in s:
        print(
            "| %.0f | %.3f | %.3f | %.4f | %.3f | %.3f | %.2f, %.2f, %.2f |"
            % (e["agl"], e["density"], e["whiteout"], e["fog_density"], e["luma"], e["luma_std"], *e["sky_rgb"])
        )
