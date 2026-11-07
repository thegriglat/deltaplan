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

FORMATS = {"sw-case": 1, "sw-field": 1, "sw-run": 1}
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
    {"sw-case": check_case, "sw-field": check_field, "sw-run": check_run}[fmt](path, d)
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
    return cp, fp, runp


def selftest():
    with tempfile.TemporaryDirectory() as t:
        cp, fp, runp = _synth(t)
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
