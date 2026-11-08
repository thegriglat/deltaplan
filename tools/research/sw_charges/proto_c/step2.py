"""Шаг 2: пары болтанки (диполи ЛЧ) с одним S(z): σ_w(z), L_w, корреляция по размаху, <u'w'>."""
import json, sys, time
import numpy as np
from scipy.spatial import cKDTree
sys.path.insert(0, ".")
from common import *

USTAR = 0.4
HMIX = 1500.0
ZMIN, ZMAX = 8.0, 150.0
PROBES = [10.0, 25.0, 60.0, 120.0]


def ell_of(z, mode):
    if mode == "kz":
        return KAPPA * z
    return 1.0 / (1.0 / (KAPPA * z) + 1.0 / 40.0)           # длина смешения игры, λ=40 м


def laws(z, mode="kz", phi_deg=45.0):
    ell = ell_of(z, mode)
    S = USTAR / (KAPPA * z)
    dU = S * ell
    gam = dU * ell
    d = ell
    Up = gam / (2 * np.pi * d)
    tau = d / Up
    E = 2 * np.pi * Up ** 2 * ell ** 2                        # энергия диполя ЛЧ на единицу y (ρ=1)
    eps = USTAR ** 3 / (KAPPA * z)                            # производство = диссипация, лог-слой
    lam = eps / E                                             # рождений на м^2 на с
    return dict(a=ell, Up=Up, tau=tau, lam=lam, E=E, S=S, gam=gam)


def envelope(age, tau):
    x = np.clip(np.minimum(age / (0.2 * tau), (tau - age) / (0.2 * tau)), 0, 1)
    return x * x * (3 - 2 * x)


_xx = np.linspace(0, 1, 100001)
_ENV_NORM = 1.0 / np.sqrt(np.mean(envelope(_xx, 1.0) ** 2))


class Pairs:
    def __init__(self, L=800.0, mode="kz", lam_scale=1.0, phi_deg=45.0, annihilate=True, seed=1, dt=0.5, f_ann=0.2):
        self.L, self.mode, self.ls, self.phi, self.ann, self.dt = L, mode, lam_scale, np.radians(phi_deg), annihilate, dt
        self.rng = np.random.default_rng(seed); self.f_ann = f_ann
        zg = np.exp(np.linspace(np.log(ZMIN), np.log(ZMAX), 400))
        lw = laws(zg, mode)
        w = lw["lam"] * zg                                     # по ln z
        self.zg = zg
        self.cdf_b = np.cumsum(w * lam_scale); self.birth_rate = L * self.cdf_b[-1] * np.log(zg[-1] / zg[0]) / len(zg) * 1.0
        # корректная интеграция λ dz
        lamz = lw["lam"]
        self.birth_rate = L * lam_scale * np.trapezoid(lamz, zg)
        c = np.cumsum(0.5 * (lamz[1:] + lamz[:-1]) * np.diff(zg)); self.cdf_b = np.concatenate([[0], c / c[-1]])
        nz = lw["lam"] * lw["tau"]
        c2 = np.cumsum(0.5 * (nz[1:] + nz[:-1]) * np.diff(zg)); self.n_alive = L * lam_scale * c2[-1]
        self.cdf_n = np.concatenate([[0], c2 / c2[-1]])
        self.x = np.empty(0); self.z = np.empty(0); self.sgn = np.empty(0); self.age = np.empty(0)
        self._fill_stationary()
        self.t = 0.0
        self.n_ann = 0; self.n_died = 0; self.n_born = 0

    def _draw_z(self, cdf, n):
        return np.interp(self.rng.random(n), cdf, self.zg)

    def _spawn(self, n, z, age):
        self.x = np.concatenate([self.x, self.rng.random(n) * self.L])
        self.z = np.concatenate([self.z, z])
        # sgn=+1: выброс (вверх и против ветра); -1: вторжение
        self.sgn = np.concatenate([self.sgn, np.where(self.rng.random(n) < 0.5, 1.0, -1.0)])
        self.age = np.concatenate([self.age, age])

    def _fill_stationary(self):
        n = self.rng.poisson(self.n_alive)
        z = self._draw_z(self.cdf_n, n)
        tau = laws(z, self.mode)["tau"]
        self._spawn(n, z, self.rng.random(n) * tau)

    def props(self):
        lw = laws(self.z, self.mode)
        nx = -self.sgn * np.sin(self.phi); nz = self.sgn * np.cos(self.phi)
        return lw, nx, nz

    def step(self):
        dt = self.dt
        lw, nx, nz = self.props()
        U = wind_profile(self.z)
        self.x = (self.x + (U + lw["Up"] * nx) * dt) % self.L
        self.z = self.z + lw["Up"] * nz * dt
        self.age = self.age + dt
        keep = (self.age < lw["tau"]) & (self.z > 0.6 * lw["a"]) & (self.z < ZMAX * 1.5)
        self.n_died += int((~keep).sum())
        if self.ann and keep.sum() > 1:
            idx = np.flatnonzero(keep)
            lw2 = laws(self.z[idx], self.mode)
            pts = np.c_[self.x[idx], self.z[idx]]
            tree = cKDTree(pts, boxsize=[self.L, 1e6]) if False else cKDTree(np.c_[self.x[idx], self.z[idx] + 1e3], boxsize=[self.L, 1e6])
            amax = float(lw2["a"].max())
            pairs = tree.query_pairs(r=self.f_ann * amax, output_type="ndarray")
            if len(pairs):
                i, j = pairs[:, 0], pairs[:, 1]
                dx = (pts[i, 0] - pts[j, 0] + self.L / 2) % self.L - self.L / 2
                dist = np.hypot(dx, pts[i, 1] - pts[j, 1])
                ok = (dist < self.f_ann * 0.5 * (lw2["a"][i] + lw2["a"][j])) & (self.sgn[idx][i] * self.sgn[idx][j] < 0)
                if ok.any():
                    kill = np.unique(np.concatenate([i[ok], j[ok]]))
                    keep[idx[kill]] = False
                    self.n_ann += len(kill)
        for name in ("x", "z", "sgn", "age"):
            setattr(self, name, getattr(self, name)[keep])
        nb = self.rng.poisson(self.birth_rate * dt)
        if nb:
            self._spawn(nb, self._draw_z(self.cdf_b, nb), self.rng.random(nb) * dt)
            self.n_born += nb
        self.t += dt

    # --- поле ---
    def field_at(self, xp, zp, rcut_a=5.0):
        """w, u в точках (xp, zp) от всех пар + изображения у земли; обрезка rcut_a·a (≤ L/2)."""
        lw, nx, nz = self.props()
        amp = envelope(self.age, lw["tau"]) * _ENV_NORM * lw["Up"]
        a = lw["a"]
        X = np.concatenate([self.x, self.x]); Z = np.concatenate([self.z, -self.z])
        NX = np.concatenate([nx, nx]); NZ = np.concatenate([nz, -nz])
        AMP = np.concatenate([amp, amp]); A = np.concatenate([a, a])
        npr = len(xp)
        u = np.zeros(npr); w = np.zeros(npr)
        cls = np.floor(np.log2(A / A.min())).astype(int)
        ptree = cKDTree(np.c_[xp, zp + 1e3], boxsize=[self.L, 1e6])
        for c in np.unique(cls):
            m = np.flatnonzero(cls == c)
            amax = A[m].max()
            rc = min(rcut_a * amax, self.L / 2 - 1)
            qt = cKDTree(np.c_[X[m], Z[m] + 1e3], boxsize=[self.L, 1e6]) if False else None
            # изображения могут иметь z<0: сдвиг 1e3 держит координаты положительными
            qt = cKDTree(np.c_[X[m] % self.L, Z[m] + 1e3], boxsize=[self.L, 1e6])
            sm = ptree.sparse_distance_matrix(qt, rc, output_type="coo_matrix")
            r, q = sm.row, sm.col
            k = m[q]
            dx = (xp[r] - X[k] + self.L / 2) % self.L - self.L / 2
            dz = zp[r] - Z[k]
            uu, ww = lc_velocity(dx, dz, NX[k], NZ[k], AMP[k], A[k])
            u += np.bincount(r, uu, minlength=npr); w += np.bincount(r, ww, minlength=npr)
        return u, w


def karman_w_stats(Lw, b=10.0):
    """Спектр Кармана для w (MIL-HDBK-1797), одностороннее Ω: σ_wing/σ_точки, ρ(b), интегральный масштаб."""
    Om = np.logspace(-6, 3, 400001) / max(Lw, 1e-3) * 1e0
    Om = np.linspace(0, 200.0 / Lw, 800001)
    x = (1.339 * Lw * Om) ** 2
    Phi = Lw / np.pi * (1 + 8 / 3 * x) / (1 + x) ** (11 / 6)
    var = np.trapezoid(Phi, Om)
    sinc2 = np.sinc(Om * b / (2 * np.pi)) ** 2
    ratio = np.sqrt(np.trapezoid(Phi * sinc2, Om) / var)
    rho = np.trapezoid(Phi * np.cos(Om * b), Om) / var
    Lam = np.pi / 2 * Phi[0] / var
    return {"sigma_wing_over_point": float(ratio), "rho_b": float(rho), "integral_scale": float(Lam), "var_check": float(var)}


def analyse(P, nsnap=24, every=20.0, spin=100.0, xs=None, b=10.0, verbose=False):
    L = P.L
    xs = np.arange(0, L, 2.0)
    for _ in range(int(spin / P.dt)):
        P.step()
    stats = {z: {"w": [], "u": []} for z in PROBES}
    nstep = int(every / P.dt)
    tstep = 0.0
    for s in range(nsnap):
        for _ in range(nstep):
            t0 = time.perf_counter(); P.step(); tstep += time.perf_counter() - t0
        xp = np.tile(xs, len(PROBES)); zp = np.repeat(PROBES, len(xs))
        u, w = P.field_at(xp, zp)
        for k, z in enumerate(PROBES):
            stats[z]["w"].append(w[k * len(xs):(k + 1) * len(xs)]); stats[z]["u"].append(u[k * len(xs):(k + 1) * len(xs)])
        if verbose:
            print(s, len(P.x), P.n_ann, flush=True)
    res = {}
    dx = xs[1] - xs[0]
    for z in PROBES:
        W = np.array(stats[z]["w"]); Uu = np.array(stats[z]["u"])
        sw = float(W.std()); su = float(Uu.std())
        uw = float(np.mean((Uu - Uu.mean()) * (W - W.mean())))
        # автокорреляция по x (круговая, усреднение по снимкам)
        Wc = W - W.mean(axis=1, keepdims=True)
        F = np.fft.rfft(Wc, axis=1)
        ac = np.fft.irfft((F * np.conj(F)).mean(axis=0), n=W.shape[1]) / W.shape[1]
        ac = ac / ac[0]
        maxlag = int(150.0 / dx)
        r = ac[:maxlag]
        zc = np.argmax(r < 0) if (r < 0).any() else maxlag
        Lam = float(np.trapezoid(r[:zc], dx=dx))
        rho_b = float(ac[int(round(b / dx))])
        # среднее по крылу b
        nb_ = int(round(b / dx))
        cs = np.cumsum(np.concatenate([np.zeros((W.shape[0], 1)), np.concatenate([W, W[:, :nb_]], axis=1)], axis=1), axis=1)
        wing = (cs[:, nb_:nb_ + W.shape[1]] - cs[:, :W.shape[1]]) / nb_
        ratio = float(wing.std() / sw)
        game_sw = 1.25 * USTAR * (1 - z / HMIX) ** 0.75
        game_uw = -USTAR ** 2 * (1 - z / HMIX) ** 1.5
        kar = karman_w_stats(z, b)
        res[str(z)] = {"sigma_w": sw, "sigma_w_game": game_sw, "sigma_ratio": sw / game_sw,
                       "sigma_u": su, "uw": uw, "uw_game": game_uw, "uw_over_ustar2": uw / USTAR ** 2,
                       "L_w_2Lam": 2 * Lam, "L_w_game": z, "L_ratio": 2 * Lam / z,
                       "rho_b": rho_b, "rho_b_karman": kar["rho_b"],
                       "wing_ratio": ratio, "wing_ratio_karman": kar["sigma_wing_over_point"]}
    res["_meta"] = {"n_alive_mean": float(len(P.x)), "n_alive_expected_no_ann": float(P.n_alive), "annihilated": P.n_ann,
                    "born": P.n_born, "died_by_age_or_wall": P.n_died, "births_per_s": float(P.birth_rate),
                    "us_per_step_dyn": tstep / (nsnap * nstep) * 1e6, "n_snap": nsnap, "L": L, "dt": P.dt}
    return res


def main(quick=False):
    t0 = time.perf_counter()
    nsnap = 8 if quick else 40
    out = {"base": None, "scan": {}}
    out["base"] = analyse(Pairs(seed=1, f_ann=0.1), nsnap=nsnap)
    print("base", json.dumps({k: (round(v["sigma_ratio"], 2), round(v["L_ratio"], 2), round(v["uw_over_ustar2"], 2), round(v["wing_ratio"], 2), round(v["wing_ratio_karman"], 2)) for k, v in out["base"].items() if k != "_meta"}), out["base"]["_meta"], flush=True)
    cfgs = {"no_annihilation": dict(annihilate=False), "f_ann_0.05": dict(f_ann=0.05), "f_ann_0.2": dict(f_ann=0.2),
            "lam_x0.5": dict(lam_scale=0.5, f_ann=0.1), "lam_x2": dict(lam_scale=2.0, f_ann=0.1), "lam_x3": dict(lam_scale=3.0, f_ann=0.1),
            "phi_30": dict(phi_deg=30.0, f_ann=0.1), "phi_60": dict(phi_deg=60.0, f_ann=0.1), "ell_game": dict(mode="game", f_ann=0.1),
            "no_ann_phi_30": dict(annihilate=False, phi_deg=30.0), "no_ann_phi_60": dict(annihilate=False, phi_deg=60.0)}
    for name, kw in cfgs.items():
        r = analyse(Pairs(seed=2, **kw), nsnap=12)
        out["scan"][name] = r
        print(name, json.dumps({k: (round(v["sigma_ratio"], 2), round(v["L_ratio"], 2), round(v["uw_over_ustar2"], 2)) for k, v in r.items() if k != "_meta"}), r["_meta"]["annihilated"], flush=True)
    out["wall_s"] = time.perf_counter() - t0
    json.dump(out, open("out/step2.json", "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main(quick="--quick" in sys.argv)
