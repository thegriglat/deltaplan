"""Шаг 3: ансамбль термиков-диполей, обратные потоки в среднее поле: H(z), <u'w'>(z), z_i(t), торможение ветра слоя."""
import json, sys, time
import numpy as np
sys.path.insert(0, ".")
from common import *
from step1 import H_KIN, WSTAR, DTH0, ZI, USTAR, KM, allen_r2

DZ = 25.0
NZ = 120
ZC = (np.arange(NZ) + 0.5) * DZ


def mean_field_init(gam_ml=0.5e-3, gam_up=5e-3, zcap=100.0):
    return theta_env(ZC, gam_ml, ZI, gam_up).astype(float), wind_profile(ZC, zcap=zcap).astype(float)


def zi_of(theta):
    g = np.gradient(theta, DZ)
    m = ZC > 300
    return float(ZC[m][np.argmax(g[m])])


def encroach_zi(t, th0, qdot=H_KIN):
    """Прогноз «срезания» по начальному профилю: тепло qdot*t = ∫0..z (θ0(z)-θ0(z')) dz'."""
    cum = np.cumsum(th0 * DZ)
    Q = th0 * ZC - cum + 0.5 * th0 * DZ           # приближённо ∫(θ0(z)-θ0)dz
    return float(np.interp(qdot * t, Q, ZC))


def induced(x, z, R, U, L, use_images=True):
    """Скорость в центрах термиков от остальных (диполи ЛЧ, курс вверх), периодика ±1, изображение у земли."""
    n = len(x)
    if n < 1:
        return np.zeros(0), np.zeros(0)
    ui = np.zeros(n); wi = np.zeros(n)
    X = x[:, None]; Z = z[:, None]
    for sh in (-L, 0.0, L):
        dx = X - (x[None, :] + sh)
        dz = Z - z[None, :]
        u, w = lc_velocity(dx, dz, 0.0, 1.0, U[None, :], R[None, :])
        np.fill_diagonal(u, 0.0) if sh == 0.0 else None
        if sh == 0.0:
            np.fill_diagonal(w, 0.0)
        ui += u.sum(axis=1); wi += w.sum(axis=1)
        if use_images:
            dz2 = Z + z[None, :]
            u2, w2 = lc_velocity(dx, dz2, 0.0, -1.0, U[None, :], R[None, :])     # изображение: курс вниз
            ui += u2.sum(axis=1); wi += w2.sum(axis=1)
    return ui, wi


def run(alpha=0.15, beta=0.5, zcap=100.0, L=5000.0, R0=None, gam_ml=0.5e-3, gam_up=5e-3, induced_on=False, T=3 * 3600.0, dt=1.0, seed=3,
        win=(3600.0, 3 * 3600.0), dth0=DTH0, verbose=False):
    rng = np.random.default_rng(seed)
    if R0 is None:
        R0 = float(allen_r2(0.1))
    A0 = np.pi * R0 ** 2
    nu = H_KIN * L / (A0 * dth0)                                # рождений/с — замыкание по потоку тепла
    th_bar, u_bar = mean_field_init(gam_ml, gam_up, zcap)
    th0_profile = th_bar.copy(); u0_profile = u_bar.copy()
    x = np.empty(0); z = np.empty(0); R = np.empty(0); U = np.empty(0); th = np.empty(0); ut = np.empty(0); age = np.empty(0)
    nsteps = int(T / dt)
    d0 = ZC - R0
    chord0 = np.where(np.abs(d0) < R0, 2 * np.sqrt(np.maximum(R0 ** 2 - d0 ** 2, 0)), 0.0)
    chord0 = chord0 / (np.sum(chord0) * DZ) * A0                 # сетка: ∫chord dz = A0 точно
    u_fixed = u_bar.copy(); sl = ZC < 100.0                      # приземный слой держит механическая болтанка (шаг 2), не термики
    blk = np.zeros(NZ); nblk = 0; zi_blocks = []
    acc_h = np.zeros(NZ); acc_uw = np.zeros(NZ); acc_n = 0
    log = []
    nalive_sum = 0.0; tstep = 0.0
    heat_in = 0.0
    for k in range(nsteps):
        t = k * dt
        t0 = time.perf_counter()
        nb = rng.poisson(nu * dt)
        if nb:
            x = np.concatenate([x, rng.random(nb) * L]); z = np.concatenate([z, np.full(nb, R0)])
            R = np.concatenate([R, np.full(nb, R0)]); U = np.concatenate([U, np.zeros(nb)])
            th = np.concatenate([th, np.full(nb, dth0)])
            ut = np.concatenate([ut, np.full(nb, float(np.interp(R0, ZC, u_bar)))]); age = np.concatenate([age, np.zeros(nb)])
        if len(x):
            ub_z = np.interp(z, ZC, u_bar)
            gam = np.interp(z, ZC, np.gradient(th_bar, DZ))
            b = G_OVER_T0 * th
            dU = b / (1 + KM) - alpha * U * U / R
            dth = -(alpha * U / R) * th - gam * U
            dut = -(alpha * U / R) * (ut - ub_z)
            if induced_on:
                ui, wi = induced(x, z, R, U, L)
            else:
                ui = wi = 0.0
            x = (x + (ut + ui) * dt) % L
            z = z + (U + wi) * dt
            R = R + 0.5 * (1.0 - beta) * alpha * U * dt
            U = U + dU * dt; th = th + dth * dt; ut = ut + dut * dt; age = age + dt
            dead = ((U <= 0.02) & (age > 30)) | (z < 0.5 * R) | (z > 2900)
            if dead.any():
                keep = ~dead
                x, z, R, U, th, ut, age = x[keep], z[keep], R[keep], U[keep], th[keep], ut[keep], age[keep]
        # потоки
        if len(x):
            dzz = ZC[None, :] - z[:, None]
            inside = np.abs(dzz) < R[:, None]
            chord = np.where(inside, 2 * np.sqrt(np.maximum(R[:, None] ** 2 - dzz ** 2, 0)), 0.0)
            Fh = (U[:, None] * th[:, None] * chord).sum(axis=0) / L
            Fu = (U[:, None] * (ut[:, None] - u_bar[None, :]) * chord).sum(axis=0) / L
        else:
            Fh = np.zeros(NZ); Fu = np.zeros(NZ)
        # дивергенция (поток на центрах, нулевой на земле и на верху)
        def ddz(F):
            Fe = np.concatenate([[0.0], 0.5 * (F[1:] + F[:-1]), [0.0]])
            return (Fe[1:] - Fe[:-1]) / DZ
        # впрыск тепла Земли: форма хорды рождения (то, что снимает ядро при рождении; ∫ = H_kin)
        inj = H_KIN * chord0 / A0
        th_bar = th_bar + dt * (-ddz(Fh) + inj)
        u_bar = u_bar + dt * (-ddz(Fu))
        u_bar[sl] = u_fixed[sl]
        blk += Fh; nblk += 1
        if nblk * dt >= 600.0:
            Fb = blk / nblk; m = ZC > 300
            zi_blocks.append({"t": t, "zi_Hmin": float(ZC[m][np.argmin(Fb[m])]),
                              "zi_H0": float(np.interp(0.0, -Fb[m][np.argmax(Fb[m] < 0) - 1:][:2], ZC[m][np.argmax(Fb[m] < 0) - 1:][:2])) if (Fb[m] < 0).any() and np.argmax(Fb[m] < 0) > 0 else None,
                              "H_min_over_Hkin": float(Fb[m].min() / H_KIN)})
            blk[:] = 0; nblk = 0
        tstep += time.perf_counter() - t0
        nalive_sum += len(x)
        if win[0] <= t < win[1]:
            acc_h += Fh; acc_uw += Fu; acc_n += 1
        if k % 60 == 0:
            log.append({"t": t, "zi": zi_of(th_bar), "zi_enc": encroach_zi(t + 1e-9, th0_profile),
                        "n_alive": int(len(x)), "heat_added_Km": float(np.sum((th_bar - th0_profile) * DZ)),
                        "heat_in_Km": H_KIN * t, "U_layer": float(np.mean(u_bar[ZC < ZI])), "U_12m": float(u_bar[0]),
                        "U_800": float(np.interp(800, ZC, u_bar)),
                        "zmax_thermal": float(np.max(z + 0 * R)) if len(x) else 0.0})
    Fh_m = acc_h / acc_n; Fu_m = acc_uw / acc_n
    zeta = ZC / ZI
    # ряды по уровням
    levels = {}
    for zeta_t in (0.1, 0.25, 0.5, 0.75):
        i = int(np.argmin(np.abs(ZC - zeta_t * ZI)))
        levels[str(zeta_t)] = {"H_over_Hkin": float(Fh_m[i] / H_KIN), "H_closure_1mzeta": float(1 - zeta_t),
                               "uw": float(Fu_m[i]), "uw_over_ustar2": float(Fu_m[i] / USTAR ** 2),
                               "uw_game_over_ustar2": float(-(1 - zeta_t) ** 1.5)}
    # поле w в конце: проверка ∫w dx
    zq = [200.0, 600.0, 1000.0]
    xg = np.arange(0, L, 2.0)
    chk = {}
    if len(x):
        for zz in zq:
            wsum = np.zeros_like(xg)
            for sh in (-L, 0.0, L):
                for img in (0, 1):
                    ww = lc_velocity(xg[:, None] - (x[None, :] + sh), (zz - z[None, :]) if not img else (zz + z[None, :]),
                                     0.0, -1.0 if img else 1.0, U[None, :], R[None, :])[1].sum(axis=1)
                    wsum += ww
            chk[str(zz)] = {"int_w_dx_over_int_abs": float(np.trapezoid(wsum, xg) / np.trapezoid(np.abs(wsum), xg)), "w_max": float(wsum.max()), "w_min": float(wsum.min())}
    zi_end = log[-1]["zi"]
    layer0 = float(np.mean(u0_profile[ZC < ZI]))
    res = {
        "params": {"alpha": alpha, "beta_detrain": beta, "zcap": zcap, "L": L, "R0": R0, "gam_ml": gam_ml, "induced": induced_on, "T": T, "dt": dt, "nu_births_per_s": nu},
        "n_alive_mean": nalive_sum / nsteps, "us_per_step": tstep / nsteps * 1e6,
        "levels": levels, "H_profile": Fh_m.tolist(), "uw_profile": Fu_m.tolist(), "z_centres": ZC.tolist(),
        "zi_start": log[0]["zi"], "zi_end": zi_end, "zi_enc_end": log[-1]["zi_enc"], "log": log,
        "layer_mean_wind_change": float(log[-1]["U_layer"] - layer0),
        "layer_100_zi_wind_change": float(np.mean(u_bar[(ZC > 100) & (ZC < ZI)]) - np.mean(u0_profile[(ZC > 100) & (ZC < ZI)])),
        "layer_drag_only_expected": float(-(USTAR ** 2) / ZI * T),
        "wind_12m_800m": {"start": [float(u0_profile[0]), float(np.interp(800, ZC, u0_profile))], "end": [float(u_bar[0]), float(np.interp(800, ZC, u_bar))]},
        "flux_check": chk, "zi_blocks": zi_blocks,
        "heat_budget_ratio": float(np.sum((th_bar - th0_profile) * DZ) / (H_KIN * T)),
        "theta_end": th_bar.tolist(), "u_end": u_bar.tolist(),
    }
    return res


def short(r):
    p = r["params"]
    lv = r["levels"]
    return (f"alpha={p['alpha']} beta={p['beta_detrain']} ind={p['induced']} R0={p['R0']:.0f} L={p['L']:.0f} alive={r['n_alive_mean']:.1f} us/step={r['us_per_step']:.0f} "
            f"zi {r['zi_start']:.0f}->{r['zi_end']:.0f} (enc {r['zi_enc_end']:.0f}) dUlayer={r['layer_mean_wind_change']:.2f} "
            f"H/Hk@.1,.5,.75={[round(lv[k]['H_over_Hkin'],2) for k in ('0.1','0.5','0.75')]} uw/u*2={[round(lv[k]['uw_over_ustar2'],2) for k in ('0.1','0.5','0.75')]} "
            f"budget={r['heat_budget_ratio']:.2f}")


def main():
    t0 = time.perf_counter()
    base = run()
    print(short(base), flush=True)
    out = {"base": base, "scan": {}}
    cfgs = {"beta_0": dict(beta=0.0), "beta_1": dict(beta=1.0), "ucap_300": dict(zcap=300.0), "alpha_0.10": dict(alpha=0.10), "alpha_0.20": dict(alpha=0.20), "induced_on": dict(induced_on=True),
            "R0_50": dict(R0=50.0), "R0_100": dict(R0=100.0), "L_2500": dict(L=2500.0), "L_10000": dict(L=10000.0),
            "gam_ml_0.1": dict(gam_ml=0.1e-3), "gam_ml_1.0": dict(gam_ml=1.0e-3)}
    for n, kw in cfgs.items():
        r = run(**kw)
        out["scan"][n] = {k: v for k, v in r.items() if k not in ("H_profile", "uw_profile", "z_centres", "theta_end", "u_end", "log")}
        print(n, short(r), flush=True)
    out["wall_s"] = time.perf_counter() - t0
    json.dump(out, open("out/step3.json", "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
