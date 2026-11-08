#!/usr/bin/env python3
"""Контрактный тест sw-ground (docs/contracts/sw-ground.md, SWG1–SWG4).

  py check_contract.py <файлы> ...   формат — по полю `format`: swg-points, swg-ground, swg-rotor, swg-timing
  py check_contract.py --selftest    валидные и сломанные образцы
Печать OK/FAIL по файлу; выход 1 при любом FAIL. Интерпретатор — tools/research/sw_ground/py.
"""
import json
import math
import os
import sys
import tempfile
from collections import Counter

CASES = {"ASK_TU03B", "PERD_NE", "PERD_SW"}
TYPES = {"upstream", "windward", "crest", "lee", "valley"}
MAIN_TYPES = ("lee", "valley", "crest", "windward")
REF_KIND = {"picard_nom", "picard_adv1", "mast"}
REF_USE = {"эталон", "справочно"}
TOL = 0.15


class Bad(Exception):
    pass


def need(d, keys, where):
    miss = [k for k in keys if k not in d]
    if miss:
        raise Bad(f"{where}: нет полей {miss}")


def num(v, where, null=False):
    if v is None and null:
        return
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise Bad(f"{where}: не число ({v!r})")


def head(doc, fmt, ver):
    need(doc, ["format", "version", "git", "created"], "файл")
    if doc["format"] != fmt or doc["version"] != ver:
        raise Bad(f"format/version {doc['format']}/{doc['version']} != {fmt}/{ver}")


# ------------------------------------------------------------------ SWG1
def check_points(doc):
    head(doc, "swg-points", 1)
    need(doc, ["rule", "rows"], "файл")
    ids = set()
    cnt = Counter()
    have_type = set()
    for i, r in enumerate(doc["rows"]):
        w = f"rows[{i}]"
        need(r, ["case", "id", "type", "x", "y", "z_ground", "z_agl", "s_nom", "s_adv1", "speed_nom"], w)
        if r["case"] not in CASES:
            raise Bad(f"{w}: case {r['case']}")
        if r["type"] not in TYPES:
            raise Bad(f"{w}: type {r['type']}")
        if r["id"] in ids:
            raise Bad(f"{w}: id {r['id']} повторён")
        ids.add(r["id"])
        for k in ("x", "y", "z_ground", "z_agl"):
            num(r[k], f"{w}.{k}")
        for k in ("s_nom", "s_adv1", "speed_nom"):
            num(r[k], f"{w}.{k}", null=True)
        cnt[(r["case"], r["type"], float(r["z_agl"]))] += 1
        have_type.add((r["case"], r["type"]))
    zs = {(c, float(z)) for (c, _, z) in cnt}
    for c in CASES:
        for z in (10.0, 50.0, 300.0):
            if (c, z) not in zs:
                raise Bad(f"{c}: нет высоты {z:g} м")
    for c in ("PERD_NE", "PERD_SW"):
        for t in MAIN_TYPES:
            for z in (10.0, 50.0):
                if cnt[(c, t, z)] < 30:
                    raise Bad(f"{c} {t} {z:g} м: n {cnt[(c, t, z)]} < 30")
    for z in (10.0, 50.0):
        if cnt[("ASK_TU03B", "lee", z)] < 30:
            raise Bad(f"ASK_TU03B lee {z:g} м: n {cnt[('ASK_TU03B', 'lee', z)]} < 30")
    return f"{len(ids)} точек"


def points_ids(path_hint):
    """id SWG1 для проверки ссылок SWG2 (если файл есть)."""
    p = path_hint or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "points",
                                  "ground_points.json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return {r["id"] for r in json.load(f)["rows"]}


# ------------------------------------------------------------------ SWG2
def check_ground(doc, pts_ids=None):
    head(doc, "swg-ground", 1)
    need(doc, ["task", "variants", "rows", "summary", "masts", "decomp", "scan"], "файл")
    if not isinstance(doc["variants"], dict) or not doc["variants"]:
        raise Bad("variants: пусто")
    for v, d in doc["variants"].items():
        if not isinstance(d, str) or not d.strip():
            raise Bad(f"variants.{v}: нет описания")
    V = set(doc["variants"])
    keyn = Counter()
    for i, r in enumerate(doc["rows"]):
        w = f"rows[{i}]"
        need(r, ["case", "variant", "id", "type", "z_agl", "ref_kind", "ref_use", "s_ref", "s_pan", "rel_err",
                 "within_tol"], w)
        if r["case"] not in CASES or r["type"] not in TYPES:
            raise Bad(f"{w}: case/type")
        if r["variant"] not in V:
            raise Bad(f"{w}: variant {r['variant']} не описан в variants")
        if r["ref_kind"] not in REF_KIND or r["ref_use"] not in REF_USE:
            raise Bad(f"{w}: ref_kind/ref_use")
        for k in ("z_agl", "s_ref", "s_pan", "rel_err"):
            num(r[k], f"{w}.{k}")
        if abs((r["s_pan"] - r["s_ref"]) / r["s_ref"] - r["rel_err"]) > 1e-6:
            raise Bad(f"{w}: rel_err не равен (s_pan − s_ref)/s_ref")
        if bool(r["within_tol"]) != (abs(r["rel_err"]) <= TOL + 1e-12):
            raise Bad(f"{w}: within_tol не согласован с rel_err")
        if r["ref_kind"] != "mast":
            if pts_ids is not None and r["id"] not in pts_ids:
                raise Bad(f"{w}: id {r['id']} нет в SWG1")
            if float(r["z_agl"]) < 50 and r["ref_use"] != "справочно":
                raise Bad(f"{w}: Пикар ниже 50 м должен быть «справочно»")
        keyn[(r["case"], r["variant"], r["type"], float(r["z_agl"]), r["ref_kind"])] += 1
    have = set()
    for i, s in enumerate(doc["summary"]):
        w = f"summary[{i}]"
        need(s, ["case", "variant", "type", "z_agl", "ref_kind", "n", "frac_tol", "mean_rel", "median_rel"], w)
        k = (s["case"], s["variant"], s["type"], float(s["z_agl"]), s["ref_kind"])
        if s["n"] != keyn[k]:
            raise Bad(f"{w}: n {s['n']} != строк {keyn[k]}")
        for f in ("frac_tol", "mean_rel", "median_rel"):
            num(s[f], f"{w}.{f}", null=(s["n"] == 0))
        have.add(k)
    for (c, v) in {(r["case"], r["variant"]) for r in doc["rows"] if r["ref_kind"] == "picard_nom"}:
        for t in MAIN_TYPES:
            for z in (10.0, 50.0, 300.0):
                if keyn[(c, v, t, z, "picard_nom")] and (c, v, t, z, "picard_nom") not in have:
                    raise Bad(f"summary: нет {c} {v} {t} {z:g} м picard_nom")
    for i, m in enumerate(doc["masts"]):
        need(m, ["case", "variant", "type", "n", "rmse_s", "frac_tol"], f"masts[{i}]")
    for i, d in enumerate(doc["decomp"]):
        need(d, ["case", "type", "z_agl", "term", "value", "unit", "note"], f"decomp[{i}]")
        if d["unit"] not in ("s", "rel", "m/s"):
            raise Bad(f"decomp[{i}]: unit {d['unit']}")
    for i, s in enumerate(doc["scan"]):
        need(s, ["case", "variant", "param", "value", "metric", "result"], f"scan[{i}]")
    return f"{len(doc['rows'])} строк, вариантов {len(V)}"


# ------------------------------------------------------------------ SWG3
def check_rotor(doc):
    head(doc, "swg-rotor", 1)
    need(doc, ["task", "params", "criterion", "rows", "ridges", "timing"], "файл")
    if not isinstance(doc["params"], dict) or "slope_min" not in doc["params"]:
        raise Bad("params: один набор (dict) со slope_min")
    seen = set()
    for i, r in enumerate(doc["rows"]):
        w = f"rows[{i}]"
        need(r, ["case", "transect", "variant", "present", "L_m", "depth_m", "u_min_over_U", "L_menke",
                 "L_picard_nom", "L_picard_adv1"], w)
        if r["case"] not in CASES:
            raise Bad(f"{w}: case")
        if not isinstance(r["present"], bool):
            raise Bad(f"{w}: present не bool")
        for k in ("L_m", "depth_m", "u_min_over_U", "L_menke", "L_picard_nom", "L_picard_adv1"):
            num(r[k], f"{w}.{k}", null=True)
        seen.add(r["case"])
    if seen != CASES:
        raise Bad(f"rows: случаи {sorted(seen)} вместо всех трёх")
    for i, g in enumerate(doc["ridges"]):
        need(g, ["case", "ridge", "slope_max", "gate_pass", "placed", "converged", "Gamma", "R", "x_c", "x_r",
                 "reverse_15m", "picard_reverse", "false_rotor"], f"ridges[{i}]")
    for i, t in enumerate(doc["timing"]):
        need(t, ["case", "t_s", "n_solves"], f"timing[{i}]")
    return f"{len(doc['rows'])} разрезов, {len(doc['ridges'])} хребтов"


# ------------------------------------------------------------------ SWG4
def check_timing(doc):
    head(doc, "swg-timing", 1)
    need(doc, ["task", "machine", "rows"], "файл")
    need(doc["machine"], ["cpu", "gpu", "threads"], "machine")
    have = set()
    for i, r in enumerate(doc["rows"]):
        w = f"rows[{i}]"
        need(r, ["method", "place", "window_dx", "nx", "ny", "nz", "n_points", "stage", "t_total_s", "parts",
                 "backend", "threads", "tol_scale", "note"], w)
        if r["method"] not in ("panels", "panels_rotor", "picard"):
            raise Bad(f"{w}: method {r['method']}")
        if r["window_dx"] not in (100, 50) or r["stage"] not in ("cold", "wind_change"):
            raise Bad(f"{w}: window_dx/stage")
        if r["backend"] not in ("cupy", "numpy", "rust"):
            raise Bad(f"{w}: backend")
        num(r["t_total_s"], f"{w}.t_total_s")
        if r["t_total_s"] <= 0:
            raise Bad(f"{w}: t_total_s ≤ 0")
        if r["method"] != "picard" and r["n_points"] != r["nx"] * r["ny"] * r["nz"]:
            raise Bad(f"{w}: n_points != nx·ny·nz")
        have.add((r["method"], r["window_dx"], r["stage"]))
    for dx in (100, 50):
        for st in ("cold", "wind_change"):
            for m in ("panels", "picard"):
                if (m, dx, st) not in have:
                    raise Bad(f"нет строки {m} {dx} м {st}")
    return f"{len(doc['rows'])} строк"


CHECK = {"swg-points": check_points, "swg-ground": check_ground, "swg-rotor": check_rotor,
         "swg-timing": check_timing}


def check_file(path, pts=None):
    with open(path) as f:
        doc = json.load(f)
    fmt = doc.get("format")
    if fmt not in CHECK:
        raise Bad(f"неизвестный format {fmt!r}")
    if fmt == "swg-ground":
        return check_ground(doc, pts)
    return CHECK[fmt](doc)


# ------------------------------------------------------------------ самопроверка
def _samples():
    H = {"git": "0000000", "created": "2026-11-08T00:00:00"}
    rows = []
    n = 0
    for c in sorted(CASES):
        for t in TYPES:
            for z in (10, 50, 300):
                for _ in range(30):
                    n += 1
                    rows.append({"case": c, "id": f"G_{c}_{n}", "type": t, "x": 1.0, "y": 2.0, "z_ground": 3.0,
                                 "z_agl": z, "s_nom": 1.0, "s_adv1": None, "speed_nom": 8.0})
    pts = dict(H, format="swg-points", version=1, rule="test", rows=rows)
    gr_rows, summ = [], []
    for r in rows[:3]:
        use = "справочно" if r["z_agl"] < 50 else "эталон"
        gr_rows.append({"case": r["case"], "variant": "potential", "id": r["id"], "type": r["type"],
                        "z_agl": r["z_agl"], "ref_kind": "picard_nom", "ref_use": use, "s_ref": 1.0, "s_pan": 1.1,
                        "rel_err": 0.1, "within_tol": True})
    k = Counter((r["case"], r["type"], r["z_agl"]) for r in gr_rows)
    for (c, t, z), m in k.items():
        summ.append({"case": c, "variant": "potential", "type": t, "z_agl": z, "ref_kind": "picard_nom", "n": m,
                     "frac_tol": 1.0, "mean_rel": 0.1, "median_rel": 0.1})
    ground = dict(H, format="swg-ground", version=1, task="swg-0", variants={"potential": "SWD2 v5, σ 40 м"},
                  rows=gr_rows, summary=summ, masts=[], decomp=[], scan=[])
    rot = dict(H, format="swg-rotor", version=1, task="swg-0", params={"slope_min": 0.27}, criterion="x",
               rows=[{"case": c, "transect": "T", "variant": "rotor_jh", "present": False, "L_m": 0.0,
                      "depth_m": None, "u_min_over_U": None, "L_menke": None, "L_picard_nom": None,
                      "L_picard_adv1": None} for c in sorted(CASES)], ridges=[], timing=[])
    trows = []
    for m in ("panels", "picard"):
        for dx in (100, 50):
            for st in ("cold", "wind_change"):
                trows.append({"method": m, "place": "ongudai", "window_dx": dx, "nx": 64, "ny": 64, "nz": 62,
                              "n_points": 64 * 64 * 62, "stage": st, "t_total_s": 1.0, "parts": {},
                              "backend": "rust" if m == "picard" else "cupy", "threads": 8, "tol_scale": None,
                              "note": ""})
    tim = dict(H, format="swg-timing", version=1, task="swg-0", machine={"cpu": "x", "gpu": "y", "threads": 20},
               rows=trows)
    return pts, ground, rot, tim


def selftest():
    import copy
    pts, ground, rot, tim = _samples()
    ids = {r["id"] for r in pts["rows"]}
    ok = [check_points(pts), check_ground(ground, ids), check_rotor(rot), check_timing(tim)]
    broken = []
    b = copy.deepcopy(pts); b["rows"] = [r for r in b["rows"] if not (r["case"] == "PERD_NE" and r["type"] == "lee")]
    broken.append(("points n<30", lambda: check_points(b)))
    g = copy.deepcopy(ground); g["rows"][0]["within_tol"] = False
    broken.append(("ground within_tol", lambda: check_ground(g, ids)))
    g2 = copy.deepcopy(ground); g2["rows"][0]["variant"] = "nope"
    broken.append(("ground variant", lambda: check_ground(g2, ids)))
    g3 = copy.deepcopy(ground); g3["rows"][0]["ref_use"] = "эталон"
    broken.append(("ground ref_use<50", lambda: check_ground(g3, ids)))
    r = copy.deepcopy(rot); r["rows"] = r["rows"][:2]
    broken.append(("rotor cases", lambda: check_rotor(r)))
    t = copy.deepcopy(tim); t["rows"] = [x for x in t["rows"] if x["method"] != "picard"]
    broken.append(("timing picard", lambda: check_timing(t)))
    t2 = copy.deepcopy(tim); t2["rows"][0]["n_points"] = 5
    broken.append(("timing n_points", lambda: check_timing(t2)))
    bad = 0
    for name, fn in broken:
        try:
            fn()
            print(f"FAIL selftest: {name} — сломанный образец прошёл")
            bad += 1
        except Bad:
            pass
    # файл: запись и чтение
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "t.json")
        with open(p, "w") as f:
            json.dump(tim, f)
        check_file(p)
    print("OK selftest:", "; ".join(ok), f"; сломанных отклонено {len(broken) - bad}/{len(broken)}")
    return bad == 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--selftest":
        return 0 if selftest() else 1
    pts = points_ids(None)
    fail = 0
    for p in argv:
        try:
            print(f"OK {p}: {check_file(p, pts)}")
        except (Bad, KeyError, ValueError, OSError) as e:
            print(f"FAIL {p}: {e}")
            fail += 1
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
