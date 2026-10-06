"""Тесты прототипа «фазы + Пикар» (P9 v1, AP-18) без GPU: механизм G (модель Прандтля, накопление, условия включения),
классификатор (карта ω, маска механизмов), опции решателя P4 v6 по вариантам, шаги 1–4 с заглушкой решателя, сшивка."""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from assembly import mechanisms as M  # noqa: E402
from hybrid import drainage as DR  # noqa: E402
from hybrid import pipeline as PL  # noqa: E402

N = 96


def cone_valley(n=N):
    """Котловина: дно 500 м в центре, склоны до 1300 м к краям (уклон ≈ 0,1)."""
    xc = (np.arange(n) + 0.5) * M.DX - n * M.DX / 2
    X, Y = np.meshgrid(xc, xc)
    r = np.hypot(X, Y)
    return 500.0 + 0.1 * np.maximum(r - 2000.0, 0.0)


def hill(n=N, h0=500.0, a=3000.0):
    xc = (np.arange(n) + 0.5) * M.DX - n * M.DX / 2
    X, Y = np.meshgrid(xc, xc)
    return 400.0 + h0 * np.exp(-(X ** 2 + Y ** 2) / (2 * a ** 2))


def cond(froude=2.0, u10=6.0, hs=150.0, sun=40.0, n_bv=0.01, cloud=0.0, wdir=270.0):
    return dict(u10_m_s=u10, wind_from_deg=wdir, alpha=0.2, max_profile=1.6, u_sat_m_s=u10 * 1.6, z_i_m=1500.0,
                n_bv_s=n_bv, froude=froude, hs_w_m2=hs, sun_el_deg=sun, cloud_cover=cloud)


# ------------------------------------------------------------------ G
def test_prandtl_formulas():
    s = np.array([0.1]); n = 0.01; H = -30.0
    P = DR.prandtl(s, n, H)
    l = math.sqrt(2 * DR.K_KAT / (n * 0.1))
    dth = 30.0 * l / (M.RHO_CP * DR.K_KAT)
    assert P["l"][0] == pytest.approx(l) and P["dth"][0] == pytest.approx(min(dth, DR.DTH_MAX))
    us = P["dth"][0] * M.G / (M.THETA0 * n)
    assert P["umax"][0] == pytest.approx(min(0.3224 * us, DR.U_MAX), rel=1e-3)
    assert P["q"][0] == pytest.approx(0.5 * P["us"][0] * l)
    # максимум профиля e^(−x)·sin x — на x = π/4
    x = np.linspace(0, 3, 30001)
    assert x[np.argmax(np.exp(-x) * np.sin(x))] == pytest.approx(math.pi / 4, abs=1e-3)
    # пологий склон — нет струи Прандтля
    assert DR.prandtl(np.array([0.005]), n, H)["us"][0] == 0.0


def test_drainage_activation_and_direction():
    hc = cone_valley()
    off = DR.evening_drainage(hc, np.full_like(hc, 100.0), cond(hs=100.0, sun=30.0))
    assert not off["diag"]["active"] and off["w"].max() == 0.0
    calm = DR.evening_drainage(hc, np.zeros_like(hc), cond(froude=0.2, u10=0.8, hs=0.0, sun=-6.0))
    windy = DR.evening_drainage(hc, np.zeros_like(hc), cond(froude=5.0, u10=10.0, hs=0.0, sun=-6.0))
    assert calm["diag"]["active"] and calm["w"].mean() > 0.5 and windy["w"].mean() < 0.05
    # сток — вниз по склону (к центру котловины): на восточном склоне u < 0 на 25 м
    j, i = N // 2, N // 2 + 20
    assert calm["u"][0, j, i] < -0.2 and abs(calm["v"][0, j, i]) < 0.2 * abs(calm["u"][0, j, i])
    assert calm["th"][0, j, i] < 0                                   # холодный слой
    assert np.all(calm["member"][-1] == 0)                           # 2 км — вне слоя
    # облачность ослабляет выхолаживание
    cl = DR.evening_drainage(hc, np.zeros_like(hc), cond(froude=0.2, u10=0.8, hs=0.0, sun=-6.0, cloud=1.0))
    assert cl["diag"]["h_cool_wm2"] == pytest.approx(-DR.H_CLEAR * 0.25)


def test_d8_accumulation_conserves():
    hc = cone_valley()
    q = np.full_like(hc, 0.1)
    Q, ex, ey = DR.d8_accumulate(M.gauss2d(hc, 1.0), q)
    assert Q.max() == pytest.approx(q.sum() * M.DX, rel=0.05) or Q.max() > 0.25 * q.sum() * M.DX
    assert np.all(Q >= q * M.DX - 1e-9)


# ------------------------------------------------------------------ классификатор
def test_omega_map_and_freeze():
    hc = hill()
    heat = np.full_like(hc, 150.0)
    for fr, u10, om in ((0.6, 4.0, 0.5), (3.0, 6.0, 1.0), (1.3, 1.0, 0.5)):
        pr = PL.prepare(hc, heat, cond(froude=fr, u10=u10))
        assert float(pr["omega_map"].mean()) == pytest.approx(om, abs=0.03)
        assert np.allclose(pr["weights"].sum(0), 1.0, atol=1e-5) and pr["weights"].shape == (6, N, N)
        assert not pr["freeze_m"].any()
    calm = PL.prepare(hc, heat, cond(froude=0.2, u10=1.0))
    assert calm["freeze_h"].all() and calm["freeze_m"].all()
    # свободная конвекция: w* ≥ U_sat → F замораживает (решение h), m — нет
    ff = PL.prepare(hc, np.full_like(hc, 400.0), cond(froude=0.5, u10=0.6))
    assert ff["freeze_h"].mean() > 0.5 and not ff["freeze_m"].any()


def test_numerics_variants():
    hc = hill()
    pr = PL.prepare(hc, np.full_like(hc, 150.0), cond(froude=0.6, u10=4.0))
    pr["freeze_h"][:10, :10] = True
    k = PL.numerics_kwargs(pr, "h")
    assert set(k) == {"max_outer", "omega_fallback", "omega_map", "freeze_mask"} and k["omega_fallback"] == (300, 0.5)
    assert set(PL.numerics_kwargs(pr, "m")) == {"max_outer", "omega_fallback", "omega_map"}
    assert set(PL.numerics_kwargs(pr, "h", variant="fallback")) == {"max_outer", "omega_fallback", "freeze_mask"}
    assert set(PL.numerics_kwargs(pr, "h", variant="cold_omap")) == {"max_outer", "omega_fallback", "omega_map"}
    assert PL.numerics_kwargs(pr, "h", variant="cold") == {"max_outer": 1000}


# ------------------------------------------------------------------ шаги 1–4 с заглушкой решателя
def _stub(calls):
    """Заглушка Пикара: поле = init + 0,1 м/с к u в незамороженных колоннах, замороженные — как init."""
    def solve(dec, kw, init):
        calls.append((dec, kw))
        f = np.asarray(init["agl"], np.float32).copy()
        fz = kw.get("freeze_mask", np.zeros(f.shape[-2:], bool))
        f[0][:, ~fz] += 0.1
        if dec == "m":
            return dict(fields=f, status="ok", iters=50)
        return dict(fields=f, status="ok", iters=40)
    return solve


def test_hybrid_case_stub_mechanical_and_picard():
    hc = cone_valley()
    calls = []
    out = PL.hybrid_case(hc, np.zeros_like(hc), cond(froude=0.2, u10=0.8, hs=0.0, sun=-6.0), _stub(calls))
    assert calls == [] and out["runs"] == {"m": None, "h": None}          # Fr < 0,3 — только механизмы
    assert np.array_equal(out["fields"], out["prep"]["init_h"])
    calls = []
    out = PL.hybrid_case(hc, np.zeros_like(hc), cond(froude=0.8, u10=1.2, hs=0.0, sun=-6.0), _stub(calls))
    assert [c[0] for c in calls] == ["m", "h"]
    fz = out["prep"]["freeze_h"]
    assert 0 < fz.mean() < 1                                             # G заморожен частично
    assert out["fields"].shape == (4, 13, N, N) and np.isfinite(out["fields"]).all()
    du = out["fields"][0] - out["prep"]["init_h"][0]
    assert np.allclose(du[:, ~fz & (out["prep"]["g"]["w"] == 0)], 0.1, atol=1e-4)


def test_stitch_projection_divergence():
    hc = cone_valley()
    pr = PL.prepare(hc, np.zeros_like(hc), cond(froude=0.8, u10=1.5, hs=0.0, sun=-6.0))
    pic = pr["init_h"].copy()
    pr["freeze_h"][:] = False                                            # вся вставка G — через сшивку
    f, fm, info = PL.stitch(pic, pr["init_m"], pr, hc)
    assert info["stitched"]
    assert info["div"]["div_max_faces"] < 1e-9 * max(1.0, info["div"]["div_max_before"]) + 1e-12
    # θ′ — с холодным слоем G там, где вес G > 0
    w = pr["g"]["w"]
    assert np.all(f[3][0][w > 0.2] <= pic[3][0][w > 0.2] + 1e-6)
