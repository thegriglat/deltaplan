"""Тесты прототипа сборки по фазам (P8 v1, AP-17): синтетика — A на малом гауссе против линейной теории (БПФ на
большой периодической области), граничное условие w = U·∇h, проекция ∇·u = 0, веса Σ = 1, детерминизм."""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from assembly import assemble as AS  # noqa: E402
from assembly import mechanisms as M  # noqa: E402

N = 96
DX = M.DX


def gauss_hill(h0=30.0, a=2000.0, n=N, cx=0.0, cy=0.0):
    xc = (np.arange(n) + 0.5) * DX - n * DX / 2
    X, Y = np.meshgrid(xc, xc)
    return 500.0 + h0 * np.exp(-((X - cx) ** 2 + (Y - cy) ** 2) / (2 * a ** 2))


def fft_reference(h, U, e, n_bv, z, pad=4):
    """Линейная теория на периодической области в pad раз больше (БПФ): û, ŵ на высоте z, постоянный U."""
    n = h.shape[0]
    big = np.full((pad * n, pad * n), h.mean())
    o = (pad * n - n) // 2
    big[o:o + n, o:o + n] = h
    hh = np.fft.fft2(big - big.mean())
    k = 2 * np.pi * np.fft.fftfreq(pad * n, DX)
    KX, KY = np.meshgrid(k, k)
    K2 = KX ** 2 + KY ** 2
    K2[0, 0] = 1.0
    sig = U * (e[0] * KX + e[1] * KY) - 1j * U / 20000.0
    m2 = (n_bv ** 2 / sig ** 2 - 1) * K2
    m = np.sqrt(m2 + 0j)
    m = np.abs(m.real) * np.sign(sig.real + 1e-30) + 1j * np.abs(m.imag)
    w = 1j * sig.real * np.exp(1j * m * z) * hh
    u = -KX * m * w / K2
    for a in (w, u):
        a[0, 0] = 0
    return np.fft.ifft2(u).real[o:o + n, o:o + n], np.fft.ifft2(w).real[o:o + n, o:o + n]


@pytest.mark.parametrize("n_bv", [0.0, 0.01])
def test_linear_a_small_gauss(n_bv):
    """A (DCT) на малом гауссе (h = 30 м, a = 2 км, h/a = 0,015) против БПФ на большой области: w и u на 100 м."""
    h = gauss_hill()
    e = np.array([1.0, 0.0])
    U = 8.0
    du, dv, dw = M.linear_a(h, e, lambda z: np.full(np.shape(z), U), n_bv, cap_frac=None)
    k = list(M.AGL_M).index(100)
    # внутренний слой при постоянном U не меняет ответ; эталон — внешнее решение на max(z, ℓ) — у мод гаусса ℓ < 100 м
    ur, wr = fft_reference(h, U, e, n_bv, 100.0)
    inner = slice(20, 76)
    assert np.max(np.abs(dw[k][inner, inner] - wr[inner, inner])) < 0.05 * np.max(np.abs(wr))
    assert np.max(np.abs(du[k][inner, inner] - ur[inner, inner])) < 0.05 * np.max(np.abs(ur))
    # разгон над вершиной, w > 0 на наветренном склоне (запад), < 0 на подветренном
    j = N // 2
    assert du[k][j, j] > 0
    assert dw[k][j, j - 8] > 0 > dw[k][j, j + 8]


def test_linear_a_ground_kinematic():
    """У земли w = U·∂h/∂x (линейное граничное условие; уровень 25 м при a = 3 км почти у земли)."""
    h = gauss_hill(h0=20.0, a=3000.0)
    e = np.array([1.0, 0.0])
    U = 6.0
    _, _, dw = M.linear_a(h, e, lambda z: np.full(np.shape(z), U), 0.0, cap_frac=None)
    gx = np.gradient(h, DX, axis=1)
    inner = slice(20, 76)
    ref = U * gx[inner, inner]
    assert np.max(np.abs(dw[0][inner, inner] - ref)) < 0.1 * np.max(np.abs(ref))


def test_projection_divergence_free():
    """Один шаг проекции: дивергенция на гранях MAC — ноль до округления; на центрах — заметно меньше исходной."""
    rng = np.random.default_rng(0)
    hc = gauss_hill(h0=300.0, a=3000.0)
    sh = (13, N, N)
    u = 5.0 + M.gauss2d(rng.normal(size=(N, N)), 3)[None] * np.ones(sh)
    v = M.gauss2d(rng.normal(size=(N, N)), 3)[None] * np.ones(sh)
    w = 0.3 * rng.normal(size=sh)
    un, vn, wn, info = M.project(u, v, w, hc)
    assert info["div_max_faces"] < 1e-9 * max(1.0, info["div_max_before"] * 1e6)
    assert info["div_rms_faces"] < 1e-6 * info["div_rms_before"]
    assert info["div_rms_centers"] < 0.5 * info["div_rms_before"]
    assert np.all(np.isfinite(un)) and np.all(np.isfinite(wn))


def test_layer_potential():
    """Слой без стенок — однородный поток; со стенкой — поток в стенку на её гранях 0, обтекание с ускорением сбоку."""
    e = np.array([1.0, 0.0])
    gx, gy = M.layer_potential(np.zeros((N, N), bool), e)
    assert np.allclose(gx[1:-1, 1:-1], 1.0, atol=1e-5) and np.allclose(gy[1:-1, 1:-1], 0.0, atol=1e-5)
    wall = np.zeros((N, N), bool)
    wall[40:56, 44:52] = True
    gx, gy = M.layer_potential(wall, e)
    assert np.all(gx[wall] == 0)
    assert gx[38, 48] > 1.05                     # обход: ускорение у боковой стороны препятствия
    assert gx[48, 42] < 0.5                      # застой перед препятствием


def synth_cond(froude=2.0, u10=6.0, wdir=270.0):
    return dict(u10_m_s=u10, wind_from_deg=wdir, alpha=0.2, max_profile=1.6, u_sat_m_s=u10 * 1.6, z_i_m=1500.0,
                n_bv_s=0.01, froude=froude)


@pytest.fixture(scope="module")
def synth_out():
    hc = gauss_hill(h0=400.0, a=1500.0)
    heat = np.full_like(hc, 150.0)
    return hc, AS.assemble(hc, synth_cond(froude=0.9), heat=heat)


def test_assemble_contract_weights(synth_out):
    hc, out = synth_out
    assert out["fields"].shape == (4, 13, N, N) and out["fields"].dtype == np.float32
    assert out["fields_m"].shape == (3, 13, N, N)
    assert out["weights"].shape == (len(AS.PHASES), N, N)
    assert np.allclose(out["weights"].sum(0), 1.0, atol=1e-5)
    assert np.allclose(out["weights_m"].sum(0), 1.0, atol=1e-5)
    assert np.all(out["weights"] >= 0)
    assert np.all(np.isfinite(out["fields"]))
    assert out["div"]["h"]["div_rms_faces"] < 1e-6 * max(out["div"]["h"]["div_rms_before"], 1e-12)
    assert out["seconds"] > 0 and "project_h" in out["steps"]


def test_assemble_deterministic(synth_out):
    hc, out = synth_out
    out2 = AS.assemble(hc, synth_cond(froude=0.9), heat=np.full_like(hc, 150.0))
    assert np.array_equal(out["fields"], out2["fields"])
    assert np.array_equal(out["weights"], out2["weights"])


def test_dividing_height():
    hc = gauss_hill(h0=1000.0, a=3000.0)
    hcd, base = M.dividing_height(hc, 0.4)
    assert math.isclose(hcd, base + (hc.max() - base) * 0.6)
    assert M.dividing_height(hc, 1.5)[0] == base
