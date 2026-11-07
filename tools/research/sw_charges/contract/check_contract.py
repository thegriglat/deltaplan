#!/usr/bin/env python3
"""Проверка файлов SW1/SW2/SW3 (sw-charges) по docs/contracts/sw-charges.md. Только stdlib.

  check_contract.py <файлы|каталоги> ...   (рекурсивно *.json по полю format)
  check_contract.py --selftest
Печать OK/FAIL по файлу; выход 1 при любом FAIL.
"""
import json
import math
import os
import struct
import sys
import tempfile

FORMATS = {"sw-case": 1, "sw-field": 1, "sw-run": 1, "sw-regimes": 1, "sw-sections": 2, "sw-panels2d": 2}
REGIMES = {"R1", "R2", "R3", "R4j", "R5", "R6", "unclassified"}
THEORY = {"R1", "R2", "R3", "R2|R4j", "R5", "R6"}
BC = {"farfield", "transmissive", "wall", "periodic"}
SHAPES = {"flat", "hill", "ridge", "step_up", "step_down", None}
STATUS = {"steady", "averaged", "max_time", "diverged"}


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


def check_grid(g, where="grid"):
    need(g, ("nx", "ny", "dx", "dy", "x0", "y0"), where)
    for k in ("nx", "ny"):
        if not isinstance(g[k], int) or g[k] < 1:
            raise ContractError(f"{where}.{k}: целое ≥ 1")
    num(g["dx"], f"{where}.dx")
    if g["dx"] <= 0:
        raise ContractError(f"{where}.dx ≤ 0")
    num(g["dy"], f"{where}.dy", allow_null=True)
    num(g["x0"], f"{where}.x0")
    num(g["y0"], f"{where}.y0")


def check_ref(r, where="ref"):
    need(r, ("h0", "b0", "U0", "V0"), where)
    for k in ("h0", "b0", "U0", "V0"):
        num(r[k], f"{where}.{k}")
    if r["h0"] <= 0 or r["b0"] <= 0:
        raise ContractError(f"{where}: h0 и b0 должны быть > 0")


def read_arrays(json_path, d, required, optional=()):
    """-> {имя: список float}; проверяет смещения, длины nx·ny, конечность."""
    g = d["grid"]
    n = g["nx"] * g["ny"]
    arrs = d.get("arrays")
    if not isinstance(arrs, dict):
        raise ContractError("arrays: ожидается объект")
    for k in required:
        if k not in arrs:
            raise ContractError(f"arrays: нет {k!r}")
    binp = json_path[: -len(".json")] + ".bin"
    try:
        with open(binp, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise ContractError(f"нет .bin: {e}")
    total = len(raw) // 4
    if len(raw) % 4:
        raise ContractError(".bin: длина не кратна 4")
    out = {}
    for k, v in arrs.items():
        if not (isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) and x >= 0 for x in v)):
            raise ContractError(f"arrays.{k}: ожидается [смещение, длина]")
        off, ln = v
        if (k in required or k in optional) and ln != n:
            raise ContractError(f"arrays.{k}: длина {ln} ≠ nx·ny = {n}")
        if off + ln > total:
            raise ContractError(f"arrays.{k}: выходит за .bin ({off}+{ln} > {total})")
        vals = struct.unpack_from(f"<{ln}f", raw, off * 4)
        if not all(math.isfinite(x) for x in vals):
            raise ContractError(f"arrays.{k}: NaN/Inf")
        out[k] = vals
    return out


def check_case(path, d):
    need(d, ("name", "dim", "grid", "ref", "physics", "bc", "sponge", "run", "source", "mapping", "arrays"), "sw-case")
    if d["dim"] not in (1, 2):
        raise ContractError("dim: 1 | 2")
    g = d["grid"]
    check_grid(g)
    if d["dim"] == 1 and (g["ny"] != 1 or g["dy"] is not None):
        raise ContractError("dim 1: ny = 1, dy = null")
    if d["dim"] == 2 and g["dy"] is None:
        raise ContractError("dim 2: dy обязателен")
    base = os.path.basename(path)[: -len(".json")]
    if d["name"] != base:
        raise ContractError(f"name {d['name']!r} ≠ имени файла {base!r}")
    check_ref(d["ref"])
    p = d["physics"]
    need(p, ("cd", "f_cor", "theta0", "rho_cp", "g", "h_min", "b_min", "forcing"), "physics")
    for k in ("cd", "f_cor", "theta0", "rho_cp", "g", "h_min", "b_min"):
        num(p[k], f"physics.{k}")
    if p["forcing"] not in ("balance", "none"):
        raise ContractError("physics.forcing: balance | none")
    bc = d["bc"]
    need(bc, ("west", "east", "south", "north"), "bc")
    for k in ("west", "east"):
        if bc[k] not in BC:
            raise ContractError(f"bc.{k}: {bc[k]!r}")
    for k in ("south", "north"):
        if d["dim"] == 1 and bc[k] is not None:
            raise ContractError(f"dim 1: bc.{k} = null")
        if d["dim"] == 2 and bc[k] not in BC:
            raise ContractError(f"bc.{k}: {bc[k]!r}")
    if d["sponge"] is not None:
        need(d["sponge"], ("width_m", "tau_s"), "sponge")
        num(d["sponge"]["width_m"], "sponge.width_m")
        num(d["sponge"]["tau_s"], "sponge.tau_s")
    r = d["run"]
    need(r, ("t_end", "cfl", "steady_tol", "avg_from", "out_every"), "run")
    num(r["t_end"], "run.t_end")
    num(r["cfl"], "run.cfl")
    if not (0 < r["cfl"] <= 0.9):
        raise ContractError("run.cfl вне (0, 0,9]")
    num(r["steady_tol"], "run.steady_tol")
    num(r["avg_from"], "run.avg_from", allow_null=True)
    num(r["out_every"], "run.out_every", allow_null=True)
    s = d["source"]
    need(s, ("kind", "shape", "s", "H", "a", "ref_case"), "source")
    if s["kind"] not in ("ideal", "cascade2d", "location"):
        raise ContractError(f"source.kind: {s['kind']!r}")
    if s["shape"] not in SHAPES:
        raise ContractError(f"source.shape: {s['shape']!r}")
    for k in ("s", "H", "a"):
        num(s[k], f"source.{k}", allow_null=True)
    if d["mapping"] is not None:
        need(d["mapping"], ("U10", "N", "z_i", "dtheta", "rule"), "mapping")
        for k in ("U10", "N", "z_i", "dtheta"):
            num(d["mapping"][k], f"mapping.{k}", allow_null=True)
    read_arrays(path, d, ("zb",), ("q_heat", "h_init", "hu_init", "hv_init", "b_init"))


def check_field(path, d):
    need(d, ("case", "t", "steps", "grid", "ref", "mean", "git", "created", "arrays"), "sw-field")
    check_grid(d["grid"])
    check_ref(d["ref"])
    num(d["t"], "t")
    req = ["zb", "h", "hu", "hv", "hb", "wet"]
    if d["mean"] is not None:
        need(d["mean"], ("t_from", "t_to", "n"), "mean")
        req += ["h_mean", "u_mean", "v_mean", "b_mean"]
    a = read_arrays(path, d, req)
    for i, w in enumerate(a["wet"]):
        if w not in (0.0, 1.0):
            raise ContractError(f"wet[{i}] = {w}, ожидается 0/1")
        if a["h"][i] < 0:
            raise ContractError(f"h[{i}] < 0")
        if w == 0.0 and (a["hu"][i] != 0.0 or a["hv"][i] != 0.0):
            raise ContractError(f"сухая клетка {i}: hu/hv ≠ 0")
    if d["grid"]["ny"] == 1 and any(x != 0.0 for x in a["hv"]):
        raise ContractError("dim 1: hv ≠ 0")


def check_run(path, d):
    need(d, ("case", "field", "status", "t", "steps", "wall_s", "threads", "dt_min", "dt_mean", "cfl",
             "mass_rel_err", "steady_residual", "dry_cells", "b_clipped", "notes", "git", "created"), "sw-run")
    if d["status"] not in STATUS:
        raise ContractError(f"status: {d['status']!r}")
    for k in ("t", "wall_s", "cfl"):
        num(d[k], k)
    for k in ("dt_min", "dt_mean", "mass_rel_err", "steady_residual"):
        num(d[k], k, allow_null=True)
    for k in ("steps", "threads", "dry_cells", "b_clipped"):
        if not isinstance(d[k], int) or d[k] < 0:
            raise ContractError(f"{k}: целое ≥ 0")


REG_KEYS = ("case", "run", "shape", "s", "H", "h0", "b0", "U0", "F0", "M", "Fr_game", "N", "z_i", "rule_b0",
            "regime_sw", "regime_theory", "match", "Fr_crest", "h_up", "bore_speed", "lee_jump", "x_jump", "q_ratio",
            "dry_cells", "status", "wall_s")
SEC_KEYS = ("case", "dx", "dx_sw", "sw_case", "sw_run", "rule_b0", "h0", "b0", "U0", "F0", "M", "E", "E0", "S_sw", "S_p",
            "D_sw", "D_p", "x_D_sw", "x_D_p", "status", "wall_s")


def check_regimes(path, d):
    need(d, ("series", "theory", "thresholds", "git", "created", "rows"), "sw-regimes")
    if d["series"] not in ("A1", "A2"):
        raise ContractError(f"series: {d['series']!r}")
    if not isinstance(d["rows"], list) or not d["rows"]:
        raise ContractError("rows: непустой список")
    for i, r in enumerate(d["rows"]):
        need(r, REG_KEYS, f"rows[{i}]")
        if r["regime_sw"] not in REGIMES:
            raise ContractError(f"rows[{i}].regime_sw: {r['regime_sw']!r}")
        if r["regime_theory"] not in THEORY:
            raise ContractError(f"rows[{i}].regime_theory: {r['regime_theory']!r}")
        if not isinstance(r["match"], bool) or not isinstance(r["lee_jump"], bool):
            raise ContractError(f"rows[{i}]: match/lee_jump — bool")
        if r["match"] != (r["regime_sw"] in r["regime_theory"].split("|")):
            raise ContractError(f"rows[{i}].match не согласован с режимами")
        if r["rule_b0"] not in ("N2h0", "N2delta", None):
            raise ContractError(f"rows[{i}].rule_b0: {r['rule_b0']!r}")
        for k in ("F0", "M", "h0", "b0", "U0"):
            num(r[k], f"rows[{i}].{k}")
        for k in ("Fr_game", "N", "z_i", "Fr_crest", "h_up", "bore_speed", "x_jump", "q_ratio", "s", "H"):
            num(r[k], f"rows[{i}].{k}", allow_null=True)
        if r["status"] not in STATUS:
            raise ContractError(f"rows[{i}].status: {r['status']!r}")
    if not os.path.exists(path[: -len(".json")] + ".csv"):
        raise ContractError("нет парного .csv")


def check_sections(path, d):
    need(d, ("git", "created", "rows"), "sw-sections")
    if not isinstance(d["rows"], list) or not d["rows"]:
        raise ContractError("rows: непустой список")
    for i, r in enumerate(d["rows"]):
        need(r, SEC_KEYS, f"rows[{i}]")
        if r["case"] not in ("C0", "C1", "C2", "C3", "C4"):
            raise ContractError(f"rows[{i}].case: {r['case']!r}")
        if r["rule_b0"] not in ("N2h0", "N2delta", None):
            raise ContractError(f"rows[{i}].rule_b0: {r['rule_b0']!r}")
        for k in ("dx", "dx_sw", "h0", "b0", "U0", "F0", "M"):
            num(r[k], f"rows[{i}].{k}")
        for k in ("E", "E0", "S_sw", "S_p", "D_sw", "D_p", "x_D_sw", "x_D_p"):
            num(r[k], f"rows[{i}].{k}", allow_null=True)
        if r["status"] not in STATUS:
            raise ContractError(f"rows[{i}].status: {r['status']!r}")
    if not os.path.exists(path[: -len(".json")] + ".csv"):
        raise ContractError("нет парного .csv")


PAN_KEYS = ("case", "variant", "point", "x", "z_agl", "ref_kind", "ref_source", "ref_reliability", "u_ref", "w_ref",
            "u_pan", "w_pan", "units", "err", "within_tol", "ref_err", "within_tol_ref", "ds_min", "t_solve_ms",
            "t_query_us")
PAN_POINTS = {"upstream", "windward", "crest", "lee", "valley", "foot"}


def check_panels(path, d):
    need(d, ("git", "created", "tol_picard", "rows", "rotor"), "sw-panels2d")
    if not isinstance(d["rows"], list) or not d["rows"]:
        raise ContractError("rows: непустой список")
    for i, r in enumerate(d["rows"]):
        need(r, PAN_KEYS, f"rows[{i}]")
        cs = r["case"]
        if not (cs in ("C1", "C2", "C4", "PERD_NE", "PERD_SW") or (isinstance(cs, str) and cs.startswith("LW_"))):
            raise ContractError(f"rows[{i}].case: {cs!r}")
        if r["variant"] not in ("potential", "vortex", "potential_bl", "vortex_bl"):
            raise ContractError(f"rows[{i}].variant: {r['variant']!r}")
        if r["point"] not in PAN_POINTS:
            raise ContractError(f"rows[{i}].point: {r['point']!r}")
        if r["ref_kind"] not in ("picard", "mast", "lidar", "tunnel"):
            raise ContractError(f"rows[{i}].ref_kind: {r['ref_kind']!r}")
        if r["ref_reliability"] not in ("измерение", "труба", "модель ±15 %"):
            raise ContractError(f"rows[{i}].ref_reliability: {r['ref_reliability']!r}")
        if r["units"] not in ("m/s", "dS"):
            raise ContractError(f"rows[{i}].units: {r['units']!r}")
        for k in ("x", "z_agl", "ds_min"):
            num(r[k], f"rows[{i}].{k}")
        for k in ("u_ref", "w_ref", "u_pan", "w_pan", "err", "t_solve_ms", "t_query_us"):
            num(r[k], f"rows[{i}].{k}", allow_null=True)
        wt = r["within_tol"]
        if r["ref_kind"] == "picard":
            if not isinstance(wt, bool):
                raise ContractError(f"rows[{i}].within_tol: bool для picard")
            if r["u_ref"] is not None and r["err"] is not None and wt != (abs(r["err"]) <= d["tol_picard"] * abs(r["u_ref"])):
                raise ContractError(f"rows[{i}].within_tol не согласован с err")
        elif wt is not None:
            raise ContractError(f"rows[{i}].within_tol: null не для picard")
        num(r["ref_err"], f"rows[{i}].ref_err", allow_null=True)
        if r["within_tol_ref"] is not None and not isinstance(r["within_tol_ref"], bool):
            raise ContractError(f"rows[{i}].within_tol_ref: bool | null")
    if not isinstance(d["rotor"], list):
        raise ContractError("rotor: список")
    for i, r in enumerate(d["rotor"]):
        need(r, ("case", "variant", "rotor_pan", "L_pan", "rotor_ref", "L_ref", "ref_source"), f"rotor[{i}]")
        if not isinstance(r["rotor_pan"], bool):
            raise ContractError(f"rotor[{i}].rotor_pan: bool")
    if not os.path.exists(path[: -len(".json")] + ".csv"):
        raise ContractError("нет парного .csv")


def check_file(path, strict=True):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        raise ContractError(f"не читается JSON: {e}")
    fmt = d.get("format") if isinstance(d, dict) else None
    if fmt not in FORMATS:
        if strict or (isinstance(fmt, str) and fmt.startswith("sw-")):
            raise ContractError(f"неизвестный format={fmt!r}")
        return None
    if d.get("version") != FORMATS[fmt]:
        raise ContractError(f"{fmt}: version {d.get('version')!r} ≠ {FORMATS[fmt]}")
    {"sw-case": check_case, "sw-field": check_field, "sw-run": check_run, "sw-regimes": check_regimes,
     "sw-sections": check_sections, "sw-panels2d": check_panels}[fmt](path, d)
    return fmt


def run(paths):
    bad = n = 0
    for p in paths:
        items = []
        if os.path.isdir(p):
            for r, _, fs in os.walk(p):
                items += [(os.path.join(r, f), False) for f in sorted(fs) if f.endswith(".json")]
        else:
            items.append((p, True))
        for fp, explicit in items:
            try:
                k = check_file(fp, strict=explicit)
            except (ContractError, KeyError, TypeError, ValueError, struct.error) as e:
                print(f"FAIL {fp}: {e}")
                bad += 1
                continue
            if k is not None:
                n += 1
                print(f"OK   {fp} [{k}]")
    print(f"проверено {n}, FAIL {bad}")
    return 1 if bad or n == 0 else 0


# --- самопроверка: синтетика по контракту и порча ---

def _write_pair(path, meta, arrays):
    blob, off, idx = bytearray(), 0, {}
    for k, v in arrays.items():
        blob += struct.pack(f"<{len(v)}f", *v)
        idx[k] = [off, len(v)]
        off += len(v)
    meta = dict(meta, arrays=idx)
    with open(path[: -len(".json")] + ".bin", "wb") as f:
        f.write(blob)
    with open(path, "w") as f:
        json.dump(meta, f)


def _synth(t):
    nx = 8
    grid = {"nx": nx, "ny": 1, "dx": 100.0, "dy": None, "x0": -400.0, "y0": 0.0}
    ref = {"h0": 500.0, "b0": 0.1, "U0": 5.0, "V0": 0.0}
    zb = [200.0 * math.exp(-((-350.0 + 100 * i) / 300.0) ** 2) for i in range(nx)]
    case = {"format": "sw-case", "version": 1, "name": "ridge_s0.30", "dim": 1, "grid": grid, "ref": ref,
            "physics": {"cd": 0.003, "f_cor": 0.0, "theta0": 290.0, "rho_cp": 1200.0, "g": 9.81, "h_min": 0.5,
                        "b_min": 1e-4, "forcing": "balance"},
            "bc": {"west": "farfield", "east": "farfield", "south": None, "north": None},
            "sponge": {"width_m": 200.0, "tau_s": 300.0},
            "run": {"t_end": 3600.0, "cfl": 0.5, "steady_tol": 1e-4, "avg_from": None, "out_every": None},
            "source": {"kind": "ideal", "shape": "ridge", "s": 0.3, "H": 200.0, "a": 300.0, "ref_case": None},
            "mapping": None}
    cp = os.path.join(t, "ridge_s0.30.json")
    _write_pair(cp, case, {"zb": zb})
    h = [500.0 - z for z in zb]
    hu = [x * 5.0 for x in h]
    field = {"format": "sw-field", "version": 1, "case": "ridge_s0.30", "t": 3600.0, "steps": 100, "grid": grid,
             "ref": ref, "mean": {"t_from": 1800.0, "t_to": 3600.0, "n": 50}, "git": "x", "created": "2026-11-08T00:00:00"}
    fp = os.path.join(t, "ridge_s0.30.field.json")
    _write_pair(fp, field, {"zb": zb, "h": h, "hu": hu, "hv": [0.0] * nx, "hb": [x * 0.1 for x in h],
                            "wet": [1.0] * nx, "h_mean": h, "u_mean": [5.0] * nx, "v_mean": [0.0] * nx,
                            "b_mean": [0.1] * nx})
    runp = os.path.join(t, "ridge_s0.30.run.json")
    with open(runp, "w") as f:
        json.dump({"format": "sw-run", "version": 1, "case": "ridge_s0.30", "field": fp, "status": "steady",
                   "t": 3600.0, "steps": 100, "wall_s": 0.1, "threads": 1, "dt_min": 1.0, "dt_mean": 2.0, "cfl": 0.5,
                   "mass_rel_err": 1e-12, "steady_residual": 5e-5, "dry_cells": 0, "b_clipped": 0, "notes": "",
                   "git": "x", "created": "2026-11-08T00:00:00"}, f)
    reg = {"format": "sw-regimes", "version": 1, "series": "A1", "theory": "literature.md §2", "thresholds": {},
           "git": "x", "created": "2026-11-08T00:00:00",
           "rows": [{"case": "ridge_s0.30", "run": runp, "shape": "ridge", "s": 0.3, "H": 200.0, "h0": 500.0, "b0": 0.1,
                     "U0": 5.0, "F0": 0.707, "M": 0.4, "Fr_game": None, "N": None, "z_i": None, "rule_b0": None,
                     "regime_sw": "R3", "regime_theory": "R3", "match": True, "Fr_crest": 1.0, "h_up": 1.1,
                     "bore_speed": 2.0, "lee_jump": True, "x_jump": 900.0, "q_ratio": 0.9, "dry_cells": 0,
                     "status": "max_time", "wall_s": 1.0}]}
    regp = os.path.join(t, "A1.json")
    with open(regp, "w") as f:
        json.dump(reg, f)
    open(regp[:-5] + ".csv", "w").close()
    sec = {"format": "sw-sections", "version": 2, "git": "x", "created": "2026-11-08T00:00:00",
           "rows": [{"case": "C1", "dx": 50.0, "dx_sw": 400.0, "sw_case": "c1", "sw_run": runp, "rule_b0": "N2h0", "h0": 500.0,
                     "b0": 0.1, "U0": 5.0, "F0": 0.7, "M": 0.4, "E": 0.1, "E0": 0.2, "S_sw": 1.2, "S_p": 1.3,
                     "D_sw": 0.8, "D_p": 0.7, "x_D_sw": 600.0, "x_D_p": 700.0, "status": "steady", "wall_s": 1.0}]}
    secp = os.path.join(t, "sections.json")
    with open(secp, "w") as f:
        json.dump(sec, f)
    open(secp[:-5] + ".csv", "w").close()
    pan = {"format": "sw-panels2d", "version": 2, "git": "x", "created": "2026-11-08T00:00:00", "tol_picard": 0.15,
           "rows": [{"case": "C1", "variant": "potential", "point": "crest", "x": 0.0, "z_agl": 50.0,
                     "ref_kind": "picard", "ref_source": "P50", "ref_reliability": "модель ±15 %", "u_ref": 8.0,
                     "w_ref": 0.0, "u_pan": 8.8, "w_pan": 0.0, "units": "m/s", "err": 0.8, "within_tol": True,
                     "ref_err": 0.05, "within_tol_ref": True,
                     "ds_min": 25.0, "t_solve_ms": 10.0, "t_query_us": 5.0}],
           "rotor": [{"case": "PERD_NE", "variant": "vortex", "rotor_pan": True, "L_pan": 300.0, "rotor_ref": True,
                      "L_ref": 350.0, "ref_source": "Menke 2019"}]}
    panp = os.path.join(t, "points.json")
    with open(panp, "w") as f:
        json.dump(pan, f)
    open(panp[:-5] + ".csv", "w").close()
    return cp, fp, runp, regp, secp, panp


def selftest():
    with tempfile.TemporaryDirectory() as t:
        cp, fp, runp, regp, secp, panp = _synth(t)
        if run([t]) != 0:
            print("selftest: синтетика не прошла")
            return 1
        broken = 0
        # порча: каждая должна дать FAIL
        cases = [
            (cp, lambda d: d.update(dim=2)),
            (cp, lambda d: d["ref"].update(h0=0.0)),
            (cp, lambda d: d["bc"].update(west="open")),
            (cp, lambda d: d.update(version=2)),
            (fp, lambda d: d["arrays"].pop("hb")),
            (fp, lambda d: d["arrays"].update(h=[0, 7])),
            (runp, lambda d: d.update(status="ok")),
            (runp, lambda d: d.pop("b_clipped")),
            (regp, lambda d: d["rows"][0].update(match=False)),
            (regp, lambda d: d["rows"][0].update(regime_theory="R4")),
            (secp, lambda d: d["rows"][0].pop("E0")),
            (secp, lambda d: d["rows"][0].update(case="C9")),
            (secp, lambda d: d.update(version=1)),
            (panp, lambda d: d["rows"][0].update(within_tol=False)),
            (panp, lambda d: d["rows"][0].update(point="top")),
            (panp, lambda d: d.pop("rotor")),
        ]
        for path, spoil in cases:
            with open(path) as f:
                orig = f.read()
            d = json.loads(orig)
            spoil(d)
            with open(path, "w") as f:
                json.dump(d, f)
            try:
                check_file(path)
                print(f"selftest: порча не поймана в {os.path.basename(path)}")
                broken += 1
            except (ContractError, KeyError, TypeError, ValueError, struct.error):
                pass
            with open(path, "w") as f:
                f.write(orig)
        print("selftest OK" if not broken else f"selftest FAIL ({broken})")
        return 1 if broken else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if not sys.argv[1:]:
        print(__doc__)
        sys.exit(2)
    sys.exit(run(sys.argv[1:]))
