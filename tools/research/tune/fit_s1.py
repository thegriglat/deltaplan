"""AM-09, масштаб 1: подгонка λ/h (Params.lam_frac) по Askervein, z0 холма — мешающий параметр.

Модель наблюдаемой = полином по прогонам 25 м + 2-й порядок + поправка сетки к 12,5 м + 2-й
порядок (среднее по точкам прогонов 12,5 м); σ модели² = σ_LOO² + σ_сетки², σ_сетки = |поправка|
⊕ разброс поправки по параметрам (оставшаяся ошибка решения 12,5 м оценена величиной последнего
шага сгущения — консервативно для порядка сходимости ≥ 1).

  .venv/bin/python fit_s1.py            → out/fit_s1.json, out/fig_s1_*.png
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from iminuit import Minuit

import askervein_runs as R
import professor as P

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
SPACE = P.Space(["lam_frac", "z0"], [0.03, 0.01], [0.6, 0.06])      # прогоны; физичный диапазон λ/h — LF_PHYS
LF_PHYS = (0.03, 0.25)                 # λ/h: Блэкадар 0,00027 G/f ≈ 0,02–0,03 h … 0,1 h (Mellor–Yamada, AM-01) … 0,25 h — с запасом
SG_PRIOR = (1.0, 1.0)                  # множитель поправки сетки 25 → 12,5 м: 0 — решение 25 м, 1 — 12,5 м, 2 — Ричардсон p = 1
Z0_PRIOR = (0.03, math.log(1.5))       # Taylor & Teunissen 1987: z0 ≈ 0,03 м; σ ln z0 — множитель 1,5 (назн.)
PROFILE_MIN_H = 9.0                    # профиль HT: ниже 1,5 Δz сетки 12,5 м (9,4 м) — значение первой клетки
DEG = 3


def load(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
    return [r for r in rows if r["status"] == "ok"]


def observables():
    obs = R.obs_points() + [p for p in R.obs_profiles() if p["h"] >= PROFILE_MIN_H]
    return obs


def group(name):
    if name.startswith("HT") or name.startswith("CP") or name in ("BNW10", "BSE10", "BSE20"):
        return "вершина/гребень"
    if name.startswith("ANE") or name.startswith("AANE"):
        return "подветренная сторона"
    if name.startswith("ASW") or name.startswith("AASW"):
        return "наветренная сторона"
    return "линия B (вдоль гребня)"


def matrices(rows, names):
    X = np.array([[r["params"].get("lam_frac", 0.1), r["params"].get("z0", 0.03)] for r in rows])
    Y = np.array([[r["obs"][n] for n in names] for r in rows])
    return X, Y


class Fit:
    def __init__(self, runs, fine, deg=DEG, drop=(), mode="indep"):
        """mode: indep — σ сетки точки = |поправка| ⊕ её разброс, независимо по точкам (основной вариант);
        scale — поправка × sg, sg — общий мешающий параметр с априорным N(1, 1) (полная корреляция, проверка)."""
        self.mode = mode
        self.obs = [o for o in observables() if o["name"] not in drop]
        self.names = [o["name"] for o in self.obs]
        X, Y = matrices(runs, self.names)
        self.sur = P.Surrogate(SPACE.to_u(X), Y, deg)
        Xf, Yf = matrices(fine, self.names)
        d = Yf - self.sur(SPACE.to_u(Xf))
        self.corr = d.mean(axis=0)
        self.sig_grid = d.std(axis=0)        # зависимость поправки от параметров
        if mode == "indep":
            self.sig_grid = np.sqrt(self.corr ** 2 + self.sig_grid ** 2)
        self.d = np.array([o["fsr"] for o in self.obs])
        self.sd = np.array([o["sig"] for o in self.obs])
        self.sig = np.sqrt(self.sd ** 2 + self.sur.loo_rms ** 2 + self.sig_grid ** 2)

    def model(self, lf, z0, sg=1.0):
        return self.sur(SPACE.to_u([[lf, z0]]))[0] + sg * self.corr

    def terms(self, lf, z0, sg=1.0):
        return ((self.model(lf, z0, sg) - self.d) / self.sig) ** 2

    def priors(self, z0, sg):
        pr = ((math.log(z0) - math.log(Z0_PRIOR[0])) / Z0_PRIOR[1]) ** 2
        if self.mode == "scale":
            pr += ((sg - SG_PRIOR[0]) / SG_PRIOR[1]) ** 2
        return pr

    def chi2(self, lf, z0, sg=1.0):
        return float(self.terms(lf, z0, sg).sum() + self.priors(z0, sg))

    def minimize(self, lf_lim=LF_PHYS, fix_sg=None):
        fix_sg = self.mode == "indep" if fix_sg is None else fix_sg
        m = Minuit(self.chi2, lf=0.1, z0=0.03, sg=1.0)
        m.limits["lf"] = lf_lim
        m.limits["z0"] = (SPACE.lo[1], SPACE.hi[1])
        m.limits["sg"] = (-1.0, 4.0)
        m.fixed["sg"] = fix_sg
        m.errordef = Minuit.LEAST_SQUARES
        m.migrad()
        m.hesse()
        try:
            m.minos()
            mn = {k: (m.merrors[k].lower, m.merrors[k].upper) for k in ("lf", "z0")}
        except Exception:     # noqa: BLE001 — у границы MINOS может не сойтись
            mn = {}
        return m, mn


def main():
    runs = load(OUT / "runs_s1_25.jsonl") + load(OUT / "runs_ext_25.jsonl")
    fine = load(OUT / "runs_s1_12p5.jsonl")
    F = Fit(runs, fine)
    m, mn = F.minimize()
    lf, z0, sg = (m.values[k] for k in ("lf", "z0", "sg"))
    cov = np.array(m.covariance)
    n_obs = len(F.names)
    ndf = n_obs + 1 - 2                     # + априорный член z0, − 2 параметра (sg = 1 в основном варианте)
    chi2 = m.fval
    terms = F.terms(lf, z0, sg)
    groups = {}
    for n, t in zip(F.names, terms):
        groups.setdefault(group(n), []).append(t)
    # eigentunes в пространстве (ln λ/h, ln z0, sg); λ/h у границы — ковариация HESSE (односторонняя)
    cov = cov[:2, :2]
    J = np.diag([1 / lf, 1 / z0])
    cov_t = J @ cov @ J
    ev, evec = P.eigentunes(cov_t)
    tunes = []
    for k in range(2):
        for sgn in (+1, -1):
            v = np.array([math.log(lf), math.log(z0)]) + sgn * math.sqrt(ev[k]) * evec[:, k]
            tunes.append(dict(dir=k, sign=sgn, lam_frac=math.exp(v[0]), z0=math.exp(v[1]),
                              chi2=F.chi2(math.exp(v[0]), math.exp(v[1]))))
    # профиль χ²(λ/h): z0 и sg — в минимуме при каждом λ/h (в т. ч. за физичной границей)
    prof = []
    for x in np.exp(np.linspace(math.log(0.03), math.log(0.6), 25)):
        mp, _ = F.minimize(lf_lim=(x, x))
        prof.append(dict(lam_frac=float(x), chi2=mp.fval, z0=mp.values["z0"], sg=mp.values["sg"]))
    m_free, _ = F.minimize(lf_lim=(SPACE.lo[0], SPACE.hi[0]))
    Fs = Fit(runs, fine, mode="scale")
    m_nog, _ = Fs.minimize()
    # напряжение: подгонка по частям
    parts = {}
    for label, pred in (("без подветренной стороны", lambda n: group(n) == "подветренная сторона"),
                        ("только подветренная сторона", lambda n: group(n) != "подветренная сторона"),
                        ("без вершины/гребня", lambda n: group(n) == "вершина/гребень"),
                        ("только наветренная сторона", lambda n: group(n) != "наветренная сторона")):
        Fp = Fit(runs, fine, drop=[n for n in F.names if pred(n)])
        mp, _ = Fp.minimize()
        parts[label] = dict(lam_frac=mp.values["lf"], lam_frac_err=mp.errors["lf"], z0=mp.values["z0"],
                            sg=mp.values["sg"], chi2=mp.fval, n=len(Fp.names))
    # номинал (как было): λ/h = 0,1, z0 = 0,03, поправка сетки 1
    nom = dict(chi2=F.chi2(0.1, 0.03, 1.0), terms=dict(zip(F.names, F.terms(0.1, 0.03, 1.0).tolist())))
    # сходимость: число прогонов × степень полинома
    conv = []
    rng = np.random.default_rng(1)
    for deg in (2, 3, 4):
        for n in (15, 20, 30, 45, len(runs)):
            vals = []
            for _rep in range(8 if n < len(runs) else 1):
                idx = rng.choice(len(runs), n, replace=False) if n < len(runs) else np.arange(n)
                try:
                    Fc = Fit([runs[i] for i in idx], fine, deg=deg)
                except ValueError:
                    continue
                mc, _ = Fc.minimize(lf_lim=(0.1, 0.1))
                mb, _ = Fc.minimize()
                vals.append((mc.fval - mb.fval, 0.0, mb.values["z0"], mb.errors["z0"], mb.fval, mb.values["lf"]))
            if vals:
                a = np.array(vals)
                conv.append(dict(deg=deg, n=n, dchi2_nom=a[:, 0].mean(), dchi2_nom_spread=a[:, 0].std(),
                                 z0=a[:, 2].mean(), z0_spread=a[:, 2].std(), z0_err=a[:, 3].mean(),
                                 chi2=a[:, 4].mean(), chi2_spread=a[:, 4].std(), lam_frac=a[:, 5].mean()))
    res = dict(
        params=dict(lam_frac=dict(value=lf, err=m.errors["lf"], minos=mn.get("lf"), limits=LF_PHYS),
                    z0=dict(value=z0, err=m.errors["z0"], minos=mn.get("z0")),
                    ),
        free=dict(lam_frac=m_free.values["lf"], err=m_free.errors["lf"], z0=m_free.values["z0"], sg=m_free.values["sg"],
                  chi2=m_free.fval),
        scale_mode=dict(lam_frac=m_nog.values["lf"], err=m_nog.errors["lf"], sg=m_nog.values["sg"],
                        sg_err=m_nog.errors["sg"], z0=m_nog.values["z0"], chi2=m_nog.fval),
        corr=P.corr(cov).tolist(), chi2=chi2, ndf=ndf, prob=P.chi2_prob(chi2, ndf),
        prior_z0=Z0_PRIOR, prior_sg_scale_mode=SG_PRIOR, n_obs=n_obs, deg=DEG, n_runs=len(runs), n_fine=len(fine),
        groups={g: dict(n=len(t), chi2=float(sum(t))) for g, t in groups.items()},
        obs=[dict(name=n, grp=group(n), data=float(F.d[i]), sig_data=float(F.sd[i]), sig_loo=float(F.sur.loo_rms[i]),
                  grid_corr=float(F.corr[i]), sig_grid=float(F.sig_grid[i]),
                  model=float(F.model(lf, z0, sg)[i]), model_nom=float(F.model(0.1, 0.03, 1.0)[i]),
                  model_25=float(F.model(lf, z0, 0.0)[i]), chi2=float(terms[i])) for i, n in enumerate(F.names)],
        eigen=dict(values=ev.tolist(), vectors=evec.tolist(), axes=["ln λ/h", "ln z0"], tunes=tunes),
        profile=prof, parts=parts, nominal=nom, convergence=conv)
    (OUT / "fit_s1.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print(f"λ/h = {P.fmt(lf, m.errors['lf'])} (MINOS {mn.get('lf')}), z0 = {P.fmt(z0, m.errors['z0'])}, "
          "(поправка сетки 25 → 12,5 м; её величина — в σ точки)")
    print(f"χ² = {chi2:.1f} / ndf {ndf} (p = {res['prob']:.3g}); номинал χ² = {nom['chi2']:.1f}")
    print("корреляции", np.round(res["corr"], 2).tolist())
    print(f"без границы: λ/h = {P.fmt(res['free']['lam_frac'], res['free']['err'])}, χ² {res['free']['chi2']:.1f}; "
          f"поправка сетки общим множителем: λ/h = {P.fmt(res['scale_mode']['lam_frac'], res['scale_mode']['err'])}, "
          f"sg = {P.fmt(res['scale_mode']['sg'], res['scale_mode']['sg_err'])}, χ² {res['scale_mode']['chi2']:.1f}")
    for g, v in res["groups"].items():
        print(f"  {g}: n = {v['n']}, χ² = {v['chi2']:.1f}")
    for k, v in parts.items():
        print(f"  {k}: λ/h = {P.fmt(v['lam_frac'], v['lam_frac_err'])}, sg {v['sg']:.2f}, χ² = {v['chi2']:.1f}/{v['n']}")
    for t in tunes:
        print("  eigentune", t)
    figs(res, F, lf, z0, sg)


def figs(res, F, lf, z0, sg):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 9})
    # 1) данные против модели по точкам
    fig, ax = plt.subplots(figsize=(12, 4.2))
    o = res["obs"]
    x = np.arange(len(o))
    ax.errorbar(x, [p["data"] for p in o], yerr=[p["sig_data"] for p in o], fmt="ko", ms=3,
                label="Askervein, 10 м (профиль HT — 15/24/34 м)")
    ax.errorbar(x + 0.2, [p["model"] for p in o], yerr=[math.hypot(p["sig_loo"], p["sig_grid"]) for p in o],
                fmt="s", color="#1f77b4", ms=3, label=f"модель (12,5 м): λ/h = {lf:.3f}, z0 = {z0:.3f}; σ — сетка ⊕ полином")
    ax.plot(x + 0.2, [p["model_nom"] for p in o], "x", color="#d62728", ms=4, label="номинал AM-01 (λ/h 0,1; 12,5 м)")
    ax.plot(x + 0.2, [p["model_25"] for p in o], "+", color="0.5", ms=4, label="те же параметры, сетка 25 м")
    ax.set_xticks(x)
    ax.set_xticklabels([p["name"] for p in o], rotation=90)
    ax.set_ylabel("ΔS = S/S_RS − 1 на той же высоте")
    ax.axhline(0, color="0.7", lw=0.5)
    ax.legend(loc="lower left", fontsize=8)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT / "fig_s1_askervein.png", dpi=110)
    plt.close(fig)
    # 2) сходимость: число прогонов × степень
    fig, axs = plt.subplots(1, 3, figsize=(13, 3.6))
    for deg, c in zip((2, 3, 4), ("#1f77b4", "#ff7f0e", "#2ca02c")):
        rr = [r for r in res["convergence"] if r["deg"] == deg]
        n = np.array([r["n"] for r in rr]) + (deg - 3) * 0.6
        axs[0].errorbar(n, [r["dchi2_nom"] for r in rr], yerr=[r["dchi2_nom_spread"] for r in rr], fmt="o-",
                        color=c, ms=3, capsize=2, label=f"степень {deg}")
        axs[1].errorbar(n, [r["z0"] for r in rr], yerr=[r["z0_spread"] for r in rr], fmt="o-", color=c, ms=3, capsize=2)
        axs[2].errorbar(n, [r["chi2"] for r in rr], yerr=[r["chi2_spread"] for r in rr], fmt="o-", color=c, ms=3, capsize=2)
    axs[0].set_ylabel("χ²(λ/h = 0,1) − χ²_мин (λ/h → 0,25)")
    axs[1].set_ylabel("z0 холма, м")
    axs[2].set_ylabel("χ² в минимуме (λ/h ≤ 0,25)")
    for a in axs:
        a.set_xlabel("число прогонов")
        a.grid(alpha=0.3)
    axs[0].legend()
    fig.suptitle("Сходимость подгонки масштаба 1 (Askervein): число прогонов и степень полинома")
    fig.tight_layout()
    fig.savefig(OUT / "fig_s1_convergence.png", dpi=110)
    plt.close(fig)
    # 3) профиль χ²(λ/h)
    pr = res["profile"]
    fig, ax = plt.subplots(figsize=(5.5, 3.8))
    ax.plot([p["lam_frac"] for p in pr], [p["chi2"] - res["chi2"] for p in pr], "k-")
    ax.axvspan(*LF_PHYS, color="#2ca02c", alpha=0.1, label="физичный диапазон")
    ax.axvline(0.1, color="#d62728", ls=":", label="номинал AM-01")
    ax.axhline(1, color="0.6", lw=0.6)
    ax.set_xscale("log")
    ax.set_xlabel("λ/h (Params.lam_frac)")
    ax.set_ylabel("χ² − χ²_мин (z0 и поправка сетки — в минимуме)")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT / "fig_s1_profile.png", dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    main()
