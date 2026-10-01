"""Б1, этап 2: совместная подгонка Askervein + Perdigão по пачке (out/runs_ask.jsonl, out/runs_pd.jsonl).

Модель между узлами — кубическая интерполяция каждой наблюдаемой по сетке (ln λ, α, ln z0) каждого (под)случая.
Параметры: общее λ (длина перемешивания; в нейтрали λ = max(lam, λ/h·h) — одно число на случай), α_A, z0_A (Askervein),
α_NE, α_SW, z0_P (Perdigão: z0 общий, α — свой у подслучая; решение К2). χ² — формула C10:
Σ ((obs + grid_corr − data)/√(sig² + sig_grid²))²; зона Menke — одно наблюдение на величину (среднее модели NE и SW).
Переводы в (λ/h, lam): «lam» — λ одно на все случаи; «lf» — λ_i = λ/h · h_i (h_i = 0,3u*/f случая при его U10 и z0);
общий — λ_i = max(lam, λ/h · h_i) (карта χ²).

  python fit.py  → out/fit.json, out/fit_table.md, out/fig_fit_*.png
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from iminuit import Minuit
from scipy.interpolate import NearestNDInterpolator, RegularGridInterpolator

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import askervein as AK     # noqa: E402
import perdigao as PD      # noqa: E402
import rules as RU         # noqa: E402
import batch as B          # noqa: E402

OUT = HERE / "out"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
ZONES = ("zoneL", "zoneDepth", "zoneRev")
PARS = ("lam", "a_A", "z0_A", "a_NE", "a_SW", "z0_P")


# ------------------------------------------------------------------------------------------ суррогат
class Surrogate:
    def __init__(self, case, sub, names):
        g = B.GRID[case]
        self.lam, self.al, self.z0 = np.array(g["lam"]), np.array(g["alpha"]), np.array(g["z0"])
        rows = [json.loads(line) for line in (OUT / f"runs_{case}.jsonl").read_text().splitlines() if line.strip()]
        rows = [r for r in rows if r["subcase"] == sub]
        Y = np.full((len(self.lam), len(self.al), len(self.z0), len(names)), np.nan)
        self.bad, self.iters = [], []
        for r in rows:
            p = r["params"]
            i = int(np.argmin(abs(np.log(self.lam) - math.log(p["lam"]))))
            j = int(np.argmin(abs(self.al - p["alpha"])))
            k = int(np.argmin(abs(np.log(self.z0) - math.log(p["z0"]))))
            self.iters.append(r["iters"])
            if r["status"] != "ok":
                self.bad.append(dict(lam=p["lam"], alpha=p["alpha"], z0=p["z0"], status=r["status"]))
                continue
            Y[i, j, k] = [np.nan if r["obs"].get(n) is None else r["obs"][n] for n in names]
        self.n_runs = len(rows)
        self.n_filled = 0
        pts = np.stack(np.meshgrid(np.log(self.lam), self.al, np.log(self.z0), indexing="ij"), -1).reshape(-1, 3)
        for q in range(len(names)):                       # пропуски (не ok / NaN) — ближайший узел
            y = Y[..., q].reshape(-1)
            ok = np.isfinite(y)
            if ok.all() or not ok.any():
                continue
            self.n_filled += int((~ok).sum())
            y[~ok] = NearestNDInterpolator(pts[ok] / [1, 0.1, 1], y[ok])(pts[~ok] / [1, 0.1, 1])
            Y[..., q] = y.reshape(Y.shape[:3])
        self.valid = np.isfinite(Y).all(axis=(0, 1, 2))
        Y = np.where(np.isfinite(Y), Y, 0.0)
        self.f = RegularGridInterpolator((np.log(self.lam), self.al, np.log(self.z0)), Y, method="cubic")
        self.box = ((self.lam[0], self.lam[-1]), (self.al[0], self.al[-1]), (self.z0[0], self.z0[-1]))

    def __call__(self, lam, al, z0):
        lam = min(max(lam, self.box[0][0]), self.box[0][1])
        al = min(max(al, self.box[1][0]), self.box[1][1])
        z0 = min(max(z0, self.box[2][0]), self.box[2][1])
        return self.f([[math.log(lam), al, math.log(z0)]])[0]


# ------------------------------------------------------------------------------------------ χ²
class Joint:
    def __init__(self):
        self.oA = AK.observations()
        self.oP = PD.observations()
        self.names = dict(tu03b=[o["name"] for o in self.oA],
                          ne=[o["name"] for o in self.oP if o["subcase"] == "ne"],
                          sw=[o["name"] for o in self.oP if o["subcase"] == "sw"])
        self.S = dict(tu03b=Surrogate("ask", "tu03b", self.names["tu03b"]),
                      ne=Surrogate("pd", "ne", self.names["ne"]), sw=Surrogate("pd", "sw", self.names["sw"]))
        # термы: (подслучай(и), индекс(ы), данные, σ_полн, поправка, grp, имя)
        self.terms = []
        for sub, obs in (("tu03b", self.oA), ("ne", [o for o in self.oP if o["subcase"] == "ne"]),
                         ("sw", [o for o in self.oP if o["subcase"] == "sw"])):
            for q, o in enumerate(obs):
                if "zone" in o["name"] or not self.S[sub].valid[q]:
                    continue
                self.terms.append(dict(subs=(sub,), idx=(q,), data=o["data"], sig=math.hypot(o["sig"], o["sig_grid"]),
                                       corr=o["grid_corr"], grp=o["grp"], name=o["name"], case="ask" if sub == "tu03b" else "pd"))
        for z in ZONES:
            on = next(o for o in self.oP if o["name"] == f"pd_ne_{z}")
            os_ = next(o for o in self.oP if o["name"] == f"pd_sw_{z}")
            qn, qs = self.names["ne"].index(on["name"]), self.names["sw"].index(os_["name"])
            sig = math.sqrt(0.5 * (on["sig"] ** 2 + os_["sig"] ** 2) + 0.5 * (on["sig_grid"] ** 2 + os_["sig_grid"] ** 2))
            self.terms.append(dict(subs=("ne", "sw"), idx=(qn, qs), data=on["data"], sig=sig,
                                   corr=0.5 * (on["grid_corr"] + os_["grid_corr"]), grp="pd_menke", name=f"pd_{z}", case="pd"))
        self.dropped = [n for sub in self.S for n, v in zip(self.names[sub], self.S[sub].valid) if not v]

    def h(self, sub, z0):
        if sub == "tu03b":
            return RU.h_mech(AK.U10_IN, z0, AK.F_COR)
        return RU.h_mech(PD.U10_IN[sub], z0, PD.F_COR)

    def model(self, lams, p):
        """lams — {sub: λ}; p — словарь параметров. Возвращает {sub: вектор модели}."""
        return dict(tu03b=self.S["tu03b"](lams["tu03b"], p["a_A"], p["z0_A"]),
                    ne=self.S["ne"](lams["ne"], p["a_NE"], p["z0_P"]), sw=self.S["sw"](lams["sw"], p["a_SW"], p["z0_P"]))

    def lams(self, mode, p):
        if mode == "lam":
            return {s: p["lam"] for s in self.S}
        z0 = dict(tu03b=p["z0_A"], ne=p["z0_P"], sw=p["z0_P"])
        if mode == "lf":
            return {s: p["lf"] * self.h(s, z0[s]) for s in self.S}
        return {s: max(p["lam"], p["lf"] * self.h(s, z0[s])) for s in self.S}

    def residuals(self, mode, p, use=None):
        L = self.lams(mode, p)
        M = self.model(L, p)
        out = []
        pen = sum(max(0.0, abs(math.log(l / np.clip(l, 10.0, 400.0)))) for l in L.values()) * 100.0
        for t in self.terms:
            if use and t["case"] not in use:
                continue
            m = np.mean([M[s][q] for s, q in zip(t["subs"], t["idx"])])
            out.append(((m + t["corr"] - t["data"]) / t["sig"], t))
        return out, pen

    def chi2(self, mode, p, use=None):
        r, pen = self.residuals(mode, p, use)
        return float(sum(x * x for x, _ in r)) + pen

    def groups(self, mode, p, use=None):
        r, _ = self.residuals(mode, p, use)
        g = {}
        for x, t in r:
            g.setdefault(t["grp"], [0.0, 0])
            g[t["grp"]][0] += x * x
            g[t["grp"]][1] += 1
        return {k: dict(chi2=v[0], n=v[1]) for k, v in g.items()}

    def fit(self, mode="lam", use=None, fix=None, common_alpha=False, start=None):
        box = self.S
        names = (["lam"] if mode == "lam" else ["lf"] if mode == "lf" else ["lam", "lf"]) + list(PARS[1:])
        st = dict(lam=40.0, lf=0.03, a_A=0.235, z0_A=0.05, a_NE=0.235, a_SW=0.235, z0_P=0.4)
        st.update(start or {})

        def f(*x):
            p = dict(zip(names, x))
            if common_alpha:
                p["a_SW"] = p["a_NE"]
            return self.chi2(mode, p, use)
        m = Minuit(f, *[st[n] for n in names], name=names)
        m.errordef = Minuit.LEAST_SQUARES
        lim = dict(lam=(10.0, 400.0), lf=(10.0 / 2000, 400.0 / 1300), a_A=box["tu03b"].box[1], z0_A=box["tu03b"].box[2],
                   a_NE=box["ne"].box[1], a_SW=box["sw"].box[1], z0_P=box["ne"].box[2])
        for n in names:
            m.limits[n] = lim[n]
        if use == ("ask",):
            for n in ("a_NE", "a_SW", "z0_P"):
                m.fixed[n] = True
        if use == ("pd",):
            for n in ("a_A", "z0_A"):
                m.fixed[n] = True
        if common_alpha:
            m.fixed["a_SW"] = True
        for k, v in (fix or {}).items():
            m.values[k] = v
            m.fixed[k] = True
        m.simplex().migrad()
        if not m.valid:
            m.migrad()
        return m, names, lim


def summarize(J, m, names, lim, mode, use=None, minos=True, common_alpha=False):
    p = dict(zip(names, m.values))
    if common_alpha:
        p["a_SW"] = p["a_NE"]
    free = [n for n in names if not m.fixed[n]]
    out = dict(mode=mode, values=p, chi2=m.fval, valid=bool(m.valid))
    r, _ = J.residuals(mode, p, use)
    out["n"] = len(r)
    out["ndf"] = len(r) - len(free)
    out["edge"] = [n for n in free if min(abs(p[n] - lim[n][0]), abs(p[n] - lim[n][1])) <= 1e-3 * (lim[n][1] - lim[n][0])]
    if minos:
        try:
            m.hesse()
            m.minos()
            out["minos"] = {n: [m.merrors[n].lower, m.merrors[n].upper] for n in free}
        except Exception as e:                  # noqa: BLE001
            out["minos_err"] = repr(e)
            out["hesse"] = {n: m.errors[n] for n in free}
    out["groups"] = J.groups(mode, p, use)
    out["by_case"] = {c: float(sum(x * x for x, t in r if t["case"] == c)) for c in ("ask", "pd")}
    out["n_by_case"] = {c: sum(1 for x, t in r if t["case"] == c) for c in ("ask", "pd")}
    out["lam_by_sub"] = J.lams(mode, p)
    out["h_by_sub"] = {s: J.h(s, p["z0_A"] if s == "tu03b" else p["z0_P"]) for s in J.S}
    return out


def profile(J, key, xs, mode="lam", use=None, base=None):
    res = []
    for x in xs:
        m, names, lim = J.fit(mode, use, fix={key: x}, start=base)
        res.append(dict(x=float(x), chi2=m.fval, **{n: float(v) for n, v in zip(names, m.values)}))
    return res


def main():
    J = Joint()
    R = dict(n_runs={s: J.S[s].n_runs for s in J.S}, bad_runs={s: J.S[s].bad for s in J.S},
             filled={s: J.S[s].n_filled for s in J.S}, dropped=J.dropped,
             iters={s: dict(min=int(min(J.S[s].iters)), median=float(np.median(J.S[s].iters)), max=int(max(J.S[s].iters)))
                    for s in J.S})
    m, names, lim = J.fit("lam")
    best = summarize(J, m, names, lim, "lam")
    R["joint_lam"] = best
    m2, n2, l2 = J.fit("lf", start=dict(lf=best["values"]["lam"] / 1500))
    R["joint_lf"] = summarize(J, m2, n2, l2, "lf")
    m3, n3, l3 = J.fit("lam", common_alpha=True, start=best["values"])
    R["joint_common_alpha"] = summarize(J, m3, n3, l3, "lam", common_alpha=True, minos=False)
    mA, nA, lA = J.fit("lam", use=("ask",), start=best["values"])
    R["ask_only"] = summarize(J, mA, nA, lA, "lam", use=("ask",))
    mP, nP, lP = J.fit("lam", use=("pd",), start=best["values"])
    R["pd_only"] = summarize(J, mP, nP, lP, "lam", use=("pd",))
    R["tension_dchi2"] = best["chi2"] - R["ask_only"]["chi2"] - R["pd_only"]["chi2"]
    # профили χ²(λ): совместно и по частям
    xs = np.exp(np.linspace(math.log(10.0), math.log(400.0), 25))
    R["profile_lam"] = dict(joint=profile(J, "lam", xs, base=best["values"]),
                            ask=profile(J, "lam", xs, use=("ask",), base=best["values"]),
                            pd=profile(J, "lam", xs, use=("pd",), base=best["values"]))
    for key, xs2 in (("a_A", np.linspace(*J.S["tu03b"].box[1], 13)), ("z0_A", np.exp(np.linspace(*np.log(J.S["tu03b"].box[2]), 13))),
                     ("a_NE", np.linspace(*J.S["ne"].box[1], 13)), ("a_SW", np.linspace(*J.S["sw"].box[1], 13)),
                     ("z0_P", np.exp(np.linspace(*np.log(J.S["ne"].box[2]), 13)))):
        R[f"profile_{key}"] = profile(J, key, xs2, base=best["values"])
    # карта χ²(λ/h, lam) — общий перевод λ_i = max(lam, λ/h·h_i)
    lfs = np.exp(np.linspace(math.log(0.006), math.log(0.25), 14))
    lams = np.exp(np.linspace(math.log(10.0), math.log(400.0), 14))
    mp = np.full((len(lfs), len(lams)), np.nan)
    for i, lf in enumerate(lfs):
        for j, la in enumerate(lams):
            mm, _, _ = J.fit("max", fix=dict(lf=lf, lam=la), start=best["values"])
            mp[i, j] = mm.fval
    R["map_lf_lam"] = dict(lf=lfs.tolist(), lam=lams.tolist(), chi2=mp.tolist())
    # остатки в лучшей точке
    r, _ = J.residuals("lam", best["values"])
    R["residuals"] = [dict(name=t["name"], grp=t["grp"], pull=float(x), data=t["data"], sig=t["sig"]) for x, t in r]
    (OUT / "fit.json").write_text(json.dumps(R, indent=1, ensure_ascii=False, default=float))
    table(R)
    figs(J, R)


def fmt_par(s, n, p=3):
    v = s["values"][n]
    if "minos" in s and n in s["minos"]:
        lo, hi = s["minos"][n]
        return f"{v:.{p}g} ({hi:+.{p - 1}g} {lo:+.{p - 1}g})"
    return f"{v:.{p}g}"


def table(R):
    L = ["# Б1: совместная подгонка Askervein + Perdigão\n",
         f"Прогонов: {R['n_runs']}; не ok: { {k: len(v) for k, v in R['bad_runs'].items()} }; заполнено ближайшим узлом: {R['filled']}; "
         f"итераций {R['iters']}; наблюдаемые без модели (NaN во всех прогонах): {R['dropped']}\n",
         "| вариант | λ, м | λ/h | α_A | z0_A, м | α_NE | α_SW | z0_P, м | χ² / ndf | Askervein (n) | Perdigão (n) | у края |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for key, lab in (("joint_lam", "совместно, одно λ"), ("joint_lf", "совместно, λ = λ/h·h_i"),
                     ("joint_common_alpha", "совместно, общий α_P"), ("ask_only", "только Askervein"), ("pd_only", "только Perdigão")):
        s = R[key]
        v = s["values"]
        lam = fmt_par(s, "lam") if "lam" in v else "—"
        lf = fmt_par(s, "lf") if "lf" in v else f"{v.get('lam', float('nan')) / s['h_by_sub']['tu03b']:.3f}"
        ask = key != "pd_only"
        pd = key != "ask_only"
        L.append(f"| {lab} | {lam} | {lf} | {fmt_par(s, 'a_A') if ask else '—'} | {fmt_par(s, 'z0_A') if ask else '—'} | "
                 f"{fmt_par(s, 'a_NE') if pd else '—'} | {fmt_par(s, 'a_SW') if pd else '—'} | {fmt_par(s, 'z0_P') if pd else '—'} | "
                 f"{s['chi2']:.1f} / {s['ndf']} | {s['by_case']['ask']:.1f} ({s['n_by_case']['ask']}) | {s['by_case']['pd']:.1f} ({s['n_by_case']['pd']}) | "
                 f"{', '.join(s['edge']) or '—'} |")
    L.append(f"\nНапряжение: χ²_совм − χ²_A,мин − χ²_P,мин = {R['tension_dchi2']:.1f} (1 общий параметр).\n")
    L.append("## χ² по группам (совместно, одно λ)\n\n| группа | n | χ² |\n|---|---|---|")
    for g, v in sorted(R["joint_lam"]["groups"].items()):
        L.append(f"| {g} | {v['n']} | {v['chi2']:.1f} |")
    L.append("\n## Наибольшие остатки (совместно)\n\n| наблюдаемая | grp | pull |\n|---|---|---|")
    for x in sorted(R["residuals"], key=lambda q: -abs(q["pull"]))[:15]:
        L.append(f"| {x['name']} | {x['grp']} | {x['pull']:+.2f} |")
    (OUT / "fit_table.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))


def figs(J, R):
    # профиль χ²(λ)
    fig, ax = plt.subplots(figsize=(7.5, 4.8))
    for i, (k, lab) in enumerate((("joint", "совместно"), ("ask", "только Askervein"), ("pd", "только Perdigão"))):
        pr = R["profile_lam"][k]
        c = np.array([q["chi2"] for q in pr])
        ax.plot([q["x"] for q in pr], c - c.min(), "-o", ms=4, lw=2, color=C[i], label=f"{lab} (мин χ² {c.min():.1f})")
    ax.axhline(1.0, color="#888", lw=1, ls=":")
    ax.set_xscale("log")
    ax.set_ylim(0, 40)
    ax.set_xlabel("λ, м (асимптотическая длина перемешивания)")
    ax.set_ylabel("Δχ² (минимум по α, z0)")
    ax.set_title("Профиль χ²(λ): Askervein против Perdigão")
    ax.grid(alpha=0.3, which="both")
    ax.legend(fontsize=9)
    fig.tight_layout()
    fig.savefig(OUT / "fig_fit_profile_lam.png", dpi=110)
    plt.close(fig)
    # карта λ/h–lam
    mp = R["map_lf_lam"]
    Z = np.array(mp["chi2"])
    fig, ax = plt.subplots(figsize=(7, 5.5))
    q = ax.pcolormesh(mp["lam"], mp["lf"], Z - np.nanmin(Z), shading="auto", cmap="Blues_r", vmin=0, vmax=30)
    ax.contour(mp["lam"], mp["lf"], Z - np.nanmin(Z), levels=[1, 4, 9], colors="k", linewidths=1)
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("lam, м"); ax.set_ylabel("λ/h")
    ax.set_title("Δχ²(λ/h, lam), λ_i = max(lam, λ/h·h_i); контуры 1, 4, 9")
    fig.colorbar(q, ax=ax, label="Δχ²")
    fig.tight_layout()
    fig.savefig(OUT / "fig_fit_map_lf_lam.png", dpi=110)
    plt.close(fig)
    # остатки
    res = R["residuals"]
    fig, ax = plt.subplots(figsize=(15, 4.8))
    cols = [C[0] if x["name"].startswith("ask") else C[1] if "_ne_" in x["name"] else C[2] if "_sw_" in x["name"] else C[3] for x in res]
    ax.bar(range(len(res)), [x["pull"] for x in res], color=cols, width=0.7)
    ax.set_xticks(range(len(res)))
    ax.set_xticklabels([x["name"].replace("ask_", "").replace("pd_", "") for x in res], rotation=80, fontsize=6)
    for y in (-2, 2):
        ax.axhline(y, color="#888", lw=1, ls=":")
    ax.set_ylabel("(модель − данные)/σ")
    ax.set_title("Остатки в совместном минимуме (синий — Askervein, оранжевый — Perdigão NE, зелёный — SW, жёлтый — зона Menke)")
    ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(OUT / "fig_fit_residuals.png", dpi=110)
    plt.close(fig)
    # профили α, z0
    fig, axs = plt.subplots(1, 5, figsize=(17, 3.6))
    for ax, key in zip(axs, ("a_A", "z0_A", "a_NE", "a_SW", "z0_P")):
        pr = R[f"profile_{key}"]
        c = np.array([q["chi2"] for q in pr])
        ax.plot([q["x"] for q in pr], c - c.min(), "-o", ms=4, lw=2, color=C[0])
        ax.axhline(1.0, color="#888", lw=1, ls=":")
        if key.startswith("z0"):
            ax.set_xscale("log")
        ax.set_ylim(0, 20)
        ax.set_title(f"Δχ²({key})")
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT / "fig_fit_profiles.png", dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    main()
