"""Ротор как цепочка «сток + вихрь» (SWD9 v2). Звено — прямой отрезок вдоль оси хребта: вихрь Γ (ток) + линейный сток q
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
# S_c: распад вихря при S ≈ 1,0–1,3 (Leibovich 1978; Escudier 1988)
DEFAULTS = dict(core=None, slope_min=0.27, l_link=None, E=0.09, S_c=(1.0, 1.3), mass="reattach", apply_state=True,
                patch=1.5, tol=2e-3, maxfev=80, tail_frac=0.10, slope_smooth=1.0, s_max=6.0, n_max=3.0)


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


def _link_rule(terrain, c0, a, t, wv, ds, pr):
    pc = c0 + t * a
    step = min(ds, terrain.dx, terrain.dy, ds / 2.0)
    s, z = _line_profile(terrain, float(pc[0]), float(pc[1]), wv[0], wv[1], step)
    if s.size < 3:
        return None, s
    rule = profile_rule(s, z, ds, 0.0, pr["tail_frac"], 0.5)
    if rule is not None:        # уклон порога — профиль, сглаженный на ds_min (не 2·ds_min правила гребня)
        h = float(s[1] - s[0])
        zg = gaussian_filter1d(z, ds * pr["slope_smooth"] / h, mode="nearest")
        lee = (s >= rule["s_c"]) & (s <= rule["s_r"])
        rule["slope_gate"] = float(-np.gradient(zg, h)[lee].min()) if lee.sum() > 1 else 0.0
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


def _build(panels, links, pos, core, mass):
    """Цепочка по звеньям links с положениями pos[i] = (s, n)."""
    loops, sinks, sources = [], [], []
    for L, (s, n) in zip(links, pos):
        c = _geometry(L, s, n)
        half = 0.5 * (L.t1 - L.t0)
        pa, pb = c - half * np.append(L.a, 0.0), c + half * np.append(L.a, 0.0)
        xyz = np.linspace(pa, pb, max(3, int(np.ceil(2 * half / (2 * panels.ds_min))) + 1))
        zg = np.asarray(panels.height(xyz[:, 0], xyz[:, 1]), float)
        xyz[:, 2] = np.maximum(xyz[:, 2], zg + 2.0 * core)
        depth = float((xyz[:, 2] - zg).max()) + core
        loops.append(_loop(panels, xyz, L.Gamma, core, depth))
        sinks.append(dict(a=xyz[0].copy(), b=xyz[-1].copy(), q=L.q, core=core))
        if mass == "reattach":
            qa = np.append(L.xr - half * L.a, 0.0), np.append(L.xr + half * L.a, 0.0)
            ga = np.asarray(panels.height(np.array([qa[0][0], qa[1][0]]), np.array([qa[0][1], qa[1][1]])), float)
            zr = float(ga.max() + 2.0 * core)
            sources.append(dict(a=np.array([qa[0][0], qa[0][1], zr]), b=np.array([qa[1][0], qa[1][1], zr]), q=-L.q,
                                core=core))
    return dict(fil=_fp._merge(loops), sinks=sinks, sources=sources)


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


def chain_rotor(panels, bg, z0, infl=None, params=None):
    """Цепочка «сток + вихрь» по роторам (контракт SWD9 v2). → (chain, sigma, info)."""
    t_start = time.time()
    pr = dict(DEFAULTS)
    pr.update(params or {})
    terrain = panels.terrain
    ds = panels.ds_min
    core = 0.5 * ds if pr["core"] is None else float(pr["core"])
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
    all_links = []
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
                       length_m=float(t_hi - t_lo), n_links=len(good), S=None, S_c_range=tuple(pr["S_c"]), state="нет",
                       H=float(H))
            if good:
                lens = np.array([L.t1 - L.t0 for L in good])
                G = float((np.array([L.Gamma for L in good]) * lens).sum() / lens.sum())
                q = float((np.array([L.q for L in good]) * lens).sum() / lens.sum())
                S = float(G / abs(q)) if q != 0 else float("inf")
                rec["S"] = S
                lo, hi = pr["S_c"]
                rec["state"] = "есть" if S < lo else ("дышит" if S <= hi else "нет")
            info["rotors"].append(rec)
            if good and (rec["state"] != "нет" or not pr["apply_state"]):
                all_links += good
    chain = dict(fil=F.Filaments(), sinks=[], sources=[])
    sigma = sigma_bg
    if all_links:
        chain, sigma, recs = _equilibrium(panels, bg, infl, all_links, core, pr, U_ref, solve, sigma_bg)
        info["links"] = recs
    info["mass_balance"] = mass_balance(chain)
    info["n_solves"] = counter["n"]
    info["t_s"] = time.time() - t_start
    return chain, sigma, info


def _equilibrium(panels, bg, infl, links, core, pr, U_ref, solve, sigma_bg):
    K = len(links)
    x0 = np.array([[0.5 * L.len_x / L.H, 0.5] for L in links]).ravel()
    zhat = np.array([0.0, 0.0, 1.0])
    state = dict(last=None)
    hmin = 1.5 * core

    def pos_of(x):
        return [(x[2 * i] * links[i].H, max(x[2 * i + 1] * links[i].H, 0.0)) for i in range(K)]

    def fun(x):
        pos = pos_of(x)
        chain = _build(panels, links, pos, core, pr["mass"])
        sigma = solve(chain_extra(chain))
        mids = np.array([_geometry(L, s, n) for L, (s, n) in zip(links, pos)])
        v = _mid_velocity(panels, bg, sigma, chain, mids)
        r = np.zeros(2 * K)
        for i, L in enumerate(links):
            r[2 * i] = v[i] @ np.append(L.na, 0.0)
            r[2 * i + 1] = v[i] @ zhat
        state["last"] = (x.copy(), r / U_ref, chain, sigma)
        return r / U_ref
    try:
        x = root(fun, x0, method="hybr", options=dict(maxfev=int(pr["maxfev"]), xtol=1e-6)).x
    except Exception:
        x = x0
    if state["last"] is None or not np.array_equal(state["last"][0], x):
        fun(x)
    _, r, chain, sigma = state["last"]
    pos = pos_of(x)
    ok = []
    recs = []
    for i, L in enumerate(links):
        s, n = pos[i]
        zc = _geometry(L, s, n)
        h = zc[2] - float(panels.height(zc[0], zc[1]))
        res = float(max(abs(r[2 * i]), abs(r[2 * i + 1])))
        conv = bool(np.isfinite(res) and res < pr["tol"] and 0 < s <= pr["s_max"] * L.H and hmin <= h
                    and n <= pr["n_max"] * L.H)
        ok.append(conv)
        recs.append(dict(rotor=L.rotor, k=L.k, s=float(s), n=float(n), Gamma=L.Gamma, q=L.q, converged=conv,
                         residual=res, x_c=(float(L.xc[0]), float(L.xc[1])), x_r=(float(L.xr[0]), float(L.xr[1])),
                         h=float(h)))
    if not all(ok):
        keep = [i for i in range(K) if ok[i]]
        if not keep:
            return dict(fil=F.Filaments(), sinks=[], sources=[]), sigma_bg, recs
        chain = _build(panels, [links[i] for i in keep], [pos[i] for i in keep], core, pr["mass"])
        sigma = solve(chain_extra(chain))
    return chain, sigma, recs
