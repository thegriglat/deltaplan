"""Ротор как цепочка «сток + вихрь» (SWD9 v3). Звено — прямой отрезок вдоль оси хребта: вихрь Γ (ток) + линейный сток q
(заряд), комплексная сила (Q − iΓ)·log z, течение спиральное. Притяжение к склону — отражение стока в земле (панели),
масса сохраняется: источник на линии присоединения. Γ — из потока завихренности со склона, q — из вовлечения слоя
смешения, положение — из равновесия. Концы ротора — на рельефе (участок хребта с подветренным уклоном выше порога).
Только вызывает panels3d, filaments3d и сборку хребтов sheet3d."""
import time

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.optimize import root

import filaments3d as F
import panels3d as P
from panels3d import influence as _inf
from panels3d.jh import _line_profile
from panels3d.terrain import u_ref_of
from rotor3d.rotor import profile_rule
from sheet3d import foppl as _fp
from sheet3d.sheet import _loop

# E: расход вовлечения на единицу длины слоя = ½·dδ_ω/dx·ΔU; dδ_ω/dx = 0,181 (Brown & Roshko 1974, U2 = 0) -> 0,09
# S_c: распад вихря S_c ∈ [0,9; 1,2] (Spall, Gatski & Grosch 1987, NASA ICASE 87-3; SWD9 v4); E по умолчанию 0,05 (SWD-16)
# R_rule: радиус ядра звена r_c = R_rule·(x_r − x_c), то же правило, что SWD7 v2 (core — только для отладки: единое число)
# keep_unconverged: оставить цепочку в положениях последней итерации и без равновесия (диагностика: |u_min|/U)
# n_corr: число поправок «равновесие с панелями» (решений панелей n_corr + 1 сверх фона; контракт: ≤ 4)
DEFAULTS = dict(core=None, R_rule=0.25, slope_min=0.27, l_link=None, E=0.05, S_c=(0.9, 1.2), mass="reattach",
                apply_state=True, patch=1.5, tol=2e-3, maxfev=80, tail_frac=0.10, slope_smooth=1.0, s_max=6.0,
                n_max=3.0, n_corr=2, keep_unconverged=False, position="geometry", z_probe=10.0, n_probe=24)
# position: "geometry" (v5, по умолчанию) — s = (x_r − x_c)/2, n = r_c, без равновесия, 1 решение панелей с цепочкой
#   (+ 1, если часть роторов в state "нет" и поле остальных нужно без них); "equilibrium" — v4 (для сравнения)
# z_probe, n_probe: u_min_over_U — u∥ на z_probe м над землёй в n_probe точках между x_c и x_r (v5)


# ---------- линейные источники/стоки ----------
def segment_velocity(a, b, q, core, x, y, z):
    """Скорость (u, v, w) от равномерного линейного источника a→b, q м²/с на единицу длины (q < 0 — сток),
    регуляризация Розенхеда — Мура (δ = core). Точка источника в 3D: q/(4π)·r/|r|³, проинтегрировано по отрезку."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = float(np.linalg.norm(d))
    t = d / L
    x = np.asarray(x, float)
    shp = x.shape
    px, py, pz = (np.ravel(np.asarray(c, float)) for c in np.broadcast_arrays(x, y, z))
    r0 = np.stack([px - a[0], py - a[1], pz - a[2]], 1)
    s0 = r0 @ t
    dp = r0 - s0[:, None] * t[None]
    rho2 = (dp * dp).sum(1) + core ** 2
    e1, e0 = L - s0, s0
    s1, s2 = np.sqrt(e1 * e1 + rho2), np.sqrt(e0 * e0 + rho2)
    T = 1.0 / s1 - 1.0 / s2
    Pf = (e1 / s1 + e0 / s2) / rho2
    v = q / (4 * np.pi) * (T[:, None] * t[None] + Pf[:, None] * dp)
    return tuple(v[:, i].reshape(shp) for i in range(3))


def chain_extra(chain):
    """Поле цепочки (x, y, z) → (u, v, w): нити + стоки + источники; пусто — None."""
    fil = chain.get("fil")
    items = list(chain.get("sinks", [])) + list(chain.get("sources", []))
    if (fil is None or len(fil.seg) == 0) and not items:
        return None

    def f(x, y, z):
        if fil is not None and len(fil.seg):
            u, v, w = F.induced(fil, x, y, z)
        else:
            u = v = w = np.zeros(np.shape(np.broadcast(np.asarray(x, float), y, z)))
        for it in items:
            du, dv, dw = segment_velocity(it["a"], it["b"], it["q"], it["core"], x, y, z)
            u, v, w = u + du, v + dv, w + dw
        return u, v, w
    return f


def velocity_chain(panels, sigma, bg, chain, x, y, z, z0, U_ref=None, infl=None):
    """(u, v, w) = velocity_jh(..., extra=поле цепочки, couple=True)."""
    return P.velocity_jh(panels, sigma, bg, x, y, z, z0, U_ref=U_ref, extra=chain_extra(chain), infl=infl, couple=True)


# ---------- станции и касательная скорость ----------
def _station(panels, bg, pt, patch):
    c = panels.c
    d = np.hypot(c[:, 0] - pt[0], c[:, 1] - pt[1])
    rr = patch * panels.ds_min
    idx = np.nonzero(d <= rr)[0]
    while idx.size < 4 and rr < 6 * panels.ds_min:
        rr *= 1.3
        idx = np.nonzero(d <= rr)[0]
    cp = c[idx]
    bgp = np.stack([np.asarray(q, float) for q in bg(cp[:, 0], cp[:, 1], cp[:, 2])], 1)
    return dict(pt=np.asarray(pt, float), idx=idx, cp=cp, bgp=bgp, d=(cp[:, :2] - pt))


def _tangent(panels, sigma, st, wv):
    pv = _inf.panel_velocity(panels, sigma, st["cp"], "auto", self_idx=st["idx"])
    U = st["bgp"] + pv
    nn = panels.n[st["idx"]]
    ut = U - (U * nn).sum(1)[:, None] * nn
    v = ut[:, 0] * wv[0] + ut[:, 1] * wv[1]
    if len(v) >= 4:
        A = np.column_stack([np.ones(len(v)), st["d"] @ wv, st["d"] @ np.array([-wv[1], wv[0]])])
        return float(np.linalg.lstsq(A, v, rcond=None)[0][0])
    return float(v.mean())


# ---------- роторы: участки хребта с уклоном выше порога ----------
def _runs(mask):
    out, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j + 1 < n and mask[j + 1]:
                j += 1
            out.append((i, j))
            i = j + 1
        else:
            i += 1
    return out


def lee_slope(s, z, s_c, s_r, smooth_m):
    """Правило уклона для порога 0,27 (SWD9 v3, одно для всех мест и для SWD7): максимум подветренного уклона профиля
    рельефа вдоль ветра между гребнем s_c и точкой присоединения s_r при сглаживании `smooth_m` = 1·ds_min
    (масштаб представления рельефа; без дополнительного сглаживания). Уклон > 0 — спуск по ветру."""
    h = float(s[1] - s[0])
    zg = gaussian_filter1d(np.asarray(z, float), smooth_m / h, mode="nearest")
    lee = (s >= s_c) & (s <= s_r)
    return float(-np.gradient(zg, h)[lee].min()) if lee.sum() > 1 else 0.0


def _link_rule(terrain, c0, a, t, wv, ds, pr):
    pc = c0 + t * a
    step = min(ds, terrain.dx, terrain.dy, ds / 2.0)
    s, z = _line_profile(terrain, float(pc[0]), float(pc[1]), wv[0], wv[1], step)
    if s.size < 3:
        return None, s
    rule = profile_rule(s, z, ds, 0.0, pr["tail_frac"], 0.5)
    if rule is not None:
        rule["slope_gate"] = lee_slope(s, z, rule["s_c"], rule["s_r"], ds * pr["slope_smooth"])
    return rule, s


def _rotor_intervals(terrain, ax, wv, ds, pr):
    """Непрерывные участки оси [t_lo, t_hi], где подветренный уклон (сглаженный профиль вдоль ветра) > slope_min."""
    dt = max(ds, (ax["t1"] - ax["t0"]) / 400.0)
    ts = ax["t0"] + dt * (np.arange(int((ax["t1"] - ax["t0"]) // dt) + 1) + 0.5)
    ok = np.zeros(len(ts), bool)
    for i, t in enumerate(ts):
        rule, _ = _link_rule(terrain, ax["c0"], ax["a"], t, wv, ds, pr)
        ok[i] = rule is not None and rule["slope_gate"] > pr["slope_min"]
    out = []
    for i, j in _runs(ok):
        lo, hi = max(ax["t0"], ts[i] - 0.5 * dt), min(ax["t1"], ts[j] + 0.5 * dt)
        out.append((float(lo), float(hi)))
    return out


class _Link:
    pass


def _make_links(panels, bg, sigma_bg, terrain, ridge, ax, wind, U_ref, ds, pr, rotor_id, t_lo, t_hi, H):
    wv = np.asarray(wind, float) / np.hypot(*wind)
    na = np.array([ax["a"][1], -ax["a"][0]])
    if na @ wv < 0:
        na = -na
    l_link = 2.0 * H if pr["l_link"] is None else float(pr["l_link"])
    K = max(1, int(np.ceil((t_hi - t_lo) / l_link)))
    edges = np.linspace(t_lo, t_hi, K + 1)
    links = []
    for k in range(K):
        L = _Link()
        L.rotor, L.k = rotor_id, k
        L.t0, L.t1 = float(edges[k]), float(edges[k + 1])
        L.tm = 0.5 * (L.t0 + L.t1)
        L.a, L.wv, L.na = ax["a"], wv, na
        L.P = ax["c0"] + L.tm * ax["a"]
        rule, s = _link_rule(terrain, ax["c0"], ax["a"], L.tm, wv, ds, pr)
        L.valid = rule is not None
        if not L.valid:
            links.append(L)
            continue
        L.rule, L.s_prof = rule, s
        step = float(s[1] - s[0])
        L.dzs = np.gradient(rule["zs"], step)
        L.H = max(rule["H"], 2 * ds)
        L.xc = L.P + rule["s_c"] * wv
        L.xr = L.P + rule["s_r"] * wv
        L.len_x = rule["s_r"] - rule["s_c"]
        L.core = float(pr["R_rule"]) * L.len_x if pr["core"] is None else float(pr["core"])
        st_c, st_r = _station(panels, bg, L.xc, pr["patch"]), _station(panels, bg, L.xr, pr["patch"])
        L.uc, L.ur = _tangent(panels, sigma_bg, st_c, wv), _tangent(panels, sigma_bg, st_r, wv)
        dp = 0.5 * (L.uc ** 2 - L.ur ** 2)
        L.Gamma = float(dp * L.len_x / U_ref)
        L.q = float(-pr["E"] * L.uc * L.len_x)
        L.valid = L.Gamma > 0 and L.q < 0 or (pr["E"] == 0 and L.Gamma > 0)
        links.append(L)
    return links


def _geometry(L, s, n):
    """Положение оси звена: s — по ветру от гребня, n — по нормали к сглаженному склону. → (центр xyz)."""
    sp = L.rule["s_c"] + s
    zf = float(np.interp(sp, L.s_prof, L.rule["zs"]))
    sl = float(np.interp(sp, L.s_prof, L.dzs))
    nrm = np.array([-sl, 1.0]) / np.hypot(sl, 1.0)
    xy = L.P + (sp + n * nrm[0]) * L.wv
    return np.array([xy[0], xy[1], zf + n * nrm[1]])


def _plane(L, s):
    """Касательная плоскость земли у оси звена (сглаженный склон): точка и единичная нормаль."""
    sp = L.rule["s_c"] + s
    zf = float(np.interp(sp, L.s_prof, L.rule["zs"]))
    sl = float(np.interp(sp, L.s_prof, L.dzs))
    xy = L.P + sp * L.wv
    nv = np.append(-sl * L.wv, 1.0)
    return np.array([xy[0], xy[1], zf]), nv / np.linalg.norm(nv)


def _reflect(p, g, nv):
    p = np.asarray(p, float)
    return p - 2.0 * ((p - g) @ nv)[..., None] * nv if p.ndim > 1 else p - 2.0 * float((p - g) @ nv) * nv


def _build(panels, links, pos, mass, images=False):
    """Цепочка по звеньям links с положениями pos[i] = (s, n); ядро — у каждого звена своё (L.core).
    images=True — ещё и зеркальное изображение центральных отрезков в касательной плоскости земли у оси звена
    (вихрь Γ -> -Γ, стоки/источники — тот же знак): для итераций равновесия без пересчёта панелей."""
    loops, sinks, sources = [], [], []
    im_f, im_items = [], []
    for L, (s, n) in zip(links, pos):
        core = L.core
        c = _geometry(L, s, n)
        half = 0.5 * (L.t1 - L.t0)
        pa, pb = c - half * np.append(L.a, 0.0), c + half * np.append(L.a, 0.0)
        xyz = np.linspace(pa, pb, max(3, int(np.ceil(2 * half / (2 * panels.ds_min))) + 1))
        zg = np.asarray(panels.height(xyz[:, 0], xyz[:, 1]), float)
        xyz[:, 2] = np.maximum(xyz[:, 2], zg + core)
        depth = float((xyz[:, 2] - zg).max()) + core
        loops.append(_loop(panels, xyz, L.Gamma, core, depth))
        sinks.append(dict(a=xyz[0].copy(), b=xyz[-1].copy(), q=L.q, core=core))
        src = None
        if mass == "reattach":
            qa = np.append(L.xr - half * L.a, 0.0), np.append(L.xr + half * L.a, 0.0)
            ga = np.asarray(panels.height(np.array([qa[0][0], qa[1][0]]), np.array([qa[0][1], qa[1][1]])), float)
            zr = float(ga.max() + core)
            src = dict(a=np.array([qa[0][0], qa[0][1], zr]), b=np.array([qa[1][0], qa[1][1], zr]), q=-L.q, core=core)
            # длина стока по рельефу (z вдоль оси меняется) и источника (горизонтальный отрезок) различна: расход сохраняется
            # пересчётом q источника (на ровной оси множитель 1; v5 — реальный рельеф, mass_balance = 0 до 1e-9)
            src["q"] = -L.q * float(np.linalg.norm(sinks[-1]["b"] - sinks[-1]["a"])) / float(np.linalg.norm(src["b"] - src["a"]))
            sources.append(src)
        if images:
            g, nv = _plane(L, s)
            im_f.append(F.line(_reflect(xyz, g, nv), -L.Gamma, core, anchored_ends=False))
            im_items.append(dict(a=_reflect(xyz[0], g, nv), b=_reflect(xyz[-1], g, nv), q=L.q, core=core))
            if src is not None:
                im_items.append(dict(a=_reflect(src["a"], g, nv), b=_reflect(src["b"], g, nv), q=src["q"], core=core))
    chain = dict(fil=_fp._merge(loops), sinks=sinks, sources=sources)
    if images:
        return chain, dict(fil=_fp._merge(im_f), sinks=im_items, sources=[])
    return chain


def mass_balance(chain):
    tot = 0.0
    for it in list(chain["sinks"]) + list(chain["sources"]):
        tot += it["q"] * float(np.linalg.norm(np.asarray(it["b"]) - np.asarray(it["a"])))
    return tot


def _mid_velocity(panels, bg, sigma, chain, pts):
    """Скорость в точках: фон + панели + поле цепочки (линия звена в своей середине самоиндукции не даёт — симметрия)."""
    pts = np.asarray(pts, float)
    pv = _inf.panel_velocity(panels, sigma, pts, "auto")
    b = np.stack([np.asarray(q, float) for q in bg(pts[:, 0], pts[:, 1], pts[:, 2])], 1)
    ex = chain_extra(chain)
    e = np.stack(ex(pts[:, 0], pts[:, 1], pts[:, 2]), 1) if ex is not None else 0.0
    return b + pv + e


def _swirl(L):
    """Число закрутки звена (SWD9 v4): S = v_θ,max / W, v_θ,max = |Γ|/(2π r_c), W = |q|·l_link/(π r_c²)."""
    ll = L.t1 - L.t0
    if L.q == 0:
        return float("inf")
    return float(abs(L.Gamma) * L.core / (2.0 * abs(L.q) * ll))


def chain_rotor(panels, bg, z0, infl=None, params=None):
    """Цепочка «сток + вихрь» по роторам (контракт SWD9 v4). → (chain, sigma, info)."""
    t_start = time.time()
    pr = dict(DEFAULTS)
    pr.update(params or {})
    terrain = panels.terrain
    ds = panels.ds_min
    if infl is None:
        infl = P.assemble(panels, "auto")
    counter = dict(n=0)

    def solve(extra):
        counter["n"] += 1
        return P.solve(panels, bg, extra, infl)[0]
    sigma_bg = solve(None)
    counter["n"] = 0
    U_ref, _ = u_ref_of(bg, terrain)
    wind = _fp._wind(bg, terrain)
    ridges = _fp.find_ridges(terrain, wind, ds)
    info = dict(links=[], rotors=[], n_ridges=len(ridges), mass_balance=0.0, t_s=0.0, n_solves=0, params=dict(pr))
    all_links, cand, applied = [], [], set()
    for r in ridges:
        ax = _fp._axis_of(r, wind, r["dc"])
        H = max(_fp._ridge_height(terrain, r, wind), 2 * ds)
        wv = np.asarray(wind, float) / np.hypot(*wind)
        for (t_lo, t_hi) in _rotor_intervals(terrain, ax, wv, ds, pr):
            rid = len(info["rotors"])
            links = _make_links(panels, bg, sigma_bg, terrain, r, ax, wind, U_ref, ds, pr, rid, t_lo, t_hi, H)
            good = [L for L in links if L.valid]
            ends = (ax["c0"] + t_lo * ax["a"], ax["c0"] + t_hi * ax["a"])
            rec = dict(axis_from=(float(ends[0][0]), float(ends[0][1])), axis_to=(float(ends[1][0]), float(ends[1][1])),
                       length_m=float(t_hi - t_lo), n_links=len(good), S=None, Gamma_over_q=None,
                       S_c_range=tuple(pr["S_c"]), state="нет", H=float(H))
            if good:
                lens = np.array([L.t1 - L.t0 for L in good])
                G = float((np.array([L.Gamma for L in good]) * lens).sum() / lens.sum())
                q = float((np.array([L.q for L in good]) * lens).sum() / lens.sum())
                rec["Gamma_over_q"] = float(G / abs(q)) if q != 0 else float("inf")
                S = max(_swirl(L) for L in good)
                rec["S"] = S
                lo, hi = pr["S_c"]
                rec["state"] = "есть" if S < lo else ("дышит" if S <= hi else "нет")
            rec["u_min_over_U"] = None
            info["rotors"].append(rec)
            cand += good
            if good and (rec["state"] != "нет" or not pr["apply_state"]):
                all_links += good
                applied.add(rid)
    chain = dict(fil=F.Filaments(), sinks=[], sources=[])
    sigma = sigma_bg
    if pr["position"] == "geometry":
        if cand:
            chain, sigma, recs = _geometry_chain(panels, bg, z0, infl, cand, applied, pr, U_ref, solve, sigma_bg, info)
            info["links"] = recs
    elif all_links:
        chain, sigma, recs = _equilibrium(panels, bg, all_links, pr, U_ref, solve, sigma_bg)
        info["links"] = recs
    info["mass_balance"] = mass_balance(chain)
    info["n_solves"] = counter["n"]
    info["t_s"] = time.time() - t_start
    return chain, sigma, info


def _geometry_chain(panels, bg, z0, infl, cand, applied, pr, U_ref, solve, sigma_bg, info):
    """SWD9 v5: положение звена по геометрии, без условия равновесия: s = (x_r − x_c)/2 от гребня вдоль ветра, n = r_c по
    нормали к склону (звено держит отражение: провод + зеркало). Одно решение панелей со всеми звеньями-кандидатами
    (диагностика: невязка в середине звена, u_min_over_U по ротору — даже при state "нет"); если часть роторов "нет" и
    apply_state — второе решение только с применёнными. Итого n_solves ≤ 2 сверх фона."""
    pos = [(0.5 * L.len_x, L.core) for L in cand]
    chain_all = _build(panels, cand, pos, pr["mass"])
    sigma_all = solve(chain_extra(chain_all))
    mids = np.array([_geometry(L, s, n) for L, (s, n) in zip(cand, pos)])
    v = _mid_velocity(panels, bg, sigma_all, chain_all, mids)
    recs = []
    for i, L in enumerate(cand):
        s, n = pos[i]
        na3 = np.append(L.na, 0.0)
        res = float(np.hypot(v[i] @ na3, v[i, 2]) / U_ref)
        h = mids[i, 2] - float(panels.height(mids[i, 0], mids[i, 1]))
        recs.append(dict(rotor=L.rotor, k=L.k, s=float(s), n=float(n), core=float(L.core), Gamma=L.Gamma, q=L.q, S=_swirl(L),
                         converged=True, on_ground=False, residual=res, x_c=(float(L.xc[0]), float(L.xc[1])),
                         x_r=(float(L.xr[0]), float(L.xr[1])), h=float(h)))
    # u∥ на z_probe м между x_c и x_r, поле ротора есть (диагностика даже при state "нет")
    umin = {}
    for L in cand:
        t = np.linspace(0.0, 1.0, int(pr["n_probe"]))
        xy = L.P[None] + (L.rule["s_c"] + t[:, None] * L.len_x) * L.wv[None]
        z = np.asarray(panels.height(xy[:, 0], xy[:, 1]), float) + float(pr["z_probe"])
        u, vv, _ = velocity_chain(panels, sigma_all, bg, chain_all, xy[:, 0], xy[:, 1], z, z0, U_ref=U_ref, infl=infl)
        up = (np.asarray(u) * L.wv[0] + np.asarray(vv) * L.wv[1]) / U_ref
        umin[L.rotor] = min(umin.get(L.rotor, np.inf), float(np.nanmin(up)))
    for rid, val in umin.items():
        info["rotors"][rid]["u_min_over_U"] = val
    keep = [i for i, L in enumerate(cand) if L.rotor in applied]
    if len(keep) == len(cand):
        return chain_all, sigma_all, recs
    if not keep:
        return dict(fil=F.Filaments(), sinks=[], sources=[]), sigma_bg, recs
    chain = _build(panels, [cand[i] for i in keep], [pos[i] for i in keep], pr["mass"])
    return chain, solve(chain_extra(chain)), recs


def _equilibrium(panels, bg, links, pr, U_ref, solve, sigma_bg):
    """Положения звеньев. Итерации — без пересчёта панелей: поле = фон + панели фона + цепочка + её зеркальное
    изображение в касательной плоскости земли у оси. Затем n_corr раз: решение панелей с полем цепочки, смещение
    (точное − модельное) в серединах звеньев, новое равновесие модели со смещением. Решений: n_corr + 1."""
    K = len(links)
    zhat = np.array([0.0, 0.0, 1.0])
    rc = np.array([L.core for L in links])
    Hh = np.array([L.H for L in links])
    na3 = np.array([np.append(L.na, 0.0) for L in links])

    def pos_of(x):
        return [(x[2 * i] * Hh[i], rc[i] + Hh[i] * x[2 * i + 1] ** 2) for i in range(K)]

    def mids_of(pos):
        return np.array([_geometry(L, s, n) for L, (s, n) in zip(links, pos)])

    def model_v(x, off):
        pos = pos_of(x)
        chain, img = _build(panels, links, pos, pr["mass"], images=True)
        v = _mid_velocity(panels, bg, sigma_bg, chain, mids_of(pos))
        e = chain_extra(img)
        if e is not None:
            m = mids_of(pos)
            v = v + np.stack(e(m[:, 0], m[:, 1], m[:, 2]), 1)
        return v + off

    def residual(v, active, y):
        r = np.zeros(2 * K)
        for i in range(K):
            r[2 * i] = v[i] @ na3[i]
            r[2 * i + 1] = y[i] if active[i] else v[i] @ zhat
        return r / U_ref

    def run_model(x0, off, active):
        x = np.array(x0, float)
        for _ in range(3):
            def fun(xx):
                xx = xx.copy()
                for i in range(K):
                    if active[i]:
                        xx[2 * i + 1] = 0.0
                v = model_v(xx, off)
                return residual(v, active, xx[1::2])
            try:
                x = root(fun, x, method="hybr", options=dict(maxfev=int(pr["maxfev"]), xtol=1e-6)).x
            except Exception:
                pass
            for i in range(K):
                if active[i]:
                    x[2 * i + 1] = 0.0
            v = model_v(x, off)
            changed = False
            for i in range(K):
                if not active[i] and Hh[i] * x[2 * i + 1] ** 2 < 0.05 * Hh[i] and v[i, 2] < 0:
                    active[i], changed = True, True        # корень уходит под границу n = r_c: n фиксируется, v_z < 0
                elif active[i] and v[i, 2] > 0:
                    active[i], changed = False, True       # прижимающей скорости нет: звено отпускается
                    x[2 * i + 1] = 0.3
            if not changed:
                break
        return x

    active = [False] * K
    x = np.array([[0.5 * L.len_x / L.H, np.sqrt(max(0.5 * L.H - L.core, 0.1 * L.H) / L.H)] for L in links]).ravel()
    off = np.zeros((K, 3))
    x = run_model(x, off, active)
    chain = _build(panels, links, pos_of(x), pr["mass"])
    sigma = solve(chain_extra(chain))
    for it in range(int(pr["n_corr"])):
        pos = pos_of(x)
        mids = mids_of(pos)
        true = _mid_velocity(panels, bg, sigma, chain, mids)
        mod = model_v(x, 0.0)
        off = true - mod
        x = run_model(x, off, active)
        chain = _build(panels, links, pos_of(x), pr["mass"])
        sigma = solve(chain_extra(chain))
    pos = pos_of(x)
    mids = mids_of(pos)
    v = _mid_velocity(panels, bg, sigma, chain, mids)
    ok, recs = [], []
    for i, L in enumerate(links):
        s, n = pos[i]
        h = mids[i, 2] - float(panels.height(mids[i, 0], mids[i, 1]))
        rs, rz = float(abs(v[i] @ na3[i]) / U_ref), float(v[i, 2] / U_ref)
        on_g = bool(active[i])
        res = rs if on_g else float(max(rs, abs(rz)))
        conv = bool(np.isfinite(res) and res < pr["tol"] and 0 < s <= pr["s_max"] * L.H and L.core * 0.999 <= n
                    and n <= max(pr["n_max"] * L.H, 1.5 * L.core) and (not on_g or rz < pr["tol"]))
        ok.append(conv)
        recs.append(dict(rotor=L.rotor, k=L.k, s=float(s), n=float(n), core=float(L.core), Gamma=L.Gamma, q=L.q,
                         S=_swirl(L), converged=conv, on_ground=on_g, residual=res,
                         x_c=(float(L.xc[0]), float(L.xc[1])), x_r=(float(L.xr[0]), float(L.xr[1])), h=float(h)))
    if not all(ok) and not pr["keep_unconverged"]:
        keep = [i for i in range(K) if ok[i]]
        if not keep:
            return dict(fil=F.Filaments(), sinks=[], sources=[]), sigma_bg, recs
        chain = _build(panels, [links[i] for i in keep], [pos[i] for i in keep], pr["mass"])
        sigma = solve(chain_extra(chain))
    return chain, sigma, recs
