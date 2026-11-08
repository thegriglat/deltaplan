"""SWG-9: внутренний слой JH на присоединённом потоке в лее вне мёртвой зоны — зонд (профили, линия вдоль ветра) и правила.

Зонд (`probe`) на одном решении панелей (`ground.model.GRun`, как SWG-1/7) по колонкам (x, y):
  * профиль по высотам ZP (11 уровней Пикара SWD1): s_pot, s_jh и величины JH (A, ΔS на max(z, l), l, h_m, t, u0/U_ref);
  * линия вдоль ветра через колонку: ΔS однородного потенциала (как в JH) на высоте l над поверхностью панелей,
    смещения OFF (м, «−» — навстречу ветру) — для градиента давления dΔS/ds и для разбора запаздывания (гипотеза «в»).

Правила (формулируются здесь до сравнения с эталонами, без констант подбора; при нулевом градиенте давления — тождество
potential_jh; выше внутреннего слоя / h_m — без изменений):
  * `attached_jh` (основное, «APG»): равновесный слой Таунсенда в внутреннем слое (Townsend 1961 JFM 11:97; Hunt,
    Leibovich & Richards 1988 QJRMS 114:1435 — внутренний приземный слой: ∂τ/∂z = ∂p/∂s): τ(z)/ρ = u*_w² + G·z,
    G = (1/ρ)∂p/∂s = −u0(h_m)²·∂ΔS/∂s (давление JH: Δp/ρ = −u0(h_m)²·ΔS); профиль du/dz = √max(τ/ρ, 0)/(κz) от u(z0)=0;
    u*_w — из сшивки u(l) = u_JH(l) (скорость на верху внутреннего слоя задаёт внешнее невязкое решение). При
    u*_w² < 0 (τ_w < 0, предотрывное состояние, Stratford 1959) — τ < 0 ниже z_s = −u*_w²/G: там u = 0 (без обратного
    потока). Только где у колонки есть гребень (L < L_FLAT = 10 км; иначе l JH — условная глубина «ровной
    земли», не слой холма). Ниже l: u_attached(z) = u_JH(l)·F(z)/F(l), F — интеграл профиля; выше l — как potential_jh.
  * `attached_jh_nl` («нелинейный Бернулли»): средний слой JH невязкий (HLR 1988), A·ΔS — линеаризация
    u² = u0² − 2Δp/ρ, Δp/ρ = −½u0(h_m)²((1+ΔS)² − 1); правило: u_in = u0·√max(0, 1 + A((1+ΔS)² − 1)) — без возврата
    скорости обратным потоком при 1 + A·ΔS < 0 (находка SWG-7).
"""
from __future__ import annotations

import numpy as np

from ground import model as M  # noqa: F401  (патчи panels3d при импорте)
from panels3d import influence as _inf
from panels3d.jh import KAPPA
from panels3d.terrain import bg_uniform, wind_of, u_ref_of

ZP = (2.0, 5.0, 10.0, 20.0, 30.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0)   # уровни Пикара SWD1
OFF = tuple(float(v) for v in np.arange(-1500.0, 501.0, 25.0))              # смещения линии вдоль ветра, м
DS_GRAD = 25.0                                                             # шаг разности ∂ΔS/∂s (= ds_min)


def _uniform(run):
    """σ однородного потенциала (кеш Influence, как в jh_parts) и сам фон."""
    panels, infl, bg = run.panels, run.infl, run.bg
    ex, ey = wind_of(bg, panels.terrain)
    U_ref, _ = u_ref_of(bg, panels.terrain)
    key = ("uniform", float(U_ref), round(ex, 12), round(ey, 12))
    if key not in infl._cache:
        from panels3d import solve
        infl._cache[key] = solve(panels, bg_uniform(U_ref, (ex, ey)), None, infl)[0]
    return infl._cache[key], bg_uniform(U_ref, (ex, ey)), float(U_ref), (ex, ey)


def dS_at(run, x, y, zagl):
    """ΔS однородного потенциала (|u|/U_ref − 1) на высоте zagl над поверхностью панелей (как dS в jh_parts)."""
    sig_u, bgu, U_ref, _ = _uniform(run)
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = run.panels.height(x, y) + np.asarray(zagl, float).ravel()
    u, v, _ = _inf.velocity(run.panels, sig_u, bgu, x, y, z, None, run.infl.backend)
    return np.hypot(u, v) / U_ref - 1.0


def probe(run, X, Y, norm_xyz):
    """Колонки (X, Y) → dict: профили (n, len(ZP)) s_pot, s_jh, A, dS, t; l, hm, L, u0hm (u0(h_m)/U_ref); линия dS_line
    (n, len(OFF)) на высоте l; dSdx (∂ΔS/∂s на l, 1/м). s нормированы на опорную точку (тем же run)."""
    X = np.asarray(X, float)
    Y = np.asarray(Y, float)
    n, nz = X.size, len(ZP)
    xa = np.repeat(X, nz)
    ya = np.repeat(Y, nz)
    za = np.tile(np.asarray(ZP), n)
    xa_, ya_, zabs = run.abs_points(np.r_[xa, norm_xyz[0]], np.r_[ya, norm_xyz[1]], np.r_[za, norm_xyz[2]])
    p = M.jh_parts(run, xa_, ya_, zabs)
    nsp, npot = p["speed"][-1], p["pot_speed"][-1]
    sh = (n, nz)
    out = dict(s_jh=(p["speed"][:-1] / nsp).reshape(sh), s_pot=(p["pot_speed"][:-1] / npot).reshape(sh),
               A=p["A"][:-1].reshape(sh), dS=p["dS"][:-1].reshape(sh), t=p["t"][:-1].reshape(sh),
               u0=(p["u0"][:-1] / p["U_ref"]).reshape(sh))
    out["l"] = p["l"][:-1].reshape(sh)[:, 0]
    out["hm"] = p["hm"][:-1].reshape(sh)[:, 0]
    out["L"] = p["L"][:-1].reshape(sh)[:, 0]
    z0 = run.z0
    out["u0hm"] = np.log(np.maximum(out["hm"], 1.01 * z0) / z0) / np.log(100.0 / z0)
    out["norm_speed"] = float(nsp)
    out["norm_pot"] = float(npot)
    _, _, _, (ex, ey) = _uniform(run)
    off = np.asarray(OFF)
    lx = (X[:, None] + off[None, :] * ex).ravel()
    ly = (Y[:, None] + off[None, :] * ey).ravel()
    lz = np.repeat(np.maximum(out["l"], z0), off.size)
    out["dS_line"] = dS_at(run, lx, ly, lz).reshape(n, off.size)
    dp = dS_at(run, X + DS_GRAD * ex, Y + DS_GRAD * ey, np.maximum(out["l"], z0))
    dm = dS_at(run, X - DS_GRAD * ex, Y - DS_GRAD * ey, np.maximum(out["l"], z0))
    out["dSdx"] = (dp - dm) / (2 * DS_GRAD)
    return out


# ---------------- правила (чистые функции величин JH) ----------------
def _F(a, g, z, z0):
    """∫_{z0}^{z} √max(a + g·z', 0)/z' dz' — профиль слоя Таунсенда (u в единицах u*_l/κ; a = u*_w²/u*_l², g = G/u*_l²,
    1/м). Первообразные (w = √(a + g z)): a > 0 — 2w + √a·ln|(w − √a)/(w + √a)|; a < 0 — 2w − 2√−a·atan(w/√−a).
    Пределы: снизу max(z0, z_s), z_s = −a/g при a < 0 < g (ниже τ < 0: u = 0); сверху min(z, z_t), z_t = −a/g при
    g < 0 < a (выше τ < 0: сдвига нет). g → 0: √a·ln(z/z0)."""
    a, g, z, z0 = np.broadcast_arrays(*(np.asarray(v, float) for v in (a, g, z, z0)))
    out = np.zeros(a.shape)
    flat = np.abs(g) * z <= 1e-12 * np.maximum(np.abs(a), 1e-12)
    out[flat] = np.sqrt(np.maximum(a[flat], 0.0)) * np.log(z[flat] / z0[flat])
    nf = ~flat
    with np.errstate(divide="ignore", invalid="ignore"):
        zr = np.where(nf, -a / np.where(nf, g, 1.0), 0.0)
        lo = np.where((a < 0) & (g > 0), np.maximum(z0, zr), z0)
        hi = np.where((a > 0) & (g < 0), np.minimum(z, zr), z)
        ok = nf & (hi > lo) & ((a > 0) | (g > 0))
        w1 = np.sqrt(np.maximum(a + g * hi, 0.0))
        w0 = np.sqrt(np.maximum(a + g * lo, 0.0))
        sa = np.sqrt(np.abs(a))
        pos = ok & (a > 0)
        neg = ok & (a <= 0)

        def p_pos(w):
            return 2 * w + sa * np.log(np.maximum(np.abs(w - sa), 1e-300) / (w + sa))

        def p_neg(w):
            return 2 * w - 2 * sa * np.arctan(w / np.maximum(sa, 1e-300))
        out = np.where(pos, p_pos(w1) - p_pos(w0), out)
        out = np.where(neg, p_neg(w1) - p_neg(w0), out)
    return out


def solve_uw2(g, l, z0, n_iter=100):
    """a = u*_w²/u*_l² из сшивки F(a, g, l) = ln(l/z0) (u(l) = u_JH(l); F монотонна по a). Поиск: g > 0 — a ∈ (−g·l, ∞)
    (τ_w < 0 допускается: предотрывное состояние), g < 0 — a ∈ (0, ∞); g = 0 → a = 1 (лог)."""
    g, l, z0 = np.broadcast_arrays(*(np.asarray(v, float) for v in (g, l, z0)))
    target = np.log(l / z0)
    lo = np.where(g > 0, -g * l, 0.0)
    hi = np.maximum(lo, 0.0) + 1.0
    for _ in range(80):
        f = _F(hi, g, l, z0)
        if np.all(f >= target):
            break
        hi = np.where(f < target, 2.0 * hi + 1.0, hi)
    for _ in range(n_iter):
        mid = 0.5 * (lo + hi)
        f = _F(mid, g, l, z0)
        lo = np.where(f < target, mid, lo)
        hi = np.where(f < target, hi, mid)
    a = 0.5 * (lo + hi)
    return np.where(np.abs(g) * l < 1e-12, 1.0, a)


def g_of(dSdx, u0hm, uin_l, l, z0):
    """g = G/u*_l² (1/м): G/U_ref² = −u0hm²·∂ΔS/∂s (Δp/ρ = −u0(h_m)²·ΔS — давление внутреннего слоя JH, в долях
    U_ref²), u*_l/U_ref = κ·uin_l/ln(l/z0) (uin_l = u_JH(l)/U_ref; ниже l профиль JH — лог от u*_l)."""
    return -u0hm ** 2 * dSdx * (np.log(l / z0) / (KAPPA * uin_l)) ** 2


def apg_factor(z, l, z0, g):
    """attached_jh: u_att/u_JH на высоте z (= 1 при z ≥ l и при g = 0). → (фактор, a = u*_w²/u*_l²)."""
    z, l, g = np.broadcast_arrays(*(np.asarray(v, float) for v in (z, l, g)))
    a = solve_uw2(g, l, z0)
    zz = np.clip(z, z0 * 1.0001, l)
    fac = _F(a, g, zz, z0) / np.log(zz / z0)
    return np.where(z < l, fac, 1.0), a


def nl_factor(A, dS):
    """attached_jh_nl: u_in/u0 = √max(0, 1 + A((1+ΔS)² − 1)); линейное JH: 1 + A·ΔS."""
    return np.sqrt(np.maximum(0.0, 1.0 + A * ((1.0 + dS) ** 2 - 1.0)))
