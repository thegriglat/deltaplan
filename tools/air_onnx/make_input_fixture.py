#!/usr/bin/env python3
"""Фикстура O4 (docs/contracts/air-onnx.md): строка входа сети (как airlite_gen.solve_case, но БЕЗ решения) для
нескольких случаев — эталон теста test_air_nn_input игры.

Строка = U10, wdir, t_max, hour, sky + profile{alpha, max_profile, stab, sun_el, sun_az} (real.case → cond.*)
+ day = cond.day.summary() (нефинитное → null) + hc (d400_hc) и heat (d400_H).
real.make тянет CuPy (GPU) — здесь не вызывается: D.hc = hc, D.H = H с гашением у края по формуле air.py:663
(heat_taper_m = Params().heat_taper_m, taper=True), побитно как в Air.__init__.

  make_input_fixture.py            записать tests/air_onnx/fixtures/input_cases.json
  make_input_fixture.py --verify   пересчитать и сверить с записанным (exit 0 — совпало)

Запуск — только CPU, venv пилота (только читать): CUDA_VISIBLE_DEVICES= .../air_nn_pilot/.venv/bin/python -B
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "tools/research/air3d"))

import numpy as np  # noqa: E402

OUT = ROOT / "tests/air_onnx/fixtures/input_cases.json"
# Онгудай 12:00 3 м/с со 150° ясно (задание); утро с инверсией (cap_agl, brk < 1); другое место/час/небо.
CASES = [
    dict(id="ongudai_12", loc="ongudai", hour=12.0, U10=3.0, wdir=150.0, t_max=26.0, sky="clear"),
    dict(id="ongudai_09", loc="ongudai", hour=9.0, U10=1.5, wdir=40.0, t_max=22.0, sky="overcast"),
    dict(id="aushkul_15", loc="aushkul", hour=15.0, U10=5.5, wdir=300.0, t_max=31.0, sky="partly"),
]
DX = 400


def tapered(H, dx, taper_m):
    ny, nx = H.shape
    Lx, Ly = nx * dx, ny * dx
    xe = (np.arange(nx) + 0.5) * dx
    ye = (np.arange(ny) + 0.5) * dx
    exx = np.clip(np.minimum(xe, Lx - xe) / taper_m, 0, 1)
    eyy = np.clip(np.minimum(ye, Ly - ye) / taper_m, 0, 1)
    return H * (np.sin(0.5 * np.pi * eyy)[:, None] * np.sin(0.5 * np.pi * exx)[None, :]) ** 2


def build(c):
    import air as A
    import real as R
    g, hc = R.grid_domain(c["loc"], DX)
    cond = R.case(c["loc"], g, hc, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], True)
    H = tapered(np.asarray(cond.H, float), g.dx, A.Params().heat_taper_m)
    day = {k: (v if not isinstance(v, float) or math.isfinite(v) else None) for k, v in cond.day.summary().items()}
    prof = dict(alpha=cond.alpha, max_profile=cond.max_profile, stab=cond.stab_class, sun_el=cond.sun_elev,
                sun_az=cond.sun[0])
    return dict(c, nx=g.nx, ny=g.ny, dx=g.dx, profile=prof, day=day,
                hc=np.round(np.asarray(hc, float), 3).ravel().tolist(), heat=np.round(H, 3).ravel().tolist())


def compare(a, b, path=""):
    """Список расхождений: числа — отн. 1e-6 (абс. 1e-6), остальное — равенство."""
    bad = []
    if isinstance(a, dict):
        for k in set(a) | set(b):
            if k not in a or k not in b:
                bad.append(f"{path}/{k}: нет с одной стороны")
            else:
                bad += compare(a[k], b[k], f"{path}/{k}")
    elif isinstance(a, list):
        if len(a) != len(b):
            bad.append(f"{path}: длина {len(a)} ≠ {len(b)}")
        elif a and isinstance(a[0], (dict, list)):
            for i, (x, y) in enumerate(zip(a, b)):
                bad += compare(x, y, f"{path}[{i}]")
        else:
            d = float(np.max(np.abs(np.asarray(a, float) - np.asarray(b, float)))) if a else 0.0
            if d > 1e-6:
                bad.append(f"{path}: max|Δ| = {d:g}")
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if abs(a - b) > 1e-6 * max(1.0, abs(b)):
            bad.append(f"{path}: {a} ≠ {b}")
    elif a != b:
        bad.append(f"{path}: {a!r} ≠ {b!r}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()
    data = dict(doc="Эталон O4: строка входа сети без решения (tools/air_onnx/make_input_fixture.py)",
                cases=[build(c) for c in CASES])
    if a.verify:
        ref = json.loads(OUT.read_text())
        bad = compare(json.loads(json.dumps(data)), ref)
        for b in bad:
            print("РАСХОЖДЕНИЕ", b)
        print("input fixture:", "FAIL" if bad else "OK", f"({len(CASES)} случаев)")
        sys.exit(1 if bad else 0)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    print("записано", OUT, f"{OUT.stat().st_size / 1e6:.2f} МБ")


if __name__ == "__main__":
    main()
