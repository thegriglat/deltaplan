#!/usr/bin/env python3
"""Отражение поперёк ветра (контракт П2 v4, `prep.reflect`): R∘R = тождество (карты, числа, цель); знаки по таблице
контракта; согласованность — карты/числа/цель из отражённого образца (рельеф, поток тепла, поля развёрнуты по j,
v → −v, остаток угла r → −r, азимут солнца — зеркально) = R(карты/числа/цель исходного). Проверка — в повёрнутой
системе (k = 0: отражение y′ → −y′ = развороту по j), на аналитической горе и, если есть, на случаях набора smoke.
Плюс: в обучении отражение детерминировано от (зерно, эпоха, индекс) и включено в config.yaml.

  .venv/bin/python tests/test_reflect.py
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn import prep as P  # noqa: E402

N, DX = 96, 400.0


def test_rr_identity_and_signs():
    rng = np.random.default_rng(0)
    X = rng.normal(size=(3, len(P.MAP_NAMES), N, N)).astype(np.float32)
    F = rng.normal(size=(3, len(P.FILM_NAMES))).astype(np.float32)
    Y = rng.normal(size=(3, 91, N, N)).astype(np.float16)
    Xr, Fr, Yr = P.reflect(X, F, Y)
    X2, F2, Y2 = P.reflect(Xr, Fr, Yr)
    assert np.array_equal(X2, X) and np.array_equal(F2, F) and np.array_equal(Y2, Y), "R∘R ≠ тождество"
    neg_maps = {n for n, s in zip(P.MAP_NAMES, P.REFLECT_MAP_SIGN) if s < 0}
    assert neg_maps == {"y", "slope_cross"}, neg_maps
    neg_film = {n for n, s in zip(P.FILM_NAMES, P.REFLECT_FILM_SIGN) if s < 0}
    assert neg_film == {"sin_r", "sun_y"}, neg_film
    nA = len(P.AGL)
    neg_ch = sorted({i // nA for i, s in enumerate(P.REFLECT_OUT_SIGN) if s < 0})
    assert neg_ch == [1, 4], neg_ch                      # u⊥ без нагрева и с нагревом
    assert np.array_equal(Xr[:, 0], X[:, 0, ::-1, :])    # terrain — только разворот по j


def hill_case(seed=1):
    """Несимметричная по j аналитическая местность + поля, чтобы отражение было заметно."""
    x = (np.arange(N) + 0.5) * DX - N * DX / 2
    Xg, Yg = np.meshgrid(x, x)
    hc = 1500 + 700 * np.exp(-((Xg - 3000) ** 2 + (Yg - 5000) ** 2) / (2 * 3000 ** 2)) \
        + 300 * np.exp(-((Xg + 6000) ** 2 + (Yg + 2000) ** 2) / (2 * 1500 ** 2)) + 0.01 * Yg
    rng = np.random.default_rng(seed)
    H = 200 + 50 * np.cos(Xg / 5000) + 30 * np.sin(Yg / 3000)
    m = rng.normal(size=(3, 13, N, N))
    h = rng.normal(size=(4, 13, N, N))
    return dict(d400_hc=hc, d400_H=H, d400_m=m, d400_h=h)


def reflected_fields(z):
    """Отражённый образец в повёрнутой системе (k = 0): разворот по j, v → −v."""
    out = dict(d400_hc=z["d400_hc"][::-1].copy(), d400_H=z["d400_H"][::-1].copy())
    for key in ("d400_m", "d400_h"):
        f = np.array(z[key], np.float64)[..., ::-1, :].copy()
        f[1] = -f[1]
        out[key] = f
    return out


def check_consistency(z, row, r, label):
    meta = dict(id=row["id"], loc=row["loc"], k=0, r=r, U10=float(row["U10"]), alpha=float(row["profile"]["alpha"]),
                mp=float(row["profile"]["max_profile"]), S=max(float(row["U10"]), 1.0),
                hc_mean=float(np.mean(z["d400_hc"])))
    meta_r = dict(meta, r=-r)
    zr = reflected_fields(z)
    row_r = dict(row, profile=dict(row["profile"], sun_az=(180.0 - float(row["profile"].get("sun_az", 180.0))) % 360))
    X, Xr = P.maps(z, meta, row), P.maps(zr, meta_r, row_r)
    dX = np.abs(P.reflect(X=X) - Xr).max(axis=(-2, -1))
    assert (dX <= 1e-5).all(), (label, dict(zip(P.MAP_NAMES, dX.round(7))))
    F, Fr = P.film(row, meta), P.film(row_r, meta_r)
    assert np.allclose(P.reflect(F=F), Fr, atol=1e-6), (label, P.reflect(F=F) - Fr)
    Y, Yr = P.target(z, meta), P.target(zr, meta_r)
    assert np.allclose(P.reflect(Y=Y), Yr, atol=1e-9), (label, np.abs(P.reflect(Y=Y) - Yr).max())
    # обратное преобразование сходится: to_physical(R(Y), −r) = отражённые поля
    back = P.to_physical(P.reflect(Y=Y), meta_r)
    assert np.allclose(back["m"], zr["d400_m"], atol=1e-9) and np.allclose(back["h"], zr["d400_h"], atol=1e-9), label
    return float(dX.max())


def test_consistency_hill():
    z = hill_case()
    row = dict(id="hill_000", loc="hill", U10=5.0, hour=13.0, t_max=26.0, wdir=270.0,
               profile=dict(alpha=0.2, max_profile=1.8, stab="C", sun_el=55.0, sun_az=200.0),
               day=dict(z_i_msl=2500.0, z_lcl_msl=3200.0, heat=0.7, t=24.0))
    for r in (0.0, 0.3, -0.6, math.radians(44.0)):
        check_consistency(z, row, r, f"гора, r = {math.degrees(r):.1f}°")


def test_consistency_smoke():
    try:
        from pilotnn.data import Dataset
        import subprocess
        p = subprocess.run([sys.executable, str(HERE / "dataset.py"), "path", "--dataset", "smoke"], cwd=HERE,
                           capture_output=True, text=True, timeout=60).stdout.strip().splitlines()[-1]
        ds = Dataset(p)
    except Exception as e:  # noqa: BLE001
        print(f"  (набор smoke недоступен — пропуск: {e})")
        return 0
    rows = ds.case_rows()[:6]
    for row in rows:
        z = {k: v.astype(np.float64) for k, v in ds.load(row["id"]).items()}
        k, r = P.rotation_of(float(row["wdir"]))
        zr = dict(z, d400_hc=P.rot_scalar(z["d400_hc"], k), d400_H=P.rot_scalar(z["d400_H"], k))
        for key in ("d400_m", "d400_h"):          # в повёрнутую систему, дальше — k = 0
            f = z[key].copy()
            u, v = P.rot_vec(f[0], f[1], k)
            f = np.concatenate([np.stack([u, v]), P.rot_scalar(f[2:], k)])
            zr[key] = f
        check_consistency(zr, row, r, row["id"])
    return len(rows)


def test_consistency_v5():
    """П2 v5: цель v5 (с γ_a) и карты v5 отражённого образца = R(исходных) по знакам контракта (REFLECT_OUT_SIGN_V5,
    REFLECT_MAP_SIGN_V5); вес скорости V и K prep5 — только разворот по j (V) и без знака (K = V·∇h_s — скаляр)."""
    from pilotnn import base as B
    from pilotnn import maps5 as M5
    from pilotnn import prep5 as P5
    z = hill_case()
    for key in ("d400_m", "d400_h"):
        z[key] = np.array(z[key]) + np.array([4.0, 1.0] + [0.0] * (len(z[key]) - 2))[:, None, None, None]
    row = dict(id="hill_000", loc="hill", U10=5.0, hour=13.0, t_max=26.0, wdir=270.0,
               profile=dict(alpha=0.2, max_profile=1.8, stab="C", sun_el=55.0, sun_az=200.0),
               day=dict(z_i_msl=2500.0, z_lcl_msl=3200.0, heat=0.7, t=24.0))
    gam = dict(m=np.linspace(0.2, 0.9, 13).tolist(), h=np.linspace(0.3, 1.0, 13).tolist())
    so = B.REFLECT_OUT_SIGN_V5[:, None, None]
    for r in (0.0, 0.3, -0.6):
        meta = dict(id="hill_000", loc="hill", k=0, r=r, U10=5.0, alpha=0.2, mp=1.8, S=5.0, hc_mean=float(np.mean(z["d400_hc"])))
        meta_r = dict(meta, r=-r)
        zr = reflected_fields(z)
        b, br = P5.base_for(z["d400_hc"], meta), P5.base_for(zr["d400_hc"], meta_r)
        Y, Yr = B.target_v5(z, meta, b, gamma=gam), B.target_v5(zr, meta_r, br, gamma=gam)
        err = float(np.abs(np.flip(Y, axis=-2) * so - Yr).max())
        assert err < 1e-6, (r, err)
        Y2 = np.flip(np.flip(Y, axis=-2) * so, axis=-2) * so
        assert np.array_equal(Y2, Y), "R∘R ≠ тождество (v5)"
        row_r = dict(row, profile=dict(row["profile"], sun_az=(180.0 - 200.0) % 360))
        X, Xr = M5.maps_v5(z, meta, row), M5.maps_v5(zr, meta_r, row_r)
        dX = float(np.abs(np.flip(X, axis=-2) * M5.REFLECT_MAP_SIGN_V5[:, None, None] - Xr).max())
        assert dX < 1e-4, (r, dX)


def test_training_flag():
    cfg = C.load_config(HERE / "config.yaml")
    assert cfg["train"].get("reflect") is True, "train.reflect не включён"
    src = (HERE / "pilotnn" / "train.py").read_text()
    assert "default_rng([seed, epoch, 4])" in src, "отражение в обучении — не от (зерно, эпоха)"
    a = np.random.default_rng([1, 3, 4]).random(1000) < 0.5
    b = np.random.default_rng([1, 3, 4]).random(1000) < 0.5
    assert np.array_equal(a, b) and 0.4 < a.mean() < 0.6


if __name__ == "__main__":
    test_rr_identity_and_signs()
    print("ok R∘R = тождество; знаки по таблице П2 v4")
    test_consistency_hill()
    print("ok гора: карты/числа/цель отражённого образца = R(исходного), обратное преобразование")
    n = test_consistency_smoke()
    print(f"ok случаи smoke: {n}")
    test_consistency_v5()
    print("ok v5: цель (с γ_a) и карты отражённого образца = R(исходных)")
    test_training_flag()
    print("ok обучение: train.reflect, детерминированно от (зерно, эпоха, индекс)")
