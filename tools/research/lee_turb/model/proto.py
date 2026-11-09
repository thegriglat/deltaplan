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


_erf = np.vectorize(math.erf, otypes=[float])


def norm_cdf(x):
    return 0.5 * (1.0 + _erf(np.asarray(x, float) / math.sqrt(2.0)))


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
    hf = np.array([g_at(d) for d in df])
    j = int(np.argmin(hf))
    foot = float(hf[j])
    H = h_c - foot
    if H <= 0:
        return None
    x_foot = max(float(df[j] - d_c), step)           # расстояние гребень - подножие (минимум на foot_search_m), не меньше шага
    return dict(d_c=d_c, h_c=h_c, H=H, foot=foot, x_foot=x_foot, s_lee=H / x_foot, n_queries=len(ds) + len(df))


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


# ---------------------------------------------------------------- линия слоя (LT-7, Q1)
def yc_fallback(xp, g_x, geo, xr, k=K):
    """Запасная линия слоя по глубине пузыря (Menke 2019): верх пузыря foot + H·(1-(x/x_r)^m), m из средней глубины 0,958 H;
    не ниже g + yc_end·H·x/x_r. MSL."""
    H, foot = geo["H"], geo["foot"]
    r = np.minimum(np.asarray(xp, float) / xr, 1.0)
    return np.maximum(foot + H * (1.0 - r ** k["yc_shape_exp"]), g_x + k["yc_end_over_h"] * H * r)


def yc_lt5(xp, g_x, geo, xr, k=K):
    """Линия LT-5 (оставлена для сверки): линейно h_гребня -> h(x_r), не ниже g + 0,3 H."""
    H, h_c, h_xr = geo["H"], geo["h_c"], geo["h_at_xr"]
    return np.maximum(h_c - (h_c - h_xr) * xp / xr, g_x + k["yc_end_over_h"] * H * np.minimum(xp / xr, 1.0))


def field_center(u_at, geo, g_i, dy, k=K):
    """Центр слоя z½ по столбцу поля: u(z½) = U2 + ½(U1-U2), U1 = u(h_гребня), U2 = u(g + u2_height_over_h·H).
    u_at(y) - опрос u_par столбца (nan - нет данных). Деление пополам field_bisect_steps раз: 2 + n опросов.
    Возвращает dict(q, z_half, dUf_over_u1, drop, n_q): q в [0,1] - гладкий признак «поле даёт слой»."""
    H, h_c = geo["H"], geo["h_c"]
    y0, y1 = g_i + k["u2_height_over_h"] * H, h_c
    out = dict(q=0.0, z_half=float("nan"), dUf_over_u1=float("nan"), drop=float("nan"), n_q=2)
    if not (y1 > y0):
        return out
    u1, u0 = u_at(y1), u_at(y0)
    if not (np.isfinite(u1) and np.isfinite(u0)) or u1 <= 0.0:
        return out
    gate = float(smoothstep(k["u1_min_ms"], 2.0 * k["u1_min_ms"], u1))      # слой при U1 < u1_min выключен: признак гаснет гладко
    frac = (u1 - u0) / u1
    tgt = u0 + 0.5 * (u1 - u0)
    lo, hi = y0, y1
    pts = [(y0, u0), (y1, u1)]
    for _ in range(int(k["field_bisect_steps"])):
        mid = 0.5 * (lo + hi)
        um = u_at(mid)
        if not np.isfinite(um):
            return out
        pts.append((mid, um))
        if um < tgt:
            lo = mid
        else:
            hi = mid
    z_half = 0.5 * (lo + hi)
    pts.sort()
    uu = np.array([p[1] for p in pts])
    drop = float(np.max(np.maximum.accumulate(uu) - uu) / u1)
    a, w = k["field_deficit_frac"], k["field_deficit_halfwidth"]
    q = float(gate * smoothstep(a - w, a + w, frac)
              * (1.0 - smoothstep(k["field_mono_tol"], 2.0 * k["field_mono_tol"], drop))
              * smoothstep(k["field_interior_cells"] - 1.0, k["field_interior_cells"] + 1.0, (z_half - g_i) / dy))
    return dict(q=q, z_half=float(z_half), dUf_over_u1=float(frac), drop=drop, n_q=2 + int(k["field_bisect_steps"]))


def below_weight(x, xr, ramp, f_sep, eta, k=K):
    """Вес B (механика стенки -> фон) только под линией слоя: f_sep·ramp·Φ(-η)·(1 - smoothstep(1-a, 1+a; x/x_r))."""
    a = k["below_end_halfwidth_over_xr"]
    return f_sep * ramp * norm_cdf(-eta) * (1.0 - smoothstep(1.0 - a, 1.0 + a, np.asarray(x, float) / xr)) * (np.asarray(x) > 0)


# ---------------------------------------------------------------- слой
def layer_state(x, y, g_x, geo, xr, u1, u2, k=K, f_sep_force=None, res=0.0, yc_mode="fb", z_half=None, q_field=0.0):
    """Величины слоя в точках (x, y). x, y — массивы одной формы; g_x — высота земли в x; u1, u2 — массивы или числа.
    yc_mode: "fb" - запасная линия по глубине пузыря (LT-7), "lt5" - линейная LT-5, "field" - q·z½ поля + (1-q)·запасная
    (z_half, q_field - массивы/числа). Возвращает dict: dU, lam, delta, yc, eta, gx, ramp, w, wB, sig{u,v,w}, L, f_sep."""
    H, h_c = geo["H"], geo["h_c"]
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    g_x = np.asarray(g_x, float)
    u1 = np.maximum(np.broadcast_to(np.asarray(u1, float), x.shape), 0.0)
    u2 = np.clip(np.broadcast_to(np.asarray(u2, float), x.shape), k["u2_min_over_u1"] * u1, u1)
    dU = u1 - u2
    lam = np.minimum(np.where(u1 + u2 > 1e-6, dU / np.maximum(u1 + u2, 1e-6), 0.0), k["lambda_max"])
    h_xr = geo["h_at_xr"]
    s_lee = geo["s_lee"]                              # LT-6: только рельеф (средний уклон гребень - подножие), не через x_r
    xi = k["ramp_x_over_xr"] * (1.0 - res) + k["ramp_x_over_xr_du"] * res
    f_sep = float(smoothstep(k["lee_slope_on"], k["lee_slope_full"], s_lee)) if f_sep_force is None else f_sep_force
    xp = np.maximum(x, 0.0)
    xb = k["mix_slow_x_over_xr"] * xr
    delta = k["mix_delta0_over_h"] * H + k["mix_growth_per_lambda"] * lam * (
        np.minimum(xp, xb) + k["mix_slow_factor"] * np.maximum(xp - xb, 0.0))
    if yc_mode == "lt5":
        yc = yc_lt5(xp, g_x, geo, xr, k)
    else:
        yc = yc_fallback(xp, g_x, geo, xr, k)
        if yc_mode == "field":
            q = np.broadcast_to(np.asarray(q_field, float), x.shape)
            zh = np.broadcast_to(np.asarray(z_half, float), x.shape)
            yc = q * np.clip(np.nan_to_num(zh, nan=0.0), g_x, h_c) + (1.0 - q) * yc
    ramp = 1.0 - np.exp(-xp / (xi * xr))              # xi: при постоянном dU (U2 не по полю) нарастание всё в g_x; при U2 по полю dU(x) растёт сам
    dec = np.exp(-np.maximum(xp - k["decay_x0_over_xr"] * xr, 0.0) / (k["decay_length_over_xr"] * xr))
    gx = ramp * dec
    on = (x > 0) & (u1 >= k["u1_min_ms"])
    eta = (y - yc) / (k["profile_sigma_over_delta"] * delta)
    G = np.exp(-0.5 * eta * eta)
    amp = np.where(on, f_sep * dU * gx * G, 0.0)
    w = np.where(on, f_sep * ramp * G, 0.0)
    wB = np.where(on, (1.0 - res) * below_weight(x, xr, ramp, f_sep, eta, k), 0.0)         # B - только при неразрешённом пузыре (res < 1)
    return dict(dU=dU, lam=lam, delta=delta, yc=yc, eta=eta, gx=gx, ramp=ramp, w=w, wB=wB, f_sep=f_sep, s_lee=s_lee,
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


VARS = ("old", "lt5", "A_fb", "A_new", "B_fb", "B_new")      # σ_w: поле (прежняя) / LT-5 / запасная линия A,B / линия по полю A,B


def run_section(path, ridge, k=K, xr_fixed_over_h=None, power=None, u2_field=False):
    """Один разрез -> dict метрик и массивы σ_w по вариантам VARS. ridge: {'name','H','zone'} (zone - клетка поля, м).
    lt5 - слой LT-5 (линия h_гребня -> h(x_r)), A_* - max(механика с l_эфф, слой), B_* - то же, механика под линией слоя заменена фоном
    (фон = σ_w наветренных колонок x/H -2..-0,5 на той же высоте над землёй); *_fb - запасная линия везде, *_new - z½ поля там, где оно слой даёт."""
    head, s_u, y_u, g = load_lts(path)
    gnd = ground_of(g, y_u)
    dx = float(ridge["zone"])
    dy = float(np.median(np.diff(y_u)))
    kk = dict(k)
    if xr_fixed_over_h is not None:
        kk["ridge_xr_over_h"] = xr_fixed_over_h
    if power is not None:
        kk["combine_rule_power"] = power
    ok_col = np.isfinite(gnd)
    g_at = lambda d: float(np.interp(d, s_u[ok_col], gnd[ok_col]))
    i_c = int(np.nanargmax(np.where(s_u < s_u[0] + 0.4 * (s_u[-1] - s_u[0]), gnd, -1e9)))
    s_c = float(s_u[i_c])
    geo_cache = {}
    ns, ny = g["agl"].shape
    cols = {}
    nq = 0
    nq_z = 0
    info = dict(H=None)
    main = None
    nan_ns = lambda: np.full(ns, np.nan)
    delta_c, yc_c, dU_c, u1_c, u2_c = nan_ns(), nan_ns(), nan_ns(), nan_ns(), nan_ns()
    yc_lt5_c, yc_fb_c, q_c, zh_c, dufrac_c, drop_c = nan_ns(), nan_ns(), nan_ns(), nan_ns(), nan_ns(), nan_ns()
    for i in range(ns):
        if s_u[i] <= s_c:
            continue
        cp = crest_params(g_at, float(s_u[i]), kk)
        if cp is None:
            continue
        nq = max(nq, cp["n_queries"])
        key = round(cp["d_c"], 1)
        if key not in geo_cache:
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
        col_ok = np.isfinite(g["agl"][i])
        u_at = lambda yq, i=i: col_interp(y_u, g["u_par"][i], yq)
        u1 = u_at(geo["h_c"])
        u2 = u_at(gnd[i] + kk["u2_height_over_h"] * geo["H"])
        if not (np.isfinite(u1) and np.isfinite(u2)):
            continue
        fc = field_center(u_at, geo, gnd[i], dy, kk)
        nq_z = max(nq_z, fc["n_q"])
        r = 1.0 if u2_field else geo["res"]
        u2 = r * u2 + (1.0 - r) * kk["u2_unresolved_over_u1"] * max(u1, 0.0)
        args = (np.full(ny, x), y_u, np.full(ny, gnd[i]), geo, geo["xr"], np.full(ny, u1), np.full(ny, u2), kk)
        sts = dict(lt5=layer_state(*args, res=geo["res"], yc_mode="lt5"),
                   fb=layer_state(*args, res=geo["res"], yc_mode="fb"),
                   new=layer_state(*args, res=geo["res"], yc_mode="field", z_half=np.full(ny, fc["z_half"]), q_field=np.full(ny, fc["q"])))
        cols[i] = (sts, col_ok, x)
        st = sts["new"]
        delta_c[i], dU_c[i], u1_c[i], u2_c[i] = st["delta"][0], st["dU"][0], u1, u2
        yc_c[i] = st["yc"][0]
        yc_lt5_c[i], yc_fb_c[i] = sts["lt5"]["yc"][0], sts["fb"]["yc"][0]
        q_c[i], zh_c[i], dufrac_c[i], drop_c[i] = fc["q"], fc["z_half"], fc["dUf_over_u1"], fc["drop"]
    geo_m = main or info
    # фон B: σ_w и σ_u наветренных колонок на тех же высотах над землёй
    agl_grid = np.arange(5.0, 400.0 + 1e-9, 5.0)
    bg = {}
    for nm in ("sigma_w", "sigma_u"):
        acc = []
        for i in range(ns):
            xh_i = (s_u[i] - geo_m["d_c"]) / geo_m["H"]
            if -2.0 <= xh_i <= -0.5:
                a, v = g["agl"][i], g[nm][i].astype(float)
                okk = np.isfinite(a) & np.isfinite(v)
                if okk.sum() >= 2:
                    o = np.argsort(a[okk])
                    acc.append(np.interp(agl_grid, a[okk][o], v[okk][o], left=np.nan, right=np.nan))
        bg[nm] = np.nanmean(np.array(acc), axis=0) if acc else np.full(len(agl_grid), np.nan)
    sig = {v: np.full((ns, ny), np.nan) for v in VARS}
    layer_sw = np.full((ns, ny), np.nan)
    wB_new = np.full((ns, ny), np.nan)
    for i, (sts, col_ok, x) in cols.items():
        agl = g["agl"][i]
        m = col_ok
        mech = (g["src"][i] == "mech")
        agl_q = np.where(m, agl, 10.0)
        sw0 = np.where(m, g["sigma_w"][i].astype(float), 0.0)
        bgw = np.interp(agl_q, agl_grid, np.where(np.isfinite(bg["sigma_w"]), bg["sigma_w"], 0.0))
        sig["old"][i] = np.where(m, g["sigma_w"][i].astype(float), np.nan)
        for tag, key, useB in (("lt5", "lt5", False), ("A_fb", "fb", False), ("A_new", "new", False), ("B_fb", "fb", True), ("B_new", "new", True)):
            st = sts[key]
            sw_in = sw0
            if useB:
                sw_in = np.where(mech, (1.0 - st["wB"]) * sw0 + st["wB"] * bgw, sw0)
            sw, _ = combine(sw_in, mech, st, agl_q, kk)
            sig[tag][i] = np.where(m, sw, np.nan)
        layer_sw[i] = np.where(m, sts["new"]["sig_w"], np.nan)
        wB_new[i] = np.where(m, sts["new"]["wB"], np.nan)
    return dict(s=s_u, y=y_u, g=g, gnd=gnd, s_c=s_c, geo=geo_m, sig=sig, layer_sw=layer_sw, wB=wB_new, delta=delta_c, yc=yc_c,
                yc_lt5=yc_lt5_c, yc_fb=yc_fb_c, q=q_c, z_half=zh_c, dUf_frac=dufrac_c, drop=drop_c,
                dU=dU_c, u1=u1_c, u2=u2_c, dx=dx, dy=dy, n_queries=nq, n_queries_zhalf=nq_z, head=head)


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
    H, d_c, h_c, foot = geo["H"], geo["d_c"], geo["h_c"], geo["foot"]
    xh = (s - d_c) / H
    agl = g["agl"]
    sig = dict(res["sig"])
    out = dict(H=H, xr_over_h=geo["xr"] / H, xr_from_field=bool(geo["res"] > 0.5), bubble_res=geo["res"], s_lee=float(geo["s_lee"]),
               f_sep=float(smoothstep(K["lee_slope_on"], K["lee_slope_full"], geo["s_lee"])), crest_msl=h_c, foot_msl=foot)
    band = (agl >= agl_lo) & (agl <= agl_hi) & (xh[:, None] > 0.05) & (xh[:, None] <= xh_max)
    out["max"] = {}
    for tag, arr in sig.items():
        a = np.where(band & np.isfinite(arr), arr, -1)
        i, j = np.unravel_index(int(np.argmax(a)), a.shape)
        out["max"][tag] = dict(sigma_w=float(arr[i, j]), xh=float(xh[i]), zc=float(y[j] - h_c), agl=float(agl[i, j]), zf=float((y[j] - foot) / H),
                               src=str(g["src"][i, j]) if tag == "old" else None)
    xr_h = geo["xr"] / H
    i_pk = int(np.argmin(abs(xh - K["decay_x0_over_xr"] * xr_h)))
    dU = res["dU"][i_pk]
    out["sw_crest05"], out["sw_reatt"], out["sw_over_dU_peak"] = {}, {}, {}
    for tag, arr in sig.items():
        for nm, xq in (("sw_crest05", 0.5), ("sw_reatt", xr_h)):
            i = int(np.argmin(abs(xh - xq)))
            col = np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), arr[i], np.nan)
            out[nm][tag] = float(np.nanmax(col)) if np.isfinite(col).any() else None
        col = np.where((agl[i_pk] >= agl_lo) & (agl[i_pk] <= agl_hi), arr[i_pk], np.nan)
        out["sw_over_dU_peak"][tag] = float(np.nanmax(col) / dU) if np.isfinite(col).any() and dU > 0.5 else None
    out["xh_reatt"] = float(xh[int(np.argmin(abs(xh - xr_h)))])
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
    lv = {tag: at_levels(arr) for tag, arr in sig.items()}
    up = (xh >= -2.0) & (xh <= -0.5)
    ref = np.nanmean(lv["old"][up], axis=0)
    out["excess"] = {}
    for tag, arr in lv.items():
        ex = arr / ref
        ex = np.where((xh[:, None] > 0.05) & (xh[:, None] <= 6.0), ex, -1)
        ex = np.where(np.isfinite(ex), ex, -1)
        i, q = np.unravel_index(int(np.argmax(ex)), ex.shape)
        out["excess"][tag] = dict(ratio=float(ex[i, q]), xh=float(xh[i]), agl=levels[q])
    out["stations"] = []
    colmax = lambda arr, i: float(np.nanmax(np.where((agl[i] >= agl_lo) & (agl[i] <= agl_hi), arr[i], np.nan)))
    for xq in (0.5, 1, 2, 3, 4, 6):
        i = int(np.argmin(abs(xh - xq)))
        st = dict(xh=float(xh[i]), dU=float(res["dU"][i]), delta=float(res["delta"][i]), yc_rel=float(res["yc"][i] - h_c),
                  yc_fb_rel=float(res["yc_fb"][i] - h_c), yc_lt5_rel=float(res["yc_lt5"][i] - h_c), q=float(res["q"][i]),
                  z_half_agl=float(res["z_half"][i] - gnd[i]), z_half_rel=float(res["z_half"][i] - h_c), dUf_frac=float(res["dUf_frac"][i]))
        for tag in sig:
            st["sw30_" + tag] = float(lv[tag][i, 1])
            st["col_" + tag] = colmax(sig[tag], i)
        out["stations"].append(st)
    # признак «поле даёт центр слоя»: доля колонок x/H 0,5..6 с q > 0,5 и гладкость по x (только соседние колонки: пропуски без данных не считаются)
    m = (xh >= 0.5) & (xh <= 6.0) & np.isfinite(res["q"])
    idx = np.where(m)[0]
    adj = np.diff(idx) == 1
    ds = np.diff(s)[idx[:-1]] if len(idx) > 1 else np.array([])
    jmp = lambda arr: float(np.nanmax(np.abs(np.diff(arr[idx]))[adj])) if adj.any() else None
    jmp_s = lambda arr: float(np.nanmax((np.abs(np.diff(arr[idx])) / ds)[adj])) if adj.any() else None
    q = res["q"][m]
    out["field_center"] = dict(n_cols=int(m.sum()), frac_q_gt_half=float(np.mean(q > 0.5)) if m.any() else None, mean_q=float(np.mean(q)) if m.any() else None,
                               max_dq=jmp(res["q"]), max_dyc_over_dx=jmp_s(res["yc"]), max_dyc_fb_over_dx=jmp_s(res["yc_fb"]),
                               yc_minus_fb_m_mean=float(np.mean((res["yc"] - res["yc_fb"])[m])) if m.any() else None,
                               yc_minus_fb_m_where_q=float(np.mean((res["yc"] - res["yc_fb"])[m][q > 0.5])) if (q > 0.5).any() else None)
    for tag in ("old", "B_fb", "B_new"):                  # скачок максимума σ_w колонки между соседними колонками (м/с): переход поле/запасная линия не должен его добавлять
        cm = np.full(len(s), np.nan)
        cm[idx] = [colmax(sig[tag], i) for i in idx]
        out["field_center"]["max_dcol_" + tag] = jmp(cm)
    out["dU_at_peak_station"] = float(dU); out["xh_peak_station"] = float(xh[i_pk])
    out["delta_at_peak_station_m"] = float(res["delta"][i_pk]); out["yc_minus_crest_at_peak_station_m"] = float(res["yc"][i_pk] - h_c)
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
        # LT-6: ξ при ΔU(x) по полю: σ_u/ΔU, ΔU = 1 - U2/U1 с ds_uback на x/H = 1 (-0,035) и 4 (-0,171)
        r_du = (L["ds_su_x1"] / (1 + 0.035)) / (L["ds_su_x4"] / (1 + 0.171))
        xi_du = (1 / L["ds_xr"]) / -math.log(1 - r_du)
        assert abs(xi_du - k["ramp_x_over_xr_du"]) < 5e-3, xi_du
        assert abs(L["ridge_xr_mean"] / k["ridge_H_mean_m"] - k["ridge_xr_over_h"]) < 0.01          # 697 м / <H> моделей NE, SW (model_obs.py)
        D = L["ridge_depth_mean"] / k["ridge_H_mean_m"]                                             # LT-7: глубина зоны Menke в долях H
        assert abs(D - k["bubble_depth_over_h"]) < 5e-4 and abs(D / (1 - D) - k["yc_shape_exp"]) < 0.1
        oc = os.path.join(HERE, "out", "obs_compare.json")
        if os.path.exists(oc):                                                                      # <H> в spec = среднее H_model из сверки LT-6/7
            gm = json.load(open(oc, encoding="utf-8"))["geometry"]
            assert abs(0.5 * (gm["perdigao/NE"]["H_model_m"] + gm["perdigao/SW"]["H_model_m"]) - k["ridge_H_mean_m"]) < 0.05
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
    sl = cg["s_lee"]                                       # LT-6: средний уклон гребень - подножие, не через x_r
    assert abs(sl - cg["H"] / cg["x_foot"]) < 1e-12 and sl < 0.128
    assert float(smoothstep(k["lee_slope_on"], k["lee_slope_full"], sl)) == 0.0
    assert abs(cp["s_lee"] - 100.0 / cp["x_foot"]) < 1e-9 and cp["x_foot"] >= 50.0      # подножие синтетики: земля 0 при d >= 333 м
    # 2. пузырь в поле: u<0 на 150..350 м
    xs = np.arange(0, 800, 10.0)
    u = np.where((xs > 150) & (xs < 350), -1.0, 3.0)
    b = bubble_from_field(xs, u, 0.0, 50.0)
    assert b is not None and abs(b[0] - 200) <= 10
    xr_f, r = pick_xr(100.0, b, 10.0)       # L/dx = 20 >= 8 -> поле
    assert r == 1.0 and abs(xr_f - b[2]) < 1e-9
    xr_h, r = pick_xr(100.0, b, 50.0)       # L/dx = 4 -> эвристика
    assert r == 0.0 and abs(xr_h - k["ridge_xr_over_h"] * 100.0) < 1e-9
    # 3. слой: x_r = 350 м, U1 = 10, U2 = 0 (λ = 1)
    geo = dict(H=100.0, h_c=100.0, h_at_xr=0.0, foot=0.0, s_lee=100.0 / 350.0)   # h(x_r)=max(100-105,0)=0
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
    # 7б. ξ нарастания: при U2 по полю (res=1) нарастание быстрее, чем при постоянном ΔU
    r0 = layer_state(np.array([30.0]), np.array([50.0]), np.zeros(1), geo, xr, 10.0, 0.0, res=0.0)["ramp"][0]
    r1 = layer_state(np.array([30.0]), np.array([50.0]), np.zeros(1), geo, xr, 10.0, 0.0, res=1.0)["ramp"][0]
    assert abs(r0 - (1 - math.exp(-30.0 / (k["ramp_x_over_xr"] * xr)))) < 1e-12 and r1 > r0
    # 8. U1 < 1 м/с: слоя нет
    s_lo = layer_state(np.array([100.0]), np.array([50.0]), np.zeros(1), geo, xr, 0.5, 0.0)
    assert s_lo["sig_w"][0] == 0.0
    # 9. LT-7: линия слоя. Запасная: у гребня h_c, среднее по 0<x<x_r верха пузыря = D·H (Menke), у присоединения - пол g + 0,3 H
    xs_ = np.linspace(0.0, xr, 200001)
    T = 1.0 - (xs_ / xr) ** k["yc_shape_exp"]
    assert abs(T.mean() - k["bubble_depth_over_h"]) < 2e-3
    fbl = yc_fallback(np.array([0.0, 0.5 * xr, xr, 2 * xr]), np.zeros(4), geo, xr)
    assert abs(fbl[0] - 100.0) < 1e-9 and fbl[1] > 99.0 and abs(fbl[2] - 30.0) < 1e-9 and abs(fbl[3] - 30.0) < 1e-9
    l5 = layer_state(np.array([0.5 * xr]), np.array([50.0]), np.zeros(1), geo, xr, 10.0, 0.0, yc_mode="lt5")["yc"][0]
    assert abs(l5 - max(100.0 - 100.0 * 0.5, 15.0)) < 1e-9                      # LT-5: линейная
    # 9а. центр слоя по полю: tanh-профиль, U1 = 10 на гребне, U2 ~ 0 у земли, центр на 50 м над землёй (H = 100, g = 0)
    prof = lambda zc, w: (lambda yq: 5.0 * (1.0 + math.tanh((yq - zc) / w)))
    f1 = field_center(prof(50.0, 12.0), geo, 0.0, 10.0)
    assert f1["q"] > 0.95 and abs(f1["z_half"] - 50.0) < 2.5 and f1["n_q"] == 2 + k["field_bisect_steps"], f1      # точность деления: (100-10)/64 = 1,4 м
    assert field_center(lambda yq: 10.0 - 0.01 * yq, geo, 0.0, 10.0)["q"] == 0.0                                     # дефицита нет: u(0,1H)/u(H) ~ 0,9
    f2 = field_center(lambda yq: 10.0 * (1.0 - 0.9 * math.exp(-((yq - 30.0) / 8.0) ** 2)), geo, 0.0, 10.0)          # провал в 30 м: немонотонно
    assert f2["q"] == 0.0 and f2["drop"] > 0.2, f2
    f3 = field_center(prof(6.0, 2.0), geo, 0.0, 10.0)                                                                # центр у стенки (< 2 клеток)
    assert f3["q"] == 0.0, f3
    lo = field_center(lambda yq: 10.0 * (0.46 + 0.54 * min(yq / 100.0, 1.0)), geo, 0.0, 10.0)["q"]                   # дефицит 0,5 +- : гладко 0..1
    hi = field_center(lambda yq: 10.0 * (0.30 + 0.70 * min(yq / 100.0, 1.0)), geo, 0.0, 10.0)["q"]
    assert 0.0 <= lo <= hi <= 1.0
    qs = [field_center(lambda yq, d=d: 10.0 * (1.0 - d + d * min(yq / 100.0, 1.0)), geo, 0.0, 10.0)["q"] for d in np.linspace(0.3, 0.7, 41)]
    assert max(abs(np.diff(qs))) < 0.15 and qs[0] < 0.2 and qs[-1] > 0.8                                         # без скачков по ΔU_f
    # 9б. y_c: q=0 - запасная, q=1 - z½, между - плавно
    xq3 = np.full(3, 0.6 * xr)
    zz = layer_state(xq3, np.full(3, 50.0), np.zeros(3), geo, xr, 10.0, 0.0, yc_mode="field", z_half=np.full(3, 44.0), q_field=np.array([0.0, 0.5, 1.0]))["yc"]
    fb6 = yc_fallback(np.array([0.6 * xr]), np.zeros(1), geo, xr)[0]
    assert abs(zz[0] - fb6) < 1e-9 and abs(zz[2] - 44.0) < 1e-9 and abs(zz[1] - 0.5 * (fb6 + 44.0)) < 1e-9
    # 9в. B только под линией: вес 0 выше линии, ~0,5·ramp на линии, 0 после x_r(1+a) и при x<=0
    ys3 = np.array([400.0, 0.0, -200.0])
    stB = layer_state(np.full(3, 0.5 * xr), ys3, np.zeros(3), geo, xr, 10.0, 0.0, yc_mode="fb")
    assert stB["wB"][0] < 1e-6 and stB["wB"][1] > 0.99 * stB["f_sep"] * stB["ramp"][1] * 0.99 and stB["wB"][2] > 0.999 * stB["ramp"][2]
    at_line = layer_state(np.array([0.5 * xr]), stB["yc"][:1] * 0 + yc_fallback(np.array([0.5 * xr]), np.zeros(1), geo, xr), np.zeros(1), geo, xr, 10.0, 0.0, yc_mode="fb")
    assert abs(at_line["wB"][0] - 0.5 * at_line["ramp"][0] * at_line["f_sep"]) < 1e-9
    stE = layer_state(np.array([-5.0, 1.25 * xr, 1.3 * xr]), np.full(3, -200.0), np.zeros(3), geo, xr, 10.0, 0.0, yc_mode="fb")
    assert stE["wB"][0] == 0.0 and stE["wB"][1] < 1e-9 and stE["wB"][2] == 0.0
    xs5 = np.linspace(0.0, 1.5 * xr, 301)
    wBx = layer_state(xs5, np.full(301, -50.0), np.zeros(301), geo, xr, 10.0, 0.0, yc_mode="fb")["wB"]
    assert np.max(np.abs(np.diff(wBx))) < 0.05                                                               # без скачка B по x
    assert layer_state(np.array([0.5 * xr]), np.array([-200.0]), np.zeros(1), geo, xr, 10.0, 0.0, res=1.0)["wB"][0] == 0.0       # пузырь разрешён полем: B не нужен
    print("selftest ok")
    return 0


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--obs", action="store_true", help="LT-6: сверка с измерениями LTO без поля -> out/obs_compare.csv, .json (model_obs.py)")
    ap.add_argument("--sections", help="каталог с *.lts.csv (LTS v1, LT-2)")
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--xr-over-h", type=float, default=None, help="чувствительность: x_r/H вместо spec")
    ap.add_argument("--u2-field", action="store_true", help="чувствительность: U2 всегда из поля (0,1H над землёй)")
    ap.add_argument("--power", type=int, default=None, help="1 = max, 2 = корень суммы квадратов")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.obs:
        sys.path.insert(0, HERE)
        import model_obs
        res, geom = model_obs.run(None)
        model_obs.write(res, geom, a.out)
        print("obs_compare: %d строк -> %s" % (len(res), a.out))
        return 0
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
        mx = m["max"]
        print(b, "H=%.0f xr/H=%.2f f_sep=%.2f q>0.5 %.2f | max σ_w (x/H, agl): " % (m["H"], m["xr_over_h"], m["f_sep"], m["field_center"]["frac_q_gt_half"] or 0) +
              " ".join("%s %.2f(%.1f,%.0f)" % (v, mx[v]["sigma_w"], mx[v]["xh"], mx[v]["agl"]) for v in VARS), flush=True)
    tag = "" if a.xr_over_h is None and a.power is None and not a.u2_field else f"_xr{a.xr_over_h}_p{a.power}" + ("_u2f" if a.u2_field else "")
    json.dump(allm, open(os.path.join(a.out, f"sections{tag}.json"), "w"), indent=1, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
