"""Шаг 3(б): ветер 5–8 м/с над хребтом с острой бровкой, вихри сходят с бровки (Γ = −½u_s²dt, как panels2d.step),
частицы GPU (без плавучести), земля — панели. Ротор: время-средняя u на слоях agl; зона u < −0,5 м/с, agl ≥ 15 м (Menke 2019).
Запуск: ../../cascade_2d/py step3_rotor.py [опыт ...]   Выход: out/step3/rotor_<имя>.json
"""
import json, os, sys, time
import numpy as np, cupy as cp
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, '..'))
import panels2d as P2
from step3_core import Ground, Run, empty_state
import step3_terrain as TT

OUT = os.path.join(HERE, 'out', 'step3')
ALPHA = 0.235
AGLS = np.array([15.0, 20, 30, 50, 75, 100, 150, 200, 300])


def zone_stats(umean, xs, aglv, x_crest, thr=-0.5, H=None):
    """umean[iz, ix]; зона: u < thr при agl ≥ 15 м, участок ниже по потоку от бровки."""
    lee = xs >= x_crest
    mk = (umean < thr)[:, lee]
    xl = xs[lee]
    out = dict(any=bool(mk.any()))
    if mk.any():
        cols = mk.any(0)
        # длина = наибольший непрерывный отрезок колонок с зоной
        best = (0, 0, 0); i = 0
        while i < cols.size:
            if cols[i]:
                j = i
                while j + 1 < cols.size and cols[j + 1]: j += 1
                if j - i + 1 > best[2]: best = (i, j, j - i + 1)
                i = j + 1
            else:
                i += 1
        i0, i1, _ = best
        sub = mk[:, i0:i1 + 1]
        out.update(L=float(xl[i1] - xl[i0] + (xs[1] - xs[0])), x_start=float(xl[i0] - x_crest), x_end=float(xl[i1] - x_crest),
                   depth_agl=float(aglv[sub.any(1)].max()))
    else:
        out.update(L=0.0)
    out['u_min'] = float(umean[:, lee].min())
    return out


def run_one(name, terrain, x_crest, U100, T=900.0, dt=1.0, t_avg0=450.0, shed_off=12.5, ds_min=25.0, shed=True,
            smooth_bg=250.0, z_sat=300.0, tau=None, sample_every=5.0, L_after=2000.0, k=1, D_ref=None, H_ref=None):
    gr = Ground(terrain, ds_min=ds_min, x_focus=None)
    U10 = U100 / 10 ** ALPHA
    bg = P2.bg_profile(U10, ALPHA, z_sat, terrain, smooth_m=smooth_bg)
    run = Run(gr, bg, 0.5 * ds_min, mode='delete', resolve_every=k, x_max=9000.0)
    st = empty_state()
    zcr = float(terrain.height(x_crest))
    xs = np.arange(x_crest - 300.0, x_crest + L_after, 10.0) + 5.0
    gz = gr.p.ground(xs)
    acc = np.zeros((AGLS.size, xs.size)); wacc = np.zeros_like(acc); nacc = 0
    ts = []
    t0 = time.time()
    steps = int(round(T / dt))
    for kk in range(steps):
        if shed:
            run.shed(st, [x_crest], [zcr + shed_off], dt)
        run.step(st, dt, baro=False)
        if tau:
            st['G'] = st['G'] * np.exp(-dt / tau)     # затухание завихрённости (вязкость/смешение), единый τ
        t = (kk + 1) * dt
        if t >= t_avg0 and abs((t / sample_every) - round(t / sample_every)) < 1e-9:
            sg = run.solve_sigma(st)
            X = np.repeat(xs[None], AGLS.size, 0); Z = gz[None] + AGLS[:, None]
            u, w = run.velocity(st, cp.asarray(X.ravel()), cp.asarray(Z.ravel()), sigma=sg)
            acc += cp.asnumpy(u).reshape(X.shape); wacc += cp.asnumpy(w).reshape(X.shape); nacc += 1
    wall = time.time() - t0
    um = acc / nacc; wm = wacc / nacc
    # одиночные снимки не храним; время-средняя
    ref = U100
    zs = zone_stats(um, xs, AGLS, x_crest)
    zs['umin_over_U100'] = zs['u_min'] / ref
    zs0 = zone_stats(um, xs, AGLS, x_crest, thr=0.0)
    # u у земли (agl 15 м, ряд 0) по x за бровкой
    row = um[0]
    sel = xs >= x_crest
    # обратная скорость на agl 15
    res = dict(name=name, tau=tau, U100=U100, T=T, dt=dt, t_avg0=t_avg0, nsamp=nacc, shed=shed, shed_off=shed_off, ds_min=ds_min, k=k,
               n_vortices=int(st['x'].size), born_G=run.born_G, lost_G=run.lost_G, sum_G=float(st['G'].sum()),
               n_deleted=run.n_deleted, wall_s=wall, ms_per_step=1e3 * wall / steps,
               n_panels=int(gr.p.n), zone_thr0p5=zs, zone_thr0=zs0,
               x_rel=(xs - x_crest).tolist(), agl=AGLS.tolist(), u_mean_agl15=um[0].tolist(), u_mean_agl30=um[2].tolist(),
               u_mean_agl50=um[3].tolist(), u_mean_agl100=um[5].tolist(), ground=(gz - zcr).tolist())
    return res


def crest_info(terrain, x_crest, span=200.0):
    x = terrain.x; z = terrain.z
    m = (x > x_crest) & (x < x_crest + 600)
    sl = np.gradient(z, x)
    # максимум крутизны под гребнем на 50 м
    k = int(50 / (x[1] - x[0]))
    sm = np.convolve(sl, np.ones(k) / k, mode='same')
    return float(-sm[m].min())


def experiments():
    ex = {}
    ag = TT.agnesi(H=200.0, L=300.0)
    pd, pos, info = TT.perdigao()
    for U in (5.0, 8.0):
        tag = f'U{int(U)}'
        ex[f'ag300_{tag}'] = dict(terrain=ag, x_crest=0.0, U100=U)
        ex[f'ag300_{tag}_noshed'] = dict(terrain=ag, x_crest=0.0, U100=U, shed=False)
        ex[f'perd_{tag}'] = dict(terrain=pd, x_crest=pos['tse13'], U100=U)
        ex[f'perd_{tag}_noshed'] = dict(terrain=pd, x_crest=pos['tse13'], U100=U, shed=False)
    ex['ag300_U8_off25'] = dict(terrain=ag, x_crest=0.0, U100=8.0, shed_off=25.0, ds_min=50.0)
    ex['ag300_U8_k4'] = dict(terrain=ag, x_crest=0.0, U100=8.0, k=4)
    for U in (5.0, 8.0):
        for tau in (60.0, 150.0):
            ex[f'perd_U{int(U)}_tau{int(tau)}'] = dict(terrain=pd, x_crest=pos['tse13'], U100=U, tau=tau)
            ex[f'ag300_U{int(U)}_tau{int(tau)}'] = dict(terrain=ag, x_crest=0.0, U100=U, tau=tau)
    return ex


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    ex = experiments()
    for n in (sys.argv[1:] or list(ex)):
        kw = dict(ex[n])
        r = run_one(n, **kw)
        r['lee_slope_max50'] = crest_info(kw['terrain'], kw['x_crest'])
        json.dump(r, open(os.path.join(OUT, f'rotor_{n}.json'), 'w'))
        z = r['zone_thr0p5']
        print(n, f"wall {r['wall_s']:.0f}s nvort={r['n_vortices']} L={z.get('L')} umin={z['u_min']:.2f} ({z['umin_over_U100']:.2f}U100) slope {r['lee_slope_max50']:.2f}", flush=True)
