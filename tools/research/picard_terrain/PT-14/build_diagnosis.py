#!/usr/bin/env python3
"""Собирает out/PT-14/diagnosis.json из логов Godot и json зондов крейта (команды — README.md)."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_probe import read
from starts_table import collect

R = os.path.expanduser("~/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/")
L, P = R + "logs/", R + "probe/"
SH = ["f44c66b4a", "4316db7e0", "9d94bf30c"]
NAME = {"f44c66b4a": "до PT-9/PT-10", "4316db7e0": "PT-9 слита", "9d94bf30c": "PT-10 слита"}

def gd_result(sha, log, test):
    t = open(L + f"{sha}-{log}.log", errors="replace").read()
    m = re.search(rf"^\s+(ok|FAIL)\s+\S+::{test}\s*$\n((?:\s{{9}}.*\n)*)", t, re.M)
    return {"status": m.group(1) if m else "?", "msg": " ".join(x.strip() for x in m.group(2).splitlines()) if m else ""}

doc = {"task": "PT-14", "commits": {s: NAME[s] for s in SH}}

# 1. таблица тесты × коммиты
tests = {}
for sha in SH:
    tests.setdefault("field_import::test_load_bytes_of_crate_snapshot", {})[sha] = gd_result(sha, "field_import", "test_load_bytes_of_crate_snapshot")
    tests.setdefault("atmosphere::test_lee_turbulence_stronger", {})[sha] = gd_result(sha, "atmosphere", "test_lee_turbulence_stronger")
    r = gd_result(sha, "lee_rotor", "test_flying_into_lee_loses_height")
    t = open(L + f"{sha}-lee_rotor.log", errors="replace").read()
    m = re.search(r"штиль −(\d+) м, ветер 6 м/с −(\d+) м", t)
    if m: r["calm_m"], r["wind6_m"] = int(m.group(1)), int(m.group(2))
    tests.setdefault("lee_rotor::test_flying_into_lee_loses_height", {})[sha] = r
doc["tests_by_commit"] = tests

# 2. синтетический гребень: дисперсии и полёт, зонд Godot
ridge = {}
for sha in SH:
    d = read(L + f"{sha}-ridge2.log")
    ridge[sha] = {
        "var_w": [x for x in d if x["tag"] == "var"][0] if any(x["tag"] == "var" for x in d) else None,
        "var2": [{k: x[k] for k in ("x_lee", "x_wind", "lee", "wind")} for x in d if x["tag"] == "var2"],
        "fly": [{k: x[k] for k in ("x_meas", "calm", "wind6")} for x in d if x["tag"] == "fly"],
    }
doc["synthetic_ridge_godot"] = ridge

# 3. зонд крейта: поле и каналы на гребне 25 км/ч (входы фасада GDScript)
probe = {}
for sha in SH:
    j = json.load(open(P + f"{sha}-ridge25gd.json"))
    pts = {}
    for p in j["points"]:
        if p["agl"] == 40 and p["x"] in (-900, -600, -300, 0, 150, 250, 350, 500, 800):
            pts[str(int(p["x"]))] = {"uf": p["uf"], "wf": p["wf"], "ustar": p["tb"]["ustar"], "shear": p["tb"]["shear"],
                                       "u_out": p["tb"]["u_out"], "desc": p["tb"]["desc"], "lee_f": p["lee_f"],
                                       "sg_w": p["sg_w"], "sep_w": p["sep_w"], "sw_total": p["sw_total"]}
    cols = [{k: c[k] for k in ("xc", "hc", "k1", "ustar", "u_out", "desc")} | {"u_first_cells": c["u"][:5], "w_first_cells": c["w"][:5]} for c in j["columns"]]
    j6 = json.load(open(P + f"{sha}-ridge6.json"))
    line = [l for l in j6["lines"] if l["y_msl"] == 350][0]["row"]
    av = lambda a, b: sum(r["field_term"][1] for r in line if a <= r["x"] <= b) / len([r for r in line if a <= r["x"] <= b])
    probe[sha] = {"points_agl40_wind25": pts, "columns_wind25": cols, "dx_levels": [l["dx"] for l in j["levels"]],
                  "w_field_mean_y350_wind6": {"x_-250_0": av(-250, 0), "x_0_150": av(0, 150), "x_150_500": av(150, 500), "x_0_500": av(0, 500)}}
doc["synthetic_ridge_crate_probe"] = probe

# 4. старты на реальном рельефе
st = collect()
starts = {}
for site, rows in st.items():
    starts[site] = {}
    for (sha, pin), r in rows.items():
        s = r.get("summary")
        if not s: continue
        entry = {"w_lee": s["w_lee"], "w_wind": s["w_wind"], "sigma_lee": s["sigma_lee"], "sigma_wind": s["sigma_wind"],
                 "p": s["p"]}
        for side in ("lee", "wind"):
            c = r.get(side, {}).get("chan")
            if c and "uf" in c:
                entry[side] = {k: c[k] for k in ("agl", "uf", "wf", "ustar", "shear", "u_out", "a_out", "desc", "lee_f", "hmix", "u_loc_sw")}
        starts[site][f"{sha}@{pin}"] = entry
doc["real_starts"] = starts

# 5. снимок
snap = {}
for sha in SH + ["patch"]:
    d = read(L + f"{sha}-probe_snap.log")
    pts = [x for x in d if x["tag"] == "snap.pt"]
    snap[sha] = {"max_abs_diff_mps": max(p["d"] for p in pts), "max_diff_by_agl_bucket": {str(b): max([p["d"] for p in pts if b <= p["agl"] < b + 100] or [0.0]) for b in (0, 100, 200, 300, 400, 500)}}
doc["snapshot"] = snap
json.dump(doc, open(R + "tables.json", "w"), ensure_ascii=False, indent=1)
print("written", R + "tables.json")
