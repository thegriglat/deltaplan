#!/usr/bin/env python3
"""Тест Б1 (линейная база) и выхода v5: аналитический холм (Аньези 2D — линейное решение для u′, w; гаусс 3D —
знаки и бездивергентность), повороты ×4, отражение, плоский рельеф, побитный повтор, обратимость цели v5.

  .venv/bin/python tests/test_base.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import base as B  # noqa: E402
from pilotnn import prep as P  # noqa: E402

N, DX, NA = 96, 400.0, len(P.AGL)
X1 = (np.arange(N) + 0.5) * DX - N * DX / 2
X, Y = np.meshgrid(X1, X1)
UB = P.ubg(P.AGL, 0.2, 1.5, 6.0)


def test_agnesi_2d():
    """h = H a²/(x²+a²), поток вдоль x. Линейное решение: g(ζ) = i H a/(ζ+ia), ζ = x + iz;
    w′ = U·Re g′(ζ), u′ = U·Im g′(ζ) (аналитичность: ∂u′/∂z = ∂w′/∂x, ∂u′/∂x + ∂w′/∂z = 0)."""
    Hh, a, U = 100.0, 2000.0, 8.0
    hc = np.tile(Hh * a ** 2 / (X1 ** 2 + a ** 2), (N, 1))
    ub = np.full(NA, U)
    b = B.linear_base(hc, 0.0, ub)
    worst = 0.0
    for i, z in enumerate(P.AGL):
        zeta = X1 + 1j * z
        gp = -Hh * a * 1j / (zeta + 1j * a) ** 2
        w_ref, u_ref = U * gp.real, U * gp.imag
        sc = np.abs(U * Hh / a)
        worst = max(worst, np.abs(b["w"][i, N // 2] - w_ref).max() / sc, np.abs(b["u"][i, N // 2] - U - u_ref).max() / sc)
        assert np.allclose(b["w"][i], b["w"][i, :1], atol=1e-9), "2D: w зависит от y"
    assert worst < 0.05, f"Аньези: отклонение от линейного решения {worst:.3f} · U·H/a"
    top = b["u"][0, N // 2, N // 2 - 1:N // 2 + 1].mean() - U
    assert top > 0.5 * U * Hh / a, "на вершине разгон должен быть > 0"
    # знаки: наветренный склон w > 0, подветренный < 0
    assert b["w"][0, 0, N // 2 - 8] > 0 > b["w"][0, 0, N // 2 + 7]
    print(f"  Аньези 2D: отклонение {worst:.4f} · U·H/a — OK")


def test_gauss_3d():
    h0, s = 300.0, 2500.0
    hc = h0 * np.exp(-((X + 1000) ** 2 + (Y - 500) ** 2) / (2 * s ** 2))
    r = 0.3
    b = B.linear_base(hc, r, UB)
    c, sn = np.cos(r), np.sin(r)
    j, i = np.unravel_index(np.argmax(hc), hc.shape)
    for a in (0, 6):
        sp = np.hypot(b["u"][a], b["v"][a])
        assert sp[j, i] > UB[a], "разгон на вершине"
        sx = (b["u"][a] * c + b["v"][a] * sn) - UB[a]
        assert sx[j, i] > 0
    ex = c * (X + 1000) + sn * (Y - 500)            # положение вдоль потока от вершины
    wind = b["w"][0][np.abs(ex + s) < 400]
    lee = b["w"][0][np.abs(ex - s) < 400]
    assert wind.max() > 0 > lee.min() and wind.mean() > 0 > lee.mean(), "знак w на склонах"
    # бездивергентность и безвихревость (по z — конечные разности на плотной сетке высот)
    zs = np.array([200.0, 220.0, 240.0])
    ub = np.full(3, 5.0)
    d = B.linear_base(hc, r, ub, agl=zs)
    dz = 20.0
    dvdy = (d["v"][1, 2:, :] - d["v"][1, :-2, :]) / (2 * DX)
    dudx = (d["u"][1, :, 2:] - d["u"][1, :, :-2]) / (2 * DX)
    dwdz = (d["w"][2] - d["w"][0]) / (2 * dz)
    res = dudx[1:-1] + dvdy[:, 1:-1] + dwdz[1:-1, 1:-1]
    assert np.abs(res).max() < 0.05 * np.abs(dwdz).max() + 1e-9, "div V ≠ 0"
    print("  гаусс 3D: знаки, бездивергентность — OK")


def test_symmetries():
    rng = np.random.default_rng(1)
    hc = 40 * rng.normal(size=(N, N)).cumsum(0).cumsum(1) * 0.01 + 500 * np.exp(-((X - 3000) ** 2 + Y ** 2) / 4e6)
    r = 0.25
    ref = B.linear_base(hc, r, UB)
    # равновариантность: рельеф и направление потока повёрнуты на k·90° против часовой: база(rot90(hc), r + k·90°) = повёрнутая база(hc, r), с векторным поворотом
    for k in (1, 2, 3):
        rk = r + k * np.pi / 2
        hk = P.rot_scalar(hc, k)
        bk = B.linear_base(hk, rk, UB)
        uk, vk = P.rot_vec(ref["u"], ref["v"], k)
        assert np.allclose(bk["u"], uk, atol=1e-8) and np.allclose(bk["v"], vk, atol=1e-8), f"поворот ×{k}: u,v"
        assert np.allclose(bk["w"], P.rot_scalar(ref["w"], k), atol=1e-8), f"поворот ×{k}: w"
        gxk, gyk = P.rot_vec(ref["gx"], ref["gy"], k)
        assert np.allclose(bk["gx"], gxk, atol=1e-10) and np.allclose(bk["gy"], gyk, atol=1e-10), f"поворот ×{k}: ∇h_s"
    # отражение y′ → −y′, r → −r: v → −v, остальное — разворот по j
    bm = B.linear_base(hc[::-1], -r, UB)
    assert np.allclose(bm["u"], ref["u"][:, ::-1], atol=1e-8) and np.allclose(bm["v"], -ref["v"][:, ::-1], atol=1e-8)
    assert np.allclose(bm["w"], ref["w"][:, ::-1], atol=1e-8) and np.allclose(bm["gy"], -ref["gy"][:, ::-1], atol=1e-8)
    # плоский рельеф
    fl = B.linear_base(np.full((N, N), 777.0), r, UB)
    assert np.allclose(fl["u"], UB[:, None, None] * np.cos(r)) and np.allclose(fl["w"], 0) and np.allclose(fl["gx"], 0)
    # побитный повтор
    again = B.linear_base(hc, r, UB)
    assert all(np.array_equal(ref[k], again[k]) for k in ref), "нет побитного повтора"
    # Ub = 0 → база нулевая
    z0 = B.linear_base(hc, r, np.zeros(NA))
    assert all(np.abs(z0[k]).max() == 0 for k in ("u", "v", "w")), "Ub = 0"
    print("  повороты ×4, отражение, плоский рельеф, повтор, Ub = 0 — OK")


def _case(k_wdir, seed=2):
    rng = np.random.default_rng(seed)
    hc = 900 + 500 * np.exp(-((X - 1500) ** 2 + (Y + 3000) ** 2) / (2 * 2500 ** 2))
    row = dict(id="t", loc="t", U10=6.0, wdir=k_wdir, t_max=26.0, hour=14,
               profile=dict(alpha=0.2, max_profile=1.5, stab="D", sun_el=40.0, sun_az=200.0), day={}, d400={"dx": DX})
    meta = P.case_meta(row, hc)
    ub = P.ubg(P.AGL, meta["alpha"], meta["mp"], meta["U10"])
    hr = np.ascontiguousarray(P.rot_scalar(hc, meta["k"]))
    base = B.linear_base(hr, meta["r"], ub)
    # «решатель»: база в физической системе + шум, потом хвосты и штиль в части клеток
    bu, bv = P.rot_vec(base["u"], base["v"], -meta["k"] % 4)
    m = np.stack([bu, bv, P.rot_scalar(base["w"], -meta["k"] % 4)]) * 1.0
    m = m + rng.normal(size=m.shape)
    h = np.concatenate([m + rng.normal(size=m.shape) * 0.5, rng.normal(size=(1, NA, N, N)) + 2], 0)
    z = dict(d400_hc=hc, d400_H=200 + 0 * hc, d400_m=m, d400_h=h)
    return z, meta, base


def test_target_roundtrip():
    for wdir in (270.0, 250.0, 200.0, 95.0, 10.0):
        z, meta, base = _case(wdir)
        y = B.target_v5(z, meta, base)
        assert y.shape == (9 * NA, N, N)
        back = B.to_physical_v5(y, meta, base)
        for key in ("m", "h"):
            assert np.allclose(back[key], z[f"d400_{key}"], atol=1e-6), (wdir, key)
        # цель в float16 → ошибка мала
        b16 = B.to_physical_v5(y.astype(np.float16), meta, base)
        e = np.abs(b16["h"][:2] - z["d400_h"][:2]).max()
        assert e < 0.15 * 10, e
        # R∘R = тождество, цель отражённого образца = R(цели)
        sg = B.REFLECT_OUT_SIGN_V5[:, None, None]
        yr = np.flip(y, -2) * sg
        assert np.allclose(np.flip(yr, -2) * sg, y)
        hr = np.ascontiguousarray(P.rot_scalar(z["d400_hc"], meta["k"]))
        ub = P.ubg(P.AGL, meta["alpha"], meta["mp"], meta["U10"])
        bm = B.linear_base(hr[::-1], -meta["r"], ub)
        # образец, отражённый в повёрнутой системе: поле решателя в повёрнутой системе (u,v,w)
        zr = {}
        for key, n in (("d400_m", 3), ("d400_h", 4)):
            f = z[key]
            u, v = P.rot_vec(f[0], f[1], meta["k"])
            w = P.rot_scalar(f[2], meta["k"])
            ch = [np.flip(u, -2), -np.flip(v, -2), np.flip(w, -2)] + ([np.flip(P.rot_scalar(f[3], meta["k"]), -2)] if n == 4 else [])
            zr[key] = np.stack(ch)           # уже в повёрнутой системе; k=0, r → −r
        mr = dict(meta, k=0, r=-meta["r"])
        zr["d400_hc"] = hr[::-1]
        yref = B.target_v5(zr, mr, bm)
        assert np.allclose(yref, yr, atol=1e-8), f"цель отражённого ≠ R(цели) (wdir {wdir})"
    # штиль: |V| < ε — ошибка не больше ε
    z, meta, base = _case(250.0)
    z["d400_h"] = z["d400_h"] * 0.0 + 0.02
    z["d400_m"] = z["d400_m"] * 0.0 + 0.02
    back = B.to_physical_v5(B.target_v5(z, meta, base), meta, base)
    assert np.abs(np.hypot(back["h"][0], back["h"][1]) - 0.0283).max() <= B.EPS + 1e-9
    print("  цель v5: обратимость, R∘R, отражённый образец, штиль — OK")


if __name__ == "__main__":
    test_agnesi_2d()
    test_gauss_3d()
    test_symmetries()
    test_target_roundtrip()
    print("test_base: OK")
