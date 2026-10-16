"""Быстрая проверка воздуха учебного острова (для шлюза 1, не подбор погоды): три набора на поле GPU игры
(air_probe.tscn, окно на DISPLAY=:0), итог — out/air_quick.json.

  склон  — 6 м/с с 270°, 12 ч, 15 июля, partly; w над склоном: 50–150 м над гребнем, 100–300 м с наветра,
           вдоль хребта ±1 км от старта ridge_west;
  ротор  — 9 м/с с 270°, 12 ч, 15 июля, partly; w и обратный ветер в чаше: 30–150 м над землёй, 0,5–1,5 км
           с подветра от гребня, вдоль чаши; ветер «на старте» ridge_west (rotor) и lee_bowl (rotor_lee);
  термики — 2 м/с с 270°, 12 ч, 15 июля, 30 °C, partly; w_conv поля на 150 и 300 м над землёй по сетке 250 м
           ±5 км у старта thermal_plain, по классу земли (пашня/грунт, луг, лес, вода) + сила источника.

  tools/terrain/island/.venv/bin/python tools/terrain/island/air_quick.py          # счёт (≈ 3 × 1–3 мин)
  python3 tools/terrain/island/air_quick.py --show                                 # печать главных чисел
Час — слот configs/world.json → time.start_hours (12). Место — копия data/locations/training_island
в user://locations своего профиля (как shots.sh).
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out"
RES = OUT / "air_quick.json"

CASES = {
    "ridge": dict(site="ridge_west", wind=6.0, wdir=270.0, hour=12, tmax="nan", sky="partly"),
    # ветер меню задаётся «на старте» (AirRuntime: приток подгоняется под u10 на 10 м над стартом): у старта в
    # роторе приток упирается в INFLOW_K_MAX = 3, поэтому главный ротор — с калибровкой на наветренном старте,
    # rotor_lee — как в игре со старта lee_bowl (для сравнения)
    "rotor": dict(site="ridge_west", wind=9.0, wdir=270.0, hour=12, tmax="nan", sky="partly"),
    "rotor_lee": dict(site="lee_bowl", wind=9.0, wdir=270.0, hour=12, tmax="nan", sky="partly"),
    "thermal": dict(site="thermal_plain", wind=2.0, wdir=270.0, hour=12, tmax="30", sky="partly"),
}
CLASS_NAMES = {1: "forest", 2: "grass", 3: "crop", 4: "shrub", 5: "bare", 6: "water", 7: "built"}


def show():
    r = json.loads(RES.read_text())
    s = r["summary"]
    for k in ("ridge_w_ms", "ridge_w_min_ms", "ridge_w_max_ms", "rotor_w_min_ms", "rotor_w_mean_ms", "rotor_reverse",
              "rotor_u_min_ms", "rotor_lee_w_min_ms", "rotor_lee_reverse", "rotor_lee_u_min_ms", "thermal_w_fields_ms", "thermal_w_water_ms", "thermal_w_fields_p90_ms", "thermal_w_water_p90_ms", "thermal_w_forest_ms", "thermal_w_grass_ms",
              "thermal_src_crop", "thermal_src_bare", "thermal_src_grass", "thermal_src_forest", "thermal_src_water"):
        v = s.get(k)
        print(f"{k}={v}")


def points(case):
    sys.path.insert(0, str(HERE))
    import _venv
    _venv.ensure("numpy", "PIL")
    import numpy as np
    import check_sites
    import sites as S
    pl = check_sites.load(ROOT / "data/locations/training_island")
    cfg = json.loads((ROOT / "configs/locations/training_island.json").read_text())
    st = {s["id"]: s for s in cfg["start_sites"]}
    pos = {k: S.latlon_to_local(v["lat"], v["lon"], cfg["center_lat"], cfg["center_lon"]) for k, v in st.items()}

    def crest(z, x0, x1):
        xs = np.arange(x0, x1, 10.0)
        hs = [pl.height(float(x), z) for x in xs]
        k = int(np.argmax(hs))
        return float(xs[k]), float(hs[k])

    pts, tags = [], []
    if case == "ridge":
        xs, zs = pos["ridge_west"]
        for dz in range(-1000, 1001, 250):
            z = zs + dz
            xc, hc = crest(z, xs - 600, xs + 800)
            for d in (100, 200, 300):
                x = xc - d
                for a in (50, 100, 150):
                    pts.append([x, z, round(hc + a - pl.height(x, z), 2)])
                    tags.append({"dz": dz, "upwind_m": d, "above_crest_m": a, "crest_x": xc, "crest_h": round(hc, 1)})
    elif case in ("rotor", "rotor_lee"):
        xs, zs = pos["lee_bowl"]
        for z in range(-2000, -499, 250):
            xc, hc = crest(float(z), -5600, -4300)
            for d in (500, 750, 1000, 1250, 1500):
                for a in (30, 60, 100, 150):
                    pts.append([xc + d, float(z), a])
                    tags.append({"z": z, "downwind_m": d, "agl_m": a, "crest_x": xc, "crest_h": round(hc, 1)})
    else:
        xs, zs = pos["thermal_plain"]
        for j in range(-20, 21):
            for i in range(-20, 21):
                for a in (150, 300):
                    pts.append([xs + 250.0 * i, zs + 250.0 * j, a])
                    tags.append({"agl_m": a})
    return pts, tags


def run_case(name, prof):
    c = CASES[name]
    pts, tags = points(name)
    OUT.mkdir(exist_ok=True)
    pfile = OUT / f"points_{name}.json"
    pfile.write_text(json.dumps(pts))
    raw = OUT / f"probe_{name}.json"
    env = dict(os.environ, XDG_DATA_HOME=prof, DISPLAY=os.environ.get("DISPLAY", ":0"))
    cmd = ["godot", "--path", str(ROOT), "--audio-driver", "Dummy", "--resolution", "320x240", "--disable-vsync",
           "res://tools/terrain/island/air_probe.tscn", "--", f"--site={c['site']}", f"--wind={c['wind']}",
           f"--from={c['wdir']}", f"--hour={c['hour']}", "--month=7", "--day=15", f"--tmax={c['tmax']}",
           f"--sky={c['sky']}", f"--points={pfile}", f"--out={raw}"]
    log = OUT / f"probe_{name}.log"
    with open(log, "w") as f:
        subprocess.run(["timeout", "900"] + cmd, env=env, stdout=f, stderr=subprocess.STDOUT, check=False)
    d = json.loads(raw.read_text())
    d["tags"] = tags
    raw.write_text(json.dumps(d))
    return d


def _mean(v):
    return round(sum(v) / len(v), 3) if v else None


def _p90(v):
    if not v:
        return None
    v = sorted(v)
    k = 0.9 * (len(v) - 1)
    i = int(k)
    return round(v[i] + (v[min(i + 1, len(v) - 1)] - v[i]) * (k - i), 3)


def summarize(res):
    s = {}
    r = res["ridge"]
    w = [row[8] for row in r["rows"]]
    s["ridge_w_ms"] = _mean(w)
    s["ridge_w_min_ms"], s["ridge_w_max_ms"] = round(min(w), 3), round(max(w), 3)
    tab = {}
    for row, t in zip(r["rows"], r["tags"]):
        tab.setdefault(f"{t['upwind_m']}m_up/{t['above_crest_m']}m_above", []).append(row[8])
    s["ridge_table"] = {k: _mean(v) for k, v in sorted(tab.items())}
    for case, pre in (("rotor", "rotor"), ("rotor_lee", "rotor_lee")):
        r = res[case]
        w = [row[8] for row in r["rows"]]
        ue = [row[6] for row in r["rows"]]
        s[f"{pre}_w_min_ms"], s[f"{pre}_w_mean_ms"] = round(min(w), 3), _mean(w)
        s[f"{pre}_u_min_ms"] = round(min(ue), 3)
        s[f"{pre}_reverse"] = round(sum(1 for u in ue if u < 0) / len(ue), 3)   # доля точек с ветром против потока
        tab = {}
        for row, t in zip(r["rows"], r["tags"]):
            tab.setdefault((t["downwind_m"], t["agl_m"]), []).append((row[8], row[6]))
        s[f"{pre}_table"] = {f"{k[0]}m_down/{k[1]}m_agl": {
            "w": _mean([a for a, _ in v]), "u_east": _mean([b for _, b in v]),
            "u_east_min": round(min(b for _, b in v), 3)} for k, v in sorted(tab.items())}
    r = res["thermal"]
    by = {}
    src = {}
    for row in r["rows"]:
        cl = CLASS_NAMES.get(row[4], str(row[4]))
        if row[2] == 150:
            src.setdefault(cl, []).append(row[5])
        if row[11] < 0.5:
            continue
        by.setdefault((cl, int(row[2])), []).append(row[10])
    s["thermal_wconv_by_class"] = {f"{k[0]}@{k[1]}m": {"w_conv": _mean(v), "p90": _p90(v),
                                                       "frac_pos": round(sum(1 for x in v if x > 0) / len(v), 3),
                                                       "n": len(v)} for k, v in sorted(by.items())}
    s["thermal_src_by_class"] = {k: {"mean": _mean(v), "n": len(v)} for k, v in sorted(src.items())}
    fields = by.get(("crop", 150), []) + by.get(("bare", 150), [])
    s["thermal_w_fields_ms"] = _mean(fields)
    s["thermal_w_fields_p90_ms"] = _p90(fields)
    s["thermal_w_water_p90_ms"] = _p90(by.get(("water", 150), []))
    s["thermal_w_water_ms"] = _mean(by.get(("water", 150), []))
    s["thermal_w_forest_ms"] = _mean(by.get(("forest", 150), []))
    s["thermal_w_grass_ms"] = _mean(by.get(("grass", 150), []))
    for k in ("crop", "bare", "grass", "forest", "water"):
        s[f"thermal_src_{k}"] = _mean(src.get(k, []))
    s["field_ok"] = {k: bool(v["info"].get("solver_ok")) for k, v in res.items()}
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--cases", default="ridge,rotor,rotor_lee,thermal")
    ap.add_argument("--summarize", action="store_true", help="только пересобрать итог из out/probe_*.json")
    a = ap.parse_args()
    if a.show:
        show()
        return
    if a.summarize:
        write({k: json.loads((OUT / f"probe_{k}.json").read_text()) for k in CASES})
        return
    prof = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".cache/dp-xdg" / ROOT.name)
    dst = Path(prof) / "Deltaplan/locations/training_island"
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    for f in (ROOT / "data/locations/training_island").iterdir():
        if f.suffix in (".json", ".webp"):
            shutil.copy2(f, dst / f.name)
    bak = Path(tempfile.mkdtemp()) / "project.godot"
    shutil.copy2(ROOT / "project.godot", bak)
    res = {}
    try:
        for name in a.cases.split(","):
            res[name] = run_case(name, prof)
            print(name, json.dumps(res[name]["info"], ensure_ascii=False)[:300], flush=True)
    finally:
        if (ROOT / "project.godot").read_bytes() != bak.read_bytes():
            shutil.copy2(bak, ROOT / "project.godot")
    if set(res) == set(CASES):
        write(res)


def _info(i):
    si = i.get("solver_info", {})
    return {"solver_ok": i.get("solver_ok"), "unavailable": i.get("unavailable"), "blend_fraction": i.get("blend_fraction"),
            "solver_wall_s": i.get("solver_wall_s"), "engine": si.get("engine"), "not_converged": si.get("not_converged"),
            "inflow_k": si.get("inflow_k"), "levels": i.get("levels")}


def write(res):
    out = {"cases": CASES, "date": "15 июля", "summary": summarize(res),
           "info": {k: _info(v["info"]) for k, v in res.items()}}
    RES.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    show()


if __name__ == "__main__":
    main()
