"""Метрики S7 на синтетике: веса 60 м, край, срезы, терцили."""
import numpy as np

import s7_eval as E


def test_weights_and_zero_error():
    assert abs(E.W50 + E.W75 - 1) < 1e-12 and abs(E.W50 - 0.6) < 1e-12
    yt = np.random.default_rng(0).normal(size=(2, 91, 96, 96)).astype(np.float32)
    dv, dw = E.errors(yt, yt, np.array([5.0, 1.0]), "h")
    assert dv.shape == (2, 86, 86) and dv.max() == 0 and dw.max() == 0


def test_known_offset():
    yt = np.zeros((1, 91, 96, 96), np.float32)
    yp = yt.copy()
    # u∥ +0.1 на 50 и 75 м (с нагревом: канал 3), u⊥ +0.2 -> |Δ| = S·hypot(0.1, 0.2)
    for lv in (1, 2):
        yp[:, 3 * 13 + lv] = 0.1
        yp[:, 4 * 13 + lv] = 0.2
    dv, _ = E.errors(yp, yt, np.array([10.0]), "h")
    assert np.allclose(dv, 10 * np.hypot(0.1, 0.2), atol=1e-6)
    # только на 25 м — на 60 м не виден
    yp = yt.copy(); yp[:, 3 * 13] = 5
    assert E.errors(yp, yt, np.array([1.0]), "h")[0].max() == 0
    # линейность между 50 и 75: ошибка 1 только на 50 м -> 0,6
    yp = yt.copy(); yp[:, 3 * 13 + 1] = 1.0
    assert np.allclose(E.errors(yp, yt, np.array([1.0]), "h")[0], 0.6)


def test_terciles_and_slices():
    rng = np.random.default_rng(1)
    meta = dict(case=np.arange(300), mechanical=rng.random(300) < 0.4, froude=rng.lognormal(0, 1, 300), dtheta=rng.normal(5, 3, 300))
    thr = E.thresholds(meta)
    m = E.slice_masks(meta, thr)
    assert (m["mechanical"] ^ m["convective"]).all()
    assert abs(sum(m[f"froude_{k}"].sum() for k in ("low", "mid", "high")) - 300) == 0
    assert all(abs(m[f"froude_{k}"].sum() - 100) <= 3 for k in ("low", "mid", "high"))


def test_stats_relative_uses_u10_floor():
    dv = np.full((2, 4, 4), 1.0)
    s = E.stats(dv, dv, np.array([1, 1]), np.array([0.5, 4.0]))
    assert abs(s["rel_median_60m"] - np.median([1.0, 0.25])) < 1e-9
    assert s["median_60m"] == 1.0
