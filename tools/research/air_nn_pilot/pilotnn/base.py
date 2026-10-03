"""Линейная база обтекания Б1 (контракт docs/contracts/air-nn-p3.md) и кодировка выхода v5 (П2 v5).

Физика (нейтральный поток, малые уклоны): потенциальное течение со скоростью Ub(z_a) вдоль ê′ = (cos r, sin r) над
рельефом h. Возмущение потенциала φ̂ = −Ub·i(k·ê)ĥ/|k|·e^(−|k|z), поэтому
  ŵ = i Ub (k·ê) ĥ e^(−|k|z)  (= Ub ê·∇h_s),   û′ = Ub kx (k·ê)/|k| ĥ e^(−|k|z),   v̂′ = Ub ky (k·ê)/|k| ĥ e^(−|k|z).
Следствия: на вершине u′ > 0 (разгон), w > 0 на наветренном склоне, < 0 на подветренном. Применимость — малые
уклоны (h/L ≪ 1), нейтральная устойчивость, без отрыва, без трения; рельеф сильнее ~0,3 даёт завышение w и u′.
Продолжение до периодичности — чётное отражение до 2N × 2N (решение владельца: по умолчанию, не менял);
∇ — спектральный (гармоника Найквиста обнулена). Поправка Jackson–Hunt: `pert_ref_z` (вне контракта, по умолчанию
выключена) — см. p3/base_vs_solver.md.
"""
from __future__ import annotations

import math

import numpy as np

from . import prep as P

AGL = P.AGL
EPS = 0.1                                  # м/с, пол скорости в разгоне и повороте (П2 v5)
OUT_NAMES_V5 = ("a_m", "sd_m", "cd_m", "wrel_m", "a_h", "sd_h", "cd_h", "wrel_h", "theta")
REFLECT_OUT_SIGN_V5 = np.repeat(np.array([1, -1, 1, 1, 1, -1, 1, 1, 1], np.float64), len(AGL))   # sin δ — минус


def _kgrid(ny, nx, dx):
    ky = 2 * np.pi * np.fft.fftfreq(2 * ny, dx)[:, None]
    kx = 2 * np.pi * np.fft.rfftfreq(2 * nx, dx)[None, :]
    return kx, ky


def linear_base(hc_r, r, ub, agl=AGL, dx=400.0, pert_ref_z=None):
    """→ dict(u, v, w, gx, gy), (13, ny, nx) float64; см. контракт Б1."""
    h = np.asarray(hc_r, np.float64)
    ny, nx = h.shape
    ub = np.asarray(ub, np.float64)
    agl = np.asarray(agl, np.float64)
    h = h - h.mean()
    e = np.block([[h, h[:, ::-1]], [h[::-1, :], h[::-1, ::-1]]])        # чётное отражение 2N × 2N
    H = np.fft.rfft2(e)
    kx, ky = _kgrid(ny, nx, dx)
    kk = np.hypot(kx, ky)
    c, s = math.cos(r), math.sin(r)
    ke = kx * c + ky * s
    inv = np.where(kk > 0, 1.0 / np.where(kk > 0, kk, 1.0), 0.0)
    kxd = np.where(np.isclose(np.abs(kx), np.pi / dx), 0.0, kx)         # Найквист — без производной
    kyd = np.where(np.isclose(np.abs(ky), np.pi / dx), 0.0, ky)
    cu, cv = kx * ke * inv, ky * ke * inv
    out = {k: np.empty((len(agl), ny, nx)) for k in ("u", "v", "w", "gx", "gy")}
    crop = (slice(0, ny), slice(0, nx))
    for a, z in enumerate(agl):
        Hz = H * np.exp(-kk * z)
        gx = np.fft.irfft2(1j * kxd * Hz, e.shape)[crop]
        gy = np.fft.irfft2(1j * kyd * Hz, e.shape)[crop]
        f = 1.0
        if pert_ref_z is not None:          # JH-подобная: давление ~ Ub(z_ref)², скорость ~ p/Ub(z)
            ur = float(np.interp(max(z, pert_ref_z), agl, ub))
            f = min(ur ** 2 / max(ub[a], 1e-9) ** 2, 4.0) if ub[a] > 0 else 0.0
        up = np.fft.irfft2(cu * Hz, e.shape)[crop]
        vp = np.fft.irfft2(cv * Hz, e.shape)[crop]
        out["gx"][a], out["gy"][a] = gx, gy
        out["w"][a] = ub[a] * (c * gx + s * gy)
        out["u"][a] = ub[a] * c + ub[a] * f * up
        out["v"][a] = ub[a] * s + ub[a] * f * vp
    return out


def _base_angle(base, r):
    sp = np.hypot(base["u"], base["v"])
    ang = np.where(sp < EPS, r, np.arctan2(base["v"], base["u"]))
    return sp, ang


def gamma_of(gamma, nA=len(AGL)):
    """γ_a (П2 v5) → массив (2, 13, 1, 1): [0] — без нагрева (m), [1] — с нагревом (h). Число — одно на все высоты;
    dict(m=[13], h=[13]) — как в enc.json прогона."""
    if isinstance(gamma, dict):
        g = np.stack([np.asarray(gamma["m"], np.float64), np.asarray(gamma["h"], np.float64)])
    else:
        g = np.broadcast_to(np.asarray(gamma, np.float64), (2, nA)) if np.ndim(gamma) < 2 else np.asarray(gamma, np.float64)
    assert g.shape == (2, nA), g.shape
    return g[:, :, None, None]


def target_v5(z, meta, base, agl=AGL, gamma=1.0):
    """Цель выхода v5 (117, ny, nx) float64: канал = c·13 + a, повёрнутая система; см. контракт П2 v5.
    gamma — γ_a (`gamma_of`): w_rel = (w − γ_a·V·∇h_s)/S; γ = 1 — чистая кинематика, γ = 0 — w/S."""
    k, r, S = meta["k"], meta["r"], meta["S"]
    gm = gamma_of(gamma, len(agl))
    sb, ab = _base_angle(base, r)
    gx, gy = base["gx"], base["gy"]
    out = []
    for ig, key in enumerate(("d400_m", "d400_h")):
        f = np.asarray(z[key], np.float64)
        u, v = P.rot_vec(f[0], f[1], k)
        w = P.rot_scalar(f[2], k)
        sp = np.hypot(u, v)
        d = np.arctan2(v, u) - ab
        out += [np.log(np.maximum(sp, EPS) / np.maximum(sb, EPS)), np.sin(d), np.cos(d),
                (w - gm[ig] * (u * gx + v * gy)) / S]
    out.append(P.rot_scalar(np.asarray(z["d400_h"], np.float64)[3], k))
    return np.concatenate(out, axis=0)


def to_physical_v5(y, meta, base, agl=AGL, gamma=1.0):
    """Обратное преобразование выхода v5 (117, ny, nx) → dict(m=(3,13,ny,nx), h=(4,13,ny,nx)), м/с и К, исходная система.
    w = w_rel·S + γ_a·V·∇h_s (gamma — как в `target_v5`)."""
    y = np.asarray(y, np.float64)
    nA = len(agl)
    y = y.reshape(9, nA, *y.shape[-2:])
    k, r, S = meta["k"], meta["r"], meta["S"]
    sb, ab = _base_angle(base, r)
    gx, gy = base["gx"], base["gy"]
    gm = gamma_of(gamma, nA)
    res = {}
    for ig, (key, c0, n) in enumerate((("m", 0, 3), ("h", 4, 4))):
        sp = np.maximum(sb, EPS) * np.exp(y[c0])
        ang = ab + np.arctan2(y[c0 + 1], y[c0 + 2])
        up, vp = sp * np.cos(ang), sp * np.sin(ang)
        wp = y[c0 + 3] * S + gm[ig] * (up * gx + vp * gy)
        u, v = P.rot_vec(up, vp, -k % 4)
        ch = [u, v, P.rot_scalar(wp, -k % 4)]
        if n == 4:
            ch.append(P.rot_scalar(y[8], -k % 4))
        res[key] = np.ascontiguousarray(np.stack(ch))
    return res
