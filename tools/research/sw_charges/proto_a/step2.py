"""Шаг 2: сдвиговой слой ΔU=3 м/с (tanh, δ=10 м) на высоте 200 м, период по x; неустойчивость Кельвина — Гельмгольца.
Без земли и крышки (только слой), без плавучести. Сравнение: рост моды с теорией tanh, σ_w(z) с turbulence.md."""
import json, time
import numpy as np, cupy as cp
from scipy.ndimage import maximum_filter
from pa_core import Sim, make_images

def run(dU=3.0, delta=10.0, nmode=6, dx=4.0, dz=4.0, zspan=50.0, sig_fac=1.5, T=300.0, dt=0.5, amp=0.3, noise=0.02, seed=1, z0=200.0, tag=''):
    lam = 2 * np.pi * delta / 0.4446          # самая быстрая длина волны для tanh-профиля
    L = nmode * lam
    nx = int(round(L / dx)); dx = L / nx
    m_ = int(zspan // dz); zs = dz * np.arange(-m_, m_ + 1)
    X, Z = np.meshgrid((np.arange(nx) + 0.5) * dx, zs)
    X = X.ravel(); Z = Z.ravel()
    om = dU / (2 * delta) / np.cosh(Z / delta) ** 2
    Gam = om * dx * dz
    rng = np.random.default_rng(seed)
    k = 2 * np.pi * nmode / L
    Zp = Z + amp * np.cos(k * X) * np.exp(-(Z / (2 * delta)) ** 2) + noise * rng.standard_normal(Z.size)
    Xp = X + noise * rng.standard_normal(Z.size)
    n = Z.size; sig = sig_fac * dx
    sim = Sim(sig, make_images(L=L, nx=4))
    st = dict(x=cp.asarray(Xp), z=cp.asarray(Zp), G=cp.asarray(Gam), A=cp.full(n, dx * dz), b=cp.zeros(n))
    mid = np.abs(Z) < 1e-9
    mid_idx = cp.asarray(np.where(mid)[0])
    rec = []; steps = int(round(T / dt)); t0 = time.time()
    P0 = float((st['z'] * st['G']).sum()); G0 = float(st['G'].sum())
    snaps = {}
    gridx = cp.arange(0, L, 2.0) + 1.0
    for kk in range(steps + 1):
        t = kk * dt
        if kk % 10 == 0:
            xm = st['x'][mid_idx]; zm = st['z'][mid_idx]
            a = complex(cp.asnumpy((zm * cp.exp(-1j * k * xm)).sum())) * 2 / mid_idx.size
            Pz = float((st['z'] * st['G']).sum())
            rec.append(dict(t=t, amp=abs(a), P=Pz, Pdrift=(Pz - P0) / abs(P0) if P0 else 0, Gdrift=(float(st['G'].sum()) - G0)/G0,
                            zmin=float(st['z'].min()), zmax=float(st['z'].max())))
        if kk * dt in (0.0, 150.0, 200.0, 250.0, 300.0):
            snaps[t] = (cp.asnumpy(st['x']), cp.asnumpy(st['z']), cp.asnumpy(st['G']))
        if kk < steps:
            sim.step(st, dt, baro=False)
    wall = time.time() - t0
    # профиль σ_w(z), σ_u(z) в конце, по сетке
    zg = np.arange(-120, 120.1, 10.0)
    sw = []; su = []; um = []
    for zz in zg:
        gx = cp.arange(0, L, 2.0) + 1.0
        u, w, _ = sim.eval(gx, cp.full_like(gx, zz), st['x'], st['z'], st['G'], st['A'] * st['b'])
        sw.append(float(w.std())); su.append(float(u.std())); um.append(float(u.mean()))
    # спектр w(k) на центральной линии и ±30 м (усреднённый), конец
    sp = 0
    for zz in (-30, -15, 0, 15, 30):
        gx = cp.arange(0, L, 1.0) + 0.5
        u, w, _ = sim.eval(gx, cp.full_like(gx, zz), st['x'], st['z'], st['G'], st['A'] * st['b'])
        wf = np.fft.rfft(cp.asnumpy(w)); sp = sp + np.abs(wf) ** 2
    ks = 2 * np.pi * np.fft.rfftfreq(int(L), 1.0)
    # число ядер вихрей по завихренности на сетке
    def cores(snap):
        x, z, G = snap
        gx = np.arange(0, L, 4.0); gz = np.arange(-100, 100, 4.0)
        GX, GZ = np.meshgrid(gx, gz)
        om = np.zeros(GX.shape)
        # прямая оценка на CuPy: ядро Гаусса, периодические копии
        cx = cp.asarray(GX.ravel()); cz = cp.asarray(GZ.ravel())
        acc = cp.zeros(cx.size)
        for s in (-1, 0, 1):
            dxx = cx[:, None] - (cp.asarray(x)[None, :] + s * L)
            dzz = cz[:, None] - cp.asarray(z)[None, :]
            acc += (cp.asarray(G)[None, :] * cp.exp(-(dxx ** 2 + dzz ** 2) / sig ** 2) / (np.pi * sig ** 2)).sum(1)
        om = cp.asnumpy(acc).reshape(GX.shape)
        mx = (om == maximum_filter(om, size=(9, 9), mode='wrap')) & (om > 0.5 * om.max())
        return int(mx.sum()), float(om.max()), float(om.min())
    cs = {str(t): cores(s) for t, s in snaps.items()}
    return dict(dU=dU, delta=delta, L=L, lam_fast=lam, nmode=nmode, n=n, sigma=sig, dt=dt, T=T, wall_s=wall, rec=rec,
                zg=zg.tolist(), sigma_w=sw, sigma_u=su, u_mean=um,
                spec_k=ks[1:].tolist(), spec_w=(sp[1:] / 5).tolist(), cores=cs)

if __name__ == '__main__':
    out = run()
    # теория: tanh-слой, max рост σ = 0.1897·(ΔU/2)/δ
    out['sigma_theory'] = 0.1897 * (out['dU'] / 2) / out['delta']
    json.dump(out, open('out/step2_raw.json', 'w'))
    print('ok', out['wall_s'])
