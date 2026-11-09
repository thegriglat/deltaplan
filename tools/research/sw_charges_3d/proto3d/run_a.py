"""Опыты прототипа A (SWC-6/13 → 3D): термик-шар R = 100 м, Δθ = 1 К над плоской землёй и склонами; нагретый склон потоком.
Запуск:  ./py -m proto3d.run_a blob|conv|flux|all   → out/proto3d/a_*.json"""
import json, os, sys, time
import numpy as np
from . import ground, pa3d, a_cases as ac
from panels3d import bg_uniform, bg_zero

OUT = os.path.join(os.path.dirname(__file__), "..", "out", "proto3d")
R0, GAP, DTH = 100.0, 15.0, 1.0


def sample_ring(g, run, xc, yc, rhos, naz=16, agl=10.0):
    th = np.arange(naz) * 2 * np.pi / naz
    out = []
    for rho in rhos:
        x = xc + rho * np.cos(th); y = yc + rho * np.sin(th)
        z = g.height(x, y) + agl
        P = np.stack([x, y, z], 1)
        u = run.induced(P)
        rad_in = -(u[:, 0] * np.cos(th) + u[:, 1] * np.sin(th))
        out.append(float(rad_in.mean()))
    return out


def plane_w(g, run, zc, xc, yc, R, n=61, half=6.0):
    ax = np.linspace(-half * R, half * R, n)
    X, Y = np.meshgrid(ax + xc, ax + yc, indexing="ij")
    X, Y = X.ravel(), Y.ravel()
    ok = (zc - g.height(X, Y)) > 20.0
    P = np.stack([X, Y, np.full_like(X, zc)], 1)[ok]
    w = run.induced(P)[:, 2]
    rho = np.hypot(P[:, 0] - xc, P[:, 1] - yc)
    dA = (ax[1] - ax[0]) ** 2
    return dict(wmax=float(w.max()), wmin=float(w.min()), pos=float(w[w > 0].sum() * dA), neg=float(-w[w < 0].sum() * dA),
                frac_neg_out=float(((w < 0) & (rho > 1.3 * R)).sum() / max(1, (rho > 1.3 * R).sum())),
                n_valid=int(ok.sum()), n_all=int(ok.size))


def run_blob(case, U, h=12.5, sg=1.3, T=90.0, dt=1.0, gap=GAP, snaps=(30, 60, 90), tag=None, ds_min=30.0, verbose=True):
    Ter, pt, wd = ac.make_case(case)
    g = ground.Ground(Ter, [pt], ds_min=ds_min, ds_max=500, focus_r=400)
    n, sl = ac.normal_at(g, *pt)
    z0 = float(g.height(np.array([pt[0]]), np.array([pt[1]]))[0])
    p0 = np.array([pt[0], pt[1], z0])
    ctr = p0 + n * (R0 + gap)
    parts = pa3d.ball_particles(ctr, R0, h, pa3d.b_of_dtheta(DTH), sg)
    keep = parts["x"][:, 2] > g.height(parts["x"][:, 0], parts["x"][:, 1]) + 2.0
    for k in parts:
        parts[k] = parts[k][keep]
    bg = bg_zero() if U == 0 else bg_uniform(U, wd)
    run = pa3d.Run(g, bg, parts, sg_over_h=sg)
    rec = dict(case=case, U=U, h=h, sg=sg, dt=dt, N_part=int(len(run.x)), N_pan=int(g.N), slope=sl, t=[], c=[], dn=[], B=[], snaps={})
    t0 = time.time()
    nst = int(round(T / dt))
    for k in range(nst):
        run.step(dt)
        c = run.centroid()
        rec["t"].append(run.t); rec["c"].append(c.tolist()); rec["dn"].append(ac.normal_dist(g, c)); rec["B"].append(run.B_total())
        if any(abs(run.t - s) < 1e-6 for s in snaps):
            xc, yc, zc = c
            s = dict(t=run.t, d_n=rec["dn"][-1], inflow=sample_ring(g, run, xc, yc, [R0, 1.5 * R0, 2 * R0]))
            if case in ("flat", "hill_wind", "hill_lee", "hill_foot") or True:
                s["plane"] = plane_w(g, run, zc, xc, yc, R0)
            rec["snaps"][str(int(run.t))] = s
        if verbose and (k % 15 == 14):
            print(case, U, run.t, np.round(c, 1), "dn", round(rec["dn"][-1], 1), flush=True)
    rec["wall_s"] = time.time() - t0
    rec["t_step_s"] = rec["wall_s"] / nst
    rec["t_vel_s"] = run.t_vel
    rec["z_ground_pt"] = z0
    rec["start"] = ctr.tolist()
    rec["n_unit"] = n.tolist()
    return rec


def run_flux(case, h=25.0, sg=1.3, T=150.0, dt=2.0, H_wm2=250.0, Rp=100.0, verbose=True, noise=0.0):
    """Нагрев склона потоком H (Вт/м²) в пятне Rp, штиль: пятно доращивается несущими частицами у земли."""
    Ter, pt, wd = ac.make_case(case)
    g = ground.Ground(Ter, [pt], ds_min=30.0, ds_max=500, focus_r=500)
    ht = pa3d.Heated(g, pt, Rp, h, H_wm2=H_wm2, height=300.0, sg_over_h=sg, noise=noise)
    parts = ht.initial()
    run = pa3d.Run(g, bg_zero(), parts, sg_over_h=sg, heater=ht)
    rec = dict(case=case, noise=noise, T=T, h=h, H=H_wm2, Rp=Rp, N0=int(len(run.x)), N_pan=int(g.N), t=[], c=[], dn=[], B=[], wmax=[], N=[])
    t0 = time.time()
    for k in range(int(T / dt)):
        run.step(dt)
        c = run.centroid() if run.B_total() > 0 else np.array([*pt, 0.0])
        rec["t"].append(run.t); rec["c"].append(c.tolist()); rec["dn"].append(ac.normal_dist(g, c)); rec["B"].append(run.B_total())
        rec["N"].append(int(len(run.x)))
        if k % 5 == 4:
            P = np.array([[c[0], c[1], c[2]], [pt[0], pt[1], g.height(np.array([pt[0]]), np.array([pt[1]]))[0] + 10.0]])
            u = run.induced(P)
            rec["wmax"].append([run.t, float(u[0, 2]), float(np.hypot(u[1, 0], u[1, 1])), float(u[1, 2])])
        if verbose and k % 10 == 9:
            print(case, run.t, np.round(c, 1), "dn", round(rec["dn"][-1], 1), "N", len(run.x), flush=True)
    rec["wall_s"] = time.time() - t0
    rec["t_step_s"] = rec["wall_s"] / int(T / dt)
    rec["start_xy"] = list(pt)
    return rec


def acc_ratio(h, sg, T=20.0, dt=0.5, ds_min=100.0):
    """Начальное ускорение центра плавучести / b (теория шара с присоединённой массой ½: 2/3), вдали от земли."""
    Ter = ground.flat_terrain(half=3000, dx=100)
    g = ground.Ground(Ter, [(0, 0)], ds_min=ds_min, ds_max=600, focus_r=300)
    parts = pa3d.ball_particles((0, 0, 3000.0), R0, h, pa3d.b_of_dtheta(DTH), sg)
    run = pa3d.Run(g, bg_zero(), parts, sg_over_h=sg)
    for _ in range(int(T / dt)):
        run.step(dt)
    dz = run.centroid()[2] - 3000.0
    P = 0.5 * np.cross(run.x, run.a).sum(0)
    b0 = pa3d.b_of_dtheta(DTH)
    return dict(h=h, sg=sg, N=int(len(run.x)), a_over_b=2 * dz / (b0 * run.t ** 2), Pz_over_Bt=float(P[2] / (run.B_total() * run.t)))


def save(name, obj):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name)
    with open(p + ".tmp", "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(p + ".tmp", p)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "blob"
    if what == "conv":
        res = [acc_ratio(h, sg) for h, sg in [(25, 1.3), (18, 1.3), (12.5, 1.3), (9, 1.3), (12.5, 1.0), (12.5, 1.6)]]
        for r in res: print(r)
        save("a_conv.json", res)
    if what == "flux":
        res = []
        for case in ("flat", "hill_wind", "hill_foot"):
            res.append(run_flux(case)); save("a_flux.json", res)
        for case, nz in (("flat", 0.3), ("hill_wind", 0.0), ("hill_wind", 0.3)):
            res.append(run_flux(case, T=400.0, dt=4.0, noise=nz)); save("a_flux.json", res)
    if what == "blob":
        res = []
        for case, U in [("flat", 0), ("flat", 3), ("hill_wind", 0), ("hill_wind", 3), ("hill_lee", 3), ("hill_foot", 0), ("perd", 0), ("perd", 3)]:
            r = run_blob(case, U)
            res.append(r)
            save("a_blob.json", res)
