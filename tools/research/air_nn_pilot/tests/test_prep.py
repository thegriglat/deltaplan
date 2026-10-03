#!/usr/bin/env python3
"""Контракт П2 v3: поворот ×4 = тождество; поворот согласован с физикой (аналитическое поле); направление
ветра после поворота в секторе ±45°; обратное преобразование выхода = исходные поля (синтетика и, если
задан набор, настоящие образцы); карты входа v3 — MAP_NAMES = порядку контракта, формулы на аналитическом рельефе
(наклонная плоскость: уклон вдоль = известному, поперёк = 0 при любом остатке r; гора: TPI > 0 на вершине,
затенённость > 0 за горой и < 0 на наветренном склоне), эквивариантность (рельеф и ветер повёрнуты вместе на 90° →
те же карты).

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


CONTRACT_MAPS = ("terrain", "heat_flux", "x", "y", "slope_along", "slope_cross", "tpi_2k", "tpi_8k", "shelter")


def maps_for(hc, wdir, H=None):
    row = fake_row(wdir, 5.0)
    meta = P.case_meta(row, hc)
    z = dict(d400_hc=hc, d400_H=np.zeros_like(hc) if H is None else H)
    return P.maps(z, meta, row), meta


def to_phys(m, k):
    """Карта повёрнутой системы → исходная (для проверки места на рельефе)."""
    return P.rot_scalar(m, -k % 4)


def test_map_names():
    assert P.MAP_NAMES == CONTRACT_MAPS, P.MAP_NAMES
    hc = np.full((N, N), 1000.0)
    m, _ = maps_for(hc, 270.0)
    assert m.shape == (9, N, N) and m.dtype == np.float32


def test_maps_plane():
    """h = s·(ê·p): склон поднимается по ветру (наветренный) с уклоном s; поперёк — 0. Любой wdir (любой r и k)."""
    X, Y = grid()
    s = 0.12
    for wdir in np.arange(0.0, 360.0, 7.3):
        a = math.radians(wdir)
        ex, ey = -math.sin(a), -math.cos(a)                  # куда дует
        hc = 1500.0 + s * (ex * X + ey * Y)
        m, meta = maps_for(hc, float(wdir))
        along, cross = m[4] * P.NORM_SLOPE, m[5] * P.NORM_SLOPE
        assert np.allclose(along, s, atol=1e-9), (wdir, along.min(), along.max())
        assert np.allclose(cross, 0.0, atol=1e-9), (wdir, np.abs(cross).max())
        # поперёк: плоскость, растущая влево от потока
        hc2 = 1500.0 + s * (-ey * X + ex * Y)
        m2, _ = maps_for(hc2, float(wdir))
        assert np.allclose(m2[4], 0.0, atol=1e-9) and np.allclose(m2[5] * P.NORM_SLOPE, s, atol=1e-9), wdir
        # на наветренной плоскости затенённость < 0 (вдали от края с наветра): atan(−s)
        sx = to_phys(m[8] * P.NORM_SX_RAD, meta["k"])
        lim = N * DX / 2 - DX                                 # точки, у которых p − d·ê внутри области при всех d ≤ 4 км
        up = (np.abs(X - 4000 * ex) < lim) & (np.abs(Y - 4000 * ey) < lim) & (np.abs(X) < lim) & (np.abs(Y) < lim)
        assert np.allclose(sx[up], math.atan(-s), atol=1e-9), wdir


def test_maps_hill():
    """Гора в центре: TPI > 0 на вершине (оба масштаба), за горой (с подветра) Sx > 0, на наветренном склоне Sx < 0;
    наветренный склон — slope_along > 0, подветренный — < 0."""
    X, Y = grid()
    hc = 900.0 + 800.0 * np.exp(-(X ** 2 + Y ** 2) / (2 * 1500.0 ** 2))
    c = N // 2
    for wdir in (270.0, 250.0, 0.0, 135.0, 200.0, 313.0):
        a = math.radians(wdir)
        ex, ey = -math.sin(a), -math.cos(a)
        m, meta = maps_for(hc, wdir)
        k = meta["k"]
        tp2, tp8 = to_phys(m[6], k), to_phys(m[7], k)
        assert tp2[c, c] > 0 and tp8[c, c] > 0 and tp2[c - 1, c - 1] > 0, wdir
        sx, sa = to_phys(m[8], k), to_phys(m[4], k)

        def at(dist):                                        # клетка на расстоянии dist по ветру от вершины
            x, y = dist * ex, dist * ey
            return int(round((y + N * DX / 2) / DX - 0.5)), int(round((x + N * DX / 2) / DX - 0.5))
        for dist in (2400.0, 3200.0, 4400.0):                # подветренная сторона: затенено
            assert sx[at(dist)] > 0, (wdir, dist, sx[at(dist)])
            assert sa[at(dist)] < 0, (wdir, dist)
        for dist in (-1200.0, -2000.0):                       # наветренный склон: открыто, склон вверх по ветру
            assert sx[at(dist)] < 0, (wdir, dist, sx[at(dist)])
            assert sa[at(dist)] > 0, (wdir, dist)


def test_maps_equivariance():
    """Рельеф и ветер, повёрнутые вместе на 90° против часовой, дают те же карты (вход зависит только от
    рельефа относительно ветра)."""
    rng = np.random.default_rng(3)
    X, Y = grid()
    hc = 1000 + 600 * np.exp(-((X - 5000) ** 2 + (Y + 3000) ** 2) / 2e7) + 30 * rng.normal(size=(N, N))
    H = rng.uniform(0, 400, size=(N, N))
    for wdir in (10.0, 100.0, 222.0, 300.0, 359.0):
        m0, _ = maps_for(hc, wdir, H)
        m1, _ = maps_for(P.rot_scalar(hc, 1), (wdir - 90.0) % 360.0, P.rot_scalar(H, 1))
        err = float(np.max(np.abs(m0 - m1)))
        assert err < 1e-5, (wdir, err)


def test_maps_rot4():
    """Карты в повёрнутой системе после обратного поворота и 4 поворотов — тождество (поворот без потерь)."""
    rng = np.random.default_rng(4)
    hc = 1000 + 200 * rng.normal(size=(N, N))
    for wdir in (5.0, 95.0, 185.0, 275.0):
        m, meta = maps_for(hc, wdir)
        b = m
        for _ in range(4):
            b = P.rot_scalar(b, meta["k"])
        assert np.array_equal(b, m)


def test_inverse_v5_enc():
    """П2 v5: `prep.to_physical(..., enc=v5, base)` — обратное к `base.target_v5` с γ_a по высоте (m и h отдельно),
    в том числе через хранение цели в f16 и сборку w_rel = Y5(γ=0) − γ·K (как prep5 + train.load_arrays_enc)."""
    from pilotnn import base as B
    from pilotnn import prep5 as P5
    rng = np.random.default_rng(5)
    X, Y = grid()
    hc = 1000 + 500 * np.exp(-((X - 3000) ** 2 + Y ** 2) / 5e7)
    gam = dict(m=rng.uniform(0, 1, 13).tolist(), h=rng.uniform(0, 1, 13).tolist())
    enc = dict(outputs="v5", gamma=gam)
    for wdir in (0.0, 135.0, 271.0):
        for U10 in (0.7, 6.0):
            m = rng.normal(size=(3, 13, N, N)) + np.array([4.0, 1.0, 0.0])[:, None, None, None]
            h = rng.normal(size=(4, 13, N, N)) + np.array([4.0, 1.0, 0.0, 0.0])[:, None, None, None]
            z = dict(d400_m=m, d400_h=h, d400_hc=hc, d400_H=0 * hc)
            row = fake_row(wdir, U10)
            meta = P.case_meta(row, hc)
            base = P5.base_for(hc, meta)
            y = B.target_v5(z, meta, base, gamma=gam)
            back = P.to_physical(y, meta, enc=enc, base=base)
            for key in ("m", "h"):          # ‖V‖ < ε — ошибка ≤ ε (контракт), иначе — точно
                e = np.abs(back[key] - z[f"d400_{key}"])
                slow = np.hypot(z[f"d400_{key}"][0], z[f"d400_{key}"][1]) < B.EPS
                assert e.max() <= B.EPS + 1e-9 and e[:, ~slow].max() < 1e-9, (wdir, U10, key, e.max())
            d = P5.prepare_case_v5(z, dict(row, loc="t"), None)
            y16 = d["Y5"].astype(np.float64)
            g = B.gamma_of(gam)
            K = d["K"].astype(np.float64)
            y16[39:52] -= g[0] * K[:13]
            y16[91:104] -= g[1] * K[13:]
            back = P.to_physical(y16, meta, enc=enc, base=base)
            for k in ("m", "h"):           # f16-цель: ошибка — от шага f16 (вне ‖V‖ < ε)
                fk = z[f"d400_{k}"]
                slow = np.hypot(fk[0], fk[1]) < B.EPS
                e = float(np.abs(back[k] - fk)[:, ~slow].max())
                assert e < 0.02, (wdir, U10, k, e)
    try:
        P.to_physical(np.zeros((117, N, N)), meta, enc=enc)
        raise AssertionError("выход v5 без базы должен падать")
    except ValueError:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="")
    a = ap.parse_args()
    tests = [test_rot4_identity, test_rot_physical, test_sector, test_inverse_synthetic, test_map_names, test_maps_plane,
             test_maps_hill, test_maps_equivariance, test_maps_rot4, test_inverse_v5_enc]
    for t in tests:
        t()
        print("ok", t.__name__)
    if a.dataset:
        test_inverse_dataset(a.dataset)
        print("ok test_inverse_dataset")


if __name__ == "__main__":
    main()
