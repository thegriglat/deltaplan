"""Тесты SY-10: набор условий hgw24 (S2 v4) и подмена погоды в решателе (без GPU: условия решателя строит real.case, как solve_case)."""
import sys
from pathlib import Path

import numpy as np
import pytest

SOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOL))
import s5_io as S5   # noqa: E402
import make_hgw24 as H   # noqa: E402
import model_place as M   # noqa: E402

W = S5._air3d_weather()
import real as R   # noqa: E402


def ridge(n=384, amp=500.0, base=800.0):
    x = (np.arange(n) - n / 2) * 100.0
    return base + amp * np.exp(-((x[None, :] / 4000.0) ** 2)) * (0.6 + 0.4 * np.sin(x[:, None] / 6000.0))


def test_orientation_parser():
    assert H.orientation_centers("S") == [180.0]
    assert H.orientation_centers("NO")[0] == 45.0                      # немецкое O — восток
    c = H.orientation_centers("N;W;NW;E;SE;S,SE;SW;NE;S")
    assert len(c) == 10 and c[0] == 0.0 and c[1] == 270.0
    assert H.orientation_centers("SSE-S;SW-W") == [168.75, 247.5]
    assert H.orientation_centers("W-O") == [0.0]                       # от запада по часовой до востока: центр — север
    assert H.orientation_centers("") == [] and H.orientation_centers(None) == [] and H.orientation_centers("abc") == []
    assert H.orientation_centers("225") == [225.0]


def test_neutral_override_is_bitwise_baseline():
    """Нулевые возмущения (северное полушарие, cover 0) = исходный конфиг: Day и условия случая побитно те же; override(None) ничего не меняет."""
    ctx = dict(month=7, day=15, lat=50.0, lon=86.0, utc_offset_h=6.0, valley_msl_m=800.0, mean_msl_m=1000.0)
    base = W.CFG
    neutral = S5.weather_cfg(base, 50.0, 0.0, base["upper_air"]["lapse_k_per_km"], 1.0, 1.0, 0.0)
    for hour in (8.0, 13.0, 18.5):
        D0 = W.Day(hour, 24.0, "clear", ctx)
        with S5.weather_override(neutral):
            D1 = W.Day(hour, 24.0, S5.HG_SKY, ctx)
            z = np.linspace(800, 5000, 50)
            g1, th1 = D1.gamma(z), D1.theta(z)
        assert D0.z_i == D1.z_i and D0.z_lcl == D1.z_lcl and D0.heat == D1.heat and D0.cover == D1.cover and D0.sky_heat == D1.sky_heat
        assert np.array_equal(D0.gamma(z), g1) and np.array_equal(D0.theta(z), th1)
    assert W.CFG is base
    with S5.weather_override(None):
        assert W.CFG is base


def test_perturbation_reaches_solver_inputs():
    """θ̄(z) (cond.gam), z_i и поток тепла H — входы решателя из real.case — меняются так, как задано; конфиг после with возвращается."""
    M.register("t_hg", ridge(), 0.0)
    ctx = M.context("t_hg")
    ctx.update(month=6, day=15, lat=45.0, lon=10.0, utc_offset_h=1.0)
    ctx = M.context("t_hg")
    ctx.update(month=6, day=15, lat=45.0, lon=10.0, utc_offset_h=1.0)
    G, hc = R.grid_domain("t_hg", 400)
    base = W.CFG
    c0 = R.case("t_hg", G, hc, 13.0, 6.0, 270.0, 25.0, "clear", True)
    z = np.linspace(float(hc.max()), float(hc.max()) + 4000.0, 40)
    lapse0 = base["upper_air"]["lapse_k_per_km"]
    for kw in (dict(dt_upper=3.0), dict(lapse=8.0), dict(cover=0.6), dict(inv_depth_f=1.5, inv_range_f=1.3)):
        p = dict(dt_upper=0.0, lapse=lapse0, inv_depth_f=1.0, inv_range_f=1.0, cover=0.0)
        p.update(kw)
        cfg = S5.weather_cfg(base, 45.0, p["dt_upper"], p["lapse"], p["inv_depth_f"], p["inv_range_f"], p["cover"])
        with S5.weather_override(cfg):
            c1 = R.case("t_hg", G, hc, 13.0, 6.0, 270.0, 25.0, S5.HG_SKY, True)
        assert W.CFG is base
        if "dt_upper" in kw:      # теплее наверху на 3 К: θ_fa выше на 3 К, свободная атмосфера устойчивее — слой перемешивания ниже
            assert abs(float(c1.day.theta_fa(4.0) - c0.day.theta_fa(4.0)) - (3.0 - 0.5 * (45.0 - 50.0))) < 1e-9
            assert c1.z_i < c0.z_i
        if "lapse" in kw:         # gam 8 К/км вместо 4: dθ/dz = Γd − γ = 1,8 К/км вместо 5,8 над слоем
            assert abs(float(c1.gam(np.array([9000.0]))[0]) * 1000 - (9.8 - 8.0)) < 1e-6 and abs(float(c0.gam(np.array([9000.0]))[0]) * 1000 - (9.8 - lapse0)) < 1e-6
        if "cover" in kw:         # cover 0,6: sky_heat = 0,55 — поток тепла меньше (H = H0·sky_heat·солнце − H_lw·(1 − 0,7·cover))
            assert abs(c1.day.sky_heat - 0.55) < 1e-12 and c1.day.cover == 0.6
            assert float(np.mean(c1.H)) < float(np.mean(c0.H)) and not np.array_equal(c1.H, c0.H)
        if "inv_depth_f" in kw:   # утренняя инверсия (час 8): глубже и с большей амплитудой — другой профиль
            with S5.weather_override(cfg):
                d8 = W.Day(8.0, 25.0, S5.HG_SKY, ctx)
            d8b = W.Day(8.0, 25.0, "clear", ctx)
            assert d8.st["cap_agl_m"] != d8b.st["cap_agl_m"] or d8.z_i != d8b.z_i
        if "lapse" in kw or "dt_upper" in kw:
            assert not np.array_equal(c1.gam(z), c0.gam(z)) or "dt_upper" in kw     # dt_upper: профиль θ сдвинут, градиент выше z_i тот же


def test_upper_air_latitude_shift():
    base = W.CFG
    for lat in (50.0, 40.0, -30.0, 60.0):
        c = S5.weather_cfg(base, lat, 2.0, 4.0, 1.0, 1.0, 0.0)
        r = base["upper_air"]["temp_c"] if lat > 0 else base["upper_air"]["temp_c"][6:] + base["upper_air"]["temp_c"][:6]
        assert abs(c["upper_air"]["temp_c"][3] - (r[3] + 2.0 - 0.5 * (abs(lat) - 50.0))) < 1e-12


def test_south_shift_tables():
    base = W.CFG
    cfg = S5.weather_cfg(base, -30.0, 0.0, 4.0, 1.0, 1.0, 0.0)
    assert abs(cfg["upper_air"]["temp_c"][0] - base["upper_air"]["temp_c"][6] - 10.0) < 1e-12 and cfg["typical_max_c"][3] == base["typical_max_c"][9]
    assert S5.weather_cfg(base, 30.0, 0.0, 4.0, 1.0, 1.0, 0.0)["typical_max_c"] == base["typical_max_c"]


def _rows(rid=3, lat=46.0, ori="S;SW"):
    g = ridge()
    summ = dict(relief_m=float(g.max() - g.min()), h_min_m=float(g.min()), h_max_m=float(g.max()))
    return H.rows_for(H.SEED, rid, "hg_x", lat, 10.0, g, summ, ori)


def test_hgw24_rows():
    r = _rows()
    assert len(r) == 24 and list(r["cond_id"]) == list(range(24))
    assert all(np.isfinite(r[n]).all() for n in r.dtype.names if r.dtype[n].kind == "f" and n not in ("n_bv_override_s", "z_i_override_agl_m"))
    assert sorted(set(r["month"])) == [4, 5, 6, 7, 8, 9] and all((r["month"] == m).sum() == 4 for m in range(4, 10))
    h = r["hour_local"]
    assert ((h >= 7) & (h <= 10) | (h >= 11) & (h <= 16) | (h >= 17) & (h <= 20)).all()
    assert (r["u10_m_s"] >= 0.5).all() and (r["u10_m_s"] <= 12).all()
    assert (np.abs(r["dt_upper_k"]) <= 7).all() and (r["lapse_k_per_km"] >= 3).all() and (r["lapse_k_per_km"] <= 9).all()
    assert (r["cloud_cover"] >= 0).all() and (r["cloud_cover"] <= 0.8).all() and (r["t_max_c"] >= 0).all() and (r["t_max_c"] <= 40).all()
    r2 = _rows()
    assert all(np.array_equal(r[n], r2[n], equal_nan=r.dtype[n].kind == 'f') for n in r.dtype.names)    # детерминированно
    assert not np.array_equal(r["dt_upper_k"], _rows(rid=4)["dt_upper_k"])
    s = _rows(lat=-30.0)
    assert sorted(set(s["month"])) == [10, 11, 12, 1, 2, 3] or sorted(set(s["month"])) == [1, 2, 3, 10, 11, 12]


def test_hgw24_wind_toward_orientation():
    from collections import Counter
    near = 0
    n = 0
    for rid in range(20):
        r = _rows(rid=rid, ori="S")
        d = np.abs(((r["wind_from_deg"] - 180.0 + 180.0) % 360.0) - 180.0)
        near += int((d <= 45.5).sum()); n += 24
    assert 0.6 <= near / n <= 0.8     # 60 % из сектора + доля равномерных, попавших в него (0,4·0,25 = 10 %)
    r = _rows(ori=None)
    assert Counter(r["cond_id"]).most_common(1)[0][1] == 1
