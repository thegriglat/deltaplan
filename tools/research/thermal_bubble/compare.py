"""TB-5 (шаблон v3; круг 1 — TB-2b): сверка шаблона пузыря (bubble.py) с литературой (literature.md) и нынешним профилем (current.py).

Пишет out/compare.json (TB3 tb-compare), разрезы PNG в build/screenshots/thermal-bubble/tb5_*.png (старые tb2b_* не трогаем); compare.md пишется вручную по out/compare.json.
Запуск: tools/research/thermal_bubble/py tools/research/thermal_bubble/compare.py   (~6-10 мин, один процесс; под .dpcli/dpcli lock cpu tb5 --)
Все оси: x, y — горизонталь, z вверх, земля z = 0. Поле пузыря осесимметрично и сносится ветром целиком, поэтому
горизонтальные величины считаются в системе воздуха (Env(wind=0)); ветер поля нужен только для проверки дивергенции суммы.
"""
from __future__ import annotations

import dataclasses
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bubble as bb  # noqa: E402
import current as cur  # noqa: E402

OUT = HERE / "out"
FIGDIR = Path("/home/greg/deltaplan/build/screenshots/thermal-bubble")
WSTAR, ZL, ZI = 2.56, 1400.0, 1400.0           # медианы docs/research/calibration_data/thermals.md
WIND = 3.0
Z0 = 0.1
ENV0 = bb.Env(wind=(0.0, 0.0), zi=ZI)
ENVW = bb.Env(wind=(WIND, 0.0), zi=ZI)
SRC = bb.from_game(0.0, 0.0, 0.0, WSTAR, ZL, ENV0)
RA, W0A, NA = cur.allen_core(WSTAR, ZL)         # R верха, w0, n_A
T_STEP = 15.0

# радиальная сетка (м): плотная у оси (шлейф b0 ~ 65 м), редкая вдали
RHO = np.unique(np.concatenate([np.linspace(0, 120, 61), np.linspace(120, 600, 97), np.linspace(600, 3000, 49)]))
RHO_FAR = np.unique(np.concatenate([np.linspace(0, 300, 151), np.geomspace(300, 30000, 400)]))
FAIL: list[str] = []


def life_end(src: bb.Source) -> float:
    t = src.t0 + 30.0
    while bb.state(src, ENV0, t) is not None and t < 20000:
        t += 5.0
    return t


T_END = life_end(SRC)
TS = np.arange(T_STEP, T_END - 1.0, T_STEP)


def ray(st: bb.State, z, rho=RHO, env=ENV0) -> np.ndarray:
    """v на луче y = yc, x = xc + rho, для набора высот z: (nz, nrho, 3)."""
    z = np.atleast_1d(np.asarray(z, float))
    P = np.zeros((z.size, rho.size, 3))
    P[..., 0] = st.xc + rho[None, :]
    P[..., 1] = st.yc
    P[..., 2] = z[:, None]
    return bb.velocity(P, [st], env)


def first_zero(rho, w):
    """Радиус первой смены знака + -> - вдоль луча (линейная интерполяция); None, если нет."""
    i = np.nonzero((w[:-1] > 0) & (w[1:] <= 0))[0]
    if i.size == 0:
        return None
    i = i[0]
    return float(rho[i] + (rho[i + 1] - rho[i]) * w[i] / (w[i] - w[i + 1]))


def cur_w_ray(z, rho=RHO, top=ZL, R=RA, w0=W0A):
    z = np.atleast_1d(np.asarray(z, float))
    P = np.zeros((z.size, rho.size, 3))
    P[..., 0] = rho[None, :]
    P[..., 2] = z[:, None]
    return cur.current_w(P, top=top, R=R, w0=w0)


def disk_mean(rho, w, r0):
    m = rho <= r0
    return float(np.trapezoid(w[m] * rho[m], rho[m]) * 2 / r0 ** 2) if r0 and r0 > 0 else None



# ---------------------------------------------------------------- баланс Φ (v3)
PHI_UP_FRAC = 0.35 * 0.45     # Φ типичный, в w*: доля площади подъёма (L&S 1980, Stull 1988) × средний подъём ŵ_max (L&S 1980) = 0,1575
CAP_W0 = 2.5                  # сила ядра не выше 2,5 w* (thermals.md, AM-07)


def _smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def current_kbar() -> dict:
    """K̄ нынешней модели, м²: (а) численно тем же определением, что у шаблона (средний по жизни и по столбу 0…z_l поток вверх
    ∫max(w,0)dA на 1 м/с, current_w(allen_core), 28 слоёв), огибающая жизни — grow/mature/decay ThermalCfg::default (середины
    180/510/225 с, smoothstep), жизнь БЕЗ паузы gap; (б) формула columns.rs: CORE_FLUX·π·r_c²·shape.mean(z_l)·life_mean
    (life_mean включает паузу gap = 180 с и duty = 1)."""
    g, m, d, gap = 180.0, 510.0, 225.0, 180.0
    t = np.linspace(0.0, g + m + d, 20001)
    env = np.where(t < g, _smooth(t / g), np.where(t < g + m, 1.0, 1.0 - _smooth((t - g - m) / d)))
    env_mean = float(np.trapezoid(env, t) / (g + m + d))
    nz = 28
    zs = (np.arange(nz) + 0.5) * ZL / nz
    rho = np.unique(np.concatenate([np.linspace(0, 150, 151), np.linspace(150, 1500, 271)]))
    w = cur_w_ray(zs, rho, top=ZL, R=RA, w0=1.0)
    area = np.trapezoid(np.maximum(w, 0.0) * 2 * np.pi * rho[None, :], rho, axis=1)
    shape_num = float(area.mean())                                     # м² на 1 м/с пика, без жизни
    # формула columns.rs
    nq = 33
    q = []
    for n in range(nq):
        xi = n / (nq - 1)
        rf = max(0.45, xi ** (1 / 3) * (1 - 0.25 * xi) / 0.75)
        dh = xi * ZL
        vert = min(1.0, (dh / 150.0) ** (1 / 3)) if dh > 0 else 0.0
        tp = float(cur.smoothstep(0.0, 120.0, ZL - dh))
        q.append(rf * rf * vert * tp)
    q_mean = float((np.sum(q) - 0.5 * (q[0] + q[-1])) / (nq - 1))
    life_mean = (0.5 * g + m + 0.5 * d) / (g + m + d + gap)
    shape_f = float(np.exp(-1.0) * np.pi * RA ** 2 * q_mean)           # CORE_FLUX π r_c² shape.mean
    return {"numeric": shape_num * env_mean, "numeric_shape_no_life_m2": shape_num, "env_mean_no_gap": env_mean,
            "formula_columns_rs": shape_f * life_mean, "formula_shape_m2": shape_f, "life_mean_with_gap": life_mean,
            "shape_ratio_numeric_over_formula": shape_num / shape_f, "r_c_m": RA, "q_mean": q_mean}


def balance(src: bb.Source) -> dict:
    """Баланс Φ (типичный случай w* 2,56, z_i = z_l = 1400): n_A = 8,5/z_l² живых ядер, сила по правилу игры
    w0 = min(2,5 w*, Φ/(n_A K̄)) (поток водосбора / поток одного пузыря), несомый ядрами поток = n_A K̄ w0, «между» = Φ − несомое."""
    nA = 8.5 / ZL ** 2
    ck = current_kbar()
    w0_typ = 1.24 * WSTAR                                  # сила типичного случая: w0 = k·w*, k = 1,24 (thermals.md «Законы»)
    kb_b = bb.kbar(ZL, src.tau, ENV0, w0_typ)
    kb_b1 = bb.kbar(ZL, src.tau, ENV0, 1.0)               # v3: при w0 = 1 м/с (для сравнения)
    kb_c = ck["numeric"]

    def share(kbar_, phi):
        w0 = min(CAP_W0 * WSTAR, phi / (nA * kbar_))
        carried = nA * kbar_ * w0
        return w0, carried

    phi = PHI_UP_FRAC * WSTAR
    w0_b, car_b = share(kb_b, phi)
    w0_c, car_c = share(kb_c, phi)
    w0_cf, car_cf = share(ck["formula_columns_rs"], phi)
    # шаблон напрямую: поток при реальной силе w0_b (K̄ шаблона зависит от силы: жизнь ∝ 1/w0), не масштабом K̄·w0
    flux_direct = bb.mean_up_flux(w0_b, ZL, src.tau, ENV0)
    car_b_dir = nA * flux_direct
    sens = []
    for f in (0.1, PHI_UP_FRAC, 0.25):
        p_ = f * WSTAR
        sens.append({"phi_over_wstar": f, "share_bubble": share(kb_b, p_)[1] / p_, "share_current": share(kb_c, p_)[1] / p_,
                     "between_bubble_over_wstar": (p_ - share(kb_b, p_)[1]) / WSTAR,
                     "between_current_over_wstar": (p_ - share(kb_c, p_)[1]) / WSTAR})
    return {
        "case": {"wstar": WSTAR, "zi": ZI, "zl": ZL, "n_A_per_m2": nA, "cap_w0_over_wstar": CAP_W0, "phi_m_s": phi,
                 "phi_over_wstar": PHI_UP_FRAC,
                 "phi_definition": "Φ типичный = доля площади подъёма 0,35 × средний подъём ŵ_max 0,45 w* (Lenschow–Stephens 1980; Stull 1988): "
                                   "восходящий массовый поток на единицу площади, м/с; НЕ F̄ + W̄ поля игры (оно зависит от места)"},
        "kbar_bubble": kb_b, "kbar_bubble_w0_1": kb_b1, "kbar_w0_typical_m_s": w0_typ, "kbar_current": kb_c, "kbar_current_formula": ck["formula_columns_rs"],
        "kbar_current_detail": ck,
        "w0_rule_bubble_m_s": w0_b, "w0_rule_current_m_s": w0_c,
        "core_share_phi_bubble": car_b / phi, "core_share_phi_current": car_c / phi,
        "core_share_phi_current_formula_kbar": car_cf / phi,
        "core_share_phi_bubble_direct": car_b_dir / phi, "flux_direct_bubble_m3_s": flux_direct,
        "core_share_phi_measured": bb.PARAMS["core_flux_fraction"]["value"],
        "between_bubble_over_wstar": (phi - car_b) / WSTAR, "between_current_over_wstar": (phi - car_c) / WSTAR,
        "between_bubble_direct_over_wstar": (phi - car_b_dir) / WSTAR,
        "between_measured_over_wstar": phi * (1 - bb.PARAMS["core_flux_fraction"]["value"]) / WSTAR,
        "sensitivity_phi": sens,
        "note": "K̄ шаблона по контракту = при w0 = 1 м/с, жизнь долгая (до крышки и дальше), поэтому K̄_b·w0 занижает поток сильного пузыря; "
                "*_direct — поток при реальной силе. Капа 2,5 w* достигнута у обоих при типичном Φ."}

# ---------------------------------------------------------------- один термик: временной скан
def scan_single(src: bb.Source, ts, zeta_core, z_ground, zeta_top, zeta_ring, rho=RHO):
    """По моментам жизни: на луче берём w (ядро), радиальную u (приток у земли, растекание у верха), минимум w."""
    out = {"t": [], "zc": [], "R": [], "U": [], "Uh": [], "core": [], "ground_in": [], "ground_out": [],
           "ground_vmax": [], "top_out": [], "top_in": [], "ring": []}
    zc_levels = np.array(sorted(set(list(zeta_core) + list(zeta_ring)))) * ZI
    for t in ts:
        st = bb.state(src, ENV0, t)
        if st is None:
            continue
        out["t"].append(float(t)); out["zc"].append(st.zc); out["R"].append(st.R); out["U"].append(st.U)
        out["Uh"].append(st.U if st.Uh < 0 else st.Uh)
        vc = ray(st, np.array(zeta_core) * ZI, rho)
        out["core"].append(vc[..., 2].max(axis=1))                       # (nζ,) max по ρ
        vg = ray(st, z_ground, rho)
        ur = vg[..., 0]
        out["ground_in"].append(float(-ur.min())); out["ground_out"].append(float(ur.max()))
        out["ground_vmax"].append(float(np.linalg.norm(vg, axis=-1).max()))
        vt = ray(st, np.array(zeta_top) * ZI, rho)
        out["top_out"].append(float(vt[..., 0].max())); out["top_in"].append(float(-vt[..., 0].min()))
        vr = ray(st, np.array(zeta_ring) * ZI, rho)
        out["ring"].append(float(vr[..., 2].min()))
    return {k: np.array(v) for k, v in out.items()}


# ---------------------------------------------------------------- дивергенция суммы с ветром
def wind_const(p):
    v = np.zeros_like(p)
    v[..., 0] = WIND
    return v


def wind_shear(p):
    v = np.zeros_like(p)
    z = np.clip(p[..., 2], 0.0, None)
    v[..., 0] = WIND * np.log1p(z / Z0) / np.log1p(1400.0 / Z0)
    return v


def div_checks(states, wind_fn, seed=0, npts=4000):
    """p99 |div|*R/U (центральные разности, h = 1e-4 R) и flux_rel (коробка земля..крышка, GL 48x48)."""
    rng = np.random.default_rng(seed)
    Rmax = max(s.R for s in states)
    xs = [s.xc for s in states]; ys = [s.yc for s in states]
    x0, x1 = min(xs) - 4 * Rmax, max(xs) + 4 * Rmax
    y0, y1 = min(ys) - 4 * Rmax, max(ys) + 4 * Rmax
    zlo, zhi = 0.0, ZI
    scale = max((s.U if s.Uh < 0 else s.Uh) / s.R for s in states)        # U/R, самый сильный вихрь

    def tot(p):
        return wind_fn(p) + bb.velocity(p, states, ENV0)

    # точки в коробке; h от R
    P = np.stack([rng.uniform(x0, x1, npts), rng.uniform(y0, y1, npts), rng.uniform(1.0, ZI - 1.0, npts)], -1)
    h = 1e-4 * Rmax
    div = np.zeros(npts)
    for ax in range(3):
        d = np.zeros(3); d[ax] = h
        div += (tot(P + d)[:, ax] - tot(P - d)[:, ax]) / (2 * h)
    p99 = float(np.percentile(np.abs(div), 99) / scale)
    # поток
    xg, wg = np.polynomial.legendre.leggauss(48)

    def face(a0, a1, b0, b1):
        A = 0.5 * (a1 - a0) * xg + 0.5 * (a1 + a0)
        B = 0.5 * (b1 - b0) * xg + 0.5 * (b1 + b0)
        W = np.outer(wg, wg) * 0.25 * (a1 - a0) * (b1 - b0)
        return np.meshgrid(A, B, indexing="ij"), W

    net = 0.0; net_p = 0.0; absum = 0.0; absum_p = 0.0
    for ax, lo, hi, (a0, a1, b0, b1) in (
            (0, x0, x1, (y0, y1, zlo, zhi)), (1, y0, y1, (x0, x1, zlo, zhi)), (2, zlo, zhi, (x0, x1, y0, y1))):
        for side, sgn in ((lo, -1.0), (hi, 1.0)):
            (G1, G2), W = face(a0, a1, b0, b1)
            P = np.zeros(G1.shape + (3,))
            others = [i for i in range(3) if i != ax]
            P[..., others[0]] = G1; P[..., others[1]] = G2; P[..., ax] = side
            vp = bb.velocity(P, states, ENV0)
            vt = wind_fn(P) + vp
            fn = sgn * vt[..., ax]; fp = sgn * vp[..., ax]
            net += float(np.sum(fn * W)); net_p += float(np.sum(fp * W))
            absum += float(np.sum(np.abs(fn) * W)); absum_p += float(np.sum(np.abs(fp) * W))
    # знаменатель — возмущение (строже: ветер сокращается точно и раздувал бы знаменатель)
    return {"p99_rel": p99, "flux_rel": abs(net) / absum_p, "flux_rel_total_wind": abs(net) / absum,
            "flux_net": net, "flux_abs_pert": absum_p, "box": [x0, x1, y0, y1]}


# ---------------------------------------------------------------- поток массы через плоскость
def plane_flux(vw_fn, rho=RHO_FAR):
    """∫ w dA отдельно вверх и вниз по кругу радиуса rho[-1] для осесимметричной w(ρ)."""
    w = vw_fn(rho)
    up = np.trapezoid(np.where(w > 0, w, 0) * 2 * np.pi * rho, rho)
    dn = np.trapezoid(np.where(w < 0, w, 0) * 2 * np.pi * rho, rho)
    return float(up), float(dn)


# ---------------------------------------------------------------- раскладка нескольких
def layout_sites(d):
    h = d * np.sqrt(3) / 2
    pts = [(0, 0), (d, 0), (2 * d, 0), (d / 2, h), (3 * d / 2, h), (5 * d / 2, h)]
    return np.array(pts, float), h


def multi_states(sites, ages, T):
    out = []
    for (x, y), a in zip(sites, ages):
        s = bb.from_game(float(x), float(y), T - a, WSTAR, ZL, ENV0)
        st = bb.state(s, ENV0, T)
        assert st is not None, (x, y, a)
        out.append(st)
    return out


def main() -> int:
    t_start = time.time()
    OUT.mkdir(exist_ok=True)
    FIGDIR.mkdir(parents=True, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import TwoSlopeNorm

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "axes.titlesize": 9})
    figures: list[str] = []
    details: dict = {}
    # осевая симметрия и независимость от ветра (sanity)
    st = bb.state(SRC, ENV0, 300.0)
    ang = np.linspace(0, 2 * np.pi, 7, endpoint=False)
    vr = []
    for a in ang:
        P = np.array([[st.xc + 80 * np.cos(a), st.yc + 80 * np.sin(a), 30.0]])
        v = bb.velocity(P, [st], ENV0)[0]
        vr.append(v[0] * np.cos(a) + v[1] * np.sin(a))
    sanity_axisym = float(np.ptp(vr) / (abs(np.mean(vr)) + 1e-12))
    stw = bb.state(SRC, ENVW, 300.0)
    Pq = np.array([[stw.xc + 80.0, 0.0, 30.0]]); Pq0 = np.array([[st.xc + 80.0, 0.0, 30.0]])
    sanity_wind = float(np.abs(bb.velocity(Pq, [stw], ENVW) - bb.velocity(Pq0, [st], ENV0)).max())
    # подгонка ядра по измерениям (v3): радиус смены знака w шаблона на уровнях против L&S и Аллена
    fit = {"alpha_thermal": bb.PARAMS["alpha_thermal"]["value"], "z_h_over_zi": bb._ZH_FRAC, "sign_over_R": bb._SIGN_OVER_R,
           "alpha_allen_alt": bb._ALPHA_ALLEN, "z_h_over_zi_allen_alt": bb._ZH_FRAC_ALLEN, "levels": {}}
    for zt in (0.2, 0.25, 0.5, 0.75, 0.8):
        r_ls = 0.08 * zt ** (1 / 3) * (1 - 0.25 * zt)
        r_al = 0.102 * zt ** (1 / 3) * (1 - 0.25 * zt)
        r_tp = bb._SIGN_OVER_R * bb._AL_T * (zt * ZI + bb._ZH_FRAC * ZL) / ZI
        fit["levels"][str(zt)] = {"lenschow_stephens": r_ls, "allen": r_al, "template_formula": r_tp,
                                  "current": 0.0765 * ZL * max(0.45, zt ** (1 / 3) * (1 - 0.25 * zt) / 0.75) / ZI}
    details["core_fit"] = fit
    details["balance"] = balance(SRC)
    details["sanity"] = {"axisym_rel_spread_ur_80m": sanity_axisym, "wind_shift_invariance_abs": sanity_wind}

    # ------------------------------------------------ 1. один термик, скан
    zeta_core = np.linspace(0.23, 0.5, 7)
    z_ground = np.array([10.0, 20.0, 30.0, 40.0, 50.0])
    zeta_top = np.array([0.85, 0.9, 0.95])
    zeta_ring = np.linspace(0.3, 0.8, 6)
    sc = scan_single(SRC, TS, zeta_core, z_ground, zeta_top, zeta_ring)
    nt = sc["t"].size
    # w ядра
    core = sc["core"]                                   # (nt, nζ)
    core_max_t = core.max(axis=0)                        # по жизни, для каждого ζ
    core_t_at = sc["t"][core.argmax(axis=0)]
    w_core_max = float(core_max_t.mean() / WSTAR)
    # w_mean (по диску w>0) в момент максимума, для сравнения с Ленсчоу–Стефенсом 0,45 (это средний подъём)
    wmean_at_max = []
    for k, zeta in enumerate(zeta_core):
        stk = bb.state(SRC, ENV0, float(core_t_at[k]))
        r = ray(stk, zeta * ZI)[0]
        r0 = first_zero(RHO, r[:, 2])
        wmean_at_max.append(disk_mean(RHO, r[:, 2], r0))
    wmean_at_max = [x for x in wmean_at_max if x is not None]
    # текущая модель: allen_core на тех же ζ, пик по оси; среднее по диску w>0
    cur_core = []; cur_mean = []
    for zeta in zeta_core:
        w = cur_w_ray(zeta * ZI)[0]
        cur_core.append(float(w.max()))
        r0 = first_zero(RHO, w)
        cur_mean.append(disk_mean(RHO, w, r0))
    w_core_cur = float(np.mean(cur_core) / WSTAR)

    # радиус: w=0 на ζ=0.5 в момент, когда центр головы на этом уровне; то же ζ=0.25, 0.75
    def head_time(zeta):
        i = np.nonzero(sc["zc"] >= zeta * ZI)[0]
        if i.size == 0:
            return None
        j = i[0]
        if j == 0:
            return float(sc["t"][0])
        f = (zeta * ZI - sc["zc"][j - 1]) / (sc["zc"][j] - sc["zc"][j - 1])
        return float(sc["t"][j - 1] + f * (sc["t"][j] - sc["t"][j - 1]))

    prof = {}
    for zeta in (0.25, 0.5, 0.75):
        th = head_time(zeta)
        stz = bb.state(SRC, ENV0, th)
        rr = ray(stz, zeta * ZI)[0]
        wb = rr[:, 2]
        wc = cur_w_ray(zeta * ZI)[0]
        prof[zeta] = {"t_head": th, "R_head": stz.R, "U": stz.U,
                      "r0_bubble": first_zero(RHO, wb), "r0_current": first_zero(RHO, wc),
                      "w_axis_bubble": float(wb[0]), "w_axis_current": float(wc[0]),
                      "w_min_bubble": float(wb.min()), "w_min_current": float(wc.min()),
                      "rho": RHO.tolist(), "w_bubble": wb.tolist(), "w_current": wc.tolist()}
    r0_b = prof[0.5]["r0_bubble"]; r0_c = prof[0.5]["r0_current"]
    # сколько точек для профиля в таблицу md (выборка)
    details["profiles"] = {str(z): {k: v for k, v in d.items() if k not in ("rho", "w_bubble", "w_current")}
                           for z, d in prof.items()}
    details["profile_samples"] = {}
    samp_rho = [0, 25, 50, 75, 100, 150, 200, 300, 450, 600, 900]
    for zeta, d in prof.items():
        rho = np.array(d["rho"]);
        details["profile_samples"][str(zeta)] = {
            "rho": samp_rho,
            "bubble": [float(np.interp(r, rho, d["w_bubble"])) for r in samp_rho],
            "current": [float(np.interp(r, rho, d["w_current"])) for r in samp_rho]}

    # скорость подъёма
    i05 = head_time(0.5)
    st05 = bb.state(SRC, ENV0, i05)
    t_stall = None
    zc_fin = sc["zc"][-1]
    j90 = np.nonzero(sc["zc"] >= 0.9 * zc_fin)[0][0]
    U_mean = float((sc["zc"][j90] - bb.state(SRC, ENV0, 1e-3).zc) / sc["t"][j90]) if bb.state(SRC, ENV0, 1e-3) else None
    rise_05 = st05.U / WSTAR
    U_mean_w = U_mean / WSTAR if U_mean is not None else None

    # приток/растекание/кольцо
    gi = sc["ground_in"]; go = sc["ground_out"]
    t_gi = float(sc["t"][gi.argmax()]); t_to = float(sc["t"][sc["top_out"].argmax()])
    inflow = float(gi.max() / WSTAR); outflow = float(sc["top_out"].max() / WSTAR)
    ring_min = float(sc["ring"].min() / WSTAR)
    t_ring = float(sc["t"][sc["ring"].argmin()])
    # приток по высоте (пик по жизни) для таблицы
    inflow_by_z = {}
    for z in z_ground:
        best = 0.0
        for t in TS[::2]:
            s_ = bb.state(SRC, ENV0, t)
            if s_ is None:
                continue
            best = max(best, float(-ray(s_, z)[0][:, 0].min()))
        inflow_by_z[str(z)] = best / WSTAR
    # ring в current
    ring_cur = float(min(cur_w_ray(z * ZI)[0].min() for z in zeta_ring) / WSTAR)
    # ring у шаблона по уровням
    ring_by_level = {}
    for zeta in zeta_ring:
        ring_by_level[f"{zeta:.2f}"] = {"bubble": None, "current": float(cur_w_ray(zeta * ZI)[0].min() / WSTAR)}
    for k, zeta in enumerate(zeta_ring):
        mn = 0.0
        for t in TS[::2]:
            s_ = bb.state(SRC, ENV0, t)
            if s_ is not None:
                mn = min(mn, float(ray(s_, zeta * ZI)[0][:, 2].min()))
        ring_by_level[f"{zeta:.2f}"]["bubble"] = mn / WSTAR

    details["single"] = {
        "T_end_s": T_END, "tau_s": SRC.tau, "F0": SRC.F0, "b0": SRC.b0, "R_allen_top": RA, "w0_allen": W0A, "n_A": NA,
        "w_core_max": {"zeta": zeta_core.tolist(), "bubble_max_over_wstar": (core_max_t / WSTAR).tolist(),
                       "t_at_max": core_t_at.tolist(), "current_over_wstar": (np.array(cur_core) / WSTAR).tolist(),
                       "bubble_disk_mean_at_max_over_wstar": [x / WSTAR for x in wmean_at_max],
                       "current_disk_mean_over_wstar": [x / WSTAR for x in cur_mean if x is not None]},
        "rise": {"U_at_zeta05": float(st05.U), "t_at_zeta05": i05, "R_at_zeta05": float(st05.R),
                 "U_mean_to_90pct_of_final": U_mean, "U_start": float(bb.state(SRC, ENV0, 10.0).U),
                 "zc_final": float(zc_fin)},
        "inflow_ground": {"t_at_max": t_gi, "max_over_wstar": inflow, "by_z_over_wstar": inflow_by_z,
                          "outflow_ground_max_over_wstar": float(go.max() / WSTAR),
                          "vmax_z_le_50_over_wstar": float(sc["ground_vmax"].max() / WSTAR)},
        "outflow_top": {"t_at_max": t_to, "max_over_wstar": outflow, "inflow_top_max_over_wstar": float(sc["top_in"].max() / WSTAR)},
        "ring": {"t_at_min": t_ring, "min_over_wstar": ring_min, "by_level": ring_by_level, "current_min": ring_cur},
    }

    # поток массы через ζ = 0.25, 0.5, 0.75
    flux = {}
    for zeta in (0.25, 0.5, 0.75):
        rows = []
        for t in np.arange(30, T_END - 30, 120.0):
            s_ = bb.state(SRC, ENV0, float(t))
            if s_ is None:
                continue
            u, d = plane_flux(lambda rho: ray(s_, zeta * ZI, rho)[0][:, 2])
            rows.append({"t": float(t), "zc": s_.zc, "up": u, "down": d, "net": u + d})
        th_ = head_time(zeta)
        s_h = bb.state(SRC, ENV0, th_)
        wh = ray(s_h, zeta * ZI, RHO_FAR)[0][:, 2]
        cd = np.cumsum(np.where(wh < 0, -wh, 0) * 2 * np.pi * RHO_FAR * np.gradient(RHO_FAR))
        cu = np.cumsum(np.where(wh > 0, wh, 0) * 2 * np.pi * RHO_FAR * np.gradient(RHO_FAR))
        r50 = float(RHO_FAR[np.searchsorted(cd, 0.5 * cd[-1])]); r90 = float(RHO_FAR[np.searchsorted(cd, 0.9 * cd[-1])])
        r_up = float(RHO_FAR[np.searchsorted(cu, 0.99 * cu[-1])])
        uc, dc = plane_flux(lambda rho: cur_w_ray(zeta * ZI, rho)[0])
        # интеграл по времени (объём, перенесённый через уровень), шаг 30 с
        ts2 = np.arange(15, T_END - 5, 30.0); ups = []; dns = []
        for t in ts2:
            s_ = bb.state(SRC, ENV0, float(t))
            if s_ is None:
                ups.append(0.0); dns.append(0.0); continue
            u, d = plane_flux(lambda rho: ray(s_, zeta * ZI, rho)[0][:, 2])
            ups.append(u); dns.append(d)
        flux[str(zeta)] = {"head_level": {"t": th_, "r_up99_m": r_up, "r50_down_m": r50, "r90_down_m": r90,
                                          "up": float(cu[-1]), "down": float(-cd[-1])},
                           "series": rows, "current": {"up": uc, "down": dc, "net": uc + dc},
                           "bubble_time_integral": {"up_m3": float(np.trapezoid(ups, ts2)),
                                                    "down_m3": float(np.trapezoid(dns, ts2))}}
    details["mass_flux"] = flux

    # чувствительность к b0 и tau
    def zb(zeta):
        return 0.102 * zeta ** (1 / 3) * (1 - 0.25 * zeta) * ZL

    sens = []
    variants = [("base", SRC)] + [(f"zeta_b0={z}", dataclasses.replace(SRC, b0=zb(z))) for z in (0.05, 0.2)] + \
               [(f"tau x{f}", dataclasses.replace(SRC, tau=SRC.tau * f)) for f in (0.6, 1.4)] + \
               [("F0 = весь поток водосбора (v2, без доли ядра)", dataclasses.replace(SRC, F0=SRC.F0 / bb.PARAMS["core_flux_fraction"]["value"]))]
    for name, s_ in variants:
        te = life_end(s_)
        ts = np.arange(30.0, te - 1.0, 30.0)
        rr = scan_single(s_, ts, np.array([0.25, 0.35, 0.5]), np.array([10.0, 30.0, 50.0, 100.0, 140.0]),
                         np.array([0.9]), np.array([0.5]), rho=RHO[::2])
        sens.append({"name": name, "b0": s_.b0, "tau": s_.tau, "T_end": te,
                     "near_ground_vmax_ms": float(rr["ground_vmax"].max()),
                     "near_ground_vmax_over_wstar": float(rr["ground_vmax"].max() / WSTAR),
                     "inflow_ground_over_wstar": float(rr["ground_in"].max() / WSTAR),
                     "w_core_max_over_wstar": float(rr["core"].max(axis=0).mean() / WSTAR),
                     "w_core_max_at_each_zeta": (rr["core"].max(axis=0) / WSTAR).tolist(),
                     "U_start": float(bb.state(s_, ENV0, 10.0).U), "ring_min_over_wstar": float(rr["ring"].min() / WSTAR)})
    details["sensitivity"] = sens
    # b0-вариант 0.1 — это база: zeta_b0 = 0.1 даёт b0 = 64.6
    details["sensitivity_note"] = "base: zeta_b0 = 0,1 (b0 = 64,6 м), tau = 690 с; near_ground_vmax — max |v| при z ≤ 50 м для base-серии: z ∈ {10,30,50,100,140}"

    # ------------------------------------------------ 2. дивергенция суммы с ветром
    divs = {}
    worst_p99 = 0.0; worst_flux = 0.0
    for name, fn in (("const", wind_const), ("shear", wind_shear)):
        for tt in (60.0, 300.0, 600.0, 690.0, 900.0, 1500.0, 2400.0):
            s_ = bb.state(SRC, ENV0, tt)
            if s_ is None:
                continue
            r = div_checks([s_], fn)
            divs[f"single_{name}_t{int(tt)}"] = {k: r[k] for k in ("p99_rel", "flux_rel", "flux_rel_total_wind")}
            worst_p99 = max(worst_p99, r["p99_rel"]); worst_flux = max(worst_flux, r["flux_rel"])

    # ------------------------------------------------ 3. несколько термиков
    d_sp = np.sqrt(2.0 / (np.sqrt(3.0) * NA))        # шаг шестиугольной решётки с плотностью n_A
    sites, h = layout_sites(d_sp)
    n_src = len(sites)
    ages_all = (np.arange(n_src) + 0.5) / n_src * T_END
    rng = np.random.default_rng(0)
    perm0 = rng.permutation(n_src)
    ages0 = ages_all[perm0]
    T = float(T_END)                                   # момент «все живы»: старший ещё жив (age < T_END)
    states_multi = multi_states(sites, ages0, T)
    for name, fn in (("const", wind_const), ("shear", wind_shear)):
        r = div_checks(states_multi, fn, seed=1)
        divs[f"multi_{name}"] = {k: r[k] for k in ("p99_rel", "flux_rel", "flux_rel_total_wind")}
        worst_p99 = max(worst_p99, r["p99_rel"]); worst_flux = max(worst_flux, r["flux_rel"])
    # линейность (контракт: 1e-9)
    Pt = np.stack([rng.uniform(-300, 2 * d_sp + 300, 2000), rng.uniform(-300, h + 300, 2000), rng.uniform(1, ZI - 1, 2000)], -1)
    vs = bb.velocity(Pt, states_multi, ENV0)
    vsum = sum(bb.velocity(Pt, [s_], ENV0) for s_ in states_multi)
    lin = float(np.abs(vs - vsum).max() / np.abs(vs).max())
    details["div"] = divs
    details["multi_linearity_rel"] = lin
    details["layout"] = {"n": n_src, "spacing_nn_m": d_sp, "mean_spacing_sqrt_1_over_nA_m": float(np.sqrt(1 / NA)),
                         "sites": sites.tolist(), "ages_s": ages0.tolist(), "T_all_alive_s": T,
                         "amplitude_note": "возраст i-го = (i+0,5)/6 · T_жизни; перестановка по узлам seed 0"}

    # поля раскладки: 36 пар (узел, возраст) на сетке ζ=0.5 и на z=30 м, периодическая ячейка 3d x 2h
    nx, ny = 45, 30
    Lx, Ly = 3 * d_sp, 2 * h
    gx = (np.arange(nx) + 0.5) / nx * Lx; gy = (np.arange(ny) + 0.5) / ny * Ly
    GX, GY = np.meshgrid(gx, gy, indexing="ij")

    def pair_field_per(site_xy, age, z, periodic):
        s_ = bb.from_game(0.0, 0.0, T - age, WSTAR, ZL, ENV0)
        st_ = bb.state(s_, ENV0, T)
        acc = np.zeros(GX.shape + (3,))
        shifts = [(i * Lx, j * Ly) for i in (-1, 0, 1) for j in (-1, 0, 1)] if periodic else [(0, 0)]
        for sx, sy in shifts:
            P = np.stack([GX - site_xy[0] - sx, GY - site_xy[1] - sy, np.full(GX.shape, z)], -1)
            P[..., 0] += st_.xc; P[..., 1] += st_.yc
            acc += bb.velocity(P, [st_], ENV0)
        return acc

    cache_p = {}; cache_f = {}
    for si in range(n_src):
        for ai in range(n_src):
            cache_p[(si, ai)] = pair_field_per(sites[si], ages_all[ai], 0.5 * ZI, True)
            cache_f[(si, ai)] = pair_field_per(sites[si], ages_all[ai], 0.5 * ZI, False)
    fr_p = []; fr_f = []; mw_p = []; wmin_p = []
    THR = (0.0, 0.02, 0.05, 0.1)                       # порог w в долях w*
    fr_thr = {th: [] for th in THR}
    for k in range(120):
        pm = np.arange(n_src) if k == 0 else rng.permutation(n_src)
        Wp = sum(cache_p[(si, pm[si])][..., 2] for si in range(n_src))
        for th in THR:
            fr_thr[th].append(float((Wp > th * WSTAR).mean()))
        fr_p.append(float((Wp > 0).mean())); mw_p.append(float(Wp.mean())); wmin_p.append(float(Wp.min()))
        # непериодическая раскладка: центральный прямоугольник [d/2, 5d/2] x [0, h]  (в нём 2 узла «весом»)
        Wf = sum(cache_f[(si, pm[si])][..., 2] for si in range(n_src))
        m = (GX >= d_sp / 2) & (GX <= 5 * d_sp / 2) & (GY <= h + 0.0)
        fr_f.append(float((Wf[m] > 0).mean()))
    # фактическая перестановка perm0
    Wp0 = sum(cache_p[(si, perm0[si])][..., 2] for si in range(n_src))
    # то же у нынешней: все ядра Аллена на ζ=0.5 на узлах решётки (периодическая)
    Wc = np.zeros(GX.shape)
    for sx in (-1, 0, 1):
        for sy in (-1, 0, 1):
            for (x, y) in sites:
                P = np.stack([GX - x - sx * Lx, GY - y - sy * Ly, np.full(GX.shape, 0.5 * ZI)], -1)
                Wc += cur.current_w(P, top=ZL, R=RA, w0=W0A)
    fr_cur = float((Wc > 0).mean())
    fr_cur_thr = {str(th): float((Wc > th * WSTAR).mean()) for th in THR}
    updraft = {"bubble_mean_periodic": float(np.mean(fr_p)), "bubble_p05": float(np.percentile(fr_p, 5)),
               "bubble_p95": float(np.percentile(fr_p, 95)), "bubble_perm0": float((Wp0 > 0).mean()),
               "bubble_patch_mean": float(np.mean(fr_f)), "current_periodic": fr_cur,
               "mean_w_cell_periodic_over_wstar": float(np.mean(mw_p) / WSTAR),
               "min_w_cell_zeta05_over_wstar_mean_over_perms": float(np.mean(wmin_p) / WSTAR),
               "current_min_w_cell_over_wstar": float(Wc.min() / WSTAR),
               "current_mean_w_cell_over_wstar": float(Wc.mean() / WSTAR),
               "bubble_mean_by_threshold_over_wstar": {str(th): float(np.mean(v)) for th, v in fr_thr.items()},
               "current_by_threshold_over_wstar": fr_cur_thr,
               "grid": [nx, ny], "cell_m": [Lx, Ly], "n_perms": 120}

    # взаимодействие пары: два соседа d, одинаковый возраст 300 с
    pair_age = 300.0
    pair_sites = np.array([[0.0, 0.0], [d_sp, 0.0]])
    stp = multi_states(pair_sites, [pair_age, pair_age], pair_age + 1.0)
    st1 = [stp[0]]
    # st.xc от from_game(x,..,t0): xc = x, так как wind=0
    def sum_vs_one(pts, st_list):
        return bb.velocity(pts, st_list, ENV0)

    line = np.stack([np.linspace(-300, d_sp + 300, 121), np.zeros(121), np.full(121, 30.0)], -1)
    # приток к оси 0: на стороне соседа (x>0) и с противоположной (x<0), на радиусе максимального притока
    best_r = None; best_in = 0
    for r_ in np.linspace(10, 250, 49):
        u_ = float(-bb.velocity(np.array([[r_, 0.0, 30.0]]), st1, ENV0)[0, 0])
        if u_ > best_in:
            best_in, best_r = u_, float(r_)
    in_nb_pair = float(-bb.velocity(np.array([[best_r, 0.0, 30.0]]), stp, ENV0)[0, 0])   # к оси 0 со стороны соседа (x>0)
    in_far_pair = float(bb.velocity(np.array([[-best_r, 0.0, 30.0]]), stp, ENV0)[0, 0])  # x<0, течёт в +x к оси
    mid = np.array([[d_sp / 2, 0.0, 30.0]])
    vmid = bb.velocity(mid, stp, ENV0)[0]
    vmid1 = bb.velocity(mid, st1, ENV0)[0]
    mid5 = np.array([[d_sp / 2, 0.0, 0.5 * ZI]])
    w_mid5 = float(bb.velocity(mid5, stp, ENV0)[0, 2]); w_mid5_1 = float(bb.velocity(mid5, st1, ENV0)[0, 2])
    ln5 = np.stack([np.linspace(-300, d_sp + 300, 241), np.zeros(241), np.full(241, 0.5 * ZI)], -1)
    wl_pair = bb.velocity(ln5, stp, ENV0)[:, 2]; wl_one = bb.velocity(ln5, st1, ENV0)[:, 2]
    # также в момент прохода головы через 0,5 (t = head_time): пара с головой на ζ=0.5
    th5 = head_time(0.5)
    stp5 = multi_states(pair_sites, [th5, th5], th5 + 1e-3)
    ln5b = np.stack([np.linspace(-400, d_sp + 400, 241), np.zeros(241), np.full(241, bb.state(SRC, ENV0, th5).zc)], -1)
    wl_pair5 = bb.velocity(ln5b, stp5, ENV0)[:, 2]; wl_one5 = bb.velocity(ln5b, [stp5[0]], ENV0)[:, 2]
    mid_x = d_sp / 2
    j_mid = int(np.argmin(np.abs(ln5b[:, 0] - mid_x)))
    # горизонтальная сходимость на 30 м в середине (∂u/∂x + ∂v/∂y центральными разностями)
    def hdiv(pt, st_list, hh=2.0):
        pt = np.array(pt, float)
        a = bb.velocity(np.array([pt + [hh, 0, 0], pt - [hh, 0, 0], pt + [0, hh, 0], pt - [0, hh, 0]]), st_list, ENV0)
        return float((a[0, 0] - a[1, 0] + a[2, 1] - a[3, 1]) / (2 * hh))
    # поле на z=30 м в ячейке для 6 термиков: max |u_h| и сравнение с одиночным
    cache_g = {}
    for si in range(n_src):
        for ai in range(n_src):
            cache_g[(si, ai)] = pair_field_per(sites[si], ages_all[ai], 30.0, True)
    Ug = sum(cache_g[(si, perm0[si])] for si in range(n_src))
    uh = np.hypot(Ug[..., 0], Ug[..., 1])
    # одиночный (сумма по периодическим образам одного узла, самый сильный возраст) — без соседей
    one_g = max(float(np.hypot(*(pair_field_per(sites[0], a, 30.0, False)[..., :2].transpose(2, 0, 1))).max()) for a in ages_all)
    inter = {
        "pair_age_s": pair_age, "pair_distance_m": d_sp,
        "r_of_max_inflow_isolated_z30_m": best_r, "inflow_isolated_ms": best_in,
        "inflow_toward_axis_from_neighbor_side_ms": in_nb_pair, "inflow_toward_axis_from_far_side_ms": in_far_pair,
        "midpoint_z30_v_pair_ms": vmid.tolist(), "midpoint_z30_v_one_ms": vmid1.tolist(),
        "midpoint_z30_hdiv_pair_1_per_s": hdiv(list(mid[0]), stp), "midpoint_z30_hdiv_one_1_per_s": hdiv(list(mid[0]), st1),
        "w_mid_zeta05_pair_ms": w_mid5, "w_mid_zeta05_one_ms": w_mid5_1,
        "line_zeta05_w_min_pair_ms": float(wl_pair.min()), "line_zeta05_w_min_one_ms": float(wl_one.min()),
        "head_level_line_w_mid_pair_ms": float(wl_pair5[j_mid]), "head_level_line_w_mid_one_ms": float(wl_one5[j_mid]),
        "head_level_line_w_min_pair_ms": float(wl_pair5.min()), "head_level_line_w_min_one_ms": float(wl_one5.min()),
        "cell_z30_max_uh_6_ms": float(uh.max()), "cell_z30_max_uh_one_ms": one_g,
        "cell_z30_uh_p50_ms": float(np.median(uh)), "cell_z30_stagnation_frac_below_0p2ms": float((uh < 0.2).mean()),
        "updraft": updraft}
    details["interaction"] = inter

    # ------------------------------------------------ rows
    row_core_note = (f"Шаблон: max по жизни и по ρ w на ζ = 0,23…0,50 (7 уровней), среднее по уровням; пик на оси головы/шлейфа "
                     f"(t пика 60…{int(core_t_at.max())} с). Нынешняя: current_w(allen_core) = w0 = 1,24 w* на оси × vert, тот же ζ, "
                     f"среднее по 7 уровням (top = z_l). Литература: пик ядра 1–2 w* (пересказ, low), "
                     f"средний подъём ŵ = 0,45 w* — другая величина (среднее по термику; шаблон: среднее по диску w>0 "
                     f"в момент пика = {np.mean(wmean_at_max)/WSTAR:.2f} w*, нынешняя = {np.mean([x for x in cur_mean if x])/WSTAR:.2f} w*).")
    rows = [
        {"quantity": "w_core_max_over_wstar", "unit": "w*", "bubble": w_core_max, "current": w_core_cur,
         "literature": None, "lit_range": [1.0, 2.0], "source": "Lenschow & Stephens 1980 (пик ядра 1–2 w* — по пересказу docs/guide/air-model/thermals.md, low); Allen 2006",
         "note": row_core_note},
        {"quantity": "core_radius_over_zi", "unit": "z_i", "bubble": r0_b / ZI, "current": r0_c / ZI,
         "literature": 0.0555, "lit_range": [0.036, 0.09],
         "source": "Lenschow & Stephens 1980: d/z_i = 0,16 ζ^⅓(1−0,25ζ) ⇒ радиус 0,0555 z_i при ζ = 0,5 (high); Allen 2006 r₂ = 0,071 z_i; Ansmann et al. 2010 (лидар) 0,08–0,09 z_i. v3: α_thermal шаблона подогнан к L&S МНК на ζ 0,2–0,8 (привязка к измерению, не подгонка под этот ряд)",
         "note": f"Радиус первой смены знака w (+ → −) на ζ = 0,5 в момент, когда центр головы на этом уровне (t = {prof[0.5]['t_head']:.0f} с, R головы = {prof[0.5]['R_head']:.0f} м); "
                 f"нынешняя: x = 1 гауссианы Гедеона на ζ = 0,5 (r = R·rf). Определение одинаково для обеих и для литературы (радиус ядра = полуширина d/2 условной выборки ≈ радиус смены знака w; у шаблона — на экваторе головы). "
                 f"ζ = 0,25: шаблон {prof[0.25]['r0_bubble']/ZI:.3f}, нынешняя {prof[0.25]['r0_current']/ZI:.3f}; ζ = 0,75: шаблон {prof[0.75]['r0_bubble']/ZI:.3f}, нынешняя {prof[0.75]['r0_current']/ZI:.3f} z_i."},
        {"quantity": "rise_speed_over_wstar", "unit": "w*", "bubble": rise_05, "current": None, "literature": None,
         "lit_range": None, "source": "числа нет: Scorer 1957 / Turner 1973 — теория, но не измерение в CBL; Ansmann 2010: w воздуха в апдрафте 0,4–0,5 м/с (100–200 м), ~1,5 м/с (>600 м) — не скорость вершины",
         "note": f"Шаблон: U центра головы при zc = 0,5 z_i (t = {i05:.0f} с). Средняя за подъём до 90 % конечной высоты: {U_mean_w:.2f} w*; старт {details['single']['rise']['U_start']/WSTAR:.2f} w*. "
                 "У нынешней модели головы нет — это столб с фиксированным ядром; скорости подъёма как величины нет (null). Литературного числа нет (null)."},
        {"quantity": "inflow_ground_over_wstar", "unit": "w*", "bubble": inflow, "current": 0.0, "literature": None,
         "lit_range": None, "source": "числа нет: Schmidt & Schumann 1989 показывают радиальное втекание («спицы») качественно; тексты закрыты",
         "note": f"Шаблон: max радиального притока к оси по ρ и по жизни на z = 10–50 м, максимум на z = {max(inflow_by_z, key=inflow_by_z.get)} м, t = {t_gi:.0f} с. "
                 "Нынешняя: горизонтальной скорости нет (только w) ⇒ 0 по построению. Литература — только качественно (null)."},
        {"quantity": "outflow_top_over_wstar", "unit": "w*", "bubble": outflow, "current": 0.0, "literature": None,
         "lit_range": None, "source": "числа нет: растекание под инверсией качественно (Schmidt & Schumann 1989); тексты закрыты",
         "note": f"Шаблон: max радиального растекания на ζ = 0,85–0,95, t = {t_to:.0f} с. Нынешняя: 0 (нет горизонтальной скорости). Литература — null."},
        {"quantity": "ring_sink_min_over_wstar", "unit": "w*", "bubble": ring_min, "current": ring_cur, "literature": None,
         "lit_range": None, "source": "числа нет: Young 1988, Schumann & Moeng 1991 — тексты закрыты; Ansmann 2010: нисходящие шире подъёмов в 1,3–1,5 раза, слабее по среднему w (не пик)",
         "note": f"Одинаково для обеих: min w по ρ и по ζ = 0,3…0,8 (6 уровней); шаблон — минимум по жизни (t = {t_ring:.0f} с). "
                 "Нынешняя: кольцо Гедеона × 1,6 (ring_sink_factor — подбор игры). Для сравнения: по уровням см. compare.md."},
        {"quantity": "updraft_area_fraction", "unit": "1", "bubble": updraft["bubble_mean_periodic"], "current": fr_cur,
         "literature": 0.35, "lit_range": [0.3, 0.4],
         "source": "Lenschow & Stephens 1980; Stull 1988 гл. 4 (0,3–0,4, воздух подъёма — по пересказу thermals.md, medium); Ansmann 2010 (лидар): 30–34 % времени; ядра Аллена 2006 ≈ 0,13",
         "note": f"Доля площади w > 0 на ζ = 0,5, периодическая ячейка 3d × 2h из 6 термиков на шестиугольной решётке с плотностью n_A = 8,5/z_l² (d = {d_sp:.0f} м), "
                 f"возрасты (i+0,5)/6 жизни, среднее по 120 перестановкам [p5…p95: {updraft['bubble_p05']:.2f}…{updraft['bubble_p95']:.2f}]. Нынешняя: те же узлы, current_w(allen_core), "
                 "все ядра одной фазы (нет жизни по возрасту). Литература — доля воздуха подъёма (не ядер), поэтому 0,13 текущей — по построению ядра Аллена."},
    ]
    case = {"wstar": WSTAR, "zi": ZI, "zl": ZL, "wind": [WIND, 0.0], "wind_shear": {"z0": Z0, "U": WIND},
            "source": dataclasses.asdict(SRC), "allen": {"R_top": RA, "w0": W0A, "n_A": NA},
            "layout": details["layout"], "frame": "система воздуха (поле пузыря сносится ветром целиком; горизонтальные величины от ветра не зависят — sanity)",
            "bubble_params": {k: v["value"] for k, v in bb.PARAMS.items()}}

    # ------------------------------------------------ 4. разрезы
    cmap = "RdBu_r"
    VMAX = 5.0

    def xz_panel(ax, st_, wfn, vfn, X, Z, vmax=VMAX, quiver=True):
        XX, ZZ = np.meshgrid(X, Z, indexing="xy")
        W = wfn(XX, ZZ)
        im = ax.pcolormesh(XX, ZZ, W, cmap=cmap, norm=TwoSlopeNorm(0.0, -vmax, vmax), shading="auto", rasterized=True)
        if quiver and vfn is not None:
            qs = (slice(None, None, 8), slice(None, None, 8))
            V = vfn(XX[qs], ZZ[qs])
            ax.quiver(XX[qs], ZZ[qs], V[..., 0], V[..., 2], color="k", width=0.002, scale=60, pivot="mid")
        return im

    X = np.linspace(-700, 700, 141); Zg = np.linspace(2, 1398, 140)
    tfig = [60.0, 300.0, 600.0, 900.0]
    fig, axs = plt.subplots(1, 4, figsize=(16, 5.2), sharey=True)
    for ax, t in zip(axs, tfig):
        s_ = bb.state(SRC, ENV0, t)
        def vf(XX, ZZ, s_=s_):
            P = np.stack([s_.xc + XX, np.zeros_like(XX), ZZ], -1)
            return bb.velocity(P, [s_], ENV0)
        im = xz_panel(ax, s_, lambda XX, ZZ, vf=vf: vf(XX, ZZ)[..., 2], vf, X, Zg)
        ax.set_title(f"t = {t:.0f} с, центр {s_.zc:.0f} м, R = {s_.R:.0f} м, U = {s_.U:.2f} м/с"); ax.set_xlabel("x от оси, м")
        ax.set_aspect("equal"); ax.axhline(ZI, color="g", lw=0.8)
    axs[0].set_ylabel("высота z, м")
    fig.colorbar(im, ax=axs, shrink=0.8, label="w, м/с (стрелки — (u, w))")
    fig.suptitle(f"Шаблон пузыря: разрез x–z через ось, w* = {WSTAR} м/с, z_i = {ZI:.0f} м")
    p = FIGDIR / "tb5_1_template_xz.png"; fig.savefig(p, dpi=110); plt.close(fig); figures.append(str(p))

    # 2. нынешняя модель: столб растёт вслед за шаблоном (top = верх головы шаблона в тот же момент)
    fig, axs = plt.subplots(1, 4, figsize=(16, 5.2), sharey=True)
    for ax, t in zip(axs, tfig):
        s_ = bb.state(SRC, ENV0, t)
        top = min(ZI, s_.zc + s_.R)
        def wf(XX, ZZ, top=top):
            P = np.stack([XX, np.zeros_like(XX), ZZ], -1)
            return cur.current_w(P, top=top, R=RA, w0=W0A)
        im = xz_panel(ax, s_, wf, None, X, Zg, quiver=False)
        ax.set_title(f"t = {t:.0f} с, верх столба {top:.0f} м"); ax.set_xlabel("x от оси, м"); ax.set_aspect("equal")
        ax.axhline(ZI, color="g", lw=0.8)
    axs[0].set_ylabel("высота z, м")
    fig.colorbar(im, ax=axs, shrink=0.8, label="w, м/с (та же шкала)")
    fig.suptitle("Нынешняя модель (Гедеон/Аллен): столб, верх = верх головы шаблона в тот же момент; горизонтальной скорости нет")
    p = FIGDIR / "tb5_2_current_xz.png"; fig.savefig(p, dpi=110); plt.close(fig); figures.append(str(p))

    # 3. горизонтальные: z = 30 м в момент максимума притока; ζ = 0.9 в момент максимума растекания
    XY = np.linspace(-700, 700, 71)
    fig, axs = plt.subplots(1, 2, figsize=(13, 6))
    for ax, (t, z, ttl) in zip(axs, ((t_gi, 30.0, f"z = 30 м (приток), t = {t_gi:.0f} с"), (t_to, 0.9 * ZI, f"ζ = 0,9 (растекание), t = {t_to:.0f} с"))):
        s_ = bb.state(SRC, ENV0, t)
        XXg, YYg = np.meshgrid(XY, XY, indexing="xy")
        P = np.stack([s_.xc + XXg, s_.yc + YYg, np.full(XXg.shape, z)], -1)
        v = bb.velocity(P, [s_], ENV0)
        vm = max(1.0, float(np.abs(v[..., 2]).max()))
        im = ax.pcolormesh(XXg, YYg, v[..., 2], cmap=cmap, norm=TwoSlopeNorm(0.0, -vm, vm), shading="auto", rasterized=True)
        ax.quiver(XXg[::3, ::3], YYg[::3, ::3], v[::3, ::3, 0], v[::3, ::3, 1], color="k", width=0.002, pivot="mid")
        ax.set_aspect("equal"); ax.set_xlabel("x, м"); ax.set_ylabel("y, м")
        uh_ = np.hypot(v[..., 0], v[..., 1]).max()
        ax.set_title(ttl + f"\nmax |(u, v)| = {uh_:.2f} м/с")
        fig.colorbar(im, ax=ax, shrink=0.8, label="w, м/с")
    fig.suptitle("Шаблон: горизонтальные сечения, цвет w, стрелки (u, v) — к оси у земли, от оси у верха")
    p = FIGDIR / "tb5_3_template_horizontal.png"; fig.savefig(p, dpi=110); plt.close(fig); figures.append(str(p))

    # 4. несколько термиков (6, непериодично): x–z через ряд y=0 и y=h; горизонталь ζ=0.5 и z=30 м
    Xm = np.linspace(-500, 2 * d_sp + 500, 160); Zm = np.linspace(2, 1398, 120)
    fig, axs = plt.subplots(2, 2, figsize=(15, 9.5))
    for ax, yy, ttl in ((axs[0, 0], 0.0, "x–z, ряд y = 0 (узлы 0, d, 2d)"), (axs[0, 1], h, "x–z, ряд y = h")):
        XXm, ZZm = np.meshgrid(Xm, Zm, indexing="xy")
        P = np.stack([XXm, np.full(XXm.shape, yy), ZZm], -1)
        v = bb.velocity(P, states_multi, ENV0)
        im = ax.pcolormesh(XXm, ZZm, v[..., 2], cmap=cmap, norm=TwoSlopeNorm(0.0, -VMAX, VMAX), shading="auto", rasterized=True)
        ax.quiver(XXm[::8, ::8], ZZm[::8, ::8], v[::8, ::8, 0], v[::8, ::8, 2], color="k", width=0.0018, scale=90, pivot="mid")
        ax.axhline(ZI, color="g", lw=0.8)
        ax.set_title(ttl + f"; t = {T:.0f} с, возрасты {np.round(ages0).astype(int).tolist()} с"); ax.set_xlabel("x, м"); ax.set_ylabel("z, м")
        for (sx, sy), s_ in zip(sites, states_multi):
            if abs(sy - yy) < 1.0:
                ax.plot([sx], [0], "k^")
    fig.colorbar(im, ax=axs[0, :], shrink=0.8, label="w, м/с")
    XYm = np.linspace(-500, 2 * d_sp + 500, 160); YYm = np.linspace(-500, h + 500, 80)
    XXh, YYh = np.meshgrid(XYm, YYm, indexing="xy")
    for ax, z, ttl in ((axs[1, 0], 0.5 * ZI, "ζ = 0,5"), (axs[1, 1], 30.0, "z = 30 м")):
        P = np.stack([XXh, YYh, np.full(XXh.shape, z)], -1)
        v = bb.velocity(P, states_multi, ENV0)
        vm = VMAX if z > 100 else max(1.0, float(np.abs(v[..., 2]).max()))
        im = ax.pcolormesh(XXh, YYh, v[..., 2], cmap=cmap, norm=TwoSlopeNorm(0.0, -vm, vm), shading="auto", rasterized=True)
        ax.quiver(XXh[::5, ::5], YYh[::5, ::5], v[::5, ::5, 0], v[::5, ::5, 1], color="k", width=0.0018, pivot="mid")
        ax.plot(sites[:, 0], sites[:, 1], "k^"); ax.set_aspect("equal"); ax.set_title(ttl + "; цвет w, стрелки (u, v)")
        ax.set_xlabel("x, м"); ax.set_ylabel("y, м"); fig.colorbar(im, ax=ax, shrink=0.8, label="w, м/с")
    fig.suptitle(f"Шесть термиков на решётке n_A = 8,5/z_l² (шаг {d_sp:.0f} м), фазы по возрасту, момент «все живы»")
    p = FIGDIR / "tb5_4_multi.png"; fig.savefig(p, dpi=105); plt.close(fig); figures.append(str(p))

    # 5. профили w(r) на ζ = 0.25/0.5/0.75 шаблон vs нынешняя; поток массы через ζ=0.5 во времени
    fig, axs = plt.subplots(1, 4, figsize=(17, 4.4))
    for ax, zeta in zip(axs[:3], (0.25, 0.5, 0.75)):
        d = prof[zeta]; rho = np.array(d["rho"])
        ax.plot(rho, np.array(d["w_bubble"]) / WSTAR, label=f"шаблон (голова на уровне, t = {d['t_head']:.0f} с)")
        ax.plot(rho, np.array(d["w_current"]) / WSTAR, "--", label="нынешняя (Гедеон, Аллен)")
        ax.axhline(0, color="gray", lw=0.5); ax.set_xlim(0, 700); ax.set_xlabel("ρ, м"); ax.set_ylabel("w / w*")
        ax.set_title(f"ζ = {zeta}"); ax.legend(fontsize=7)
    ser = flux["0.5"]["series"]
    axs[3].plot([r["t"] for r in ser], [r["up"] for r in ser], label="вверх (шаблон)")
    axs[3].plot([r["t"] for r in ser], [r["down"] for r in ser], label="вниз (шаблон)")
    axs[3].axhline(flux["0.5"]["current"]["up"], color="C0", ls="--", label="вверх (нынешняя)")
    axs[3].axhline(flux["0.5"]["current"]["down"], color="C1", ls="--", label="вниз (нынешняя)")
    axs[3].set_xlabel("t, с"); axs[3].set_ylabel("поток через ζ = 0,5, м³/с"); axs[3].legend(fontsize=7)
    fig.suptitle("Профиль w(ρ) в ядре и поток массы через уровень (один термик)")
    p = FIGDIR / "tb5_5_profiles_flux.png"; fig.tight_layout(); fig.savefig(p, dpi=110); plt.close(fig); figures.append(str(p))

    # ------------------------------------------------ вывод
    result = {"format": "tb-compare", "version": 1, "case": case, "rows": rows,
              "div": {"p99_rel": worst_p99, "flux_rel": worst_flux, "detail": divs},
              "figures": figures, "details": details, "runtime_s": time.time() - t_start}
    tmp = OUT / "compare.json.tmp"
    tmp.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    os.replace(tmp, OUT / "compare.json")
    print(f"compare.json: div p99 = {worst_p99:.3g}, flux = {worst_flux:.3g}; {len(figures)} рисунков; {time.time() - t_start:.0f} с")
    return 0


if __name__ == "__main__":
    sys.exit(main())
