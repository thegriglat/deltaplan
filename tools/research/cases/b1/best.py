"""Б1, этап 2: проверка у лучшей точки совместной подгонки (out/fit.json → joint_lam).

Прогоны (строка C10 на прогон, out/best_runs.jsonl, продолжение с места):
  best   — общая схема, dx номинала (сверка суррогата: χ² прямого прогона против интерполяции);
  nolk   — local_k выкл. (scheme_ctl);
  adv1   — 1-й порядок переноса, схема игры (scheme_ctl): систематика схемы игры отдельно от параметров;
  fine   — dx·2/3 (scheme_ctl): годится ли сеточная поправка, посчитанная у номинала, у лучшей точки.
Итог: out/best_table.md, out/best.json, out/fig_best_sections.png.

  python best.py run | table
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import askervein as AK     # noqa: E402
import perdigao as PD      # noqa: E402

OUT = HERE / "out"
MOD = dict(ask=AK, pd=PD)
FINE = dict(ask=40.0 / 3.0, pd=20.0)


def best_params():
    v = json.loads((OUT / "fit.json").read_text())["joint_lam"]["values"]
    base = dict(lam_frac=0.0, lam=v["lam"])
    return dict(tu03b=dict(base, alpha=v["a_A"], z0=v["z0_A"]), ne=dict(base, alpha=v["a_NE"], z0=v["z0_P"]),
                sw=dict(base, alpha=v["a_SW"], z0=v["z0_P"]))


def plan():
    P = best_params()
    out = []
    for case, sub in (("ask", "tu03b"), ("pd", "ne"), ("pd", "sw")):
        dx = MOD[case].DX_NOM
        out += [(f"{case}_{sub}_best", case, sub, P[sub], dx, None),
                (f"{case}_{sub}_nolk", case, sub, P[sub], dx, {"local_k": False}),
                (f"{case}_{sub}_adv1", case, sub, P[sub], dx, {"adv2": False}),
                (f"{case}_{sub}_fine", case, sub, P[sub], FINE[case], {"adv2": True})]
    return out


def run():
    f = OUT / "best_runs.jsonl"
    done = {json.loads(l)["tag"] for l in f.read_text().splitlines()} if f.exists() else set()
    t0 = time.perf_counter()
    for tag, case, sub, over, dx, ctl in plan():
        if tag in done:
            continue
        keep = tag.endswith(("_best", "_adv1"))
        r = MOD[case].run_one(over, sub, dx, ctl=ctl, keep=keep)
        r["tag"] = tag
        if keep and "_S" in r:
            import ctl as CT
            CT.save_fields(tag, case, sub, r)
        with open(f, "a") as fh:
            fh.write(json.dumps(r) + "\n")
        print(f"{tag}: {r['status']} {r['iters']} it {r['t']:.1f} с ({time.perf_counter() - t0:.0f} с)", flush=True)


def table():
    import fit as F
    J = F.Joint()
    R = {json.loads(l)["tag"]: json.loads(l) for l in (OUT / "best_runs.jsonl").read_text().splitlines()}
    fitv = json.loads((OUT / "fit.json").read_text())["joint_lam"]
    grid = json.loads((OUT / "grid.json").read_text())

    def vec(var):
        rows = {s: R.get(f"{'ask' if s == 'tu03b' else 'pd'}_{s}_{var}") for s in ("tu03b", "ne", "sw")}
        if any(r is None or r["status"] != "ok" for r in rows.values()):
            return None
        return {s: np.array([np.nan if rows[s]["obs"].get(n) is None else rows[s]["obs"][n] for n in J.names[s]]) for s in rows}

    def chi(M, corr=True):
        g, tot = {}, {"ask": 0.0, "pd": 0.0}
        for t in J.terms:
            m = np.nanmean([M[s][q] for s, q in zip(t["subs"], t["idx"])])
            x = ((m + (t["corr"] if corr else 0.0) - t["data"]) / t["sig"]) ** 2
            g[t["grp"]] = g.get(t["grp"], 0.0) + x
            tot[t["case"]] += x
        return tot, g

    out = {}
    L = ["# Б1: проверка у лучшей точки совместной подгонки\n",
         f"Точка: λ = {fitv['values']['lam']:.1f} м, α_A {fitv['values']['a_A']:.3f}, z0_A {fitv['values']['z0_A']:.3f} м, "
         f"α_NE {fitv['values']['a_NE']:.3f}, α_SW {fitv['values']['a_SW']:.3f}, z0_P {fitv['values']['z0_P']:.3f} м; "
         f"суррогат: χ² {fitv['chi2']:.1f} (Askervein {fitv['by_case']['ask']:.1f}, Perdigão {fitv['by_case']['pd']:.1f}).\n",
         "| прогон | статус | итераций | t, с | χ² Askervein (47) | χ² Perdigão (35) | всего |", "|---|---|---|---|---|---|---|"]
    Ms = {}
    for var in ("best", "nolk", "adv1", "fine"):
        M = vec(var)
        rows = [R.get(f"{c}_{s}_{var}") for c, s in (("ask", "tu03b"), ("pd", "ne"), ("pd", "sw"))]
        st = "/".join(r["status"] if r else "—" for r in rows)
        it = "/".join(str(r["iters"]) if r else "—" for r in rows)
        tt = "/".join(f"{r['t']:.0f}" if r else "—" for r in rows)
        if M is None:
            L.append(f"| {var} | {st} | {it} | {tt} | — | — | — |")
            continue
        Ms[var] = M
        tot, g = chi(M, corr=(var != "fine"))
        out[var] = dict(chi2=tot, groups=g, status=st, iters=it)
        L.append(f"| {var}{' (без поправки сетки)' if var == 'fine' else ''} | {st} | {it} | {tt} | {tot['ask']:.1f} | {tot['pd']:.1f} | "
                 f"{tot['ask'] + tot['pd']:.1f} |")
    # сеточная поправка у лучшей точки против номинала; систематика схемы игры
    if "best" in Ms and "fine" in Ms:
        L += ["", "## Сеточная поправка: у лучшей точки против номинала (Δ = y(dx·2/3) − y(dx))\n",
              "| подслучай | n | ⟨Δ_лучш⟩ | ⟨Δ_ном⟩ | rms(Δ_лучш − Δ_ном) | max |Δ_лучш − Δ_ном| | rms(Δ_лучш − Δ_ном)/σ |", "|---|---|---|---|---|---|---|"]
        out["grid_check"] = {}
        for s in ("tu03b", "ne", "sw"):
            d_best = Ms["fine"][s] - Ms["best"][s]
            d_nom = np.array([grid.get(n, {}).get("d_grid", 0.0) for n in J.names[s]])
            sig = np.array([o["sig"] for o in (J.oA if s == "tu03b" else [o for o in J.oP if o["subcase"] == s])])
            dd = d_best - d_nom
            ok = np.isfinite(dd)
            out["grid_check"][s] = dict(mean_best=float(np.nanmean(d_best)), mean_nom=float(np.mean(d_nom)),
                                        rms=float(np.sqrt(np.nanmean(dd ** 2))), max=float(np.nanmax(np.abs(dd))),
                                        rms_sig=float(np.sqrt(np.nanmean((dd / sig) ** 2))))
            q = out["grid_check"][s]
            L.append(f"| {s} | {ok.sum()} | {q['mean_best']:+.3f} | {q['mean_nom']:+.3f} | {q['rms']:.3f} | {q['max']:.3f} | {q['rms_sig']:.2f} |")
    if "best" in Ms and "adv1" in Ms:
        L += ["", "## Систематика схемы игры у лучшей точки: 1-й порядок − 2-й (dx номинала)\n",
              "| группа | n | ⟨Δ⟩ | ⟨Δ/σ⟩ | max |Δ| |", "|---|---|---|---|---|"]
        out["adv1"] = {}
        grp = {}
        for s in ("tu03b", "ne", "sw"):
            obs = J.oA if s == "tu03b" else [o for o in J.oP if o["subcase"] == s]
            for q, o in enumerate(obs):
                d = Ms["adv1"][s][q] - Ms["best"][s][q]
                if np.isfinite(d):
                    grp.setdefault(o["grp"], []).append((d, d / o["sig"]))
        for g, v in sorted(grp.items()):
            a = np.array(v)
            out["adv1"][g] = dict(n=len(v), mean=float(a[:, 0].mean()), mean_sig=float(a[:, 1].mean()), max=float(np.abs(a[:, 0]).max()))
            L.append(f"| {g} | {len(v)} | {a[:, 0].mean():+.3f} | {a[:, 1].mean():+.2f} | {np.abs(a[:, 0]).max():.3f} |")
        # зона Menke у лучшей точки
        L += ["", "## Зона рециркуляции и подветренная сторона Askervein у лучшей точки\n",
              "| величина | данные | 2-й пор. | 1-й пор. | local_k выкл |", "|---|---|---|---|---|"]
        for z in ("zoneL", "zoneDepth", "zoneRev"):
            for s in ("ne", "sw"):
                n = f"pd_{s}_{z}"
                q = J.names[s].index(n)
                d = next(o["data"] for o in J.oP if o["name"] == n)
                vals = [Ms[v][s][q] if v in Ms else float("nan") for v in ("best", "adv1", "nolk")]
                L.append(f"| {n} | {d:.3f} | " + " | ".join(f"{x:.3f}" for x in vals) + " |")
        for n in ("ask_ANE10", "ask_ANE20", "ask_AANE10", "ask_AANE20", "ask_AANE30", "ask_HT"):
            q = J.names["tu03b"].index(n)
            d = next(o["data"] for o in J.oA if o["name"] == n)
            vals = [Ms[v]["tu03b"][q] if v in Ms else float("nan") for v in ("best", "adv1", "nolk")]
            L.append(f"| {n} | {d:.3f} | " + " | ".join(f"{x:.3f}" for x in vals) + " |")
    (OUT / "best.json").write_text(json.dumps(out, indent=1, ensure_ascii=False, default=float))
    (OUT / "best_table.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))
    import analyze1 as A1
    import matplotlib.pyplot as plt
    fs = [(s, v) for s in ("ne", "sw") for v in ("best", "adv1") if (OUT / f"fields_pd_{s}_{v}.npz").exists()]
    if fs:
        fig, axs = plt.subplots(2, 2, figsize=(14, 7.5), squeeze=False)
        for ax, (s, v) in zip(axs.ravel(), fs):
            z = np.load(OUT / f"fields_pd_{s}_{v}.npz")
            U = z["upar"] / float(z["sref"])
            q = ax.pcolormesh(z["s"], z["z"], U, cmap="RdBu_r", vmin=-1.2, vmax=1.2, shading="auto")
            ax.contour(z["s"], z["z"], np.nan_to_num(U, nan=1.0), levels=[-0.5 / float(z["sref"])], colors=["k"], linewidths=[1.2])
            ax.fill_between(z["s"], z["hs"], z["z"][0], color="#bbb")
            ax.set_ylim(z["z"][0], z["hs"].max() + 450)
            ax.set_title(f"Perdigão {s.upper()}, лучшая точка, {'2-й' if v == 'best' else '1-й (игра)'} порядок: u_∥/S_ref; "
                         "чёрная — u_∥ = −0,5 м/с")
            ax.set_xlabel("вдоль ветра от центра долины, м")
            ax.set_ylabel("высота н. у. м., м")
            fig.colorbar(q, ax=ax)
        fig.tight_layout()
        fig.savefig(OUT / "fig_best_sections.png", dpi=100)
        plt.close(fig)


if __name__ == "__main__":
    run() if sys.argv[1] == "run" else table()
