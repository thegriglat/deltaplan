#!/usr/bin/env python3
"""Контрактный тест П2 v5 и Б1 (docs/contracts/air-nn-p3.md): форма на стыке — имена и порядок карт и каналов,
знаки отражения, формы и типы, первые 9 карт v5 = карты v4, обратное преобразование выхода v5 возвращает поле.
Падает, если формат поменяли без правки контракта. Модуль, которого ещё нет (base — NN-P9, maps5 — NN-P11), —
его проверки пропускаются с сообщением (до вливания задачи).

  .venv/bin/python tests/test_contract_p2v5.py
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import prep as P  # noqa: E402

N, DX, NA = 96, 400.0, len(P.AGL)
MAP_NAMES_V5 = P.MAP_NAMES + (
    "slope_along_1k2", "slope_cross_1k2", "slope_along_3k2", "slope_cross_3k2", "slope_along_8k", "slope_cross_8k",
    "sub_slope_std", "sub_slope_p95", "sub_steep_lee", "sub_steep_wind", "sub_relief",
    "sep_400", "sep_1k2", "sep_3k2", "sep_wake", "base_a25", "base_a150", "base_a600")
NEG_MAPS = {"y", "slope_cross", "slope_cross_1k2", "slope_cross_3k2", "slope_cross_8k"}
OUT_NAMES_V5 = ("a_m", "sd_m", "cd_m", "wrel_m", "a_h", "sd_h", "cd_h", "wrel_h", "theta")
NEG_OUT = {"sd_m", "sd_h"}


def opt(name):
    try:
        return importlib.import_module(f"pilotnn.{name}")
    except ModuleNotFoundError as e:
        if e.name != f"pilotnn.{name}":
            raise
        print(f"  пропуск: pilotnn/{name}.py ещё нет")
        return None


def case(seed=3):
    x = (np.arange(N) + 0.5) * DX - N * DX / 2
    X, Y = np.meshgrid(x, x)
    hc = 900 + 600 * np.exp(-((X - 2000) ** 2 + (Y + 4000) ** 2) / (2 * 2500 ** 2)) + 0.02 * X
    rng = np.random.default_rng(seed)
    m = rng.normal(size=(3, NA, N, N)) + np.array([5.0, 1.0, 0.0])[:, None, None, None]
    h = rng.normal(size=(4, NA, N, N)) + np.array([5.0, 1.0, 0.0, 0.0])[:, None, None, None]
    z = dict(d400_hc=hc, d400_H=200 + 0 * hc, d400_m=m, d400_h=h)
    row = dict(id="t", loc="t", U10=5.0, wdir=250.0, t_max=26.0, hour=14,
               profile=dict(alpha=0.2, max_profile=1.5, stab="D", sun_el=40.0, sun_az=200.0), day={}, d400={"dx": DX})
    return z, row, P.case_meta(row, hc)


def test_base(B):
    z, row, meta = case()
    hr = np.ascontiguousarray(P.rot_scalar(z["d400_hc"], meta["k"]))
    ub = P.ubg(P.AGL, meta["alpha"], meta["mp"], meta["U10"])
    b = B.linear_base(hr, meta["r"], ub)
    for key in ("u", "v", "w", "gx", "gy"):
        assert b[key].shape == (NA, N, N), (key, b[key].shape)
    flat = B.linear_base(np.full((N, N), 1000.0), meta["r"], ub)
    c, s = np.cos(meta["r"]), np.sin(meta["r"])
    assert np.allclose(flat["u"], ub[:, None, None] * c, atol=1e-6) and np.allclose(flat["v"], ub[:, None, None] * s, atol=1e-6)
    assert np.allclose(flat["w"], 0, atol=1e-6), "плоский рельеф: w_base ≠ 0"
    # выход v5
    assert tuple(B.OUT_NAMES_V5) == OUT_NAMES_V5, B.OUT_NAMES_V5
    sg = np.asarray(B.REFLECT_OUT_SIGN_V5)
    assert sg.shape == (len(OUT_NAMES_V5) * NA,)
    neg = {OUT_NAMES_V5[i // NA] for i, v in enumerate(sg) if v < 0}
    assert neg == NEG_OUT, neg
    y = B.target_v5(z, meta, b)
    assert y.shape == (len(OUT_NAMES_V5) * NA, N, N), y.shape
    back = B.to_physical_v5(y, meta, b)
    for key, n in (("m", 3), ("h", 4)):
        assert back[key].shape == (n, NA, N, N), (key, back[key].shape)
        assert np.allclose(back[key], z[f"d400_{key}"], atol=1e-6), f"to_physical_v5(target_v5) ≠ поле ({key})"
    print("  Б1 и выход v5: OK")


def test_maps(M):
    assert tuple(M.MAP_NAMES_V5) == MAP_NAMES_V5, M.MAP_NAMES_V5
    neg = {n for n, s in zip(M.MAP_NAMES_V5, M.REFLECT_MAP_SIGN_V5) if s < 0}
    assert neg == NEG_MAPS, neg
    z, row, meta = case()
    X = M.maps_v5(z, meta, row)
    assert X.shape == (27, N, N) and X.dtype == np.float32, (X.shape, X.dtype)
    assert np.isfinite(X).all()
    assert np.array_equal(X[:9], P.maps(z, meta, row)), "первые 9 карт v5 ≠ карты v4"
    assert np.array_equal(X, M.maps_v5(z, meta, row)), "нет побитного повтора"
    print("  вход v5: OK")


if __name__ == "__main__":
    B, M = opt("base"), opt("maps5")
    if B is not None:
        test_base(B)
    if M is not None:
        test_maps(M)
    print("П2 v5: OK" if B is not None and M is not None else "П2 v5: частично (см. пропуски)")
