"""VI-5: проверка воздуха стартов вулканического острова в игре — фиксированная погода старта (TI-К2 v2) из конфига места,
поле GPU (главная сцена с --autostart, air_check_run.tscn, окно DISPLAY=:0). Образец — tools/terrain/island/air_check.py.

  python3 tools/terrain/volcano/air_check.py                    # все случаи (≈ 10 запусков, ≈ 30 мин) + кадры F3/F6 + итог
  python3 tools/terrain/volcano/air_check.py --cases crater6    # часть случаев (итог — из сохранённых сырых файлов)
  python3 tools/terrain/volcano/air_check.py --summarize        # пересобрать итог из out/check_*.json
  python3 tools/terrain/volcano/air_check.py --show             # печать ключ=значение из out/air_check.json

Случаи:
  cliffs6, crater6 — старты east_cliffs, crater_ridge с набором из конфига (кадры F3/F6 → SHOTS); cliffs5/8, crater5/8 — тот же
      набор с ветром 5 и 8 м/с (подмена только в памяти). Точки: бровка — верх обрыва к морю на линии по ветру (самая наветренная
      точка с h ≥ 100 м в 1,5 км от линии фронта); 9 линий вдоль фронта ±1 км (шаг 250 м); «slope» — 100/200/300 м с наветра от
      бровки, 50/100/150 м над ней; «face» — те же 100–300 м, 30/60/100 м над землёй; «start» — 10 м над стартом;
      «rotor» (только crater) — за бровкой с подветра 300–1500 м, 30–150 м над землёй (дно и склоны кратера).
  landing — старт plateau_landing с набором из конфига: ветер на 10/30/60 м над каждой посадкой.
  thermal12, thermal15 — фокус plateau_landing, погода подменена: ясно, 28 °C, 3 м/с с 110°, 12 и 15 ч; w_conv поля на 150/300 м
      над землёй по сетке 250 м над островом и морем вокруг; ядра термиков (300–1200 м) во всей зоне 15 км; 3 вылета кружения.
  thermal_slope — старт thermal_slope с погодой из конфига (запечённое поле): ядра 15 км и вылеты кружения со 100 м над стартом (VI-9).
  thermal_top, thermal_east — та же погода (15 ч), ядра и вылеты кружения от кандидатов старта thermal_slope (--from=x,z,курс; вылет —
      со 100 м над стартом, --climb-agl: на пологих склонах простой пилот с земли до термика не долетает).
w — вертикальная скорость воздуха (Atmosphere.air_velocity_at без болтанки), среднее 5 снимков через 60 с.
Итог — out/air_check.json, сырые — out/check_<случай>.json (не коммитятся).
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
RES = OUT / "air_check.json"
SHOTS = Path("/home/greg/deltaplan/build/screenshots/volcano-island/VI-5")
sys.path.insert(0, str(HERE))
CLASS = {1: "forest", 2: "grass", 3: "crop", 4: "shrub", 5: "bare", 6: "water", 7: "built"}
WDIR = 110.0
TH = dict(sky="clear", temp=28.0, wind=3.0)
CASES = {
    "cliffs6": dict(site="east_cliffs", mode="points", geo="slope", shots=True),
    "cliffs5": dict(site="east_cliffs", mode="points", geo="slope", wind=5.0),
    "cliffs8": dict(site="east_cliffs", mode="points", geo="slope", wind=8.0),
    "crater6": dict(site="crater_ridge", mode="points", geo="slope+rotor", shots=True),
    "crater5": dict(site="crater_ridge", mode="points", geo="slope+rotor", wind=5.0),
    "crater8": dict(site="crater_ridge", mode="points", geo="slope+rotor", wind=8.0),
    "landing": dict(site="plateau_landing", mode="landing"),
    "thermal12": dict(site="plateau_landing", mode="thermal", geo="grid", hour=12, **TH),
    "thermal15": dict(site="plateau_landing", mode="thermal", geo="grid", hour=15, **TH),
    # кандидаты старта thermal_slope (правила стартов проходят): вершина острова и восточное плато; ядра и вылеты — от них
    "thermal_top": dict(site="plateau_landing", mode="thermal", hour=15, frm="-3000,-1450,110", climb_agl=100, **TH),
    "thermal_east": dict(site="plateau_landing", mode="thermal", hour=15, frm="9350,700,140", climb_agl=100, **TH),
    # VI-9: сам старт thermal_slope с погодой из конфига (запечённое поле), ядра и вылеты от старта
    "thermal_slope": dict(site="thermal_slope", mode="thermal", climb_agl=100),
}
THERMAL_R_M = 15000.0
KEYS = ["east_cliffs_w_ms", "east_cliffs_w_p90_ms", "east_cliffs_w_max_ms", "east_cliffs_w_5ms", "east_cliffs_w_8ms",
        "east_cliffs_inflow_k", "east_cliffs_u10_start_ms", "east_cliffs_w_start_ms",
        "crater_ridge_w_ms", "crater_ridge_w_p90_ms", "crater_ridge_w_max_ms", "crater_ridge_w_5ms", "crater_ridge_w_8ms",
        "crater_ridge_inflow_k", "crater_ridge_u10_start_ms", "crater_ridge_w_start_ms",
        "crater_rotor_reverse_frac", "crater_rotor_u_min_ms", "crater_rotor_w_min_ms",
        "landing_wind_ms", "landing_inflow_k",
        "thermal_land_wconv_p90_150m", "thermal_land_wconv_p90_300m", "thermal_sea_wconv_p90_150m", "thermal_sea_wconv_p90_300m",
        "thermal_core_w_p90", "thermal_core_land_w_p90", "thermal_core_w_max", "thermal_climb_m",
        "thermal_top_core_land_w_p90", "thermal_top_climb_m", "thermal_east_core_land_w_p90", "thermal_east_climb_m",
        "thermal_slope_core_land_w_p90", "thermal_slope_climb_m", "thermal_slope_over_water", "thermal_slope_baked", "thermals_over_water", "thermals_land", "thermal_exists",
        "u10_start_max_ms"]


def show():
    s = json.loads(RES.read_text())["summary"]
    for k in KEYS:
        print(f"{k}={s.get(k)}")
    bad = s.get("not_ok", [])
    print("ALL_OK" if not bad else "NOT_OK " + "; ".join(bad))


def _place():
    import _venv
    _venv.ensure("numpy", "PIL")
    import check_sites
    return check_sites.load(ROOT / "data/locations/volcano_island")


def points(name):
    """Точки [x, z, agl] мира и метки к ним."""
    import numpy as np
    import sites as S
    c = CASES[name]
    pl = _place()
    cfg = json.loads((ROOT / "configs/locations/volcano_island.json").read_text())
    st = {s["id"]: s for s in cfg["start_sites"]}
    pts, tags = [], []
    if c["geo"] == "grid":
        for z in range(-8000, 14001, 250):
            for x in range(-12000, 14001, 250):
                sea = pl.height(float(x), float(z)) < 0.5
                for a in (150, 300):
                    pts.append([x, z, a])
                    tags.append({"agl_m": a, "sea": sea})
        return pts, tags
    v = st[c["site"]]
    xs, zs = S.latlon_to_local(v["lat"], v["lon"], cfg["center_lat"], cfg["center_lon"])
    pts.append([xs, zs, 10.0])
    tags.append({"kind": "start"})
    ux, uz = S.heading_vec(WDIR)          # на наветренную сторону (откуда дует ветер)
    px, pz = -uz, ux                       # вдоль фронта
    for s in range(-1000, 1001, 250):
        bx, bz = xs + px * s, zs + pz * s
        ts = np.arange(-300.0, 1500.1, 10.0)
        hs = [pl.height(bx + ux * float(t), bz + uz * float(t)) for t in ts]
        hi = [i for i, h in enumerate(hs) if h >= 100.0]
        k = max(hi) if hi else int(np.argmax(hs))      # верх обрыва к морю; на краях фронта обрыва может не быть — максимум
        t0 = float(ts[k])
        cx, cz, hc = bx + ux * t0, bz + uz * t0, float(hs[k])
        for d in (100, 200, 300):
            x, z = cx + ux * d, cz + uz * d
            for a in (50, 100, 150):
                pts.append([x, z, round(hc + a - max(pl.height(x, z), 0.0), 2)])
                tags.append({"kind": "slope", "s": s, "upwind_m": d, "above_crest_m": a, "crest_h": round(hc, 1), "crest_t": t0})
            for a in (30, 60, 100):
                pts.append([x, z, a])
                tags.append({"kind": "face", "s": s, "upwind_m": d, "agl_m": a})
        if "rotor" in c["geo"]:
            for d in (300, 600, 900, 1200, 1500):
                x, z = cx - ux * d, cz - uz * d
                for a in (30, 60, 100, 150):
                    pts.append([x, z, a])
                    tags.append({"kind": "rotor", "s": s, "downwind_m": d, "agl_m": a})
    return pts, tags


def run_case(name, prof, shots):
    c = CASES[name]
    raw = OUT / f"check_{name}.json"
    env = dict(os.environ, XDG_DATA_HOME=prof, DISPLAY=os.environ.get("DISPLAY", ":0"))
    cmd = ["godot", "--path", str(ROOT), "--audio-driver", "Dummy", "--resolution", "1280x720", "--disable-vsync",
           "res://tools/terrain/volcano/air_check_run.tscn", "--", f"--site={c['site']}", f"--mode={c['mode']}",
           f"--out={raw}", f"--thermal-r={THERMAL_R_M}"]
    tags = None
    if "geo" in c:
        pts, tags = points(name)
        pf = OUT / f"points_{name}.json"
        pf.write_text(json.dumps(pts))
        cmd.append(f"--points={pf}")
    for k in ("wind", "hour", "sky", "temp"):
        if k in c:
            cmd.append(f"--{k}={c[k]}")
    if "frm" in c:
        cmd.append(f"--from={c['frm']}")
    if "climb_agl" in c:
        cmd.append(f"--climb-agl={c['climb_agl']}")
    if shots and c.get("shots"):
        cmd += [f"--shots={SHOTS}", f"--raw={OUT / 'shots_raw'}"]
    log = OUT / f"check_{name}.log"
    with open(log, "w") as f:
        p = subprocess.run(["timeout", "2400"] + cmd, env=env, stdout=f, stderr=subprocess.STDOUT, check=False)
    if p.returncode != 0 or not raw.exists():
        raise SystemExit(f"{name}: код {p.returncode}, лог {log}")
    d = json.loads(raw.read_text())
    if not d["info"].get("air_field_on"):   # таймаут расчёта поля — аналитика, не годится
        raise SystemExit(f"{name}: поле воздуха не посчитано (аналитика), лог {log} — повторить")
    ar = d["info"].get("air_runtime") or {}
    d["info"]["air_runtime"] = {k: ar.get(k) for k in ("engine", "inflow_k", "not_converged", "frozen_frac", "gpu_s", "hour", "baked")}
    d["tags"] = tags
    d["baked_line"] = [l for l in log.read_text().splitlines() if "запеч" in l.lower() or "baked" in l.lower()][:5]
    raw.write_text(json.dumps(_round(d), ensure_ascii=False))
    return d


def _round(v):
    if isinstance(v, float):
        return round(v, 3)
    if isinstance(v, list):
        return [_round(x) for x in v]
    if isinstance(v, dict):
        return {k: _round(x) for k, x in v.items()}
    return v


def _mean(v):
    return round(sum(v) / len(v), 3) if v else None


def _pct(v, q):
    if not v:
        return None
    v = sorted(v)
    k = q * (len(v) - 1)
    i = int(k)
    return round(v[i] + (v[min(i + 1, len(v) - 1)] - v[i]) * (k - i), 3)


def _down(d):
    b = math.radians(float(d["cond"]["wind_from"]))
    return -math.sin(b), math.cos(b)          # куда дует (мир: X — восток, −Z — север)


def _slope(d):
    rows, tags = d["points"]["rows"], d["tags"]     # x, y, z, vx, w, vz, w_mean, w_min, h_земли
    dx, dz = _down(d)
    out = {"cond": d["cond"], "inflow_k": d["info"]["air_runtime"].get("inflow_k"), "baked": d.get("baked_line")}
    st = [r for r, t in zip(rows, tags) if t["kind"] == "start"][0]
    out["u10_start_ms"] = round(math.hypot(st[3], st[5]), 3)
    out["w_start_ms"] = st[4]
    sl = [(r, t) for r, t in zip(rows, tags) if t["kind"] == "slope"]
    w = [r[4] for r, _ in sl]
    out.update({"w_mean": _mean(w), "w_min": round(min(w), 3), "w_max": round(max(w), 3), "w_p10": _pct(w, .1),
                "w_p90": _pct(w, .9), "frac_up": round(sum(x > 0 for x in w) / len(w), 3), "n": len(w),
                "crest_h_mean": _mean([t["crest_h"] for _, t in sl])})
    tab = {}
    for r, t in sl:
        tab.setdefault(f"{t['upwind_m']}m_up/{t['above_crest_m']}m_above", []).append(r[4])
    out["table"] = {k: _mean(v) for k, v in sorted(tab.items())}
    fa = [(r, t) for r, t in zip(rows, tags) if t["kind"] == "face"]
    tab = {}
    for r, t in fa:
        tab.setdefault(f"{t['upwind_m']}m_up/{t['agl_m']}m_agl", []).append(r[4])
    out["face_w_mean"] = _mean([r[4] for r, _ in fa])
    out["face_table"] = {k: _mean(v) for k, v in sorted(tab.items())}
    ro = [(r, t) for r, t in zip(rows, tags) if t["kind"] == "rotor"]
    if ro:
        ud = [r[3] * dx + r[5] * dz for r, _ in ro]
        out["rotor"] = {"w_min": round(min(r[4] for r, _ in ro), 3), "w_mean": _mean([r[4] for r, _ in ro]),
                        "w_snap_min": round(min(r[7] for r, _ in ro), 3),
                        "u_down_min": round(min(ud), 3), "reverse_frac": round(sum(u < 0 for u in ud) / len(ud), 3), "n": len(ud)}
        tab = {}
        for (r, t), u in zip(ro, ud):
            tab.setdefault(f"{t['downwind_m']}m_down/{t['agl_m']}m_agl", []).append((r[4], u))
        out["rotor"]["table"] = {k: {"w": _mean([a for a, _ in v]), "u_down": _mean([b for _, b in v]),
                                     "u_down_min": round(min(b for _, b in v), 3)} for k, v in sorted(tab.items())}
    return out


def _thermal(d):
    t = d["thermal"]
    w = [c["w"] for c in t["cores"]]
    by_agl, by_cls = {}, {}
    for c in t["cores"]:
        by_agl.setdefault(int(c["agl"]), []).append(c["w"])
        by_cls.setdefault(CLASS.get(c["cls"], str(c["cls"])), []).append(c["w"])
    th = t["thermals"]
    water = [x for x in th if x["cls"] == 6]
    fl = t["flights"]
    g = {}
    for r, tg in zip(d["grid"]["rows"], d["tags"] or []):      # x, z, agl, h, класс, w_conv, доля поля
        if r[6] < 0.5:
            continue
        g.setdefault(("sea" if tg["sea"] else "land", int(r[2])), []).append(r[5])
        if not tg["sea"]:
            g.setdefault((CLASS.get(r[4], str(r[4])), int(r[2])), []).append(r[5])
    grid = {f"{k[0]}@{k[1]}m": {"mean": _mean(v), "p90": _pct(v, .9), "max": round(max(v), 3), "n": len(v)} for k, v in sorted(g.items())}
    return {
        "cond": d["cond"], "weather": d["info"]["weather"], "inflow_k": d["info"]["air_runtime"].get("inflow_k"),
        "grid": grid, "core_w_p50": _pct(w, .5), "core_w_p90": _pct(w, .9), "core_w_max": round(max(w), 3) if w else None,
        "core_n": len(w), "core_by_agl": {k: {"p50": _pct(v, .5), "p90": _pct(v, .9)} for k, v in sorted(by_agl.items())},
        "core_by_class": {k: {"p50": _pct(v, .5), "p90": _pct(v, .9), "n": len(v)} for k, v in sorted(by_cls.items())},
        "thermals_seen": len(th), "thermals_land": len([x for x in th if x["cls"] != 6]), "over_water": len(water),
        "by_class": {CLASS.get(k, str(k)): sum(1 for x in th if x["cls"] == k) for k in sorted({x["cls"] for x in th})},
        "from": d["cond"]["start"], "heading": d["cond"]["heading"],
        "climb_m": [round(f["max_gain_m"], 1) for f in fl], "climb_end": [f["end"] for f in fl],
        "cloudbase_msl_start": d["info"]["cloudbase_msl"],
    }


def summarize(res):
    s = {"cases": {}}
    for site, pre in (("east_cliffs", "cliffs"), ("crater_ridge", "crater")):
        for v in (6, 5, 8):
            k = f"{pre}{v}"
            if k not in res:
                continue
            r = s["cases"][k] = _slope(res[k])
            if v == 6:
                for a, b in (("w_ms", "w_mean"), ("w_p90_ms", "w_p90"), ("w_max_ms", "w_max"), ("w_min_ms", "w_min"),
                             ("inflow_k", "inflow_k"), ("u10_start_ms", "u10_start_ms"), ("w_start_ms", "w_start_ms")):
                    s[f"{site}_{a}"] = r[b]
            else:
                s[f"{site}_w_{v}ms"] = r["w_mean"]
                s[f"{site}_u10_start_{v}ms"] = r["u10_start_ms"]
                s[f"{site}_inflow_k_{v}ms"] = r["inflow_k"]
            if "rotor" in r and v == 6:
                s["crater_rotor_reverse_frac"] = r["rotor"]["reverse_frac"]
                s["crater_rotor_u_min_ms"] = r["rotor"]["u_down_min"]
                s["crater_rotor_w_min_ms"] = r["rotor"]["w_min"]
    u10 = [s["cases"][k]["u10_start_ms"] for k in s["cases"]]
    s["u10_start_max_ms"] = max(u10) if u10 else None
    if "landing" in res:
        lt = res["landing"]["landing"]
        s["cases"]["landing"] = {"cond": res["landing"]["cond"], "sites": lt,
                                 "inflow_k": res["landing"]["info"]["air_runtime"].get("inflow_k")}
        s["landing_wind_ms"] = round(next(r["h_ms"] for r in lt["landing_target"] if round(r["agl"]) == 10), 3)
        s["landing_inflow_k"] = s["cases"]["landing"]["inflow_k"]
    best = None
    for k in ("thermal12", "thermal15"):
        if k in res:
            t = s["cases"][k] = _thermal(res[k])
            if best is None or (t["core_w_p90"] or 0) > (best["core_w_p90"] or 0):
                best = t
    cand = {}
    for k in ("thermal_top", "thermal_east", "thermal_slope"):
        if k in res:
            t = s["cases"][k] = _thermal(res[k])
            land = [c["w"] for c in res[k]["thermal"]["cores"] if c["cls"] not in (6, 0)]
            t["core_land_w_p90"] = _pct(land, .9)
            cand[k] = t
            s[f"{k}_core_land_w_p90"] = t["core_land_w_p90"]
            s[f"{k}_climb_m"] = max(t["climb_m"]) if t["climb_m"] else None
            if k == "thermal_slope":
                s["thermal_slope_over_water"] = t["over_water"]
                s["thermal_slope_baked"] = res[k]["info"]["air_runtime"].get("baked")
    if best is not None:
        s["thermal_best_case"] = best["cond"]["hour"]
        for lev in (150, 300):
            s[f"thermal_land_wconv_p90_{lev}m"] = best["grid"].get(f"land@{lev}m", {}).get("p90")
            s[f"thermal_sea_wconv_p90_{lev}m"] = best["grid"].get(f"sea@{lev}m", {}).get("p90")
        s["thermal_core_w_p90"], s["thermal_core_w_max"] = best["core_w_p90"], best["core_w_max"]
        s["thermal_climb_m"] = max(best["climb_m"]) if best["climb_m"] else None
        s["thermals_over_water"], s["thermals_land"] = best["over_water"], best["thermals_land"]
        land = [c["w"] for c in res[f"thermal{best['cond']['hour']:.0f}"]["thermal"]["cores"] if c["cls"] not in (6, 0)]
        s["thermal_core_land_w_p90"] = _pct(land, .9)
        s["thermal_exists"] = any((t["core_land_w_p90"] or 0) >= 1.0 and max(t["climb_m"] or [0]) >= 300.0 for t in cand.values())
    bad = []
    for k, op, thr in [("east_cliffs_w_ms", ">", 0.0), ("crater_ridge_w_ms", ">", 0.0), ("u10_start_max_ms", "<=", 10.0),
                       ("landing_wind_ms", "<=", 3.0), ("thermals_over_water", "<=", 0)]:
        v = s.get(k)
        if v is None or not {">": v > thr, "<=": v <= thr}[op]:
            bad.append(f"{k}={v} (нужно {op} {thr})")
    s["not_ok"] = bad
    return s


def write(res):
    out = {"cases": CASES, "summary": summarize(res)}
    RES.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    show()


def load_raw():
    return {k: json.loads((OUT / f"check_{k}.json").read_text()) for k in CASES if (OUT / f"check_{k}.json").exists()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--summarize", action="store_true")
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--no-shots", action="store_true")
    a = ap.parse_args()
    if a.show:
        show()
        return
    if a.summarize:
        write(load_raw())
        return
    OUT.mkdir(exist_ok=True)
    prof = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".cache/dp-xdg" / ROOT.name)
    bak = Path(tempfile.mkdtemp()) / "project.godot"
    shutil.copy2(ROOT / "project.godot", bak)
    try:
        for name in a.cases.split(","):
            d = run_case(name, prof, not a.no_shots)
            print(name, json.dumps(d["info"].get("air_runtime"), ensure_ascii=False), flush=True)
    finally:
        if (ROOT / "project.godot").read_bytes() != bak.read_bytes():
            shutil.copy2(bak, ROOT / "project.godot")
    write(load_raw())


if __name__ == "__main__":
    main()
