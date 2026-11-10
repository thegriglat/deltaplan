"""Анализ разрезов LTS v1 (out/*.lts.csv) -> out/summary.json и таблицы в out/tables.md.

Запуск: python3 analyze.py  (numpy, stdlib). Координаты: x/H = (s − 2H)/H от гребня по ветру; высота
над гребнем zc = y − crest_msl; agl — над местной землёй. Все высоты у земли ниже AGL_MIN исключены из
поиска максимумов (формула σ при agl→0 даёт артефакт: z = max(agl, 1) м).
"""
import csv, json, math, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
RIDGES = {r["name"]: r for r in json.load(open(os.path.join(HERE, "ridges.json")))}
SEP_SU, SEP_SW = 0.18, 0.14   # configs/atmosphere.json → lee.field_sigma_{u,w}_per_du
AGL_MIN = 5.0          # м: ниже — артефакты малого z
AGL_SHEAR_MIN = 20.0   # м: поиск центра слоя сдвига не ниже (пристенный сдвиг исключён)
WIN50 = (5625.0, 8825.0, -1275.0, 1925.0)    # x0,x1,z0,z1
WIN100 = (4025.0, 10425.0, -2875.0, 3525.0)
EDGE_CELLS = 5


def dx_at(x, z):
    """Размер клетки поля в точке (без полосы края): окно 50/100 м, иначе 400 м."""
    def inside(w, m):
        return w[0] + m <= x <= w[1] - m and w[2] + m <= z <= w[3] - m
    if inside(WIN50, EDGE_CELLS * 50 / 2):
        return 50.0
    if inside(WIN100, EDGE_CELLS * 100 / 2):
        return 100.0
    return 400.0


def load(path):
    with open(path) as f:
        head = f.readline()
        rd = csv.DictReader(f)
        rows = list(rd)
    cols = {}
    for k in rd.fieldnames:
        if k == "src":
            cols[k] = np.array([r[k] for r in rows])
        else:
            cols[k] = np.array([float(r[k]) if r[k] != "" else np.nan for r in rows])
    return head, cols


def grid(cols):
    """Колонки -> массивы [ns, ny] (NaN под рельефом)."""
    s_u = np.unique(cols["s"])
    y_u = np.unique(cols["y"])
    si = {v: i for i, v in enumerate(s_u)}
    yi = {v: i for i, v in enumerate(y_u)}
    ii = np.array([si[v] for v in cols["s"]])
    jj = np.array([yi[v] for v in cols["y"]])
    g = {}
    for k, v in cols.items():
        if k in ("s", "y"):
            continue
        if k == "src":
            a = np.full((len(s_u), len(y_u)), "", dtype=object)
        else:
            a = np.full((len(s_u), len(y_u)), np.nan)
        a[ii, jj] = v
        g[k] = a
    return s_u, y_u, g


def at_agl(g, y_u, name, agl):
    """Значение величины на высоте agl над землёй по каждой колонке (линейно по y)."""
    n = g[name].shape[0]
    out = np.full(n, np.nan)
    for i in range(n):
        a = g["agl"][i]
        v = g[name][i]
        ok = ~np.isnan(a) & ~np.isnan(v)
        if ok.sum() < 2:
            continue
        aa, vv = a[ok], v[ok]
        if aa.min() <= agl <= aa.max():
            out[i] = np.interp(agl, aa, vv)
    return out


def ground_col(g, y_u):
    n = g["agl"].shape[0]
    out = np.full(n, np.nan)
    for i in range(n):
        ok = ~np.isnan(g["agl"][i])
        if ok.any():
            j = np.where(ok)[0][0]
            out[i] = y_u[j] - g["agl"][i][j]
    return out


def first_cross(xh, v, lo, hi, sign):
    """Первое x/H в [lo, hi], где v меняет знак (sign=-1: + -> −, +1: − -> +)."""
    for k in range(1, len(v)):
        if not (lo <= xh[k] <= hi) or np.isnan(v[k]) or np.isnan(v[k - 1]):
            continue
        if sign < 0 and v[k - 1] > 0 >= v[k]:
            return float(xh[k - 1] + (xh[k] - xh[k - 1]) * v[k - 1] / (v[k - 1] - v[k]))
        if sign > 0 and v[k - 1] < 0 <= v[k]:
            return float(xh[k - 1] + (xh[k] - xh[k - 1]) * (-v[k - 1]) / (v[k] - v[k - 1]))
    return None


def analyze(path):
    base = os.path.basename(path)[: -len(".lts.csv")]
    case, ridge = base.split("_", 1)[0] + "_" + base.split("_")[1], "_".join(base.split("_")[2:])
    R = RIDGES[ridge]
    H = R["H"]
    head, cols = load(path)
    s_u, y_u, g = grid(cols)
    xh = (s_u - 2 * H) / H
    dd = np.array(R["dir"])
    xs = R["frm"][0] + dd[0] * s_u
    zs = R["frm"][1] + dd[1] * s_u
    dxl = np.array([dx_at(a, b) for a, b in zip(xs, zs)])
    gnd = ground_col(g, y_u)
    crest = R["crest_msl"]
    dy = float(np.median(np.diff(y_u)))
    res = dict(case=case, ridge=ridge, zone=R["zone"], H=H, crest_msl=crest, dy=dy, n_rows=int(len(cols["s"])),
               dx_crest=float(dxl[np.argmin(abs(xh))]))
    src = g["src"]
    inf = src != "none"
    inf &= src != ""
    agl = g["agl"]
    # ---------- превышение гребня против ветра r (GroundField.relief_at: max_i h(p − ŵ·d_i) − h(p), d_i из конфига)
    from terrain import ground as _ground
    wd = dd  # линия идёт по ветру
    D6 = (60.0, 150.0, 300.0, 600.0, 1000.0, 1600.0)
    r6 = np.zeros(len(s_u))
    rc = np.zeros(len(s_u))
    dstar = np.zeros(len(s_u))
    for i in range(len(s_u)):
        h0 = float(_ground(xs[i], zs[i]))
        hh = [float(_ground(xs[i] - wd[0] * d, zs[i] - wd[1] * d)) - h0 for d in D6]
        r6[i] = max(0.0, max(hh))
        dc = np.arange(10.0, 1600.1, 10.0)
        hc = _ground(xs[i] - wd[0] * dc, zs[i] - wd[1] * dc) - h0
        rc[i] = max(0.0, float(hc.max()))
        dstar[i] = float(dc[int(np.argmax(hc))])
    rel = []
    for target in (-1, 0.1, 0.5, 1, 2, 4, 6, 8, 12):
        i = int(np.argmin(abs(xh - target)))
        rel.append(dict(xh=float(xh[i]), r6=float(r6[i]), r_cont=float(rc[i]), d_star=float(dstar[i]), H=H))
    res["relief"] = rel
    on = np.where(r6 > 0.1 * H)[0]
    res["relief_first_gt_0.1H_xh"] = float(xh[on[0]]) if len(on) else None
    # ---------- (а) нынешняя модель
    lee = g["lee_f"]
    lee_col = np.nanmax(np.where(agl >= AGL_MIN, lee, np.nan), axis=1)
    pos = lee_col > 0.05
    half = lee_col > 0.5
    res["lee_f_gt0_xh"] = [float(xh[pos].min()), float(xh[pos].max())] if pos.any() else None
    res["lee_f_gt05_xh"] = [float(xh[half].min()), float(xh[half].max())] if half.any() else None
    du = g["du"]
    res["du_max"] = float(np.nanmax(du)) if np.isfinite(du).any() else 0.0
    res["du_gt0_points"] = int(np.nansum(du > 1e-6))
    mixp = (src == "mix").sum()
    res["src_counts"] = {k: int((src == k).sum()) for k in ("mech", "conv", "mix", "none")}
    sw = np.where((agl >= AGL_MIN) & inf, g["sigma_w"], np.nan)
    # максимум σ_w: по всему разрезу, и в зоне lee_f>0.5
    def argmax2(a):
        if not np.isfinite(a).any():
            return None
        i, j = np.unravel_index(np.nanargmax(a), a.shape)
        return int(i), int(j)
    def desc(ij):
        if ij is None:
            return None
        i, j = ij
        return dict(xh=float(xh[i]), zc=float(y_u[j] - crest), agl=float(agl[i, j]), sigma_w=float(g["sigma_w"][i, j]),
                    sigma_u=float(g["sigma_u"][i, j]), src=str(src[i, j]), lee_f=float(g["lee_f"][i, j]),
                    du=float(g["du"][i, j]), l_w=float(g["l_w"][i, j]), l_u=float(g["l_u"][i, j]))
    res["max_sigma_w_all"] = desc(argmax2(sw))
    res["max_sigma_w_agl50"] = desc(argmax2(np.where(agl >= 50, sw, np.nan)))
    res["max150"] = desc(argmax2(np.where((agl <= 150) & (agl >= AGL_MIN) & inf, g["sigma_w"], np.nan)))
    res["max_sigma_w_in_lee"] = desc(argmax2(np.where(lee > 0.5, sw, np.nan)))
    # u_par на высоте гребня в колонке (U_H поля) — для ΔU поля там, где модель du = 0
    uh_col = np.full(len(s_u), np.nan)
    for i in range(len(s_u)):
        ok = ~np.isnan(g["u_par"][i])
        if ok.sum() >= 3 and y_u[ok].min() <= crest <= y_u[ok].max():
            uh_col[i] = np.interp(crest, y_u[ok], g["u_par"][i][ok])
    # станции по x/H: столбцовый максимум σ_w и σ_w на фиксированных agl
    st = []
    for target in (-2, -1, -0.5, 0, 0.25, 0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12):
        i = int(np.argmin(abs(xh - target)))
        col = np.where(agl[i] <= 150.0, sw[i], np.nan)   # станции: максимум σ_w ниже 150 м над землёй (высоты полёта)
        row = dict(xh=float(xh[i]), dx=float(dxl[i]), lee_f=float(lee_col[i]) if not np.isnan(lee_col[i]) else None)
        if np.isfinite(col).any():
            j = int(np.nanargmax(col))
            row.update(sw_max=float(col[j]), agl_at_max=float(agl[i, j]), zc_at_max=float(y_u[j] - crest),
                       src_at_max=str(src[i, j]), du=float(g["du"][i, j]), su=float(g["sigma_u"][i, j]),
                       lw=float(g["l_w"][i, j]))
            duf = uh_col[i] - g["u_par"][i, j] if not np.isnan(uh_col[i]) else np.nan
            row["du_field"] = None if np.isnan(duf) else float(duf)
            if not np.isnan(duf) and duf > 1.0:
                row["su_over_duf"] = float(g["sigma_u"][i, j] / duf)
                row["sw_over_duf"] = float(g["sigma_w"][i, j] / duf)
        okc = ~np.isnan(agl[i])
        if okc.any():
            j30 = int(np.nanargmin(np.where(okc, abs(agl[i] - 30.0), np.nan)))
            row["src30"] = str(src[i, j30])
        for a in (10, 30, 100):
            v = at_agl(g, y_u, "sigma_w", a)[i]
            row["sw_agl%d" % a] = None if np.isnan(v) else float(v)
        st.append(row)
    res["stations"] = st
    # избыток над притоком: σ_w(x, agl) / σ_w,вверх(agl), вверх — среднее x/H ∈ [−2, −0.5]
    levels = [10, 20, 30, 50, 75, 100, 150, 200, 300, 400]
    LV_MIN = 20  # избыток ищем не ниже 20 м (у земли σ_w притока мал и отношение раздувается)
    M = np.array([at_agl(g, y_u, "sigma_w", a) for a in levels]).T  # [ns, nl]
    upm = (xh >= -2) & (xh <= -0.5)
    ref = np.nanmean(M[upm], axis=0)
    ratio = M / ref
    res["sw_up_ref"] = {str(a): float(r) for a, r in zip(levels, ref)}
    ex = {}
    for name, sel in (("lee_gt0", xh >= 0.0), ("lee_f_gt05", lee_col > 0.5)):
        m = np.where(sel[:, None], ratio, np.nan)
        m[:, [k for k, a in enumerate(levels) if a < LV_MIN]] = np.nan
        if np.isfinite(m).any():
            i, k = np.unravel_index(np.nanargmax(m), m.shape)
            ex[name] = dict(xh=float(xh[i]), agl=levels[k], ratio=float(m[i, k]), sigma_w=float(M[i, k]),
                            src=str(src[i, int(np.nanargmin(abs(agl[i] - levels[k])))]))
    res["sw_ratio_max"] = ex
    # то же по горизонтальным σ_u
    Mu = np.array([at_agl(g, y_u, "sigma_u", a) for a in levels]).T
    refu = np.nanmean(Mu[upm], axis=0)
    mu = np.where((xh >= 0)[:, None], Mu / refu, np.nan)
    mu[:, [k for k, a in enumerate(levels) if a < LV_MIN]] = np.nan
    if np.isfinite(mu).any():
        i, k = np.unravel_index(np.nanargmax(mu), mu.shape)
        res["su_ratio_max"] = dict(xh=float(xh[i]), agl=levels[k], ratio=float(mu[i, k]), sigma_u=float(Mu[i, k]))
    # таблица σ_w(x/H, agl)
    tab = []
    for target in (-1, 0, 0.5, 1, 2, 3, 4, 6, 8, 10, 12):
        i = int(np.argmin(abs(xh - target)))
        tab.append(dict(xh=float(xh[i]), **{("a%d" % a): (None if np.isnan(M[i, k]) else float(M[i, k])) for k, a in enumerate(levels)}))
    res["sw_table"] = tab
    # контрфактическая оценка слоя смешения «если бы relief был известен» (в поле a = 1 аналитика не
    # считается, relief = 0, du = 0): ΔU = max(0, u_par на высоте гребня в колонке − u_par) · lee_f,
    # σ_w,mix = SEP_SW·ΔU, σ_u,mix = SEP_SU·ΔU; только точки ниже гребня (relief > agl)
    cf_w = np.full_like(g["u_par"], np.nan)
    cf_u = np.full_like(g["u_par"], np.nan)
    for i in range(len(s_u)):
        ok = ~np.isnan(g["u_par"][i])
        if ok.sum() < 3 or not (y_u[ok].min() <= crest <= y_u[ok].max()):
            continue
        uh = np.interp(crest, y_u[ok], g["u_par"][i][ok])
        below = ok & (y_u <= crest) & (agl[i] >= AGL_MIN)
        d = np.maximum(0.0, uh - g["u_par"][i]) * np.nan_to_num(g["lee_f"][i])
        cf_w[i, below] = SEP_SW * d[below]
        cf_u[i, below] = SEP_SU * d[below]
    cf = {}
    if np.isfinite(cf_w).any():
        k = argmax2(cf_w)
        cf["max"] = dict(xh=float(xh[k[0]]), agl=float(agl[k]), zc=float(y_u[k[1]] - crest), sigma_w_mix=float(cf_w[k]),
                         sigma_w_now=float(g["sigma_w"][k]), du=float(cf_w[k] / SEP_SW))
        rows_cf = []
        for target in (0.5, 1, 1.5, 2, 3, 4, 5, 6, 8):
            i = int(np.argmin(abs(xh - target)))
            if not np.isfinite(cf_w[i]).any():
                continue
            j = int(np.nanargmax(cf_w[i]))
            rows_cf.append(dict(xh=float(xh[i]), sw_mix=float(cf_w[i][j]), agl=float(agl[i][j]), sw_now=float(g["sigma_w"][i][j]),
                                lee_f=float(g["lee_f"][i][j])))
        cf["stations"] = rows_cf
        # доля точек в следе (lee_f>0.5, ниже гребня), где слой смешения дал бы σ_w больше нынешней
        m = np.isfinite(cf_w) & (g["lee_f"] > 0.5)
        cf["frac_mix_gt_now"] = float((cf_w[m] > g["sigma_w"][m]).mean()) if m.any() else None
        cf["median_ratio_mix_over_now"] = float(np.median(cf_w[m] / g["sigma_w"][m])) if m.any() else None
    res["counterfactual_mix"] = cf
    # σ_w(x) на agl 30 м: профиль вдоль x/H для максимума «у земли»
    sw30 = at_agl(g, y_u, "sigma_w", 30.0)
    if np.isfinite(sw30).any():
        i = int(np.nanargmax(sw30))
        res["max_sigma_w_agl30"] = dict(xh=float(xh[i]), sigma_w=float(sw30[i]))
    # ---------- (б) поле
    U10 = at_agl(g, y_u, "u_par", 10.0)
    U30 = at_agl(g, y_u, "u_par", 30.0)
    up = (xh >= -2) & (xh <= -0.5)
    u_up = float(np.nanmean(U10[up])) if np.isfinite(U10[up]).any() else None
    res["u10_upstream"] = u_up
    lo = xh >= 0.0
    res["sep_u10"] = first_cross(xh, U10, 0.0, 12.0, -1)
    if res["sep_u10"] is not None:
        res["reattach_u10"] = first_cross(xh, U10, res["sep_u10"], 12.0, +1)
    else:
        res["reattach_u10"] = None
    res["min_u10_lee"] = float(np.nanmin(np.where(lo, U10, np.nan))) if np.isfinite(U10[lo]).any() else None
    k = np.nanargmin(np.where(lo, U10, np.nan)) if np.isfinite(U10[lo]).any() else None
    res["xh_min_u10"] = float(xh[k]) if k is not None else None
    if u_up:
        # «начало дефицита»: u10 падает ниже 0.5·u10_апстрим
        d = first_cross(xh, U10 - 0.5 * u_up, 0.0, 12.0, -1)
        res["deficit_half_xh"] = d
        d2 = first_cross(xh, U10 - 0.5 * u_up, d if d is not None else 0.0, 12.0, +1) if d is not None else None
        res["recover_half_xh"] = d2
    # разделяющая линия тока: ψ = ∫_ground^z u_par dz (прямоугольник от земли до первой точки)
    psi_min = np.full(len(s_u), np.nan)
    zdiv = np.full(len(s_u), np.nan)
    for i in range(len(s_u)):
        ok = ~np.isnan(agl[i]) & ~np.isnan(g["u_par"][i])
        if ok.sum() < 3:
            continue
        a, u = agl[i][ok], g["u_par"][i][ok]
        order = np.argsort(a)
        a, u = a[order], u[order]
        a = np.concatenate([[0.0], a])
        uu = np.concatenate([[u[0]], u])
        psi = np.concatenate([[0.0], np.cumsum(0.5 * (uu[1:] + uu[:-1]) * np.diff(a))])
        psi_min[i] = psi.min()
        if psi.min() < -1e-6:
            # высота, где ψ снова пересекает 0 после минимума
            jm = int(np.argmin(psi))
            above = np.where(psi[jm:] >= 0)[0]
            if len(above):
                kk = jm + above[0]
                zdiv[i] = a[kk - 1] + (a[kk] - a[kk - 1]) * (-psi[kk - 1]) / (psi[kk] - psi[kk - 1]) if psi[kk] != psi[kk - 1] else a[kk]
    nb = np.isfinite(zdiv) & lo
    res["bubble_psi"] = (dict(x0=float(xh[nb].min()), x1=float(xh[nb].max()), L_over_H=float(xh[nb].max() - xh[nb].min()),
                              h_max=float(np.nanmax(zdiv[nb])), xh_hmax=float(xh[nb][np.nanargmax(zdiv[nb])]))
                         if nb.any() else None)
    # центр слоя сдвига и δ_ω
    dUdz = np.full_like(g["u_par"], np.nan)
    for i in range(len(s_u)):
        u = g["u_par"][i]
        dUdz[i, 1:-1] = (u[2:] - u[:-2]) / (2 * dy)
    band = np.zeros_like(dUdz, dtype=bool)
    ygrid = np.broadcast_to(y_u, dUdz.shape)
    band = (np.abs(ygrid - crest) <= H) & (agl >= AGL_SHEAR_MIN)
    shear_abs = np.where(band, np.abs(dUdz), np.nan)
    sh_c = np.full(len(s_u), np.nan)
    sh_z = np.full(len(s_u), np.nan)
    sh_agl = np.full(len(s_u), np.nan)
    interior = np.zeros(len(s_u), dtype=bool)
    dU = np.full(len(s_u), np.nan)
    delta = np.full(len(s_u), np.nan)
    for i in range(len(s_u)):
        if not np.isfinite(shear_abs[i]).any():
            continue
        j = int(np.nanargmax(shear_abs[i]))
        sh_c[i] = shear_abs[i][j]
        sh_z[i] = y_u[j] - crest
        sh_agl[i] = agl[i][j]
        valid = np.where(band[i] & ~np.isnan(shear_abs[i]))[0]
        interior[i] = valid.min() < j < valid.max()
        # ΔU: u на верху разреза (y = крест+2H) минус u на 10 м над землёй
        utop = g["u_par"][i][~np.isnan(g["u_par"][i])]
        top = g["u_par"][i][np.where(~np.isnan(g["u_par"][i]))[0][-1]]
        ub = U10[i]
        if not np.isnan(ub):
            dU[i] = top - ub
            if dU[i] > 0.5 and sh_c[i] > 1e-3:
                delta[i] = dU[i] / sh_c[i]
    z_half = np.full(len(s_u), np.nan)
    zc_half = np.full(len(s_u), np.nan)
    d_vis = np.full(len(s_u), np.nan)
    for i in range(len(s_u)):
        ok = ~np.isnan(agl[i]) & ~np.isnan(g["u_par"][i]) & (agl[i] >= 10.0)
        if ok.sum() < 5 or np.isnan(dU[i]) or dU[i] < 1.0:
            continue
        a, u = agl[i][ok], g["u_par"][i][ok]
        lo_u = U10[i]
        def crossing(frac):
            tgt = lo_u + frac * dU[i]
            for k in range(1, len(a)):
                if (u[k - 1] - tgt) * (u[k] - tgt) <= 0 and u[k] != u[k - 1]:
                    return a[k - 1] + (a[k] - a[k - 1]) * (tgt - u[k - 1]) / (u[k] - u[k - 1])
            return np.nan
        z_half[i] = crossing(0.5)
        zc_half[i] = z_half[i] + gnd[i] - crest if not np.isnan(z_half[i]) else np.nan
        z1, z9 = crossing(0.1), crossing(0.9)
        d_vis[i] = z9 - z1 if not (np.isnan(z1) or np.isnan(z9)) else np.nan
    res["shear_center"] = []
    for target in (0.5, 1, 1.5, 2, 3, 4, 5, 6, 8):
        i = int(np.argmin(abs(xh - target)))
        res["shear_center"].append(dict(xh=float(xh[i]), zc=None if np.isnan(sh_z[i]) else float(sh_z[i]),
                                        agl=None if np.isnan(sh_agl[i]) else float(sh_agl[i]),
                                        max_shear=None if np.isnan(sh_c[i]) else float(sh_c[i]),
                                        dU=None if np.isnan(dU[i]) else float(dU[i]),
                                        delta_w=None if np.isnan(delta[i]) else float(delta[i]),
                                        interior=bool(interior[i]), dx=float(dxl[i]),
                                        z_half_agl=None if np.isnan(z_half[i]) else float(z_half[i]),
                                        z_half_zc=None if np.isnan(zc_half[i]) else float(zc_half[i]),
                                        d_vis=None if np.isnan(d_vis[i]) else float(d_vis[i])))
    # наклон δ_ω(x): линейная подгонка на x/H ∈ [1, 6] там, где интерьер и δ определена
    fit = {}
    for (a, b) in ((1.0, 4.0), (1.0, 6.0), (2.0, 8.0)):
        m = (xh >= a) & (xh <= b) & np.isfinite(delta) & interior
        if m.sum() >= 5:
            p = np.polyfit(xh[m] * H, delta[m], 1)
            pred = np.polyval(p, xh[m] * H)
            ss = float(((delta[m] - delta[m].mean()) ** 2).sum())
            r2 = 1 - float(((delta[m] - pred) ** 2).sum()) / ss if ss > 0 else None
            fit["%g-%g" % (a, b)] = dict(slope=float(p[0]), r2=r2, n=int(m.sum()), delta_mid=float(np.polyval(p, 0.5 * (a + b) * H)))
        else:
            fit["%g-%g" % (a, b)] = None
    res["delta_fit"] = fit
    vf = {}
    for (a, b) in ((1.0, 4.0), (1.0, 6.0)):
        m = (xh >= a) & (xh <= b) & np.isfinite(d_vis)
        if m.sum() >= 5:
            p = np.polyfit(xh[m] * H, d_vis[m], 1)
            pred = np.polyval(p, xh[m] * H)
            ss = float(((d_vis[m] - d_vis[m].mean()) ** 2).sum())
            vf["%g-%g" % (a, b)] = dict(slope=float(p[0]), r2=(1 - float(((d_vis[m] - pred) ** 2).sum()) / ss) if ss > 0 else None,
                                       n=int(m.sum()), d_mid=float(np.polyval(p, 0.5 * (a + b) * H)))
        else:
            vf["%g-%g" % (a, b)] = None
    res["dvis_fit"] = vf
    res["interior_frac_1_6"] = float(interior[(xh >= 1) & (xh <= 6)].mean())
    # длина пузыря по u10<0 и по ψ
    neg = (U10 < 0) & lo
    res["bubble_u10_xh"] = ([float(xh[neg].min()), float(xh[neg].max())] if neg.any() else None)
    Lb = res["reattach_u10"] - res["sep_u10"] if res.get("reattach_u10") is not None and res.get("sep_u10") is not None else None
    res["bubble_L_over_H_u10"] = Lb
    if Lb is not None:
        res["bubble_L_over_dx"] = Lb * H / res["dx_crest"]
    elif res["bubble_psi"]:
        res["bubble_L_over_dx"] = res["bubble_psi"]["L_over_H"] * H / res["dx_crest"]
    else:
        res["bubble_L_over_dx"] = None
    # ширина зоны lee_f > 0.5 и её сравнение с пузырём поля
    # w у земли (нисходящий/восходящий): минимум w вдоль гребня
    wmin = np.nanmin(g["w"]) if np.isfinite(g["w"]).any() else None
    res["w_min"] = None if wmin is None else float(wmin)
    return res


def fmt(v, p=2):
    return "-" if v is None or (isinstance(v, float) and math.isnan(v)) else (f"{v:.{p}f}" if isinstance(v, float) else str(v))


def main():
    files = sorted(f for f in os.listdir(OUT) if f.endswith(".lts.csv"))
    allres = []
    for f in files:
        r = analyze(os.path.join(OUT, f))
        allres.append(r)
        print(r["case"], r["ridge"], "sep", fmt(r["sep_u10"]), "reat", fmt(r["reattach_u10"]), "maxsw", r["max_sigma_w_all"] and (fmt(r["max_sigma_w_all"]["xh"]), fmt(r["max_sigma_w_all"]["agl"]), r["max_sigma_w_all"]["src"]), file=sys.stderr)
    json.dump(allres, open(os.path.join(OUT, "summary.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
