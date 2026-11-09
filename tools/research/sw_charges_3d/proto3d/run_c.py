"""Опыты прототипа C в 3D. Запуск: ./py -m proto3d.run_c neutral|sens|thresh|closure|terrain  → out/proto3d/c_*.json"""
import json, os, sys, time
import numpy as np
from . import pc3d, rings, ground
from .run_a import save

UST, KAP = 0.4, 0.4
S_LOG = lambda z: UST / (KAP * z)
ZERO = lambda z: 0.0
NP = dict(nprobe=800, nlines=4, nline_pts=96)


def neutral(seeds=3, levels=(10, 25, 60, 120), P=None, tag="base", **kw):
    P = P or pc3d.Params()
    rng = np.random.default_rng(11)
    out = []
    for zp in levels:
        t0 = time.time()
        r = pc3d.stats_at_level(rng, zp, S_LOG, ZERO, P, seeds=seeds, **NP, **kw)
        r.update(tag=tag, ratio_sw=r["sigma_w"] / (1.25 * UST), Lw_over_z=r["L_w"] / zp, uw_over_ust2=r["uw"] / UST ** 2,
                 su_over_sw=r["sigma_u"] / max(r["sigma_w"], 1e-12), wall_s=time.time() - t0)
        out.append(r)
        print(tag, zp, {k: round(v, 3) for k, v in r.items() if isinstance(v, float)}, flush=True)
    return out


def sens():
    res = []
    for tag, P, kw in [("c/R=0.25", pc3d.Params(c_over_R=0.25), {}), ("c/R=0.5", pc3d.Params(c_over_R=0.5), {}),
                       ("R=ℓ", pc3d.Params(Rfac=1.0), {}), ("φ=30°", pc3d.Params(phi_deg=30), {}),
                       ("φ=60°", pc3d.Params(phi_deg=60), {}), ("nseg=24", pc3d.Params(nseg=24), {}),
                       ("win=3", pc3d.Params(), dict(win=3.0)), ("win=6", pc3d.Params(), dict(win=6.0)),
                       ("L=8ℓ", pc3d.Params(), dict(Lfac=8.0)), ("L=16ℓ", pc3d.Params(), dict(Lfac=16.0))]:
        res += neutral(seeds=2, levels=(25,), P=P, tag=tag, **kw)
    return res


def thresh():
    res = []
    for zc in (30.0, 60.0):
        N = UST / (2 * KAP * zc)  # Ri(z_c) = 1/4 в логарифмическом слое
        for fk in ("step", "none"):
            P = pc3d.Params(fkind=fk)
            rng = np.random.default_rng(5)
            for zp in (5, 10, 20, 40, 80, 160):
                r = pc3d.stats_at_level(rng, zp, S_LOG, lambda z: N * N, P, seeds=2, **NP)
                r.update(z_c=zc, N=N, fkind=fk, Ri_z=(N * KAP * zp / UST) ** 2, ratio_sw=r["sigma_w"] / (1.25 * UST))
                res.append(r)
                print(zc, fk, zp, round(r["Ri_z"], 3), round(r["ratio_sw"], 3), r["n_rings"], flush=True)
    return res


def closure():
    """Локально-однородный ансамбль (S, N² const) на z = 25 м: c_K(Ri) = −⟨u'w'⟩/(ℓ²S²), c_σ = σ_w/(ℓ S)."""
    zp = 25.0
    S0 = UST / (KAP * zp)
    ell = KAP * zp
    res = []
    rng = np.random.default_rng(3)
    for Ri in (0.0, 0.05, 0.1, 0.15, 0.2, 0.24):
        r = pc3d.stats_at_level(rng, zp, lambda z: S0, lambda z: Ri * S0 ** 2, pc3d.Params(), seeds=3, **NP)
        r.update(Ri=Ri, cK=-r["uw"] / (ell * S0) ** 2, c_sigma=r["sigma_w"] / (ell * S0))
        res.append(r)
        print(Ri, round(r["cK"], 3), round(r["c_sigma"], 3), r["n_rings"], flush=True)
    return res


def terrain():
    from panels3d import bg_profile, bg_zero, velocity
    zp = 40.0
    ell = KAP * zp
    L = 12 * ell
    res = []
    for name, case, pt in [("flat", "flat", (0.0, 0.0)), ("windward", "hill", (-250.0, 0.0)), ("crest", "hill", (0.0, 0.0)),
                           ("lee", "hill", (250.0, 0.0))]:
        Ter = ground.flat_terrain(half=3000, dx=100) if case == "flat" else ground.gauss_hill_terrain(200.0, 250.0, 3000, 50)
        g = ground.Ground(Ter, [pt], ds_min=10.0, ds_max=500, focus_r=1.2 * L, growth=1.2)
        bg = bg_profile(6.0, 0.14, 300.0, Ter, wind_to=(1, 0), smooth_m=0.0)
        sig = g.solve_sigma(bg)
        z0 = float(g.height(np.array([pt[0]]), np.array([pt[1]]))[0])
        aglz = np.geomspace(2.0, 250.0, 40)
        Pcol = np.stack([np.full_like(aglz, pt[0]), np.full_like(aglz, pt[1]), z0 + aglz], 1)
        u = velocity(g.panels, sig, bg, Pcol[:, 0], Pcol[:, 1], Pcol[:, 2], backend="cupy")
        sp = np.hypot(u[0], u[1])
        Sz = np.gradient(sp, aglz)
        Sfun = lambda a, Sz=Sz, aglz=aglz: max(float(np.interp(a, aglz, Sz)), 1e-6)
        zx, zy = g.slope(np.array([pt[0]]), np.array([pt[1]]))
        nvec = np.array([-zx[0], -zy[0], 1.0]); nvec /= np.linalg.norm(nvec)
        rng = np.random.default_rng(21)
        P = pc3d.Params()
        sws, uws, nr = [], [], []
        for seed in range(3):
            ens = _site_ens(rng, g, pt, L, zp, Sfun, P, nvec)
            nr.append(ens["n_rings"])
            sigma_r = g.solve_sigma(bg_zero(), ens["S"], ens["A"], ens["SG"])
            m = 0.25 * L
            X = np.stack([pt[0] + rng.uniform(-m, m, 600), pt[1] + rng.uniform(-m, m, 600), np.zeros(600)], 1)
            X[:, 2] = g.height(X[:, 0], X[:, 1]) + zp
            ur = pc3d.vp.velocity(X, ens["S"], ens["A"], ens["SG"]).get() + g.panel_vel(sigma_r, X)
            sws.append(float(np.sqrt(np.mean(ur[:, 2] ** 2)))); uws.append(float(np.mean(ur[:, 0] * ur[:, 2])))
        r = dict(site=name, z_ground=z0, slope=float(np.hypot(zx[0], zy[0])), S_zp=Sfun(zp), N_panels=int(g.N), n_rings=int(np.mean(nr)),
                 sigma_w=float(np.mean(sws)), sigma_w_all=sws, uw=float(np.mean(uws)))
        res.append(r)
        print(name, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items() if k != "sigma_w_all"}, flush=True)
    return res


def _site_ens(rng, g, pt, L, zp, Sfun, P, nvec=None):
    """Ансамбль колец в прямоугольнике L×L вокруг pt: высоты — над землёй (агл); ориентация колец — как над ровной землёй (мировая вертикаль), не повёрнута к склону."""
    ens = pc3d.snapshot(rng, max(zp / 4, 0.5), zp * 4, L, lambda a: Sfun(a), lambda a: 0.0, P)
    S, A, SG = ens["S"], ens["A"], ens["SG"]
    nseg = P.nseg
    S = S.copy()
    S[:, 0] += pt[0] - L / 2; S[:, 1] += pt[1] - L / 2
    agl = S[:, 2].copy()
    S[:, 2] = g.height(S[:, 0], S[:, 1]) + agl
    below = S[:, 2] < g.height(S[:, 0], S[:, 1]) + 1.0
    bad = below.reshape(-1, nseg).any(1)
    keep = np.repeat(~bad, nseg)
    return dict(S=S[keep], A=A[keep], SG=SG[keep], n_rings=int((~bad).sum()))


if __name__ == "__main__":
    what = sys.argv[1]
    f = dict(neutral=neutral, sens=sens, thresh=thresh, closure=closure, terrain=terrain)[what]
    save(f"c_{what}.json", f())
