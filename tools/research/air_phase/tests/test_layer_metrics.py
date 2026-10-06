"""Тесты метрик слоёв (P6) и подгонки сигмоиды на синтетике: известная зона опускания за гребнем, известный подъём
у склона, известный источник термика; layer_diff(a, a) = 0; восстановление x_c, w сигмоиды."""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import layer_metrics as LM  # noqa: E402
import sigmoid as SG  # noqa: E402

N = 96
DX = 400.0
Z = LM.AGL_M[:, None, None]
X, Y = LM.grid_xy(N, N, DX)


def _case(**kw):
    c = dict(wdir_from_deg=270.0, z_i_agl_m=1500.0, n_bv=0.01, u10=4.0, u_sat=5.0, status=0, h_m=500.0, slope=0.15,
             shape="RIDGE")
    c.update(kw)
    return c


def _ridge(h=500.0, a=3000.0):
    return 1000.0 + h * np.exp(-(X / a) ** 2)


def _base_field(u0=5.0):
    """Логарифмический профиль u0 на 600 м, с запада, без вертикали и θ′."""
    f = np.zeros((4, 13, N, N), np.float32)
    prof = np.log(LM.AGL_M / LM.Z0) / np.log(600.0 / LM.Z0)
    f[0] = (u0 * np.minimum(prof, 1.0))[:, None, None]
    return f


def test_layer_diff_self_zero():
    hc = _ridge()
    f = _base_field()
    heat = np.full((N, N), 200.0, np.float32)
    m = LM.layer_metrics(f, hc, heat, None, _case())
    d = LM.layer_diff(m, m)
    assert set(d) == set(m)
    assert all(v == 0.0 for v in d.values())
    assert all(k in LM.NAMES for k in m)
    for g in LM.GROUPS:
        assert any(k.startswith(g) for k in m)


def test_lee_zone_known():
    """Зона за гребнем: x ∈ (1, 5) км, |y| < 4 км, до 150 м над землёй скорость 10 % внешней, опускание −0,6 м/с
    в слое 0…300 м. Площадь признака ≥ ½ на 25 м = площадь зоны, глубина — 150 м, w_min = −0,6."""
    hc = _ridge()
    f = _base_field(5.0)
    zone = (X > 1000) & (X < 5000) & (np.abs(Y) < 4000)
    low = (LM.AGL_M <= 150)[:, None, None] & zone[None]
    f[0] = np.where(low, 0.1 * f[0], f[0])
    f[2] = np.where((LM.AGL_M <= 300)[:, None, None] & zone[None], -0.6, 0.0)
    m = LM.layer_metrics(f, hc, np.zeros((N, N)), None, _case(slope=0.0))
    area = zone.sum() * DX * DX * 1e-6
    assert abs(m["lee_area25_km2"] - area) < 1e-6, (m["lee_area25_km2"], area)
    assert m["lee_depth_max_m"] == 150.0
    assert abs(m["lee_wmin_ms"] + 0.6) < 1e-6
    assert abs(m["lee_desc_max"] - 0.6 / 5.0) < 1e-6
    assert m["lee_rev_area25_km2"] == 0.0
    # протяжённость: дальняя клетка зоны x = 4600 м (центры 200 + 400k) от вершины (0) → 4600/500
    assert abs(m["lee_len_over_h"] - 4600.0 / 500.0) < 1e-6
    # обратное течение в части зоны
    f[0, 0] = np.where(zone & (X < 3000), -1.0, f[0, 0])
    m2 = LM.layer_metrics(f, hc, np.zeros((N, N)), None, _case(slope=0.0))
    assert abs(m2["lee_rev_area25_km2"] - (zone & (X < 3000)).sum() * 0.16) < 1e-6
    assert abs(m2["lee_urev_min_over_us"] + 1.0 / 5.0) < 1e-6
    # без опускания признака нет (игра: отличает след от торможения у наветренного подножия)
    f[2] = 0.0
    m3 = LM.layer_metrics(f, hc, np.zeros((N, N)), None, _case(slope=0.0))
    assert m3["lee_area25_km2"] == 0.0


def test_slope_lift_known():
    """Подъём w = 2 м/с в слое 50–300 м над наветренным склоном (−3 < x < 0 км, где e·∇h > 0,02), выше — 0:
    площадь = клетки склона, средняя сила 2, потолок между 300 и 400 м."""
    hc = _ridge(a=3000.0)
    gy, gx = np.gradient(hc, DX)
    windward = (gx > LM.SL_SLOPE_MIN)
    lift = windward & (X > -3000) & (X < 0)
    inner = np.zeros((N, N), bool)
    inner[LM.EDGE:-LM.EDGE, LM.EDGE:-LM.EDGE] = True
    f = _base_field()
    f[2] = np.where((LM.AGL_M <= 300)[:, None, None] & lift[None], 2.0, 0.0)
    m = LM.layer_metrics(f, hc, np.zeros((N, N)), None, _case())
    assert abs(m["sl_area_km2"] - (lift & inner).sum() * 0.16) < 1e-6
    assert abs(m["sl_w_mean_ms"] - 2.0) < 1e-5
    assert abs(m["sl_w_max_ms"] - 2.0) < 1e-5
    assert -3000 / 500 < m["sl_x_peak_over_h"] < 0
    assert 300.0 <= m["sl_ceil_agl_m"] < 400.0
    assert abs(m["sl_w_max_over_us"] - 2.0 / (5.0 * 0.15)) < 1e-5
    # подветренный склон с тем же w не считается
    f[2] = np.where((LM.AGL_M <= 300)[:, None, None] & (X > 0)[None] & (X < 3000)[None], 2.0, 0.0)
    m2 = LM.layer_metrics(f, hc, np.zeros((N, N)), None, _case())
    assert m2["sl_area_km2"] == 0.0


def test_thermal_source_known():
    """Ровная земля, нагрев только в круге 1,2 км вокруг (4 км, −2 км) и там же организованный подъём 0,5 м/с
    в слое перемешивания: источники — только в круге, первый (наибольший Φ) — у оси подъёма; сила 1,24·w*;
    потолок — около z_i (инверсия 3 К/км над z_i = 1500 м)."""
    hc = np.full((N, N), 1000.0)
    hc[N // 2, N // 2] = 1000.5                             # вершина — центр
    xs, ys = 4000.0, -2000.0
    r = np.hypot(X - xs, Y - ys)
    disk = r < 1200.0
    heat = np.where(disk, 250.0, 0.0)
    f = _base_field(3.0)
    wconv = np.where((Z <= 1500) & disk[None], 0.5 * np.exp(-(r / 800.0) ** 2)[None], 0.0)
    f[2] = wconv
    case = _case(u10=3.0 / 2.341, z_i_agl_m=1500.0, shape="HILL")
    m = LM.layer_metrics(f, hc, heat, None, case, w_mech=np.zeros((13, N, N)))
    assert m["th_wconv_src"] == 1.0
    assert m["th_n_src"] >= 1
    col = LM.thermal_columns(f, hc, heat, case, np.zeros((13, N, N)))
    sj, si, *_ = LM.select_sources(col, DX)
    assert np.all(disk[sj, si]), "источники только там, где греется"
    top = np.argmax(col["phi"][sj, si])
    assert math.hypot(X[sj[top], si[top]] - xs, Y[sj[top], si[top]] - ys) <= 300.0
    ws = LM.deardorff_wstar(250.0, 1000.0 + 1500.0, 1000.0)
    assert abs(float(ws) - (9.81 / 300 * 250 / 1206 * 1500) ** (1 / 3)) < 1e-9
    assert abs(m["th_w0_max_ms"] - LM.K_ALLEN * float(ws)) < 1e-6
    assert 1.0 <= m["th_ceil_over_zi"] < 1.3, m["th_ceil_over_zi"]
    assert abs(m["th_drift_along_ms"] - m["th_drift_mean_ms"]) < 1e-6 and m["th_drift_mean_ms"] > 0
    assert m["th_src_top_dist_m"] <= math.hypot(xs, ys) + 300.0
    assert abs(m["th_phi_x_over_h"] - xs / 500.0) < 1.0
    # без нагрева — источников нет
    m0 = LM.layer_metrics(f, hc, np.zeros((N, N)), None, case)
    assert m0["th_n_src"] == 0.0 and m0["th_wconv_src"] == 0.0 and math.isnan(m0["th_w0_mean_ms"])


def test_sigmoid_recovers_synthetic():
    rng = np.random.default_rng(1)
    x = np.repeat(np.logspace(-1, 0.7, 25), 2)
    for xc, w in ((0.8, 0.05), (0.5, 0.2), (1.2, 0.4)):
        y = 0.1 + 0.6 / (1 + np.exp(-(np.log10(x) - np.log10(xc)) / w)) + rng.normal(0, 0.01, x.size)
        r = SG.fit_sigmoid(x, y, n_boot=60)
        assert abs(math.log10(r["x_c"] / xc)) < 0.03, (xc, r["x_c"])
        assert abs(r["w_dec"] - w) < 0.25 * w + 0.01, (w, r["w_dec"])
        assert abs(r["dy"] - 0.6) < 0.05 and abs(r["y0"] - 0.1) < 0.05
        assert r["x_c_ci"][0] <= r["x_c"] <= r["x_c_ci"][1]
        assert r["sharp"] == (w < 0.1) and r["smooth"] == (w > 0.3)
    # скачок больше 3σ шума стартов — резкая и при широкой подгонке
    y = np.where(x > 1.0, 1.0, 0.0) + rng.normal(0, 0.01, x.size)
    assert SG.fit_sigmoid(x, y, n_boot=20, noise=0.05)["sharp"]
