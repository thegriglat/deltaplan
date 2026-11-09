#!/usr/bin/env python3
"""LT-5: прототип модели слоя смешения за гребнем на разрезах LTS v1 (numpy + stdlib).

  python3 -I proto.py --selftest                       # без внешних данных
  python3 -I proto.py --sections DIR --out out/         # 18 разрезов LT-2 -> out/sections.json, sections.csv

Модель — spec.json (константы и формулы); всё вычисление здесь. Единицы СИ; x — от гребня по ветру, y — высота MSL.
"""
import argparse, csv, glob, json, math, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(os.path.join(HERE, "spec.json"), encoding="utf-8"))
K = {c["name"]: c["value"] for c in SPEC["constants"]}
KAPPA = 0.4


def smoothstep(a, b, x):
    t = np.clip((np.asarray(x, float) - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- геометрия гребня
def crest_params(g_at, x_p, k=K):
    """Гребень и параметры слоя для точки на расстоянии x_p от начала луча.
    g_at(d) — высота земли вдоль луча (d — координата по ветру, м, любая; ветер в сторону +d).
    Возвращает dict или None (гребня нет). Опрос высот: луч против ветра шагом crest_step_m."""
    step = k["crest_step_m"]
    offs = np.concatenate([np.arange(0.0, k["crest_near_m"] + 1e-9, step),
                           np.arange(k["crest_near_m"] + k["crest_step_far_m"], k["crest_search_m"] + 1e-9, k["crest_step_far_m"])])
    ds = x_p - offs                                   # d = x_p, x_p-50, ... (против ветра)
    hs = np.array([g_at(d) for d in ds])
    h_p = hs[0]
    i, m = 0, hs[0]
    for j in range(1, len(hs)):
        if hs[j] > m + 1e-9:
            i, m = j, hs[j]
        elif hs[j] < m - max(k["crest_drop_abs_m"], k["crest_drop_frac"] * (m - h_p)):
            break                                     # земля упала: максимум позади - гребень
    d_c, h_c = float(ds[i]), float(hs[i])
    if i == 0:
        return None                                   # выше всего против ветра: слоя нет
    df = d_c + step * np.arange(0, int(k["foot_search_m"] / step) + 1)
    foot = float(min(g_at(d) for d in df))
    H = h_c - foot
    if H <= 0:
        return None
    return dict(d_c=d_c, h_c=h_c, H=H, foot=foot, n_queries=len(ds) + len(df))


def bubble_from_field(xs, u_low, d_c, dx):
    """Длина пузыря по полю: первая связная область u<0 на xr_search_u_agl_m над землёй за гребнем.
    xs — координата вдоль ветра колонок, u_low — u_par на этой высоте. Возвращает (L, x_sep, x_att) или None."""
    m = (xs > d_c) & np.isfinite(u_low)
    idx = np.where(m)[0]
    neg = False
    start = None
    for i in idx:
        if u_low[i] < 0 and not neg:
            neg, start = True, xs[i]
        elif u_low[i] >= 0 and neg:
            return float(xs[i] - start), float(start - d_c), float(xs[i] - d_c)
    return None


def pick_xr(H, bub, dx, k=K):
    """x_r: эвристика ridge_xr_over_h·H, где поле пузыря не разрешает; плавно от 4 до 8 клеток к полю."""
    xr_h = k["ridge_xr_over_h"] * H
    if bub is None:
        return xr_h, 0.0
    L, _, att = bub
    r = float(smoothstep(k["bubble_resolved_cells_min"], k["bubble_resolved_cells"], L / dx))
    return r * att + (1.0 - r) * xr_h, r


# ---------------------------------------------------------------- слой
def layer_state(x, y, g_x, geo, xr, u1, u2, k=K, f_sep_force=None):
    """Величины слоя в точках (x, y). x, y — массивы одной формы; g_x — высота земли в x; u1, u2 — массивы или числа.
    Возвращает dict: dU, lam, delta, yc, eta, gx, ramp, w, sig{u,v,w}, L, f_sep."""
    H, h_c = geo["H"], geo["h_c"]
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    g_x = np.asarray(g_x, float)
    u1 = np.maximum(np.broadcast_to(np.asarray(u1, float), x.shape), 0.0)
    u2 = np.clip(np.broadcast_to(np.asarray(u2, float), x.shape), k["u2_min_over_u1"] * u1, u1)
    dU = u1 - u2
    lam = np.minimum(np.where(u1 + u2 > 1e-6, dU / np.maximum(u1 + u2, 1e-6), 0.0), k["lambda_max"])
    h_xr = geo["h_at_xr"]
    s_lee = (h_c - h_xr) / xr
    f_sep = float(smoothstep(k["lee_slope_on"], k["lee_slope_full"], s_lee)) if f_sep_force is None else f_sep_force
    xp = np.maximum(x, 0.0)
    xb = k["mix_slow_x_over_xr"] * xr
    delta = k["mix_delta0_over_h"] * H + k["mix_growth_per_lambda"] * lam * (
        np.minimum(xp, xb) + k["mix_slow_factor"] * np.maximum(xp - xb, 0.0))
    yc = np.maximum(h_c - (h_c - h_xr) * xp / xr, g_x + k["yc_end_over_h"] * H * np.minimum(xp / xr, 1.0))
    ramp = 1.0 - np.exp(-xp / (k["ramp_x_over_xr"] * xr))
    dec = np.exp(-np.maximum(xp - k["decay_x0_over_xr"] * xr, 0.0) / (k["decay_length_over_xr"] * xr))
    gx = ramp * dec
    on = (x > 0) & (u1 >= k["u1_min_ms"])
    eta = (y - yc) / (k["profile_sigma_over_delta"] * delta)
    G = np.exp(-0.5 * eta * eta)
    amp = np.where(on, f_sep * dU * gx * G, 0.0)
    w = np.where(on, f_sep * ramp * G, 0.0)
    return dict(dU=dU, lam=lam, delta=delta, yc=yc, eta=eta, gx=gx, ramp=ramp, w=w, f_sep=f_sep, s_lee=s_lee,
                sig_u=k["sigma_u_over_du"] * amp, sig_v=k["sigma_v_over_du"] * amp, sig_w=k["sigma_w_over_du"] * amp,
                L=k["eddy_scale_over_delta"] * delta, uc=0.5 * (u1 + u2), burst=k["burst_peak_sigmas"] * k["sigma_w_over_du"] * amp)


def mix_len(z, lam_m=None):
    lam_m = K["mech_lambda_m"] if lam_m is None else lam_m
    z = np.maximum(z, 1.0)
    return 1.0 / (1.0 / (KAPPA * z) + 1.0 / lam_m)


def combine(sig_old, from_mech, st, agl, k=K):
    """Новая σ: механика с l_эфф (если σ_old дала механика) и слой; max или корень суммы квадратов."""
    l = mix_len(agl)
    l_eff = l * (1 - st["w"]) + np.minimum(l, k["mix_len_over_delta"] * st["delta"]) * st["w"]
    mech = np.where(from_mech, sig_old * l_eff / l, sig_old)
    if k["combine_rule_power"] == 2:
        return np.sqrt(mech ** 2 + st["sig_w"] ** 2), l_eff
    return np.maximum(mech, st["sig_w"]), l_eff


# ---------------------------------------------------------------- LTS
def load_lts(path):
    with open(path, encoding="utf-8") as f:
        head = f.readline()
        rd = csv.DictReader(f)
        rows = list(rd)
    c = {}
    for kk in rd.fieldnames:
        c[kk] = np.array([r[kk] for r in rows]) if kk == "src" else np.array([float(r[kk]) if r[kk] != "" else np.nan for r in rows])
    s_u, y_u = np.unique(c["s"]), np.unique(c["y"])
    ii = np.searchsorted(s_u, c["s"])
    jj = np.searchsorted(y_u, c["y"])
    g = {}
    for kk, v in c.items():
        if kk in ("s", "y"):
            continue
        a = np.full((len(s_u), len(y_u)), "" if kk == "src" else np.nan, dtype=object if kk == "src" else float)
        a[ii, jj] = v
        g[kk] = a
    return head, s_u, y_u, g


def ground_of(g, y_u):
    out = np.full(g["agl"].shape[0], np.nan)
    for i in range(len(out)):
        ok = np.where(np.isfinite(g["agl"][i]))[0]
        if len(ok):
            out[i] = y_u[ok[0]] - g["agl"][i][ok[0]]
    return out


def col_interp(y_u, col, yq):
    ok = np.isfinite(col)
    if ok.sum() < 2:
        return np.nan
    tol = 1.5 * float(np.median(np.diff(y_u)))        # у самой земли допустим сдвиг на полтора шага сетки
    if yq < y_u[ok][0] - tol or yq > y_u[ok][-1]:
        return np.nan
    return float(np.interp(yq, y_u[ok], col[ok]))


def run_section(path, ridge, k=K, xr_fixed_over_h=None, power=None, u2_field=False):
    """Один разрез -> dict метрик и массивы новой σ. ridge: {'name','H','zone'} из имени/справочника (только H для осей)."""
    head, s_u, y_u, g = load_lts(path)
    gnd = ground_of(g, y_u)
    dx = float(ridge["zone"])          # клетка поля, м (50 / 100 / 400)
    kk = dict(k)
    if xr_fixed_over_h is not None:
        kk["ridge_xr_over_h"] = xr_fixed_over_h
    if power is not None:
        kk["combine_rule_power"] = power
    ok_col = np.isfinite(gnd)
    g_at = lambda d: float(np.interp(d, s_u[ok_col], gnd[ok_col]))
    # гребень секции: самый высокий в первой трети (линия идёт от -2H); параметры для x ниже по ветру — по лучу точки
    i_c = int(np.nanargmax(np.where(s_u < s_u[0] + 0.4 * (s_u[-1] - s_u[0]), gnd, -1e9)))
    s_c = float(s_u[i_c])
    geo_cache = {}
    ns, ny = g["agl"].shape
    sig_new = {n: np.full((ns, ny), np.nan) for n in ("u", "v", "w")}
    sig_old_w = g["sigma_w"].astype(float)
    sig_old_u = g["sigma_u"].astype(float)
    layer_sw = np.full((ns, ny), np.nan)
    delta_c = np.full(ns, np.nan); yc_c = np.full(ns, np.nan); dU_c = np.full(ns, np.nan); u1_c = np.full(ns, np.nan); u2_c = np.full(ns, np.nan)
    nq = 0
    info = dict(H=None)
    main = None
    for i in range(ns):
        if s_u[i] <= s_c:
            continue
        cp = crest_params(g_at, float(s_u[i]), kk)
        if cp is None:
            continue
        nq = max(nq, cp["n_queries"])
        key = round(cp["d_c"], 1)
        if key not in geo_cache:
            # пузырь по полю: колонки за гребнем, u_par на xr_search_u_agl_m над землёй
            u_low = np.array([_u_at_agl(g, j, kk["xr_search_u_agl_m"]) for j in range(ns)])
            bub = bubble_from_field(s_u, u_low, cp["d_c"], dx)
            xr, res = pick_xr(cp["H"], bub, dx, kk)
            cp["h_at_xr"] = g_at(cp["d_c"] + xr)
            cp["xr"], cp["res"], cp["bub"] = xr, res, bub
            cp["x_field"] = None if bub is None else bub
            geo_cache[key] = cp
        geo = geo_cache[key]
        info = geo
        if main is None and s_u[i] - geo["d_c"] > 0.05 * geo["H"] and abs(geo["d_c"] - s_c) < 3 * k["crest_step_m"]:
            main = geo
        x = s_u[i] - geo["d_c"]
        yy = y_u
        col_ok = np.isfinite(g["agl"][i])
        u1 = col_interp(y_u, g["u_par"][i], geo["h_c"])
        u2 = col_interp(y_u, g["u_par"][i], gnd[i] + kk["u2_height_over_h"] * geo["H"])
        if not (np.isfinite(u1) and np.isfinite(u2)):
            continue
        r = 1.0 if u2_field else geo["res"]      # u2_field - чувствительность: U2 всегда по полю
        u2 = r * u2 + (1.0 - r) * kk["u2_unresolved_over_u1"] * max(u1, 0.0)    # след: поле при r<1 занижает
        st = layer_state(np.full(ny, x), y_u, np.full(ny, gnd[i]), geo, geo["xr"], np.full(ny, u1), np.full(ny, u2), kk)
        agl = g["agl"][i]
        m = col_ok
        mech = (g["src"][i] == "mech")
        sw, _ = combine(np.where(m, sig_old_w[i], 0.0), mech, st, np.where(m, agl, 10.0), kk)
        k2 = dict(kk)
        st_u = dict(st); st_u["sig_w"] = st["sig_u"]
        su, _ = combine(np.where(m, sig_old_u[i], 0.0), mech, st_u, np.where(m, agl, 10.0), kk)
        sig_new["w"][i] = np.where(m, sw, np.nan)
        sig_new["u"][i] = np.where(m, su, np.nan)
        layer_sw[i] = np.where(m, st["sig_w"], np.nan)
        delta_c[i], dU_c[i], u1_c[i], u2_c[i] = st["delta"][0], st["dU"][0], u1, u2
        yc_c[i] = st["yc"][0]
    return dict(s=s_u, y=y_u, g=g, gnd=gnd, s_c=s_c, geo=main or info, sig_new=sig_new, layer_sw=layer_sw, delta=delta_c, yc=yc_c,
                dU=dU_c, u1=u1_c, u2=u2_c, dx=dx, n_queries=nq, head=head)


def _u_at_agl(g, j, agl_q):
    a, u = g["agl"][j], g["u_par"][j]
    ok = np.isfinite(a) & np.isfinite(u)
    if ok.sum() < 2 or agl_q < a[ok].min() or agl_q > a[ok].max():
        return np.nan
    o = np.argsort(a[ok])
    return float(np.interp(agl_q, a[ok][o], u[ok][o]))


# ---------------------------------------------------------------- метрики
def metrics(res, agl_lo=5.0, agl_hi=150.0, xh_max=12.0):
    s, y, g, gnd, geo = res["s"], res["y"], res["g"], res["gnd"], res["geo"]
    H, d_c, h_c = geo["H"], geo["d_c"], geo["h_c"]
    xh = (s - d_c) / H
    agl = g["agl"]
    out = dict(H=H, xr_over_h=geo["xr"] / H, xr_from_field=bool(geo["res"] > 0.5), bubble_res=geo["res"], s_lee=float((h_c - geo["h_at_xr"]) / geo["xr"]),
               f_sep=float(smoothstep(K["lee_slope_on"], K["lee_slope_full"], (h_c - geo["h_at_xr"]) / geo["xr"])), crest_msl=h_c)
    band = (agl >= agl_lo) & (agl <= agl_hi) & (xh[:, None] > 0.05) & (xh[:, None] <= xh_max)
    for tag, arr in (("old", g["sigma_w"].astype(float)), ("new", res["sig_new"]["w"])):
        a = np.where(band & np.isfinite(arr), arr, -1)
        i, j = np.unravel_index(int(np.argmax(a)), a.shape)
        out[tag + "_max"] = dict(sigma_w=float(arr[i, j]), xh=float(xh[i]), zc=float(y[j] - h_c), agl=float(agl[i, j]),
                                 src=str(g["src"][i, j]) if tag == "old" else None)
    # σ_w на гребне (x/H 0,5) и у присоединения: максимум по высоте agl 5..150 в колонке
    xr_h = geo["xr"] / H
    for tag, xq in (("crest05", 0.5), ("reatt", xr_h)):
        i = int(np.argmin(abs(xh - xq)))
        for nm, arr in (("old", g["sigma_w"].astype(float)), ("new", res["sig_new"]["w"])):
            col = np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), arr[i], np.nan)
            out[f"{nm}_sw_{tag}"] = float(np.nanmax(col)) if np.isfinite(col).any() else None
        out[f"xh_{tag}"] = float(xh[i])
    # σ_w/ΔU в слое: максимум по высоте у x = 0,64 x_r
    i_pk = int(np.argmin(abs(xh - K["decay_x0_over_xr"] * xr_h)))
    i = i_pk
    dU = res["dU"][i]
    for nm, arr in (("old", g["sigma_w"].astype(float)), ("new", res["sig_new"]["w"])):
        col = np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), arr[i], np.nan)
        out[f"{nm}_sw_over_dU_peak"] = float(np.nanmax(col) / dU) if np.isfinite(col).any() and dU > 0.5 else None
    # избыток над притоком (σ_w / σ_w притока на той же высоте над землёй) и станции
    levels = (20.0, 30.0, 50.0, 75.0, 100.0, 150.0)
    def at_levels(arr):
        o = np.full((arr.shape[0], len(levels)), np.nan)
        for i in range(arr.shape[0]):
            for q, lv in enumerate(levels):
                a, v = agl[i], arr[i]
                ok = np.isfinite(a) & np.isfinite(v)
                if ok.sum() >= 2 and a[ok].min() <= lv <= a[ok].max():
                    oo = np.argsort(a[ok]); o[i, q] = np.interp(lv, a[ok][oo], v[ok][oo])
        return o
    sw_old, sw_new = at_levels(g["sigma_w"].astype(float)), at_levels(res["sig_new"]["w"])
    up = (xh >= -2.0) & (xh <= -0.5)
    ref = np.nanmean(sw_old[up], axis=0)
    for nm, arr in (("old", sw_old), ("new", sw_new)):
        ex = arr / ref
        ex = np.where((xh[:, None] > 0.05) & (xh[:, None] <= 6.0), ex, -1)   # избыток - до x/H 6: дальше рельеф следующих гребней
        ex = np.where(np.isfinite(ex), ex, -1)
        i, q = np.unravel_index(int(np.argmax(ex)), ex.shape)
        out[nm + "_excess"] = dict(ratio=float(ex[i, q]), xh=float(xh[i]), agl=levels[q])
    out["stations"] = []
    for xq in (0.5, 1, 2, 3, 4, 6):
        i = int(np.argmin(abs(xh - xq)))
        out["stations"].append(dict(xh=float(xh[i]), sw30_old=float(sw_old[i, 1]), sw30_new=float(sw_new[i, 1]),
                                    sw_col_old=float(np.nanmax(np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), g["sigma_w"][i].astype(float), np.nan))),
                                    sw_col_new=float(np.nanmax(np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), res["sig_new"]["w"][i], np.nan))),
                                    dU=float(res["dU"][i]), delta=float(res["delta"][i]), yc_rel=float(res["yc"][i] - h_c)))
    i = i_pk
    out["dU_at_peak_station"] = float(dU); out["xh_peak_station"] = float(xh[i])
    out["delta_at_peak_station_m"] = float(res["delta"][i]); out["yc_minus_crest_at_peak_station_m"] = float(res["yc"][i] - h_c)
    return out


# ---------------------------------------------------------------- selftest
def selftest():
    """Синтетика без внешних данных. Каждая проверка — assert; выход 0 при успехе."""
    k = K
    # 0. derived-константы пересчитываются из LTL (если csv рядом в репозитории)
    ltl = os.path.join(HERE, "..", "lit", "lit_numbers.csv")
    if os.path.exists(ltl):
        L = {r["id"]: float(r["value"]) for r in csv.DictReader(open(ltl, encoding="utf-8"))}
        assert abs(np.mean([L["br74_ddw_dx_over_lambda"], L["del_ddw_dx_over_lambda"], L["ml_ddelta_omega_dx_over_lambda"]]) - k["mix_growth_per_lambda"]) < 2e-3
        assert abs((L["ds_dw_x1"] - L["ds_ddw_dx_1_4"]) - k["mix_delta0_over_h"]) < 6e-3
        assert abs(0.1037 / L["ds_ddw_dx_1_4"] - k["mix_slow_factor"]) < 5e-3
        assert abs(4 / L["ds_xr"] - k["mix_slow_x_over_xr"]) < 1e-2
        assert abs(0.5 / math.sqrt(-2 * math.log(L["del_su_prof_half"])) - k["profile_sigma_over_delta"]) < 1e-3
        xi = (1 / L["ds_xr"]) / -math.log(1 - L["ds_su_x1"] / L["ds_su_x4"])
        assert abs(xi - k["ramp_x_over_xr"]) < 5e-3, xi
        assert abs(math.sqrt(L["del_uv_peak"]) - k["mix_len_over_delta"]) < 1e-3
        assert abs(L["br74_eddy_spacing"] / 6.87 - k["eddy_scale_over_delta"]) < 5e-3
        xs = np.array([6 - 4, 10 - 4]) / 1.0 / L["ds_xr"]
        ys = -np.log(np.array([L["ds_su_x6"], L["ds_su_x10"]]) / L["ds_su_x4"])
        assert abs(1 / ((xs * ys).sum() / (xs * xs).sum()) - k["decay_length_over_xr"]) < 0.1
        for nm, key in (("sigma_u_over_du", "del_sigma_u_peak"), ("sigma_v_over_du", "del_sigma_v_peak"), ("sigma_w_over_du", "del_sigma_w_peak")):
            assert abs(L[key] - k[nm]) < 1e-3
    # 1. синтетический гребень: H=100, подветренный уклон 0,3, потом плоско; ветер вдоль +d
    H = 100.0
    def ground(d):
        d = np.asarray(d, float)
        return np.where(d < 0, np.maximum(100.0 + 0.1 * d, 0.0), np.maximum(100.0 - 0.3 * d, 0.0)).item() if np.ndim(d) == 0 else None
    g_at = lambda d: float(ground(d))
    bump = lambda d: ground(d) + (8.0 if 100 < d < 150 else 0.0)
    cpb = crest_params(lambda d: float(bump(d)), 300.0)
    assert abs(cpb["h_c"] - 100.0) < 1e-9, cpb                 # бугор 8 м на склоне гребнем не считается
    cp = crest_params(g_at, 400.0)
    assert cp is not None and abs(cp["H"] - 100.0) < 1e-9 and cp["h_c"] == 100.0, cp
    assert crest_params(g_at, -300.0) is None             # наветренный склон: выше всего против ветра нет
    # пологий склон: нет слоя
    gent = lambda d: 100.0 - 0.05 * max(d, 0.0) if d > 0 else max(100.0 + 0.1 * d, 0.0)
    cg = crest_params(gent, 400.0)
    xr = k["ridge_xr_over_h"] * cg["H"]
    sl = (cg["h_c"] - gent(cg["d_c"] + xr)) / xr
    assert float(smoothstep(k["lee_slope_on"], k["lee_slope_full"], sl)) == 0.0
    # 2. пузырь в поле: u<0 на 150..350 м
    xs = np.arange(0, 800, 10.0)
    u = np.where((xs > 150) & (xs < 350), -1.0, 3.0)
    b = bubble_from_field(xs, u, 0.0, 50.0)
    assert b is not None and abs(b[0] - 200) <= 10
    xr_f, r = pick_xr(100.0, b, 10.0)       # L/dx = 20 >= 8 -> поле
    assert r == 1.0 and abs(xr_f - b[2]) < 1e-9
    xr_h, r = pick_xr(100.0, b, 50.0)       # L/dx = 4 -> эвристика
    assert r == 0.0 and abs(xr_h - 350.0) < 1e-9
    # 3. слой: x_r = 350 м, U1 = 10, U2 = 0 (λ = 1)
    geo = dict(H=100.0, h_c=100.0, h_at_xr=0.0)   # h(x_r)=max(100-105,0)=0
    xr = 350.0
    x = np.array([1.0, 50.0, 0.64 * xr, 0.64 * xr, 600.0])
    st = layer_state(x, np.full(5, 80.0), np.zeros(5), geo, xr, 10.0, 0.0)
    assert abs(st["lam"][0] - 1.0) < 1e-12 and abs(st["dU"][0] - 10.0) < 1e-12
    # δ(x): δ0 + sλx до x_b, затем ×0,57
    xb = 0.64 * xr
    d_exp = lambda xx: k["mix_delta0_over_h"] * 100 + k["mix_growth_per_lambda"] * (min(xx, xb) + k["mix_slow_factor"] * max(xx - xb, 0))
    assert np.allclose(st["delta"], [d_exp(v) for v in x]), st["delta"]
    assert abs(st["delta"][0] - 30.0) < 0.2                    # δ0
    d1 = layer_state(np.array([xb - 1.0, xb]), np.full(2, 80.0), np.zeros(2), geo, xr, 10.0, 0.0)["delta"]
    d2 = layer_state(np.array([xb, xb + 1.0]), np.full(2, 80.0), np.zeros(2), geo, xr, 10.0, 0.0)["delta"]
    assert abs((d1[1] - d1[0]) - k["mix_growth_per_lambda"]) < 1e-9 and abs((d2[1] - d2[0]) - k["mix_growth_per_lambda"] * k["mix_slow_factor"]) < 1e-9
    # y_c: у гребня = h_c, монотонно вниз, не ниже земля + 0,3 H
    xx = np.linspace(0.0, 800.0, 81)
    stc = layer_state(xx, np.full(81, 50.0), np.zeros(81), geo, xr, 10.0, 0.0)
    assert abs(stc["yc"][0] - 100.0) < 1e-9 and np.all(np.diff(stc["yc"][:26]) <= 1e-9) and np.all(stc["yc"] <= 100.0 + 1e-9) and abs(stc["yc"][-1] - 30.0) < 1e-9 and stc["yc"][1] <= 100.0 + 1e-9
    # профиль σ: на линии слоя максимум; при |y-yc| = 0,5 δ_ω отношение 0,5959 ± 0,001; симметрия
    xq = 0.64 * xr
    yc0 = layer_state(np.array([xq]), np.array([0.0]), np.zeros(1), geo, xr, 10.0, 0.0)["yc"][0]
    dl = layer_state(np.array([xq]), np.array([0.0]), np.zeros(1), geo, xr, 10.0, 0.0)["delta"][0]
    ys = np.array([yc0, yc0 + 0.5 * dl, yc0 - 0.5 * dl, yc0 + dl])
    sp = layer_state(np.full(4, xq), ys, np.zeros(4), geo, xr, 10.0, 0.0)
    assert abs(sp["sig_u"][1] / sp["sig_u"][0] - 0.5959) < 1e-3 and abs(sp["sig_u"][1] - sp["sig_u"][2]) < 1e-12
    assert sp["sig_u"][3] / sp["sig_u"][0] < 0.14
    # амплитуда в пике: σ_i = a_i·ΔU·g_x, g_x(0,64 x_r) = ramp; σ_w > σ_v
    f = float(smoothstep(k["lee_slope_on"], k["lee_slope_full"], (100.0 - 0.0) / xr))
    gx = 1 - math.exp(-0.64 / k["ramp_x_over_xr"] * 1.0)
    assert f == 1.0 and abs(sp["sig_w"][0] - k["sigma_w_over_du"] * 10 * gx) < 1e-9 and sp["sig_w"][0] > sp["sig_v"][0]
    assert sp["sig_w"][0] <= k["sigma_w_over_du"] * 10 + 1e-12
    # затухание за присоединением: g_x(x_r)/g_x(0,64 x_r) -> exp(-(0,36 x_r)/(2 x_r)) раз ramp
    gx_far = layer_state(np.array([3 * xr]), np.array([50.0]), np.zeros(1), geo, xr, 10.0, 0.0)["gx"][0]
    assert gx_far < 0.55 * gx
    # до гребня слоя нет
    sb = layer_state(np.array([-10.0]), np.array([80.0]), np.zeros(1), geo, xr, 10.0, 0.0)
    assert sb["sig_w"][0] == 0.0 and sb["w"][0] == 0.0
    # 4. ограничение l: в центре слоя l_эфф <= k·δ_ω, вдали от слоя l_эфф = l; max и σ²
    agl = np.array([30.0, 30.0])
    stt = layer_state(np.full(2, xq), np.array([yc0, yc0 + 20 * dl]), np.zeros(2), geo, xr, 10.0, 0.0)
    old = np.array([2.0, 2.0])
    new, l_eff = combine(old, np.array([True, True]), stt, agl)
    l30 = float(mix_len(30.0))
    assert l_eff[1] <= l30 + 1e-9 and abs(l_eff[1] - l30) < 1e-6 * l30                 # вдали - без изменения
    assert l_eff[0] < l30 and l_eff[0] >= min(l30, k["mix_len_over_delta"] * dl) - 1e-9  # в слое ограничена
    assert abs(new[1] - 2.0) < 1e-6 and new[0] >= stt["sig_w"][0] - 1e-12 and new[0] <= 2.0
    k2 = dict(k); k2["combine_rule_power"] = 2
    n2, _ = combine(old, np.array([True, True]), stt, agl, k2)
    assert n2[0] >= new[0] - 1e-12 and n2[0] <= new[0] * 1.4143 + 1e-9
    # конвекция (не mech) не меняется
    nc, _ = combine(old, np.array([False, False]), stt, agl)
    assert nc[1] == 2.0 and nc[0] >= 2.0 - 1e-12
    # 5. масштаб и перенос: L = 0,48 δ_ω; U_c = 5
    assert abs(sp["L"][0] - 0.48 * dl) < 1e-9 and abs(sp["uc"][0] - 5.0) < 1e-12
    # 6. рывки: пик 3σ_w слоя
    assert abs(sp["burst"][0] - 3 * sp["sig_w"][0]) < 1e-12
    # 7. U2 ограничен снизу обратным током -0,17 U1
    s_neg = layer_state(np.array([100.0]), np.array([50.0]), np.zeros(1), geo, xr, 10.0, -5.0)
    assert abs(s_neg["dU"][0] - 11.7) < 1e-9
    assert s_neg["lam"][0] <= k["lambda_max"] + 1e-12
    # 8. U1 < 1 м/с: слоя нет
    s_lo = layer_state(np.array([100.0]), np.array([50.0]), np.zeros(1), geo, xr, 0.5, 0.0)
    assert s_lo["sig_w"][0] == 0.0
    print("selftest ok")
    return 0


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--sections", help="каталог с *.lts.csv (LTS v1, LT-2)")
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--xr-over-h", type=float, default=None, help="чувствительность: x_r/H вместо spec")
    ap.add_argument("--u2-field", action="store_true", help="чувствительность: U2 всегда из поля (0,1H над землёй)")
    ap.add_argument("--power", type=int, default=None, help="1 = max, 2 = корень суммы квадратов")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.sections:
        ap.error("нужен --selftest или --sections")
    os.makedirs(a.out, exist_ok=True)
    R = {r["name"]: r for r in json.load(open(os.path.join(HERE, "ridges_ref.json")))}
    rows, allm = [], {}
    for p in sorted(glob.glob(os.path.join(a.sections, "*.lts.csv"))):
        b = os.path.basename(p)[:-8]
        case = "_".join(b.split("_")[:2]); rn = "_".join(b.split("_")[2:])
        res = run_section(p, R[rn], K, a.xr_over_h, a.power, a.u2_field)
        m = metrics(res)
        m.update(case=case, ridge=rn, zone=R[rn]["zone"], n_queries_height=res["n_queries"])
        allm[b] = m
        rows.append(m)
        print(b, "H=%.0f xr/H=%.2f s_lee=%.2f f_sep=%.2f | old max %.2f@x/H %.1f agl %.0f | new max %.2f@x/H %.1f agl %.0f zc %.0f" % (
            m["H"], m["xr_over_h"], m["s_lee"], m["f_sep"], m["old_max"]["sigma_w"], m["old_max"]["xh"], m["old_max"]["agl"],
            m["new_max"]["sigma_w"], m["new_max"]["xh"], m["new_max"]["agl"], m["new_max"]["zc"]), flush=True)
    tag = "" if a.xr_over_h is None and a.power is None and not a.u2_field else f"_xr{a.xr_over_h}_p{a.power}" + ("_u2f" if a.u2_field else "")
    json.dump(allm, open(os.path.join(a.out, f"sections{tag}.json"), "w"), indent=1, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
