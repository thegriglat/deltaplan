#!/usr/bin/env python3
"""Контракт П2: поворот ×4 = тождество; поворот согласован с физикой (аналитическое поле); направление
ветра после поворота в секторе ±45°; обратное преобразование выхода = исходные поля (синтетика и, если
задан набор, настоящие образцы).

  .venv/bin/python tests/test_prep.py [--dataset <каталог набора>]
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pilotnn import prep as P  # noqa: E402

N, DX = 96, 400.0


def grid():
    x = (np.arange(N) + 0.5) * DX - N * DX / 2
    return np.meshgrid(x, x)       # X[j, i] — восток, Y[j, i] — север


def test_rot4_identity():
    rng = np.random.default_rng(0)
    a = rng.normal(size=(3, 13, N, N))
    u, v = rng.normal(size=(2, 13, N, N))
    for k in range(4):
        b = a
        for _ in range(4):
            b = P.rot_scalar(b, k)
        assert np.array_equal(b, a)
        uu, vv = u, v
        for _ in range(4):
            uu, vv = P.rot_vec(uu, vv, k)
        assert np.array_equal(uu, u) and np.array_equal(vv, v)
        # k, затем −k — тождество
        b2 = P.rot_scalar(P.rot_scalar(a, k), -k % 4)
        assert np.array_equal(b2, a)


def test_rot_physical():
    """Скаляр f(x, y) и векторное поле V(x, y) = ∇f: повёрнутые массивы = поле, повёрнутое в пространстве."""
    X, Y = grid()

    def f(x, y):
        return np.exp(-((x - 6000) ** 2 + (y + 2000) ** 2) / 4e7) + 0.3 * np.exp(-((x + 9000) ** 2 + (y - 7000) ** 2) / 1e7)

    def grad(x, y, e=1.0):
        return (f(x + e, y) - f(x - e, y)) / (2 * e), (f(x, y + e) - f(x, y - e)) / (2 * e)

    for k in range(4):
        th = k * math.pi / 2
        c, s = round(math.cos(th)), round(math.sin(th))
        # повёрнутое поле в точке p' — значение в R⁻¹p'
        xb, yb = c * X + s * Y, -s * X + c * Y
        exp_s = f(xb, yb)
        got = P.rot_scalar(f(X, Y), k)
        assert np.allclose(got, exp_s, atol=1e-12), k
        gu, gv = grad(xb, yb)
        eu, ev = c * gu - s * gv, s * gu + c * gv     # R·V(R⁻¹p')
        ru, rv = P.rot_vec(*grad(X, Y), k)
        assert np.allclose(ru, eu, atol=1e-9) and np.allclose(rv, ev, atol=1e-9), k


def test_sector():
    for wdir in np.arange(0, 360, 0.7):
        k, r = P.rotation_of(float(wdir))
        assert -math.pi / 4 - 1e-9 <= r < math.pi / 4 + 1e-9, (wdir, r)
        a = math.radians(wdir)
        ex, ey = -math.sin(a), -math.cos(a)
        u, v = P.rot_vec(np.full((1, 1), ex), np.full((1, 1), ey), k)
        assert abs(u[0, 0] - math.cos(r)) < 1e-12 and abs(v[0, 0] - math.sin(r)) < 1e-12, wdir
        assert u[0, 0] > 0.7          # «с запада»
    assert P.rotation_of(270.0) == (0, 0.0)


def fake_row(wdir, U10):
    return dict(id="t", loc="t", wdir=wdir, U10=U10, hour=12.0, t_max=26.0,
                profile=dict(alpha=0.16, max_profile=1.8, stab="C", sun_el=50.0, sun_az=150.0),
                day=dict(z_i_msl=3000, z_lcl_msl=2800, heat=0.9, cap_agl=None, brk=1.0, t=24.0),
                d400=dict(dx=DX, nx=N, ny=N))


def roundtrip(z, row, tol):
    hc = z["d400_hc"].astype(np.float64)
    meta = P.case_meta(row, hc)
    y = P.target(z, meta)
    assert y.shape == (91, N, N)
    back = P.to_physical(y, meta)
    for key in ("m", "h"):
        ref = np.asarray(z[f"d400_{key}"], np.float64)
        err = np.max(np.abs(back[key] - ref))
        assert err <= tol, (key, err)
    return meta


def test_inverse_synthetic():
    rng = np.random.default_rng(1)
    X, Y = grid()
    hc = 1000 + 500 * np.exp(-(X ** 2 + Y ** 2) / 5e7)
    for wdir in (0.0, 44.0, 46.0, 135.0, 200.0, 271.0, 359.0):
        for U10 in (0.0, 0.7, 6.0):
            z = dict(d400_m=rng.normal(size=(3, 13, N, N)), d400_h=rng.normal(size=(4, 13, N, N)), d400_hc=hc,
                     d400_H=rng.normal(size=(N, N)))
            roundtrip(z, fake_row(wdir, U10), 1e-12)


def test_inverse_dataset(root):
    from pilotnn.data import Dataset
    ds = Dataset(root)
    rows = ds.case_rows()[:6]
    for row in rows:
        z = ds.load(row["id"])
        # из fp16 в float64 — обратное преобразование точное (до округления float64)
        roundtrip({k: v.astype(np.float64) for k, v in z.items()}, row, 1e-9)
        # через хранение цели в fp16: ошибка ≤ шага fp16 от величины
        meta = P.case_meta(row, z["d400_hc"].astype(np.float64))
        y16 = P.target(z, meta).astype(np.float16)
        back = P.to_physical(y16, meta)
        e = max(float(np.max(np.abs(back[k] - z[f"d400_{k}"].astype(np.float64)))) for k in ("m", "h"))
        print(f"  {row['id']}: k={meta['k']}, r={math.degrees(meta['r']):.1f}°, fp16-цель → поле: max|Δ| {e:.2e}")
        assert e < 0.02
    print(f"  образцов набора: {len(rows)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="")
    a = ap.parse_args()
    tests = [test_rot4_identity, test_rot_physical, test_sector, test_inverse_synthetic]
    for t in tests:
        t()
        print("ok", t.__name__)
    if a.dataset:
        test_inverse_dataset(a.dataset)
        print("ok test_inverse_dataset")


if __name__ == "__main__":
    main()
