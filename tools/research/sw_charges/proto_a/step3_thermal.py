"""Шаг 3(а): термик-пятно (R = 100 м, Δθ = 1 К, как шаг 1) над линией рельефа с землёй из панелей.
Запуск: ../../cascade_2d/py step3_thermal.py [имя_опыта ...]   Выход: out/step3/thermal_<имя>.json
"""
import json, os, sys, time
import numpy as np, cupy as cp
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, ".."))
import panels2d as P2
from step3_core import Ground, Run, patch_state
import step3_terrain as TT

R, DTH, NPART = 100.0, 1.0, 10000
OUT = os.path.join(HERE, 'out', 'step3')


def flat():
    return P2.Terrain(np.array([-6000.0, 6000.0]), np.array([0.0, 0.0]))


def diag(run, st, base_sig, meta, t, xc0, U_bg):
    """Диагностика возмущения: поле с частицами минус поле без них (одна земля, σ0)."""
    b = st['b'] > 0
    wgt = (st['A'] * st['b'])
    xcen = float((st['x'] * wgt).sum() / wgt.sum()); zcen = float((st['z'] * wgt).sum() / wgt.sum())
    gz = float(run.gr.p.ground(np.array([xcen]))[0])
    sl = float(np.gradient(run.gr.p.ground(np.array([xcen - 25, xcen + 25])), 50.0)[0])
    ins = meta['inside']
    r = dict(t=t, xc=xcen, zc=zcen, agl=zcen - gz, slope=sl, d_n=(zcen - gz) / np.sqrt(1 + sl ** 2),
             z_min_p=float((st['z'][ins] - cp.asarray(run.gr.p.ground(cp.asnumpy(st['x'][ins])))).min()))
    # возмущение: точки внутри ядра (скорость пятна), линия через центр, линия у земли
    sg = run.solve_sigma(st)
    def pert(x, z):
        u, w = run.velocity(st, x, z, sigma=sg)
        u0, w0 = run.velocity(st, x, z, sigma=base_sig, particles=False)
        return cp.asnumpy(u - u0), cp.asnumpy(w - w0)
    xi, zi = st['x'][ins], st['z'][ins]
    up, wp = pert(xi, zi)
    r['v_in'] = float(wp.mean()); r['u_in'] = float(up.mean())
    r['v_pred'] = 0.5 * meta['b0'] * t
    r['ratio'] = r['v_in'] / r['v_pred'] if t > 0 else None
    # линия через центр по x, 3 км
    xl = cp.arange(xcen - 1500, xcen + 1500, 2.0) + 1.0
    zl = cp.full_like(xl, zcen)
    # не заходить под землю
    gl = cp.asarray(run.gr.p.ground(cp.asnumpy(xl)))
    ok = cp.asnumpy(zl > gl + 2)
    ul, wl = pert(xl, zl)
    s = cp.asnumpy(xl) - xcen
    wpos = wl[ok & (wl > 0)].sum(); wneg = -wl[ok & (wl < 0)].sum()
    far = ok & (np.abs(s) > 1.3 * R)
    r['line'] = dict(wmax=float(wl[ok].max()), wmin=float(wl[ok].min()), return_frac=float(wneg / wpos) if wpos > 0 else None,
                     frac_far_neg=float((wl[far] < 0).mean()), n_far=int(far.sum()),
                     int_over_pos=float(wl[ok].sum() / wpos) if wpos > 0 else None, ok_frac=float(ok.mean()))
    # у земли: z = ground + 5 м, подтекание = горизонтальное возмущение к центру термика
    xg = cp.arange(xcen - 3 * R, xcen + 3 * R, 5.0) + 2.5
    gg = run.gr.p.ground(cp.asnumpy(xg))
    ug, wg = pert(xg, cp.asarray(gg + 5.0))
    sg_ = cp.asnumpy(xg) - xcen
    tow = -np.sign(sg_) * ug           # >0: к термику
    m = (np.abs(sg_) > 0.5 * R) & (np.abs(sg_) < 3 * R)
    r['inflow'] = dict(mean=float(tow[m].mean()), max=float(tow[m].max()), min=float(tow[m].min()),
                       frac_pos_gt0p1=float((tow[m] > 0.1).mean()),
                       up=float(tow[m & (sg_ > 0)].mean()), down=float(tow[m & (sg_ < 0)].mean()),
                       w_ground_max=float(wg.max()), w_ground_min=float(wg.min()))
    # циркуляция: правая/левая половины относительно центра
    right = st['x'] > xcen
    r['G_half'] = float(st['G'][right].sum()); r['G_left'] = float(st['G'][~right].sum()); r['G_tot'] = float(st['G'].sum())
    r['G_half_pred'] = -2 * meta['b0'] * R * t
    Gh, Gl = r['G_half'], r['G_left']
    xr = float((st['x'][right] * st['G'][right]).sum()) / Gh if abs(Gh) > 0 else float('nan')
    xl_ = float((st['x'][~right] * st['G'][~right]).sum()) / Gl if abs(Gl) > 0 else float('nan')
    r['d_pair'] = xr - xl_; r['d_pred'] = np.pi * R / 2
    r['P'] = float(-(st['x'] * st['G']).sum()); r['P_over_Bt'] = r['P'] / (meta['B'] * t) if t > 0 else None
    r['n_under_total'] = run.n_under
    return r


def run_one(name, terrain, xc, U, T=90.0, dt=1.0, gap=15.0, mode='reflect', k=1, N=NPART, ds_min=25.0, diag_every=5, sig_fac=1.5):
    gr = Ground(terrain, ds_min=ds_min, x_focus=None)
    bg = P2.bg_uniform(U)
    # центр: нижняя точка пятна (с поясом) на высоте gap над землёй
    st, meta = patch_state(0.0, 0.0, R, DTH, N, sig_fac=sig_fac)
    lx, lz = cp.asnumpy(st['x']), cp.asnumpy(st['z'])
    zc = float(np.max(gr.p.ground(xc + lx) - lz)) + gap
    st['x'] = st['x'] + xc; st['z'] = st['z'] + zc
    run = Run(gr, bg, meta['sigma'], mode=mode, resolve_every=k)
    base_sig = run.solve_sigma(dict(x=cp.zeros(0), z=cp.zeros(0), G=cp.zeros(0), A=cp.zeros(0), b=cp.zeros(0)))
    rec = []
    t0 = time.time()
    steps = int(round(T / dt))
    for kk in range(steps + 1):
        t = kk * dt
        if kk % diag_every == 0:
            rec.append(diag(run, st, base_sig, meta, t, xc, U))
        if kk < steps:
            run.step(st, dt)
    wall = time.time() - t0
    return dict(name=name, xc0=xc, zc0=zc, ground0=float(gr.p.ground(np.array([xc]))[0]), U=U, T=T, dt=dt, mode=mode, k=k,
                N=int(st['x'].size), sigma=meta['sigma'], n_panels=int(gr.p.n), ds_min=ds_min, t_setup_inv=gr.t_setup,
                wall_s=wall, ms_per_step=1e3 * wall / steps, t_solve=run.t_solve, t_vel=run.t_vel,
                n_under=run.n_under, n_deleted=run.n_deleted, lost_G=run.lost_G, rec=rec)


def experiments():
    ag = TT.agnesi()
    ex = {}
    ex['flat_U0'] = dict(terrain=flat(), xc=0.0, U=0.0)
    ex['flat_U2p5'] = dict(terrain=flat(), xc=0.0, U=2.5)
    for pos, xc in (('foot', -900.0), ('mid', -289.0)):
        for U in (0.0, 2.5):
            ex[f'ag_{pos}_U{str(U).replace(".", "p")}'] = dict(terrain=ag, xc=xc, U=U)
    pd, pos, info = TT.perdigao()
    for tag, xc in (('foot', -1750.0), ('mid', -1000.0)):
        for U in (0.0, 3.0):
            ex[f'pd_{tag}_U{str(U).replace(".", "p")}'] = dict(terrain=pd, xc=xc, U=U)
    m = ex['ag_mid_U2p5']
    ex['ag_mid_U2p5_delete'] = dict(m, mode='delete')
    ex['ag_mid_U2p5_k2'] = dict(m, k=2)
    ex['ag_mid_U2p5_k4'] = dict(m, k=4)
    ex['ag_mid_U2p5_ds12'] = dict(m, ds_min=12.5)
    ex['ag_mid_U2p5_N4000'] = dict(m, N=4000)
    ex['ag_mid_U2p5_T180'] = dict(m, T=180.0)
    ex['flat_T180'] = dict(ex['flat_U0'], T=180.0)
    # термик, прижатый к земле (gap = 0: нижняя точка пояса лежит на линии земли) — нагретое пятно на склоне
    for n in ('flat_U0', 'ag_foot_U0p0', 'ag_mid_U0p0', 'ag_mid_U2p5', 'pd_mid_U0p0', 'pd_mid_U3p0'):
        ex[n + '_gap0'] = dict(ex[n], gap=0.0)
    return ex


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    ex = experiments()
    names = sys.argv[1:] or list(ex)
    for n in names:
        r = run_one(n, **ex[n])
        json.dump(r, open(os.path.join(OUT, f'thermal_{n}.json'), 'w'))
        L = [q for q in r['rec'] if q['t'] == 60.0][0]
        print(n, f"wall {r['wall_s']:.0f}s N={r['N']} under={r['n_under']} | t60: ratio {L['ratio']:.3f} agl {L['agl']:.0f} inflow mean {L['inflow']['mean']:.3f} max {L['inflow']['max']:.3f} ret {L['line']['return_frac']:.2f}", flush=True)
