#!/usr/bin/env python3
"""Контрактный тест sw-charges-3d (docs/contracts/sw-charges-3d.md, SWD1–SWD5).

  py check_contract.py files <файлы|каталоги> ...   SWD1 (*.h5 sw3d-ref, points.json sw3d-points), SWD5 (sw3d-compare)
  py check_contract.py api <panels3d|filaments3d|sim3d> ...   публичные имена и параметры SWD2–SWD4
  py check_contract.py --selftest
Печать OK/FAIL по объекту; выход 1 при любом FAIL. Интерпретатор — tools/research/sw_charges_3d/py.
"""
import importlib
import inspect
import json
import math
import os
import sys
import tempfile

CASES = {"ASK_TU03B", "PERD_NE", "PERD_SW"}
POINTS = {"upstream", "windward", "crest", "lee", "valley"}
REF_KIND = {"mast", "lidar", "picard_nom", "picard_adv1"}
RELIAB = {"измерение", "модель ±15 %"}
ROTOR_SRC = {"menke2019", "picard_nom", "picard_adv1", "masts"}
VARIANTS = {"potential", "potential_jh", "vortex_jh"}
Z_REQUIRED = (2, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300)

# SWD2–SWD4: имя -> обязательные параметры (по порядку, как в контракте); класс — параметры __init__
API = {
    "panels3d": {
        "Terrain3D": ["x", "y", "z", "smooth_m", "far_m", "blend_m"],
        "build_panels": ["terrain", "focus", "ds_min", "ds_max", "growth", "focus_r"],
        "bg_uniform": ["U", "wind_to"],
        "bg_profile": ["U10", "alpha", "z_sat", "terrain", "wind_to", "smooth_m"],
        "bg_zero": [],
        "assemble": ["panels", "backend"],
        "solve": ["panels", "bg", "extra", "infl", "method", "backend"],
        "velocity": ["panels", "sigma", "bg", "x", "y", "z", "extra", "backend"],
        "surface_flow": ["panels", "sigma", "bg", "extra"],
        "hill_length": ["terrain", "x", "y", "wind_to", "smooth_m", "ds_min"],
        "velocity_jh": ["panels", "sigma", "bg", "x", "y", "z", "z0", "U_ref", "extra", "infl"],
        "separation3d": ["panels", "sigma", "bg", "z0", "extra", "method", "lee_only", "seed_dy"],
    },
    "filaments3d": {
        "Filaments": ["x", "seg", "gamma", "core", "anchored", "fid"],
        "imbalance": ["f"],
        "induced": ["f", "x", "y", "z", "backend"],
        "self_velocity": ["f"],
        "ring": ["R", "gamma", "core", "n", "center", "normal"],
        "line": ["points", "gamma", "core", "anchored_ends"],
        "shed": ["f", "line_pts", "u_s", "dt", "core", "normals"],
        "step": ["f", "flow", "dt", "ground", "params"],
    },
    "sim3d": {
        "Setup": ["terrain", "panels", "bg", "z0", "params"],
        "run": ["setup", "t_end", "dt", "t_avg", "probes", "sep_every", "record_every"],
        "velocity_mean": [],
        "velocity_jh_mean": [],
    },
}


class ContractError(Exception):
    pass


def need(d, keys, where):
    for k in keys:
        if k not in d:
            raise ContractError(f"{where}: нет ключа {k!r}")


def num(v, where, allow_null=False):
    if v is None and allow_null:
        return
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ContractError(f"{where}: ожидается конечное число, есть {v!r}")


def one_of(v, allowed, where, allow_null=False):
    if v is None and allow_null:
        return
    if v not in allowed:
        raise ContractError(f"{where}: {v!r} не из {sorted(map(str, allowed))}")


def check_unit(v, where):
    if not isinstance(v, (list, tuple)) or len(v) != 2:
        raise ContractError(f"{where}: ожидается вектор из 2 чисел")
    for c in v:
        num(c, where)
    if abs(math.hypot(v[0], v[1]) - 1) > 1e-3:
        raise ContractError(f"{where}: не единичный")


# ---------- SWD1: HDF5 ----------
def _arr(ds):
    import numpy as np
    a = ds[...]
    if a.dtype == np.int16:
        for k in ("scale", "offset"):
            if k not in ds.attrs:
                raise ContractError(f"{ds.name}: int16 без атрибута {k}")
        scale = float(ds.attrs["scale"])
        if not (0 < scale <= 0.01):
            raise ContractError(f"{ds.name}: scale {scale} — ошибка квантования > 0,005 м/с")
        out = a.astype("f8") * scale + float(ds.attrs["offset"])
        out[a == -32768] = np.nan
        return out
    return a.astype("f8")


def _axis(g, name, where):
    import numpy as np
    if name not in g:
        raise ContractError(f"{where}: нет {name}")
    a = g[name][...]
    if a.ndim != 1 or a.size < 2 or not np.all(np.diff(a) > 0):
        raise ContractError(f"{where}/{name}: 1D, строго по возрастанию")
    return a


def check_ref_h5(path):
    import h5py
    import numpy as np
    with h5py.File(path, "r") as h:
        at = h.attrs
        for k in ("format", "version", "case", "git", "created", "wind_to", "wind_from_deg"):
            if k not in at:
                raise ContractError(f"{path}: нет атрибута {k}")
        if at["format"] != "sw3d-ref" or int(at["version"]) != 1:
            raise ContractError(f"{path}: format/version {at['format']}/{at['version']}")
        one_of(str(at["case"]), CASES, f"{path}.case")
        check_unit([float(c) for c in at["wind_to"]], f"{path}.wind_to")
        if "terrain" not in h:
            raise ContractError(f"{path}: нет группы terrain")
        t = h["terrain"]
        x = _axis(t, "x", "terrain")
        y = _axis(t, "y", "terrain")
        if np.ptp(np.diff(x)) > 1e-6 * abs(x[1] - x[0]) or np.ptp(np.diff(y)) > 1e-6 * abs(y[1] - y[0]):
            raise ContractError("terrain: шаг x/y непостоянный")
        for k in ("z", "z0"):
            if k not in t or t[k].shape != (y.size, x.size):
                raise ContractError(f"terrain/{k}: форма (ny, nx) = {(y.size, x.size)}")
            if not np.all(np.isfinite(t[k][...])):
                raise ContractError(f"terrain/{k}: NaN")
        if np.any(t["z0"][...] <= 0):
            raise ContractError("terrain/z0 ≤ 0")
        for k in ("dx", "source", "smoothing"):
            if k not in t.attrs:
                raise ContractError(f"terrain: нет атрибута {k}")
        groups = [g for g in h if g.startswith("picard_")]
        if not groups:
            raise ContractError(f"{path}: нет групп picard_<variant>")
        for gname in groups:
            one_of(gname, {"picard_nom", "picard_adv1"}, path)
            g = h[gname]
            px = _axis(g, "x", gname)
            py_ = _axis(g, "y", gname)
            zl = _axis(g, "z_agl", gname)
            for z in Z_REQUIRED:
                if z <= 300 and not np.any(np.isclose(zl, z)) and z <= zl.max():
                    raise ContractError(f"{gname}: нет уровня z_agl {z} м")
            for z in (10, 50):
                if not np.any(np.isclose(zl, z)):
                    raise ContractError(f"{gname}: нет уровня z_agl {z} м")
            if g["z_ground"].shape != (py_.size, px.size):
                raise ContractError(f"{gname}/z_ground: форма")
            for k in ("u", "v", "w"):
                if k not in g or g[k].shape != (zl.size, py_.size, px.size):
                    raise ContractError(f"{gname}/{k}: форма (nz, ny, nx)")
                a = _arr(g[k])
                if np.isfinite(a).mean() < 0.99:
                    raise ContractError(f"{gname}/{k}: NaN > 1 %")
                if np.nanmax(np.abs(a)) > 60:
                    raise ContractError(f"{gname}/{k}: |скорость| > 60 м/с")
            for k in ("interp",):
                if k not in g["u"].attrs and k not in g.attrs:
                    raise ContractError(f"{gname}: нет атрибута interp")
            for k in ("params", "status", "iters", "wall_s", "dx", "U_ref", "z_ref", "first_cell_levels"):
                if k not in g.attrs:
                    raise ContractError(f"{gname}: нет атрибута {k}")
            json.loads(g.attrs["params"])


# ---------- SWD1: points.json ----------
def check_points(path, d):
    need(d, ("git", "created", "norm", "rows", "transects", "rotor"), path)
    if not isinstance(d["norm"], dict) or not d["norm"]:
        raise ContractError("norm: пустой")
    for c, n in d["norm"].items():
        one_of(c, CASES, "norm")
        need(n, ("name", "x", "y", "z_agl", "source"), f"norm.{c}")
    if not d["rows"]:
        raise ContractError("rows: пусто")
    have = set()
    for i, r in enumerate(d["rows"]):
        w = f"rows[{i}]"
        need(r, ("case", "name", "point", "x", "y", "z_agl", "ref_kind", "ref_source", "ref_reliability", "ref_err",
                 "u", "v", "w", "speed", "s_norm", "dS"), w)
        one_of(r["case"], CASES, w + ".case")
        one_of(r["point"], POINTS, w + ".point")
        one_of(r["ref_kind"], REF_KIND, w + ".ref_kind")
        one_of(r["ref_reliability"], RELIAB, w + ".ref_reliability")
        for k in ("x", "y", "z_agl"):
            num(r[k], f"{w}.{k}")
        for k in ("ref_err", "u", "v", "w", "speed", "s_norm", "dS"):
            num(r[k], f"{w}.{k}", allow_null=True)
        if r["dS"] is not None and not r["case"].startswith("ASK"):
            raise ContractError(f"{w}: dS только для Askervein")
        if r["case"].startswith("ASK") and r["ref_kind"].startswith("picard") and r["dS"] is None:
            raise ContractError(f"{w}: dS Askervein у Пикара обязателен (v2)")
        if r["ref_kind"].startswith("picard") and r["name"].startswith("P_"):
            have.add((r["case"], r["ref_kind"], r["point"], round(r["z_agl"])))
    for c in {r["case"] for r in d["rows"]}:
        for kind in {r["ref_kind"] for r in d["rows"] if r["case"] == c and r["ref_kind"].startswith("picard")}:
            for p in POINTS:
                for z in (10, 50):
                    if (c, kind, p, z) not in have:
                        raise ContractError(f"{c}/{kind}: нет синтетической точки {p} на {z} м")
    for i, t in enumerate(d["transects"]):
        need(t, ("case", "name", "x0", "y0", "x1", "y1", "source"), f"transects[{i}]")
        one_of(t["case"], CASES, f"transects[{i}].case")
    for i, r in enumerate(d["rotor"]):
        w = f"rotor[{i}]"
        need(r, ("case", "transect", "source", "present", "L_m", "depth_m", "criterion", "ref_source"), w)
        one_of(r["source"], ROTOR_SRC, w + ".source")
        if r["present"] is not None and not isinstance(r["present"], bool):
            raise ContractError(f"{w}.present: bool | null")
        num(r["L_m"], w + ".L_m", allow_null=True)
        num(r["depth_m"], w + ".depth_m", allow_null=True)


# ---------- SWD5 ----------
def check_compare(path, d):
    need(d, ("git", "created", "tol_picard", "rows", "rotor", "timing", "problems2d"), path)
    num(d["tol_picard"], "tol_picard")
    if not d["rows"]:
        raise ContractError("rows: пусто")
    for i, r in enumerate(d["rows"]):
        w = f"rows[{i}]"
        need(r, ("case", "variant", "point", "name", "x", "y", "z_agl", "ref_kind", "ref_source", "ref_reliability",
                 "ref_err", "s_ref", "s_pan", "dS_ref", "dS_pan", "u_par_ref", "u_par_pan", "err", "within_tol",
                 "within_tol_ref", "ds_min", "N"), w)
        one_of(r["case"], CASES, w + ".case")
        one_of(r["variant"], VARIANTS, w + ".variant")
        one_of(r["point"], POINTS, w + ".point")
        one_of(r["ref_kind"], REF_KIND, w + ".ref_kind")
        for k in ("s_ref", "s_pan", "dS_ref", "dS_pan", "u_par_ref", "u_par_pan", "err", "ref_err"):
            num(r[k], f"{w}.{k}", allow_null=True)
        if r["s_ref"] is not None and r["s_pan"] is not None and r["err"] is not None:
            if abs(r["err"] - (r["s_pan"] - r["s_ref"])) > 1e-6:
                raise ContractError(f"{w}: err ≠ s_pan − s_ref")
        if r["ref_kind"].startswith("picard"):
            if not isinstance(r["within_tol"], bool):
                raise ContractError(f"{w}.within_tol: bool для Пикара")
            if r["err"] is not None and r["within_tol"] != (abs(r["err"]) <= d["tol_picard"] * abs(r["s_ref"]) + 1e-12):
                raise ContractError(f"{w}.within_tol не по порогу")
        elif r["within_tol"] is not None:
            raise ContractError(f"{w}.within_tol: null для измерений")
    for i, r in enumerate(d["rotor"]):
        need(r, ("case", "transect", "variant", "present", "L_m", "depth_m", "L_ref", "ref_source"), f"rotor[{i}]")
        one_of(r["variant"], VARIANTS, f"rotor[{i}].variant")
    for i, r in enumerate(d["timing"]):
        need(r, ("case", "variant", "N", "t_assemble_s", "t_solve_s", "t_query_us", "t_run_s", "backend"), f"timing[{i}]")
    for i, r in enumerate(d["problems2d"]):
        need(r, ("problem", "kind", "status", "evidence"), f"problems2d[{i}]")
        one_of(r["kind"], {"схема", "2D-артефакт"}, f"problems2d[{i}].kind")
        one_of(r["status"], {"ушла", "осталась", "новая в 3D"}, f"problems2d[{i}].status")


JSON_FORMATS = {"sw3d-points": (1, check_points), "sw3d-compare": (1, check_compare)}


def check_file(path):
    if path.endswith(".h5"):
        check_ref_h5(path)
        return True
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    fmt = d.get("format") if isinstance(d, dict) else None
    if fmt not in JSON_FORMATS:
        return False
    ver, fn = JSON_FORMATS[fmt]
    if d.get("version") != ver:
        raise ContractError(f"{path}: version {d.get('version')} ≠ {ver}")
    fn(path, d)
    return True


def run_files(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                files += [os.path.join(root, n) for n in names if n.endswith((".json", ".h5"))]
        else:
            files.append(p)
    bad = seen = 0
    for p in sorted(files):
        try:
            if check_file(p):
                seen += 1
                print(f"OK   {p}")
        except (ContractError, KeyError, ValueError, OSError) as e:
            bad += 1
            seen += 1
            print(f"FAIL {p}: {e}")
    if seen == 0:
        print("FAIL: нет файлов SWD1/SWD5")
        return 1
    return 1 if bad else 0


def check_api(modname, mod=None):
    mod = mod or importlib.import_module(modname)
    errs = []
    for name, params in API[modname].items():
        obj = getattr(mod, name, None)
        if obj is None:
            errs.append(f"{modname}.{name}: нет")
            continue
        try:
            sig = inspect.signature(obj)
        except (TypeError, ValueError):
            errs.append(f"{modname}.{name}: нет сигнатуры")
            continue
        got = [p for p in sig.parameters if p not in ("self", "args", "kwargs")]
        if got[:len(params)] != params:
            errs.append(f"{modname}.{name}: параметры {got} — по контракту начинаются с {params}")
    for e in errs:
        print(f"FAIL {e}")
    if not errs:
        print(f"OK   {modname}")
    return 1 if errs else 0


def run_api(names):
    rc = 0
    for n in names:
        if n not in API:
            print(f"FAIL {n}: не пакет SWD2–SWD4")
            rc = 1
            continue
        try:
            rc |= check_api(n)
        except ImportError as e:
            print(f"FAIL {n}: импорт: {e}")
            rc = 1
    return rc


# ---------- selftest ----------
def _good_points():
    rows = []
    for c in ("ASK_TU03B",):
        rows.append({"case": c, "name": "HT", "point": "crest", "x": 0.0, "y": 0.0, "z_agl": 10.0, "ref_kind": "mast",
                     "ref_source": "askervein_validation1.txt", "ref_reliability": "измерение", "ref_err": 0.05,
                     "u": None, "v": None, "w": None, "speed": 16.0, "s_norm": 1.8, "dS": 0.8})
        for p in sorted(POINTS):
            for z in (10.0, 50.0, 300.0):
                rows.append({"case": c, "name": f"P_{p}_0", "point": p, "x": 1.0, "y": 2.0, "z_agl": z,
                             "ref_kind": "picard_nom", "ref_source": "air3d b1 nom", "ref_reliability": "модель ±15 %",
                             "ref_err": None, "u": 5.0, "v": 1.0, "w": 0.1, "speed": 5.1, "s_norm": 1.0, "dS": 0.1})
    return {"format": "sw3d-points", "version": 1, "git": "x", "created": "t",
            "norm": {"ASK_TU03B": {"name": "RS", "x": -3000.0, "y": 0.0, "z_agl": 10.0, "source": "RS"}},
            "rows": rows, "transects": [{"case": "ASK_TU03B", "name": "A", "x0": 0, "y0": 0, "x1": 1, "y1": 1,
                                         "source": "line A"}],
            "rotor": [{"case": "ASK_TU03B", "transect": "A", "source": "picard_nom", "present": False, "L_m": None,
                       "depth_m": None, "criterion": "u∥<-0.5 at 15 m, >50 m", "ref_source": "x"}]}


def _good_compare():
    row = {"case": "PERD_NE", "variant": "potential", "point": "crest", "name": "P_crest_0", "x": 0.0, "y": 0.0,
           "z_agl": 10.0, "ref_kind": "picard_nom", "ref_source": "x", "ref_reliability": "модель ±15 %", "ref_err": None,
           "s_ref": 1.0, "s_pan": 1.1, "dS_ref": None, "dS_pan": None, "u_par_ref": 5.0, "u_par_pan": 5.5, "err": 0.1,
           "within_tol": True, "within_tol_ref": True, "ds_min": 25.0, "N": 10000}
    return {"format": "sw3d-compare", "version": 1, "git": "x", "created": "t", "tol_picard": 0.15, "rows": [row],
            "rotor": [{"case": "PERD_NE", "transect": "T1", "variant": "vortex_jh", "present": True, "L_m": 500.0,
                       "depth_m": 100.0, "L_ref": 530.0, "ref_source": "menke2019"}],
            "timing": [{"case": "PERD_NE", "variant": "potential", "N": 10000, "t_assemble_s": 1.0, "t_solve_s": 1.0,
                        "t_query_us": 10.0, "t_run_s": None, "backend": "cupy"}],
            "problems2d": [{"problem": "отрыв на наветренном склоне", "kind": "схема", "status": "ушла", "evidence": "x"}]}


def _write_h5(path, drop=None, bad_scale=False):
    import h5py
    import numpy as np
    x = np.arange(10) * 25.0
    y = np.arange(8) * 25.0
    zl = np.array(Z_REQUIRED, dtype="f4")
    with h5py.File(path, "w") as h:
        h.attrs.update({"format": "sw3d-ref", "version": 1, "case": "PERD_NE", "git": "x", "created": "t",
                        "wind_to": [0.6, 0.8], "wind_from_deg": 216.9})
        t = h.create_group("terrain")
        t["x"], t["y"] = x, y
        t["z"] = np.zeros((8, 10), "f4")
        t["z0"] = np.full((8, 10), 0.1, "f4")
        t.attrs.update({"dx": 25.0, "source": "s", "smoothing": "none"})
        g = h.create_group("picard_nom")
        g["x"], g["y"], g["z_agl"] = x, y, zl
        g["z_ground"] = np.zeros((8, 10), "f4")
        for k in ("u", "v", "w"):
            if k == drop:
                continue
            raw = np.full((zl.size, 8, 10), 5000, "i2")
            ds = g.create_dataset(k, data=raw, chunks=True, compression="gzip")
            ds.attrs.update({"scale": 0.02 if bad_scale else 0.001, "offset": 0.0, "interp": "linear"})
        g.attrs.update({"params": "{}", "status": "ok", "iters": 10, "wall_s": 1.0, "dx": 25.0, "U_ref": 8.0,
                        "z_ref": 100.0, "first_cell_levels": [2.0]})


def selftest():
    import types
    fails = 0

    def expect(ok, what):
        nonlocal fails
        print(("OK   " if ok else "FAIL ") + what)
        fails += 0 if ok else 1

    with tempfile.TemporaryDirectory() as tmp:
        def jtry(d, fn):
            p = os.path.join(tmp, "x.json")
            with open(p, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False)
            try:
                check_file(p)
                return True
            except ContractError:
                return False

        expect(jtry(_good_points(), None), "points: верный проходит")
        d = _good_points(); d["rows"] = [r for r in d["rows"] if not (r["point"] == "lee" and r["z_agl"] == 50.0)]
        expect(not jtry(d, None), "points: нет синтетической lee 50 м — ловится")
        d = _good_points(); d["rows"][0]["ref_kind"] = "picard"
        expect(not jtry(d, None), "points: неверный ref_kind — ловится")
        d = _good_points(); d["rows"][1]["case"] = "PERD_NE"; d["rows"][1]["dS"] = 0.1
        expect(not jtry(d, None), "points: dS вне Askervein — ловится")
        expect(jtry(_good_compare(), None), "compare: верный проходит")
        d = _good_compare(); d["rows"][0]["err"] = 0.3
        expect(not jtry(d, None), "compare: err ≠ s_pan − s_ref — ловится")
        d = _good_compare(); d["rows"][0]["s_pan"] = 1.3; d["rows"][0]["err"] = 0.3
        expect(not jtry(d, None), "compare: within_tol не по порогу — ловится")
        d = _good_compare(); d["problems2d"][0]["status"] = "непонятно"
        expect(not jtry(d, None), "compare: неверный статус проблемы — ловится")

        def htry(**kw):
            p = os.path.join(tmp, "r.h5")
            _write_h5(p, **kw)
            try:
                check_file(p)
                return True
            except ContractError:
                return False

        expect(htry(), "h5: верный проходит")
        expect(not htry(drop="w"), "h5: нет w — ловится")
        expect(not htry(bad_scale=True), "h5: грубое квантование — ловится")

    mod = types.ModuleType("filaments3d")
    for name, params in API["filaments3d"].items():
        src = f"def {name}({', '.join(params)}): pass"
        exec(src, mod.__dict__)
    expect(check_api("filaments3d", mod) == 0, "api: полный модуль проходит")
    del mod.shed
    expect(check_api("filaments3d", mod) == 1, "api: нет shed — ловится")
    print("selftest:", "OK" if fails == 0 else f"{fails} FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["--selftest"]:
        sys.exit(selftest())
    if len(a) >= 2 and a[0] == "files":
        sys.exit(run_files(a[1:]))
    if len(a) >= 2 and a[0] == "api":
        sys.exit(run_api(a[1:]))
    print(__doc__)
    sys.exit(2)
