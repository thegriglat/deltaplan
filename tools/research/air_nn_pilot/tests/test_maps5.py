#!/usr/bin/env python3
"""Карты входа П2 v5 (`pilotnn/maps5.py`, контракт docs/contracts/air-nn-p3.md): имена, знаки отражения, первые 9 карт =
v4, побитный повтор, эквивариантность (рельеф 25 м и ветер повёрнуты вместе на 90° → те же карты; отражённый образец =
R(карты)), аналитика (наклонная плоскость, уступ с подветренным следом), тайл 25 м ↔ билинейная подстановка.

  .venv/bin/python tests/test_maps5.py
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import maps5 as M  # noqa: E402
from pilotnn import prep as P  # noqa: E402

N, DX = 96, 400.0
NAMES = {n: i for i, n in enumerate(M.MAP_NAMES_V5)}


def row_of(wdir, U10=6.0):
    return dict(id="t", loc="t", U10=U10, wdir=wdir, t_max=26.0, hour=14,
                profile=dict(alpha=0.2, max_profile=1.5, stab="D", sun_el=40.0, sun_az=200.0), day={}, d400={"dx": DX})


def grid():
    x = (np.arange(N) + 0.5) * DX - N * DX / 2
    return np.meshgrid(x, x)


def hill():
    X, Y = grid()
    hc = (900 + 600 * np.exp(-((X - 2000) ** 2 + (Y + 4000) ** 2) / (2 * 2500 ** 2))
          + 250 * np.exp(-((X + 6000) ** 2 + (Y - 3000) ** 2) / (2 * 1200 ** 2)) + 0.02 * X)
    H = 200 + 50 * np.cos(X / 5000) + 30 * np.sin(Y / 3000)
    return dict(d400_hc=hc, d400_H=H)


def tile_from_crop(crop, fill=0.0):
    """Тайл 1601² с квадратом 1538² узлов (31…1568) из `crop`."""
    t = np.full((1601, 1601), fill, np.float32)
    t[M.N0:M.N1, M.N0:M.N1] = crop
    return t


def rough_tile(hc, seed=2):
    """Тайл: билинейная подстановка + мелкий рельеф (чтобы подсеточные карты были содержательны)."""
    c, _ = M.h25_crop(hc, None)
    rng = np.random.default_rng(seed)
    from scipy import ndimage
    c = c + 25 * ndimage.gaussian_filter(rng.normal(size=c.shape), 6) * 8
    return tile_from_crop(c.astype(np.float64))


def maps_of(z, wdir, tile):
    row = row_of(wdir)
    meta = P.case_meta(row, z["d400_hc"])
    return M.maps_v5(z, meta, row, tile=tile), meta


def test_names_signs():
    assert len(M.MAP_NAMES_V5) == 27 and tuple(M.MAP_NAMES_V5[:9]) == P.MAP_NAMES
    neg = {n for n, s in zip(M.MAP_NAMES_V5, M.REFLECT_MAP_SIGN_V5) if s < 0}
    assert neg == {"y", "slope_cross", "slope_cross_1k2", "slope_cross_3k2", "slope_cross_8k"}, neg
    assert np.array_equal(M.REFLECT_MAP_SIGN_V5[:9], P.REFLECT_MAP_SIGN)


def test_first9_and_repeat():
    z = hill()
    tile = rough_tile(z["d400_hc"])
    for t in (None, tile):
        X, meta = maps_of(z, 250.0, t)
        row = row_of(250.0)
        assert X.shape == (27, N, N) and X.dtype == np.float32 and np.isfinite(X).all()
        assert np.array_equal(X[:9], P.maps(z, meta, row)), "первые 9 карт ≠ v4"
        assert np.array_equal(X, M.maps_v5(z, meta, row, tile=t)), "нет побитного повтора"


def rotate_case(z, tile, kq):
    """Образец, повёрнутый против часовой на kq·90° (рельеф, поток тепла, тайл); ветер — wdir − kq·90°."""
    z2 = dict(d400_hc=P.rot_scalar(z["d400_hc"], kq).copy(), d400_H=P.rot_scalar(z["d400_H"], kq).copy())
    t2 = None
    if tile is not None:
        t2 = tile_from_crop(P.rot_scalar(tile[M.N0:M.N1, M.N0:M.N1], kq).copy())
    return z2, t2


def test_rotations():
    z = hill()
    for use_tile in (False, True):
        tile = rough_tile(z["d400_hc"]) if use_tile else None
        for wdir in (250.0, 290.0, 20.0, 133.0):
            X0, _ = maps_of(z, wdir, tile)
            for kq in (1, 2, 3):
                z2, t2 = rotate_case(z, tile, kq)
                X2, m2 = maps_of(z2, (wdir - 90.0 * kq) % 360.0, t2)
                d = np.abs(X2 - X0).max()
                assert d < 2e-4, (use_tile, wdir, kq, d, [M.MAP_NAMES_V5[i] for i in np.where(np.abs(X2 - X0).max((1, 2)) > 2e-4)[0]])


def test_reflection():
    """R: y′ → −y′ при k = 0: рельеф, тайл и поле тепла развёрнуты по j, wdir → 540 − wdir; карты = R(карты)."""
    z = hill()
    for use_tile in (False, True):
        tile = rough_tile(z["d400_hc"]) if use_tile else None
        for wdir in (250.0, 275.0, 295.0):
            X0, m0 = maps_of(z, wdir, tile)
            assert m0["k"] == 0
            z2 = dict(d400_hc=z["d400_hc"][::-1].copy(), d400_H=z["d400_H"][::-1].copy())
            t2 = tile_from_crop(tile[M.N0:M.N1, M.N0:M.N1][::-1].copy()) if use_tile else None
            X2, m2 = maps_of(z2, (540.0 - wdir) % 360.0, t2)
            assert abs(m2["r"] + m0["r"]) < 1e-12
            exp = np.flip(X0, axis=-2) * M.REFLECT_MAP_SIGN_V5[:, None, None]
            d = np.abs(X2 - exp).max((1, 2))
            assert d.max() < 2e-4, (use_tile, wdir, [(M.MAP_NAMES_V5[i], float(d[i])) for i in np.where(d > 2e-4)[0]])


def test_plane():
    """Наклонная плоскость h = a·x + b·y: уклоны по масштабам в центре = известные; подсеточные — аналитически."""
    X, Y = grid()
    a, b = 0.12, -0.05
    hc = 1000 + a * X + b * Y
    z = dict(d400_hc=hc, d400_H=0 * hc + 300)
    xs = -20000.0 + 25.0 * np.arange(1601)
    XT, YT = np.meshgrid(xs, xs)
    tile = (1000 + a * XT + b * YT).astype(np.float32)
    wdir = 270.0                                    # ветер на восток: k = 0, r = 0
    Xm, meta = maps_of(z, wdir, tile)
    assert meta["k"] == 0 and abs(meta["r"]) < 1e-12
    c = slice(30, -30)
    g = lambda n: Xm[NAMES[n]][c, c]  # noqa: E731
    for sc in ("", "_1k2", "_3k2", "_8k"):
        nm_a, nm_c = ("slope_along", "slope_cross") if sc == "" else (f"slope_along{sc}", f"slope_cross{sc}")
        if sc in ("_1k2", "_3k2", "_8k"):
            pass
        assert np.allclose(g(nm_a), a / 0.3, atol=2e-3), (nm_a, g(nm_a).mean())
        assert np.allclose(g(nm_c), b / 0.3, atol=2e-3), (nm_c, g(nm_c).mean())
    sl = math.hypot(a, b)
    assert np.allclose(g("sub_slope_std"), 0, atol=1e-4)
    assert np.allclose(g("sub_slope_p95"), sl / 0.6, atol=1e-4)
    assert np.allclose(g("sub_steep_lee"), 0) and np.allclose(g("sub_steep_wind"), 0)      # a = 0,12 < 0,3
    assert np.allclose(g("sub_relief"), 15 * 25 * (abs(a) + abs(b)) / 300.0, atol=1e-4)
    # крутая плоскость вниз по ветру: все подклетки «круто вниз»
    tile2 = (1000 - 0.5 * XT).astype(np.float32)
    z2 = dict(d400_hc=1000 - 0.5 * X, d400_H=0 * hc + 300)
    X2, _ = maps_of(z2, wdir, tile2)
    assert np.allclose(X2[NAMES["sub_steep_lee"]], 1.0) and np.allclose(X2[NAMES["sub_steep_wind"]], 0.0)
    assert (X2[NAMES["sep_400"]][c, c] > 0.97).all() and (X2[NAMES["sep_wake"]][c, c] >= X2[NAMES["sep_400"]][c, c]).all()
    X3, _ = maps_of(dict(d400_hc=1000 + 0.5 * X, d400_H=0 * hc + 300), wdir, (1000 + 0.5 * XT).astype(np.float32))
    assert np.allclose(X3[NAMES["sub_steep_wind"]], 1.0) and np.allclose(X3[NAMES["sub_steep_lee"]], 0.0)
    assert (X3[NAMES["sep_400"]][c, c] < 1e-3).all()
    # плоскость без тайла (билинейная подстановка): в глубине области те же подсеточные карты
    X4, _ = maps_of(z, wdir, None)
    cc = slice(3, -3)
    for n in ("sub_slope_std", "sub_slope_p95", "sub_steep_lee", "sub_steep_wind", "sub_relief"):
        assert np.allclose(X4[NAMES[n]][cc, cc], Xm[NAMES[n]][cc, cc], atol=1e-4), n


def test_escarpment_wake():
    """Уступ высотой 500 и 1200 м на x = 0 (вниз по ветру, ветер на восток): sep_400 — на кромке, sep_wake убывает за ней
    и ≈ 0 выше по ветру от кромки; длина следа растёт с перепадом."""
    X, Y = grid()
    z = dict(d400_H=0 * X + 300)
    prof = {}
    for H in (500.0, 1200.0):
        z["d400_hc"] = 1000 + H * (1 - 1 / (1 + np.exp(-X / 200.0)))
        Xm, _ = maps_of(z, 270.0, None)
        sw, s4 = Xm[NAMES["sep_wake"]][N // 2], Xm[NAMES["sep_400"]][N // 2]
        ic = int(np.argmax(s4))
        assert abs(ic - N // 2) <= 1 and s4[ic] > 0.9, (ic, s4[ic])
        down = sw[ic:ic + 8]
        assert np.all(np.diff(down) <= 1e-9) and down[1] > 0.0, down
        assert sw[ic - 6] < 0.01, sw[ic - 6]
        prof[H] = sw[ic + 3]
    assert prof[1200.0] > prof[500.0], prof


def test_tile_vs_bilinear():
    """Тайл = билинейная подстановка → те же карты; грубый тайл меняет только подсеточные карты 15–19."""
    z = hill()
    hc = z["d400_hc"]
    c, had = M.h25_crop(hc, None)
    assert not had
    t_bil = tile_from_crop(c)
    Xa, _ = maps_of(z, 250.0, None)
    Xb, _ = maps_of(z, 250.0, t_bil)
    assert np.abs(Xa - Xb).max() < 1e-5
    Xc, _ = maps_of(z, 250.0, rough_tile(hc))
    diff = np.abs(Xa - Xc).max((1, 2))
    assert all(diff[i] < 1e-6 for i in range(27) if not 15 <= i <= 19), diff
    assert diff[15:20].max() > 1e-2
    # подстановка согласована с блочным средним: среднее блока 16×16 билинейного h25 ≈ hc (линейный рельеф — точно)
    assert np.allclose(c[1:-1, 1:-1].reshape(N, 16, N, 16).mean((1, 3))[4:-4, 4:-4], hc[4:-4, 4:-4], atol=10.0)   # ≤ ~¼ второй разности (гора σ = 1,2 км: 6,5 м)


def test_base_maps():
    """Карты 24–26: плоский рельеф → 0 (V_base = Ub·ê′); на холме нетривиальны; повороты/отражение — в test_rotations/
    test_reflection (там все 27 карт)."""
    X, Y = grid()
    for wdir in (270.0, 250.0, 133.0):
        Xf, _ = maps_of(dict(d400_hc=0 * X + 1000, d400_H=0 * X + 300), wdir, None)
        assert np.abs(Xf[24:27]).max() < 1e-6, np.abs(Xf[24:27]).max()
    Xh, _ = maps_of(hill(), 270.0, None)
    assert np.abs(Xh[24:27]).max((1, 2)).min() > 1e-3 and np.isfinite(Xh[24:27]).all()
    assert Xh[24].max() > 0.0 > Xh[24].min(), "разгон на вершине и торможение в лощине ожидаются"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"  {name}: OK")
    print("test_maps5: OK")
