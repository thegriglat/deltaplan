"""Подгонка (λ/h, α, z0) по Askervein: разгоны AM-09 (39 наблюдаемых, поправки сетки/области и σ из
tune/out/fit_s1.json, как в Моррисе) + профиль опорной мачты RS (S(z)/S(24 м), config.json → rs_profile).
Модель между узлами — кубическая интерполяция каждой наблюдаемой по сетке (ln λ/h, α, ln z0), минимум —
iminuit (MIGRAD + MINOS), профили χ² — минимизация по остальным параметрам.

  python fit.py  → out/fit.json, out/fig_*.png
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import numpy as np
from iminuit import Minuit
from scipy.interpolate import RegularGridInterpolator

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
CFG = json.loads((HERE / "config.json").read_text())
FIT = json.loads((HERE.parent / "tune" / "out" / "fit_s1.json").read_text())
ASK = {o["name"]: o for o in FIT["obs"]}
DATA = HERE.parent / "data" / "askervein" / "askervein_validation1.txt"
RSG = "профиль RS"
ALPHA_MAX = 0.24                # верх диапазона Морриса; сетка идёт до 0,27 — чтобы видеть край


def rs_data():
    rows = [r for r in csv.DictReader(open(DATA)) if r["Name"] == "RS"]
    cup = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Sensor"] == "AES cup"}
    kite = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if "kite" in r["Sensor"]}
    ref = cup[24.0]
    out = {}
    for name, sig in CFG["rs_profile"]["use"].items():
        src, h = (cup, float(name[3:])) if name.startswith("cup") else (kite, float(name[4:]))
        out[f"RS_{name}"] = dict(h=h, data=src[h] / ref, sig=sig)
    return out


RS = rs_data()
NAMES = list(ASK) + list(RS)
D = np.array([ASK[n]["data"] for n in ASK] + [RS[n]["data"] for n in RS])
SIG = np.array([math.sqrt(a["sig_data"] ** 2 + a["sig_loo"] ** 2 + a["sig_grid"] ** 2 + a["sig_dom"] ** 2)
                for a in ASK.values()] + [RS[n]["sig"] for n in RS])
CORR = np.array([a["grid_corr"] + a["dom_corr"] for a in ASK.values()] + [0.0] * len(RS))
GRP = [ASK[n]["grp"] for n in ASK] + [RSG] * len(RS)
GROUPS = list(dict.fromkeys(GRP))


def obs_vec(r):
    o, rs = r["obs"], r["rs"]
    return np.array([o[n] for n in ASK] + [rs[f"{RS[n]['h']:g}"] / rs["24"] for n in RS])


def load(name="grid"):
    runs = [json.loads(line) for line in (OUT / f"runs_{name}.jsonl").read_text().splitlines()]
    return runs


def build(runs):
    lf = np.array(sorted({r["lam_frac"] for r in runs}))
    al = np.array(sorted({r["alpha"] for r in runs}))
    z0 = np.array(sorted({r["z0"] for r in runs}))
    Y = np.full((len(lf), len(al), len(z0), len(NAMES)), np.nan)
    bad = []
    for r in runs:
        i, j, k = (int(np.argmin(abs(a - r[key]))) for a, key in ((lf, "lam_frac"), (al, "alpha"), (z0, "z0")))
        if r["status"] in ("ok", "max_iter") and "obs" in r:
            Y[i, j, k] = obs_vec(r)
        if r["status"] != "ok":
            bad.append((r["lam_frac"], r["alpha"], r["z0"], r["status"]))
    return lf, al, z0, Y, bad


class Chi2:
    def __init__(self, lf, al, z0, Y, mask=None, prior=False):
        self.prior = prior
        self.box = [(lf[0], lf[-1]), (al[0], al[-1]), (z0[0], z0[-1])]
        self.f = RegularGridInterpolator((np.log(lf), al, np.log(z0)), Y, method="cubic")
        self.m = np.ones(len(NAMES), bool) if mask is None else mask

    def model(self, lf, al, z0):
        return self.f([[math.log(lf), al, math.log(z0)]])[0] + CORR

    def terms(self, lf, al, z0):
        return ((self.model(lf, al, z0) - D) / SIG) ** 2

    def __call__(self, lf, al, z0):
        c = float(self.terms(lf, al, z0)[self.m].sum())
        if self.prior:
            z, s = CFG["z0_prior"]
            c += ((math.log(z0) - math.log(z)) / s) ** 2
        return c

    def fit(self, amax=ALPHA_MAX, fix=None, start=(0.05, 0.21, 0.03)):
        m = Minuit(self, lf=start[0], al=start[1], z0=start[2])
        m.errordef = Minuit.LEAST_SQUARES
        m.limits["lf"], m.limits["al"], m.limits["z0"] = self.box[0], (self.box[1][0], min(amax, self.box[1][1])), self.box[2]
        for k, v in (fix or {}).items():
            m.values[k] = v
            m.fixed[k] = True
        m.simplex().migrad()
        return m


def groups(terms, mask=None):
    return {g: dict(n=int(sum(1 for x in GRP if x == g)), chi2=float(sum(t for t, x in zip(terms, GRP) if x == g)))
            for g in GROUPS}


def summary(C, m, n_obs):
    free = [k for k in ("lf", "al", "z0") if not m.fixed[k]]
    out = dict(lam_frac=m.values["lf"], alpha=m.values["al"], z0=m.values["z0"], chi2=m.fval,
               ndf=n_obs - len(free), valid=bool(m.valid))
    try:
        m.hesse()
        m.minos()
        out["err"] = {k: m.errors[k] for k in free}
        out["minos"] = {k: [m.merrors[k].lower, m.merrors[k].upper] for k in free}
        cov = np.array(m.covariance)
        sd = np.sqrt(np.diag(cov))
        out["corr"] = {f"{a}-{b}": float(cov[i, j] / sd[i] / sd[j]) for i, a in enumerate(("lf", "al", "z0"))
                       for j, b in enumerate(("lf", "al", "z0")) if i < j and a in free and b in free}
    except Exception as e:                                   # noqa: BLE001
        out["err_fail"] = repr(e)
    t = C.terms(m.values["lf"], m.values["al"], m.values["z0"])
    out["groups"] = groups(t)
    out["chi2_speedup"] = float(sum(x for x, g in zip(t, GRP) if g != RSG))
    out["chi2_rs"] = float(sum(x for x, g in zip(t, GRP) if g == RSG))
    return out


def profile(C, key, xs, amax):
    res = []
    for x in xs:
        start = dict(lf=0.05, al=0.21, z0=0.03)
        start[key] = x
        m = C.fit(amax, fix={key: x}, start=(start["lf"], start["al"], start["z0"]))
        res.append(dict(x=float(x), chi2=m.fval, lf=m.values["lf"], al=m.values["al"], z0=m.values["z0"]))
    return res


def interval(prof, chi_min, d=1.0):
    xs = np.array([p["x"] for p in prof])
    c = np.array([p["chi2"] for p in prof]) - chi_min
    ok = xs[c <= d]
    return [float(ok.min()), float(ok.max())] if len(ok) else None


def main():
    runs = load()
    lf, al, z0, Y, bad = build(runs)
    if np.isnan(Y).any():
        raise SystemExit(f"пропуски в сетке: {int(np.isnan(Y).any(-1).sum())} точек")
    res = dict(grid=dict(lam_frac=lf.tolist(), alpha=al.tolist(), z0=z0.tolist(), n_runs=len(runs), not_ok=bad,
                         t_gpu_s=float(sum(r.get("t", 0) for r in runs))),
               rs_obs=RS, n_obs=len(NAMES), n_speedup=len(ASK))
    C = Chi2(lf, al, z0, Y)
    Cs = Chi2(lf, al, z0, Y, mask=np.array([g != RSG for g in GRP]))
    # до: AM-09 (λ/h 0,25, α 0,17, z0 0,0345) — прямой прогон и интерполяция
    t0 = [json.loads(x) for x in (OUT / "runs_test.jsonl").read_text().splitlines()][-1]
    tt = ((obs_vec(t0) + CORR - D) / SIG) ** 2
    res["before_am09"] = dict(params=[0.25, 0.17, 0.0345], chi2=float(tt.sum()), ndf=len(NAMES) - 2, groups=groups(tt),
                              chi2_speedup=float(tt[:len(ASK)].sum()), chi2_rs=float(tt[len(ASK):].sum()),
                              chi2_interp=C(0.25, 0.17, 0.0345))
    fits = {}
    Cp = Chi2(lf, al, z0, Y, prior=True)
    for tag, CC, n in (("all", C, len(NAMES)), ("speedup_only", Cs, len(ASK)), ("all_z0prior", Cp, len(NAMES) + 1)):
        for amax, atag in ((ALPHA_MAX, ""), (al[-1], "_amax%.2f" % al[-1])):
            best = None
            for s in [(a, b, c) for a in (0.03, 0.1, 0.3) for b in (0.15, 0.2, 0.235) for c in (0.02, 0.05)]:
                m = CC.fit(amax, start=s)
                if best is None or m.fval < best.fval:
                    best = m
            fits[tag + atag] = summary(CC, best, n)
            fits[tag + atag]["chi2_all_obs"] = C(best.values["lf"], best.values["al"], best.values["z0"])
    res["fits"] = fits
    b = fits["all"]
    profs = {}
    for key, xs in (("lf", np.exp(np.linspace(math.log(lf[0]), math.log(lf[-1]), 31))),
                    ("al", np.linspace(al[0], ALPHA_MAX, 33)),
                    ("z0", np.exp(np.linspace(math.log(z0[0]), math.log(z0[-1]), 25)))):
        profs[key] = profile(C, key, xs, ALPHA_MAX)
        b.setdefault("profile_1sigma", {})[key] = interval(profs[key], b["chi2"])
    ps = {"al": profile(Cs, "al", np.linspace(al[0], ALPHA_MAX, 33), ALPHA_MAX)}
    res["profiles"] = profs
    res["profile_speedup_only_alpha"] = ps["al"]
    # карта χ²(λ/h, α), z0 — в минимуме; с профилем RS и без
    LF = np.exp(np.linspace(math.log(lf[0]), math.log(lf[-1]), 25))
    AL = np.linspace(al[0], al[-1], 25)
    maps = {}
    for tag, CC in (("all", C), ("speedup_only", Cs)):
        Z = np.zeros((len(AL), len(LF)))
        for i, a in enumerate(AL):
            for j, x in enumerate(LF):
                m = CC.fit(al[-1], fix=dict(lf=x, al=a), start=(x, a, 0.03))
                Z[i, j] = m.fval
        maps[tag] = Z
    np.savez_compressed(OUT / "chi2_maps.npz", lam_frac=LF, alpha=AL, **maps)
    # профиль RS в лучшей точке / AM-09 и остатки
    mb = C.model(b["lam_frac"], b["alpha"], b["z0"])
    res["best_terms"] = {n: dict(data=float(d), model=float(x), sig=float(s), chi2=float(((x - d) / s) ** 2))
                         for n, d, x, s in zip(NAMES, D, mb, SIG)}
    (OUT / "fit.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    figs(res, maps, LF, AL, C, t0)
    print(json.dumps(dict(before=res["before_am09"], fits={k: {kk: v[kk] for kk in ("lam_frac", "alpha", "z0", "chi2", "ndf", "chi2_speedup", "chi2_rs", "chi2_all_obs")} for k, v in fits.items()},
                          prof=b.get("profile_1sigma"), minos=b.get("minos"), corr=b.get("corr")), ensure_ascii=False, indent=1))


def figs(res, maps, LF, AL, C, t0):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    b = res["fits"]["all"]
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.4), sharey=True)
    for ax, tag, title in ((axs[0], "speedup_only", "только разгоны (39)"), (axs[1], "all", "разгоны + профиль RS (47)")):
        Z = maps[tag] - maps[tag].min()
        cs = ax.contourf(LF, AL, Z, levels=[0, 1, 2.3, 4, 6.2, 9, 16, 25, 50, 100], cmap="viridis_r")
        ax.contour(LF, AL, Z, levels=[2.3, 6.2], colors="w", linewidths=1)
        ax.set_xscale("log")
        ax.set_xticks([0.02, 0.05, 0.1, 0.2, 0.5], ["0,02", "0,05", "0,1", "0,2", "0,5"])
        ax.minorticks_off()
        ax.axhline(ALPHA_MAX, color="k", ls=":", lw=0.8)
        ax.plot([0.25], [0.17], "rx", label="AM-09")
        f = res["fits"][tag]
        ax.plot([f["lam_frac"]], [f["alpha"]], "r*", ms=11, label="минимум (α ≤ 0,24)")
        ax.set_title(title, fontsize=10)
        ax.set_xlabel("λ/h")
        ax.legend(loc="lower right", fontsize=8)
    axs[0].set_ylabel("α притока")
    fig.suptitle("Δχ²(λ/h, α), z0 — в минимуме", fontsize=11)
    fig.colorbar(cs, ax=axs, label="Δχ²")
    fig.savefig(OUT / "fig_chi2_lf_alpha.png", dpi=130)
    plt.close(fig)
    # профиль RS
    fig, ax = plt.subplots(figsize=(5, 5))
    rows = [r for r in csv.DictReader(open(DATA)) if r["Name"] == "RS"]
    cup24 = next(float(r["S(m/s)"]) for r in rows if r["Sensor"] == "AES cup" and r["H(m)"] == "24")
    for sens, mk, lab in (("AES cup", "o", "чашки AES"), ("BRE tala kite", "s", "змей BRE"), ("AES tilted gill uvw", "^", "Gill UVW")):
        pts = [(float(r["H(m)"]), float(r["S(m/s)"]) / cup24) for r in rows if r["Sensor"] == sens]
        ax.plot([p[1] for p in pts], [p[0] for p in pts], mk, mfc="none", label=lab)
    hs = [h for h in CFG["rs_heights"] if h >= 10]
    for rr, lab, st in ((t0["rs"], "AM-09 (0,25; 0,17; 0,035)", "--"),):
        ax.plot([rr[f"{h:g}"] / rr["24"] for h in hs], hs, st, label=lab)
    best = min(load(), key=lambda r: (math.log(r["lam_frac"] / b["lam_frac"])) ** 2 + ((r["alpha"] - b["alpha"]) / 0.1) ** 2
               + (math.log(r["z0"] / b["z0"])) ** 2)
    ax.plot([best["rs"][f"{h:g}"] / best["rs"]["24"] for h in hs], hs, "-",
            label=f"ближайший к минимуму узел ({best['lam_frac']:.3f}; {best['alpha']:.3f}; {best['z0']:.3f})")
    ax.set_yscale("log")
    ax.set_xlabel("S(z)/S(24 м, чашки)")
    ax.set_ylabel("z, м над землёй")
    ax.set_title("Профиль ветра на мачте RS")
    ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(OUT / "fig_rs_profile.png", dpi=130)
    plt.close(fig)
    # профили χ²
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6))
    for ax, key, lab in zip(axs, ("lf", "al", "z0"), ("λ/h", "α", "z0, м")):
        p = res["profiles"][key]
        ax.plot([q["x"] for q in p], [q["chi2"] - b["chi2"] for q in p], "-o", ms=3, label="все 47")
        if key == "al":
            q = res["profile_speedup_only_alpha"]
            c0 = min(x["chi2"] for x in q)
            ax.plot([x["x"] for x in q], [x["chi2"] - c0 for x in q], "--", label="только разгоны")
            ax.legend(fontsize=8)
        ax.axhline(1, color="k", lw=0.6, ls=":")
        ax.set_ylim(0, 25)
        ax.set_xlabel(lab)
        if key != "al":
            ax.set_xscale("log")
    axs[0].set_ylabel("Δχ² (остальные в минимуме)")
    fig.tight_layout()
    fig.savefig(OUT / "fig_chi2_profiles.png", dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    main()
