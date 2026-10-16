"""TI-5: проверка воздуха стартов учебного острова в игре (фиксированная погода TI-К2 из конфига места) — числа и
кадры F3/F6. Каждый случай — отдельный запуск главной сцены (air_check_run.tscn, окно DISPLAY=:0, поле GPU).

  python3 tools/terrain/island/air_check.py                 # все случаи (~6 запусков, ≈ 10 мин) + кадры + итог
  python3 tools/terrain/island/air_check.py --cases thermal  # часть случаев (итог — из сохранённых сырых файлов)
  python3 tools/terrain/island/air_check.py --summarize      # пересобрать итог из out/check_*.json
  python3 tools/terrain/island/air_check.py --show           # печать ключ=значение из out/air_check.json

Случаи: ridge5/ridge6/ridge8 — старт ridge_west, ветер набора 5/6/8 м/с (5 и 8 — подмена только в памяти);
thermal — thermal_plain; landing — landing_hill; rotor — lee_bowl. Кадры <старт>_f3.jpg / _f6.jpg (JPEG q88) —
в SHOTS. Итог — out/air_check.json, сырые — out/check_<случай>.json.
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
SHOTS = Path("/home/greg/deltaplan/build/screenshots/training-island/TI-5")
CLASS = {1: "forest", 2: "grass", 3: "crop", 4: "shrub", 5: "bare", 6: "water", 7: "built"}
CASES = {
    "ridge6": dict(site="ridge_west", mode="ridge", shots=True),
    "ridge5": dict(site="ridge_west", mode="ridge", wind=5.0),
    "ridge8": dict(site="ridge_west", mode="ridge", wind=8.0),
    "thermal": dict(site="thermal_plain", mode="thermal", shots=True),
    "landing": dict(site="landing_hill", mode="landing", shots=True),
    "rotor": dict(site="lee_bowl", mode="rotor", shots=True),
}
THERMAL_R_M = 4000.0
# Пороги карточки TI-5 (≥/≤) и свои (диапазоны решения пользователя Q2: ядро 1,5–3 м/с, база 1500–2000 м).
CHECKS = [
    ("ridge_w_6ms", ">=", 1.0), ("ridge_w_5ms", ">", 0.0), ("ridge_w_8ms", ">", 0.0),
    ("thermal_core_w_p90", ">=", 1.5), ("thermal_core_w_p90", "<=", 3.0), ("thermal_climb_m", ">=", 300.0),
    ("thermal_base_m", ">=", 1500.0), ("thermal_base_m", "<=", 2000.0), ("thermals_over_water", "<=", 0),
    ("thermals_over_bare", ">", 0), ("rotor_w_min", "<=", -1.0), ("rotor_reverse_frac", ">", 0.0),
    ("landing_wind_ms", "<=", 3.0),
]
KEYS = ["ridge_w_5ms", "ridge_w_6ms", "ridge_w_8ms", "thermal_core_w_p90", "thermal_core_w_max", "thermal_climb_m",
        "thermal_base_m", "thermals_over_water", "thermals_over_water_zone", "thermals_over_bare", "thermals_over_crop",
        "rotor_w_min", "rotor_reverse_frac", "landing_wind_ms"]


def show():
    s = json.loads(RES.read_text())["summary"]
    for k in KEYS:
        print(f"{k}={s.get(k)}")
    bad = s.get("not_ok", [])
    print("ALL_OK" if not bad else "NOT_OK " + "; ".join(bad))


def run_case(name, prof, shots):
    c = CASES[name]
    raw = OUT / f"check_{name}.json"
    env = dict(os.environ, XDG_DATA_HOME=prof, DISPLAY=os.environ.get("DISPLAY", ":0"))
    cmd = ["godot", "--path", str(ROOT), "--audio-driver", "Dummy", "--resolution", "1280x720", "--disable-vsync",
           "res://tools/terrain/island/air_check_run.tscn", "--", f"--site={c['site']}", f"--mode={c['mode']}",
           f"--out={raw}"]
    if "wind" in c:
        cmd.append(f"--wind={c['wind']}")
    if shots and c.get("shots"):
        cmd += [f"--shots={SHOTS}", f"--raw={OUT / 'shots_raw'}"]
    log = OUT / f"check_{name}.log"
    with open(log, "w") as f:
        p = subprocess.run(["timeout", "1800"] + cmd, env=env, stdout=f, stderr=subprocess.STDOUT, check=False)
    if p.returncode != 0 or not raw.exists():
        raise SystemExit(f"{name}: код {p.returncode}, лог {log}")
    d = json.loads(raw.read_text())
    ar = d["info"].get("air_runtime") or {}
    d["info"]["air_runtime"] = {k: ar.get(k) for k in ("engine", "inflow_k", "not_converged", "frozen_frac", "gpu_s", "hour")}
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


def _ridge(d):
    rows = d["ridge"]["rows"]       # x, y, z, vx, w, vz, w_mean_field, w_min, tag
    w = [r[4] for r in rows]
    tab = {}
    for r in rows:
        t = r[8]
        tab.setdefault(f"{int(t['upwind_m'])}m_up/{int(t['above_crest_m'])}m_above", []).append(r[4])
    return {"w_mean": _mean(w), "w_min": round(min(w), 3), "w_max": round(max(w), 3),
            "w_field_mean": _mean([r[6] for r in rows]), "frac_up": round(sum(x > 0 for x in w) / len(w), 3),
            "n": len(w), "along_m": max(r[8]["dz"] for r in rows) - min(r[8]["dz"] for r in rows),
            "table": {k: _mean(v) for k, v in sorted(tab.items())}, "cond": d["cond"]}


def _rotor(d):
    rows = d["rotor"]["rows"]
    b = math.radians(float(d["cond"]["wind_from"]))
    dx, dz = -math.sin(b), math.cos(b)          # куда дует (мир: X — восток, −Z — север)
    w = [r[4] for r in rows]
    ud = [r[3] * dx + r[5] * dz for r in rows]
    tab = {}
    for r, u in zip(rows, ud):
        t = r[8]
        tab.setdefault(f"{int(t['downwind_m'])}m_down/{int(t['agl_m'])}m_agl", []).append((r[4], u))
    return {"w_min": round(min(w), 3), "w_mean": _mean(w), "w_field_min": round(min(r[6] for r in rows), 3),
            "u_down_min": round(min(ud), 3), "reverse_frac": round(sum(u < 0 for u in ud) / len(ud), 3), "n": len(w),
            "table": {k: {"w": _mean([a for a, _ in v]), "u_down": _mean([b for _, b in v])} for k, v in sorted(tab.items())},
            "cond": d["cond"], "inflow_k": (d["info"].get("air_runtime") or {}).get("inflow_k")}


def _thermal(d):
    t = d["thermal"]
    cores = [c for c in t["cores"]]
    w = [c["w"] for c in cores]
    by_agl = {}
    by_cls = {}
    for c in cores:
        by_agl.setdefault(int(c["agl"]), []).append(c["w"])
        by_cls.setdefault(CLASS.get(c["cls"], str(c["cls"])), []).append(c["w"])
    th = t["thermals"]
    zone = [x for x in th if x["d_start"] <= THERMAL_R_M]
    water = [x for x in th if x["cls"] == 6]
    srcs = lambda xs: len({(round(x["src"][0]), round(x["src"][2])) for x in xs})
    fl = t["flights"]
    return {
        "core_w_p50": _pct(w, 0.5), "core_w_p90": _pct(w, 0.9), "core_w_max": round(max(w), 3) if w else None,
        "core_n": len(w), "core_by_agl": {k: {"p50": _pct(v, .5), "p90": _pct(v, .9)} for k, v in sorted(by_agl.items())},
        "core_by_class": {k: {"p50": _pct(v, .5), "p90": _pct(v, .9), "n": len(v)} for k, v in sorted(by_cls.items())},
        "thermals_seen": len(th), "zone_by_class": {CLASS.get(k, str(k)): sum(1 for x in zone if x["cls"] == k)
                                                    for k in sorted({x["cls"] for x in zone})},
        "over_water": len(water), "over_water_sources": srcs(water),
        "over_water_zone": sum(1 for x in water if x["d_start"] <= THERMAL_R_M),
        "water_detail": [{k: x.get(k) for k in ("src", "strength", "radius", "top", "d_start", "col_heat", "col_phi",
                                                 "level_dx", "src_sun")} for x in water],
        "climb_m": [round(f["max_gain_m"], 1) for f in fl], "climb_end": [f["end"] for f in fl],
        "circle_r_m": fl[0]["R_m"] if fl else None, "circle_sink_ms": fl[0]["sink_circle_ms"] if fl else None,
        "cloudbase_msl_start": d["info"]["cloudbase_msl"], "cloudbase_msl_end": t["cloudbase_msl"], "weather": d["info"]["weather"], "cond": d["cond"],
    }


def summarize(res):
    s = {"cases": {}}
    for k in ("ridge5", "ridge6", "ridge8"):
        if k in res:
            s["cases"][k] = _ridge(res[k])
            s[f"ridge_w_{k[-1]}ms"] = s["cases"][k]["w_mean"]
    if "rotor" in res:
        r = s["cases"]["rotor"] = _rotor(res["rotor"])
        s["rotor_w_min"], s["rotor_reverse_frac"] = r["w_min"], r["reverse_frac"]
    if "thermal" in res:
        t = s["cases"]["thermal"] = _thermal(res["thermal"])
        s["thermal_core_w_p90"], s["thermal_core_w_max"] = t["core_w_p90"], t["core_w_max"]
        s["thermal_climb_m"] = max(t["climb_m"]) if t["climb_m"] else None
        s["thermal_base_m"] = round(t["cloudbase_msl_start"])   # кромка на час старта (к концу замера ~45 мин — выше)
        s["thermals_over_water"] = t["over_water"]
        s["thermals_over_water_zone"] = t["over_water_zone"]
        s["thermals_over_bare"] = t["zone_by_class"].get("bare", 0)
        s["thermals_over_crop"] = t["zone_by_class"].get("crop", 0)
    if "landing" in res:
        lt = res["landing"]["landing"]
        s["cases"]["landing"] = {"cond": res["landing"]["cond"], "sites": lt}
        s["landing_wind_ms"] = round(next(r["h_ms"] for r in lt["landing_target"] if round(r["agl"]) == 10), 3)
    bad = []
    for k, op, thr in CHECKS:
        v = s.get(k)
        ok = v is not None and {">=": v >= thr, "<=": v <= thr, ">": v > thr}[op]
        if not ok:
            bad.append(f"{k}={v} (нужно {op} {thr})")
    s["not_ok"] = bad
    return s


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
    if not a.summarize:
        OUT.mkdir(exist_ok=True)
        prof = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".cache/dp-xdg" / ROOT.name)
        bak = Path(tempfile.mkdtemp()) / "project.godot"
        shutil.copy2(ROOT / "project.godot", bak)
        try:
            for name in a.cases.split(","):
                run_case(name, prof, not a.no_shots)
                print(name, "ok", flush=True)
        finally:
            if (ROOT / "project.godot").read_bytes() != bak.read_bytes():
                shutil.copy2(bak, ROOT / "project.godot")
    res = {k: json.loads((OUT / f"check_{k}.json").read_text()) for k in CASES if (OUT / f"check_{k}.json").exists()}
    out = {"weather_sets": {s["id"]: s.get("weather") for s in
                            json.loads((ROOT / "configs/locations/training_island.json").read_text())["start_sites"]},
           "summary": summarize(res)}
    s = out["summary"]
    out["summary"] = {k: s[k] for k in KEYS + ["not_ok"] if k in s}
    out["cases"] = s["cases"]
    # Кадры: доля пикселей, изменённых слоем F3/F6 против того же вида без слоя (air_check_run._diff).
    out["frames"] = {}
    for c in CASES.values():
        fj = OUT / "shots_raw" / f"{c['site']}_frames.json"
        if c.get("shots") and fj.exists():
            out["frames"][c["site"]] = json.loads(fj.read_text())
    RES.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    show()


if __name__ == "__main__":
    main()
