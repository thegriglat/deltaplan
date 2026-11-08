"""Шаг 1: одно пятно b>0, R=100 м, Δθ=1 К, 2D; земля z=0 и крышка z=1200 — изображения."""
import json, sys, time
import numpy as np, cupy as cp
from pa_core import Sim, make_images, disk_lattice

G0, TH0 = 9.81, 300.0
def run(dtheta=1.0, R=100.0, N=10000, sig_fac=1.5, T=150.0, dt=1.0, z0=400.0, H=1200.0, L=3000.0,
        obs=(30, 60, 120), ke_every=30, tag='', pad_sig=3.5, belt=True, walls=True):
    b0 = G0 * dtheta / TH0
    h0 = R * np.sqrt(2 * np.pi / (np.sqrt(3) * N))
    sig = sig_fac * h0
    lx, lz, A, h, inside = disk_lattice(R, N, pad=pad_sig * sig if belt else 0.0)
    n = lx.size
    sim = Sim(sig, make_images(H=H, kz=1) if walls else make_images())
    xc = L / 2
    st = dict(x=cp.asarray(xc + lx), z=cp.asarray(z0 + lz), G=cp.zeros(n), A=cp.full(n, A), b=cp.asarray(np.where(inside, b0, 0.0)))
    ins = cp.asarray(inside)
    B = float(inside.sum() * A * b0)
    zi = st['z'].copy()
    gx = cp.arange(0, L, 10.0) + 5; gz = cp.arange(0, H, 10.0) + 5
    GX, GZ = [a.ravel() for a in cp.meshgrid(gx, gz)]
    rec = []; lines = {}
    steps = int(round(T / dt))
    t0 = time.time()
    for k in range(steps + 1):
        t = k * dt
        need_diag = (k % 5 == 0) or (t in obs)
        if need_diag or True:
            pass
        # диагностика (до шага)
        if k % 5 == 0 or t in obs:
            x, z, G = st['x'], st['z'], st['G']
            u, w, _ = sim.eval(x, z, x, z, G, st['A'] * st['b'])
            xcen = float(x[ins].mean()); zcen = float(z[ins].mean())
            right = x > xcen
            Gh = float(G[right].sum()); Gl = float(G[~right].sum())
            P = float(-(x * G).sum())  # P_z = -Σ x Γ  (на единицу плотности)
            Pexp = B * t
            # центры вихрей: взвешенные по |Γ|
            xr = float((x[right] * G[right]).sum() / G[right].sum()) if abs(Gh) > 0 else np.nan
            xl = float((x[~right] * G[~right]).sum() / G[~right].sum()) if abs(Gl) > 0 else np.nan
            d_eff = (xr - xl) / 2 if abs(Gh) > 0 else np.nan   # половина расстояния между центрами
            d_pair = xr - xl
            vmean = float(w[ins].mean())
            r = dict(t=t, zc=zcen, v=vmean, v_pred=0.5 * b0 * t, ratio=vmean / (0.5 * b0 * t) if t > 0 else None,
                     G_half=Gh, G_half_pred=-2 * b0 * R * t, G_tot=float(G.sum()), P=P, P_over_Bt=P / Pexp if t > 0 else None,
                     d_pair=d_pair, d_pred=np.pi * R / 2, z_c=zcen)
            if t > 0 and abs(Gh) > 0 and d_pair > 0:
                r['U_pair'] = abs(Gh) / (2 * np.pi * d_pair)
                r['U_pair_over_bt'] = r['U_pair'] / (b0 * t)
            if t % ke_every == 0:
                ux, wx, _ = sim.eval(GX, GZ, x, z, G, st['A'] * st['b'])
                ke = 0.5 * float((ux ** 2 + wx ** 2).sum()) * 100.0
                pe = float((st['A'] * st['b'] * (z - zi)).sum())
                r['KE'] = ke; r['PE_released'] = pe; r['KE_over_PE'] = ke / pe if pe > 0 else None
            rec.append(r)
            if t in obs:
                xl_ = cp.arange(0, L, 1.0) + 0.5
                for off in (0.0, 150.0, -150.0):
                    zz = cp.full_like(xl_, zcen + off)
                    uu, ww, _ = sim.eval(xl_, zz, x, z, G, st['A'] * st['b'])
                    lines[f't{int(t)}_off{int(off)}'] = dict(zline=zcen + off, xc=xcen, x=xl_.get().tolist(), w=ww.get().tolist())
        if k < steps:
            sim.step(st, dt)
    wall = time.time() - t0
    return dict(n_in=int(inside.sum()), b=b0, dtheta=dtheta, R=R, N=n, sigma=sig, h=h, dt=dt, T=T, wall_s=wall, z0=z0, rec=rec, lines=lines)

def line_stats(ln, R):
    x = np.array(ln['x']); w = np.array(ln['w']); xc = ln['xc']; dx = x[1] - x[0]
    s = x - xc
    wp = w[w > 0].sum() * dx; wm = -w[w < 0].sum() * dx
    far = np.abs(s) > 1.3 * R
    # нуль ядра: ближайший к центру переход знака
    i0 = np.argmin(np.abs(s)); idx = i0
    while idx < len(w) - 1 and w[idx] > 0: idx += 1
    x0 = s[idx]
    # край линии 1.5 км; хвосты диполя ~1/x^2 за пределами
    return dict(zline=ln['zline'], wmax=float(w.max()), wmin=float(w.min()), x_zero=float(x0),
                int_w=float(w.sum() * dx), int_pos=float(wp), int_neg=float(wm),
                int_over_pos=float(w.sum() * dx / wp), return_frac=float(wm / wp),
                frac_far_negative=float((w[far] < 0).mean()),
                frac_far_neg_1p5x0=float((w[np.abs(s) > 1.5 * abs(x0)] < 0).mean()))

def gedeon_compare(ln, R):
    x = np.array(ln['x']); w = np.array(ln['w']); s = x - ln['xc']
    st = line_stats(ln, R); x0 = st['x_zero']; w0 = st['wmax']
    g = lambda q: np.exp(-q ** 2) * (1 - q ** 2)
    q = s / x0
    out = {}
    for name, fac in (('ring1.0', 1.0), ('ring1.6', 1.6)):
        gg = g(q); gg = np.where(gg < 0, gg * fac, gg) * w0
        dx = x[1] - x[0]
        m = np.abs(s) < 4 * x0
        out[name] = dict(int=float(gg.sum() * dx), return_frac=float(-gg[gg < 0].sum() / gg[gg > 0].sum()),
                         wmin_over_wmax=float(gg.min() / w0),
                         rms_diff_over_wmax=float(np.sqrt(np.mean((gg[m] - w[m]) ** 2)) / w0),
                         far_negative_frac=float((gg[np.abs(s) > 1.5 * abs(x0)] < 0).mean()))
    out['proto'] = dict(int=st['int_w'], return_frac=st['return_frac'], wmin_over_wmax=st['wmin'] / st['wmax'])
    out['x_zero'] = x0
    return out

if __name__ == '__main__':
    out = {}
    out['main'] = run(tag='main')
    out['conv'] = {}
    for N, sf in ((2500, 1.5), (10000, 2.5), (20000, 1.5)):
        r = run(N=N, sig_fac=sf, T=60.0, obs=(60,), ke_every=60)
        rr = [q for q in r['rec'] if q['t'] == 60.0][0]
        out['conv'][f'N{N}_s{sf}'] = dict(N=r['N'], sigma=r['sigma'], ratio=rr['ratio'], G_half_ratio=rr['G_half'] / rr['G_half_pred'],
                                         P_over_Bt=rr['P_over_Bt'], KE_over_PE=rr.get('KE_over_PE'),
                                         int_over_pos=line_stats(r['lines']['t60_off0'], 100.0)['int_over_pos'], wall_s=r['wall_s'])
    # длинный прогон 10 мин: Δθ = 0.1 К
    lg = run(dtheta=0.1, T=600.0, z0=300.0, dt=2.0, obs=(), ke_every=100, N=10000)
    out['long'] = lg
    for k, v in out['main']['lines'].items():
        pass
    json.dump(out, open('out/step1_raw.json', 'w'))
    print('ok')
