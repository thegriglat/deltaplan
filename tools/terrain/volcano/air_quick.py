"""Быстрая проверка воздуха вулканического острова (VI-1, для шлюза 1, не подбор погоды): наборы на поле GPU игры
(air_probe.tscn, окно на DISPLAY=:0), итог — out/air_quick.json.

  east_cliffs, crater_ridge — 6 м/с с 110° (пассат), 12 ч, 15 января, partly; w на 50–150 м над бровкой и 100–300 м с наветра
           от неё (бровка: east_cliffs — верх обрыва к морю (самая наветренная точка линии по ветру с h ≥ 100 м, ~950 м от старта), crater_ridge — тоже верх обрыва к морю (~350 м от старта), ±1 км вдоль фронта, шаг 250 м; face — то же в метрах над землёй); ротор — w и доля обратного
           ветра за бровкой с подветра (300–1500 м, 30–150 м над землёй); k притока и ветер у старта — из строки лога air_model;
  thermal — 2 м/с с 110°, 12 ч, 15 января (южное лето), ясно, 27 °C; w_conv поля на 150 и 300 м над землёй по сетке 250 м
           над островом, суша против моря, по классу земли; сила источника.

  tools/terrain/volcano/.venv/bin/python tools/terrain/volcano/air_quick.py          # счёт (≈ 3 × 1–3 мин)
  python3 tools/terrain/volcano/air_quick.py --show                                  # печать главных чисел
Место — bundled, игра читает его из res:// (сети и копирования в профиль нет). Условие остановки VI-1: k притока 3,0 или ветер у старта
> 15 м/с — старт не брать (в --show: east_cliffs_stop=…).
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out"
RES = OUT / "air_quick.json"
sys.path.insert(0, str(HERE))

WDIR = 110.0
CASES = {
    "east_cliffs": dict(site="east_cliffs", wind=6.0, wdir=WDIR, hour=12, tmax="nan", sky="partly", kind="slope", brink="edge"),
    "crater_ridge": dict(site="crater_ridge", wind=6.0, wdir=WDIR, hour=12, tmax="nan", sky="partly", kind="slope", brink="edge"),
    "thermal": dict(site="plateau_landing", wind=2.0, wdir=WDIR, hour=12, tmax="27", sky="clear", kind="thermal"),
}
CLASS_NAMES = {1: "forest", 2: "grass", 3: "crop", 4: "shrub", 5: "bare", 6: "water", 7: "built"}


def show():
    r = json.loads(RES.read_text())
    s = r["summary"]
    for k, v in s.items():
        if isinstance(v, (dict, list)):
            continue
        print(f"{k}={v}")


def points(case):
    import _venv
    _venv.ensure("numpy", "PIL")
    import numpy as np
    import check_sites
    import sites as S
    pl = check_sites.load(ROOT / "data/locations/volcano_island")
    cfg = json.loads((ROOT / "configs/locations/volcano_island.json").read_text())
    st = {s["id"]: s for s in cfg["start_sites"]}
    c = CASES[case]
    pts, tags = [], []
    if c["kind"] == "slope":
        v = st[c["site"]]
        xs, zs = S.latlon_to_local(v["lat"], v["lon"], cfg["center_lat"], cfg["center_lon"])
        ux, uz = S.heading_vec(WDIR)          # на наветренную сторону (откуда дует ветер)
        px, pz = -uz, ux                       # вдоль фронта
        for s in range(-1000, 1001, 250):
            bx, bz = xs + px * s, zs + pz * s
            if c["brink"] == "edge":
                # обрыв к морю: самая наветренная точка линии (до 1,5 км) с высотой ≥ 100 м — верх обрыва
                ts = np.arange(0.0, 1500.1, 10.0)
                hs = [pl.height(bx + ux * float(t), bz + uz * float(t)) for t in ts]
                hi = [i for i, h in enumerate(hs) if h >= 100.0]
                k = max(hi) if hi else int(np.argmax(hs))     # на краях фронта обрыва может не быть — тогда максимум линии
            else:                      # "local": гребень у старта — максимум высоты в 300 м за стартом и 100 м перед ним
                ts = np.arange(-300.0, 100.1, 10.0)
                hs = [pl.height(bx + ux * float(t), bz + uz * float(t)) for t in ts]
                k = int(np.argmax(hs))
            t0 = float(ts[k])
            cx, cz, hc = bx + ux * t0, bz + uz * t0, float(hs[k])
            for d in (100, 200, 300):
                x, z = cx + ux * d, cz + uz * d
                for a in (50, 100, 150):
                    pts.append([x, z, round(hc + a - pl.height(x, z), 2)])
                    tags.append({"kind": "slope", "s": s, "upwind_m": d, "above_crest_m": a, "crest_h": round(hc, 1), "crest_t": t0})
            for d in (100, 200, 300):
                x, z = cx + ux * d, cz + uz * d
                for a in (30, 60, 100):
                    pts.append([x, z, a])
                    tags.append({"kind": "face", "s": s, "upwind_m": d, "agl_m": a, "crest_h": round(hc, 1), "crest_t": t0})
            for d in (300, 600, 900, 1200, 1500):
                x, z = cx - ux * d, cz - uz * d
                for a in (30, 60, 100, 150):
                    pts.append([x, z, a])
                    tags.append({"kind": "rotor", "s": s, "downwind_m": d, "agl_m": a, "crest_h": round(hc, 1), "crest_t": t0})
    else:
        for z in range(-8000, 14001, 250):
            for x in range(-12000, 14001, 250):
                if pl.height(float(x), float(z)) < 0.5:
                    pts.extend([[x, z, 150], [x, z, 300]])
                    tags.extend([{"agl_m": 150, "sea": True}, {"agl_m": 300, "sea": True}])
                else:
                    pts.extend([[x, z, 150], [x, z, 300]])
                    tags.extend([{"agl_m": 150, "sea": False}, {"agl_m": 300, "sea": False}])
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
           "res://tools/terrain/volcano/air_probe.tscn", "--", f"--site={c['site']}", f"--wind={c['wind']}",
           f"--from={c['wdir']}", f"--hour={c['hour']}", "--month=1", "--day=15", f"--tmax={c['tmax']}",
           f"--sky={c['sky']}", f"--points={pfile}", f"--out={raw}"]
    log = OUT / f"probe_{name}.log"
    with open(log, "w") as f:
        subprocess.run(["timeout", "900"] + cmd, env=env, stdout=f, stderr=subprocess.STDOUT, check=False)
    d = json.loads(raw.read_text())
    d["tags"] = tags
    m = re.findall(r"k притока ([\d.]+), U над стартом на 10 м ([\d.]+) м/с", log.read_text())
    d["log_k"] = float(m[-1][0]) if m else None
    d["log_u10"] = float(m[-1][1]) if m else None
    raw.write_text(json.dumps(d))
    return d


def _mean(v):
    return round(sum(v) / len(v), 3) if v else None


def _p(v, q):
    if not v:
        return None
    v = sorted(v)
    k = q * (len(v) - 1)
    i = int(k)
    return round(v[i] + (v[min(i + 1, len(v) - 1)] - v[i]) * (k - i), 3)


def summarize(res):
    s = {}
    wx, wz = math.sin(math.radians(WDIR)), math.cos(math.radians(WDIR))   # (E, N) на наветренную сторону
    for case in ("east_cliffs", "crater_ridge"):
        r = res[case]
        slope = [(row[8], t) for row, t in zip(r["rows"], r["tags"]) if t["kind"] == "slope"]
        w = [a for a, _ in slope]
        s[f"{case}_w_ms"] = _mean(w)
        s[f"{case}_w_min_ms"], s[f"{case}_w_max_ms"] = round(min(w), 3), round(max(w), 3)
        s[f"{case}_w_p10_ms"], s[f"{case}_w_p90_ms"] = _p(w, 0.1), _p(w, 0.9)
        tab = {}
        for a, t in slope:
            tab.setdefault(f"{t['upwind_m']}m_up/{t['above_crest_m']}m_above", []).append(a)
        s[f"{case}_table"] = {k: _mean(v) for k, v in sorted(tab.items())}
        face = [(row[8], t) for row, t in zip(r["rows"], r["tags"]) if t["kind"] == "face"]
        s[f"{case}_face_w_ms"] = _mean([a for a, _ in face])
        tab = {}
        for a, t in face:
            tab.setdefault(f"{t['upwind_m']}m_up/{t['agl_m']}m_agl", []).append(a)
        s[f"{case}_face_table"] = {k: _mean(v) for k, v in sorted(tab.items())}
        rot = [(row, t) for row, t in zip(r["rows"], r["tags"]) if t["kind"] == "rotor"]
        along = [-(row[6] * wx + row[7] * wz) for row, _ in rot]       # составляющая по ветру (вниз по потоку)
        s[f"{case}_rotor_w_min_ms"] = round(min(row[8] for row, _ in rot), 3)
        s[f"{case}_rotor_w_mean_ms"] = _mean([row[8] for row, _ in rot])
        s[f"{case}_rotor_reverse"] = round(sum(1 for u in along if u < 0) / len(along), 3)
        s[f"{case}_rotor_u_min_ms"] = round(min(along), 3)
        tab = {}
        for (row, t), u in zip(rot, along):
            tab.setdefault(f"{t['downwind_m']}m_down/{t['agl_m']}m_agl", []).append((row[8], u))
        s[f"{case}_rotor_table"] = {k: {"w": _mean([a for a, _ in v]), "u_along": _mean([b for _, b in v]),
                                         "u_along_min": round(min(b for _, b in v), 3)} for k, v in sorted(tab.items())}
        s[f"{case}_crest_h_m"] = _mean([t["crest_h"] for _, t in slope])
        s[f"{case}_inflow_k"] = r["log_k"]
        s[f"{case}_u10_start_ms"] = r["log_u10"]
        s[f"{case}_stop"] = bool((r["log_k"] or 0) >= 2.999 or (r["log_u10"] or 0) > 15.0)
    r = res["thermal"]
    by, src = {}, {}
    cover = {"land": [], "sea": []}
    for row, t in zip(r["rows"], r["tags"]):
        cl = "sea" if t["sea"] else CLASS_NAMES.get(row[4], str(row[4]))
        if row[2] == 150:
            cover["sea" if t["sea"] else "land"].append(row[11])
            if not t["sea"]:
                src.setdefault(cl, []).append(row[5])
        if row[11] < 0.5:
            continue
        by.setdefault((cl, int(row[2])), []).append(row[10])
    s["thermal_wconv_by_class"] = {f"{k[0]}@{k[1]}m": {"w_conv": _mean(v), "p90": _p(v, 0.9), "frac_pos": round(sum(1 for x in v if x > 0) / len(v), 3), "n": len(v)}
                                   for k, v in sorted(by.items())}
    s["thermal_src_by_class"] = {k: {"mean": _mean(v), "p90": _p(v, 0.9), "n": len(v)} for k, v in sorted(src.items())}
    for lev in (150, 300):
        land = [x for (cl, a), v in by.items() if a == lev and cl != "sea" and cl != "water" for x in v]
        sea = by.get(("sea", lev), [])
        s[f"thermal_land_w_mean_{lev}m_ms"] = _mean(land)
        s[f"thermal_land_w_p90_{lev}m_ms"] = _p(land, 0.9)
        s[f"thermal_sea_w_mean_{lev}m_ms"] = _mean(sea)
        s[f"thermal_sea_w_p90_{lev}m_ms"] = _p(sea, 0.9)
    s["thermal_field_cover_land"] = _mean(cover["land"])
    s["thermal_field_cover_sea"] = _mean(cover["sea"])
    s["thermal_inflow_k"], s["thermal_u10_start_ms"] = r["log_k"], r["log_u10"]
    s["thermal_exists"] = bool((s["thermal_land_w_p90_150m_ms"] or 0) >= 1.0)
    s["field_ok"] = {k: bool(v["info"].get("solver_ok")) for k, v in res.items()}
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--summarize", action="store_true", help="только пересобрать итог из out/probe_*.json")
    a = ap.parse_args()
    if a.show:
        show()
        return
    if a.summarize:
        write({k: json.loads((OUT / f"probe_{k}.json").read_text()) for k in CASES})
        return
    prof = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".cache/dp-xdg" / ROOT.name)
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
    out = {"cases": CASES, "date": "15 января", "summary": summarize(res),
           "info": {k: _info(v["info"]) for k, v in res.items()}}
    RES.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    show()


if __name__ == "__main__":
    main()
