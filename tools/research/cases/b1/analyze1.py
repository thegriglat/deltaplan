"""Б1, этап 1: итог контрольных прогонов (b1/out/ctl_runs.jsonl) одним скриптом.

  * сеточная поправка и σ сетки — ОДНИМ способом для обоих случаев (→ out/grid.json, его читают askervein.py/perdigao.py):
      Δ_сетки = y(dx/2) − y(dx)  (2-й порядок; если dx/2 не сошёлся — dx·2/3),   Δ_обл = y(обл. ×1,5) − y(номинал);
      grid_corr = Δ_сетки,   sig_grid = |Δ_сетки| ⊕ |Δ_обл|/2   (как AM-09: остаток мелкой сетки ~ последний шаг;
      область — половина как σ, без сдвига; у Askervein Δ_обл — к потоку притока, см. код);
      Δ_уст = y(stab) − y(номинал) (Perdigão) — в σ данных (perdigao.observations);
  * систематика схемы игры: 1-й порядок против 2-го на dx — по наблюдаемым и группам (в χ² не идёт);
  * отклик на λ (15 / 46 / 150 м), устойчивость (Perdigão), SW: направление и компонента вдоль ветра на мачтах;
  * χ² на номинале по группам (формула C10) для всех вариантов.

  python analyze1.py   → out/grid.json, out/ctl_table.md, out/ctl_summary.json, out/fig_ctl_*.png
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import askervein as AK     # noqa: E402
import perdigao as PD      # noqa: E402

OUT = HERE / "out"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
SUBS = [("ask", "tu03b", AK), ("pd", "ne", PD), ("pd", "sw", PD)]
VARS = ["nom", "adv1", "fine", "half", "dom", "side", "top", "stab", "lamlo", "lamhi"]


def load():
    R = {}
    for line in (OUT / "ctl_runs.jsonl").read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            R[r["tag"]] = r
    return R


def get(R, case, sub, var):
    """Строка прогона; для Perdigão obs мачт — в виде PD.MAST_OBS (u_∥ или S — из поля mast строки)."""
    r = R.get(f"{case}_{sub}_{var}")
    if not (r and r["status"] == "ok"):
        return None
    if case == "pd" and "mast" in r:
        r = dict(r, obs=dict(r["obs"]))
        for k, m in r["mast"].items():
            r["obs"][k] = m["upar"] if PD.MAST_OBS == "upar" else m.get("S", r["obs"].get(k))
    return r


def chi2(obs, vals, corr=None, sgrid=True):
    out = {}
    for o in obs:
        v = vals.get(o["name"])
        if v is None or not math.isfinite(v):
            continue
        c = (corr or {}).get(o["name"], 0.0)
        s2 = o["sig"] ** 2 + ((o.get("_sg", 0.0)) ** 2 if sgrid else 0.0)
        out.setdefault(o["grp"], [0.0, 0])
        out[o["grp"]][0] += (v + c - o["data"]) ** 2 / s2
        out[o["grp"]][1] += 1
    return out


def main():
    R = load()
    grid, summ, lines = {}, {}, []
    all_obs = {"ask": AK.observations(), "pd": PD.observations()}
    # ---------------------------------------------------------------- сеточная поправка (одним способом)
    for case, sub, M in SUBS:
        nom, half, fine, dom, stab = (get(R, case, sub, v) for v in ("nom", "half", "fine", "dom", "stab"))
        fine_used = half or fine
        summ[f"{case}_{sub}"] = dict(fine_level=("half" if half else "fine" if fine else None))
        for o in all_obs[case]:
            if o["subcase"] != sub or nom is None:
                continue
            n = o["name"]
            y = nom["obs"].get(n)
            if y is None:
                continue
            dg = (fine_used["obs"].get(n) - y) if fine_used and fine_used["obs"].get(n) is not None else float("nan")
            if case == "ask":
                # опорная RS в номинале — в губке притока (= профиль притока по данным); в большой области она выходит
                # из губки, и её профиль сползает к равновесию модели (+5 % на 10 м) — это смена опоры, а не потока над
                # холмом. Δ_обл считается к неизменному потоку притока (фон U10·(z/10)^α на 10 м): разгоны на 10 м —
                # из «dom» с пересчётом к фону; профили HT и RS (нет абсолютной опоры в строке) — из «top».
                top = get(R, case, sub, "top")
                if dom and not ("prof" in n or "_RS_" in n):
                    u0 = M.U10_IN
                    dd = ((1 + dom["obs"][n]) * dom["inputs"]["rs10_model"] - (1 + y) * nom["inputs"]["rs10_model"]) / u0
                else:
                    dd = (top["obs"].get(n) - y) if top and top["obs"].get(n) is not None else 0.0
            else:
                dd = (dom["obs"].get(n) - y) if dom and dom["obs"].get(n) is not None else 0.0
            if not math.isfinite(dg):
                dg = 0.0
            ds = (stab["obs"].get(n) - y) if stab and stab["obs"].get(n) is not None else 0.0
            # поправка — только сетка; область — половиной в σ (как AM-09), без сдвига: опора случая — по данным
            grid[n] = dict(grid_corr=dg, sig_grid=math.hypot(dg, 0.5 * dd), d_grid=dg, d_dom=dd, d_stab=ds)
    (OUT / "grid.json").write_text(json.dumps(grid, indent=1, sort_keys=True))

    # ---------------------------------------------------------------- таблица и χ²
    lines.append("# Б1, этап 1: контрольные прогоны у номинала\n")
    lines.append("Номинал: λ/h 0,031 (λ ≈ 46 м), lam 40, α 0,235, z0 случая (Askervein 0,03, Perdigão 0,645), общая схема scheme.py; "
                 "U10 — по правилу «модель на опорной точке = данные». Столбцы: nom — dx номинала 2-й порядок; adv1 — 1-й порядок "
                 "(схема игры); fine — dx·2/3; half — dx/2; dom — область и запас над рельефом ×1,5; stab — поток тепла по z/L данных; "
                 "lamlo/lamhi — λ 15/150 м.\n")
    lines.append("## Прогоны\n")
    lines.append("| прогон | dx | клеток | статус | итераций | t решателя, с | всего, с | S_ref / RS10 модель |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for tag, r in R.items():
        ref = r.get("inputs", {}).get("sref_model", r.get("inputs", {}).get("rs10_model"))
        lines.append(f"| {tag} | {r['dx']:.4g} | {r.get('geo', {}).get('n_cells', '—')} | {r['status']} | {r['iters']} | {r['t']:.1f} | "
                     f"{r.get('wall_total', 0):.0f} | {ref if ref is None else round(ref, 3)} |")
    lines.append("")
    for case, sub, M in SUBS:
        obs = [dict(o) for o in all_obs[case] if o["subcase"] == sub]
        for o in obs:
            o["_sg"] = grid.get(o["name"], {}).get("sig_grid", 0.0)
        runs = {v: get(R, case, sub, v) for v in VARS}
        lines.append(f"## {case} {sub}\n")
        hdr = [v for v in VARS if runs[v]]
        lines.append("| наблюдаемая | grp | данные | σ | " + " | ".join(hdr) + " | Δ_сетки | Δ_обл | adv1−nom | (nom+corr−d)/σ_tot |")
        lines.append("|---|---|---|---|" + "---|" * len(hdr) + "---|---|---|---|")
        dev_adv = {}
        for o in obs:
            n = o["name"]
            vals = [runs[v]["obs"].get(n) for v in hdr]
            g = grid.get(n, {})
            nv = runs["nom"]["obs"].get(n) if runs["nom"] else None
            av = runs["adv1"]["obs"].get(n) if runs["adv1"] else None
            da = (av - nv) if (av is not None and nv is not None) else None
            if da is not None:
                dev_adv.setdefault(o["grp"], []).append(da / o["sig"])
            pull = ((nv + g.get("grid_corr", 0) - o["data"]) / math.hypot(o["sig"], g.get("sig_grid", 0))) if nv is not None else None
            lines.append(f"| {n.split('_', 1)[1]} | {o['grp']} | {o['data']:.3f} | {o['sig']:.3f} | "
                         + " | ".join("—" if v is None else f"{v:.3f}" for v in vals)
                         + f" | {g.get('d_grid', 0):+.3f} | {g.get('d_dom', 0):+.3f} | {'—' if da is None else f'{da:+.3f}'} | "
                         + ("—" if pull is None else f"{pull:+.1f}") + " |")
        lines.append("")
        # χ² по группам для вариантов: без сеточной поправки (как есть) и с поправкой/σ сетки номинала
        cs = {}
        for v in hdr:
            vals = runs[v]["obs"]
            cs[v] = dict(raw=chi2(obs, vals, sgrid=False),
                         corr=chi2(obs, vals, {k: grid.get(k, {}).get("grid_corr", 0.0) for k in vals}, sgrid=True))
        grps = sorted({o["grp"] for o in obs})
        lines.append("χ² по группам (без поправки сетки, σ = σ данных | с поправкой и σ сетки номинала):\n")
        lines.append("| группа | n | " + " | ".join(hdr) + " |")
        lines.append("|---|---|" + "---|" * len(hdr))
        for gname in grps + ["всего"]:
            row = []
            nn = 0
            for v in hdr:
                if gname == "всего":
                    a = sum(x[0] for x in cs[v]["raw"].values()); b = sum(x[0] for x in cs[v]["corr"].values())
                    nn = sum(x[1] for x in cs[v]["raw"].values())
                else:
                    a = cs[v]["raw"].get(gname, [float("nan"), 0])[0]; b = cs[v]["corr"].get(gname, [float("nan"), 0])[0]
                    nn = cs[v]["raw"].get(gname, [0, 0])[1]
                row.append(f"{a:.1f} \\| {b:.1f}")
            lines.append(f"| {gname} | {nn} | " + " | ".join(row) + " |")
        lines.append("")
        summ[f"{case}_{sub}"].update(
            chi2={v: dict(raw=sum(x[0] for x in cs[v]["raw"].values()), corr=sum(x[0] for x in cs[v]["corr"].values()),
                          n=sum(x[1] for x in cs[v]["raw"].values())) for v in hdr},
            adv1_minus_nom_over_sig={gname: dict(mean=float(np.mean(x)), rms=float(np.sqrt(np.mean(np.square(x)))), n=len(x))
                                     for gname, x in dev_adv.items()},
            runs={v: dict(iters=runs[v]["iters"], t=runs[v]["t"], dx=runs[v]["dx"], cells=runs[v].get("geo", {}).get("n_cells"),
                          lam_eff=runs[v].get("lam_eff"), h_bl=runs[v].get("h_bl")) for v in hdr})
    # ---------------------------------------------------------------- SW/NE: направление и u_∥ на мачтах
    lines.append("## Мачты Perdigão: направление и компонента вдоль ветра притока (данные — 5-мин u, v; модель — nom)\n")
    lines.append("| подслучай | мачта, z | dir данных | dir модели | S/S_ref данных | модели | u_∥/S_ref данных | модели |")
    lines.append("|---|---|---|---|---|---|---|---|")
    mastsum = {}
    for sub in PD.SUBCASES:
        nom = get(R, "pd", sub, "nom")
        c = PD.CASES[sub]
        inp = PD.case_inputs(sub)
        ang = math.radians(inp["wdir"])
        ex, ey = -math.sin(ang), -math.cos(ang)
        t0, t1 = c["window"]
        acc = {}
        for r in csv.DictReader(open(PD.DATA / f"cases/{c['file']}_5min.csv")):
            if not (t0 <= r["time_utc"][11:16] < t1) or r["u_east"] == "":
                continue
            acc.setdefault((r["site"], int(float(r["z_agl_m"]))), []).append((float(r["u_east"]), float(r["v_north"])))
        uref = float(np.mean([math.hypot(*q) for q in acc[(inp["ref"], 100)]]))
        for o in PD.observations():
            if o["subcase"] != sub or "zone" in o["name"]:
                continue
            site, z = o["name"].split("_")[2], int(o["name"].split("_")[3])
            q = np.array(acc.get((site, z), [(np.nan, np.nan)]))
            um, vm = q[:, 0].mean(), q[:, 1].mean()
            ddir = math.degrees(math.atan2(-um, -vm)) % 360
            upar = (um * ex + vm * ey) / uref
            m = (nom or {}).get("mast", {}).get(o["name"], {}) if nom else {}
            mastsum[o["name"]] = dict(dir_data=ddir, dir_model=m.get("dir"), upar_data=upar, upar_model=m.get("upar"),
                                      S_data=o["data"], S_model=(nom["obs"].get(o["name"]) if nom else None))
            f = lambda x, p=2: "—" if x is None else f"{x:.{p}f}"
            lines.append(f"| {sub} | {site} {z} | {ddir:.0f} | {f(m.get('dir'), 0)} | {o['data']:.2f} | {f(mastsum[o['name']]['S_model'])} | "
                         f"{upar:.2f} | {f(m.get('upar'))} |")
    lines.append("")
    summ["masts"] = mastsum
    (OUT / "ctl_table.md").write_text("\n".join(lines) + "\n")
    (OUT / "ctl_summary.json").write_text(json.dumps(summ, indent=1, ensure_ascii=False))
    figs(R, all_obs, grid)
    print("\n".join(lines))


def figs(R, all_obs, grid):
    # модель против данных: nom, adv1, half, dom — по наблюдаемым, три панели
    fig, axs = plt.subplots(3, 1, figsize=(15, 12))
    for ax, (case, sub, M) in zip(axs, SUBS):
        obs = [o for o in all_obs[case] if o["subcase"] == sub]
        x = np.arange(len(obs))
        ax.errorbar(x, [o["data"] for o in obs], yerr=[o["sig"] for o in obs], fmt="o", color="#222", ms=5, lw=1.2,
                    label="данные ± σ", zorder=5)
        for i, (v, lab) in enumerate((("nom", "2-й пор., dx"), ("half", "2-й пор., dx/2"), ("adv1", "1-й пор. (игра), dx"),
                                      ("dom", "область ×1,5"))):
            r = get(R, case, sub, v)
            if r:
                ax.plot(x + (i - 1.5) * 0.12, [r["obs"].get(o["name"], np.nan) if r["obs"].get(o["name"]) is not None else np.nan
                                               for o in obs], "s", ms=5, color=C[i], label=lab)
        ax.set_xticks(x)
        ax.set_xticklabels([o["name"].split("_", 1)[1].replace(sub + "_", "") for o in obs], rotation=70, fontsize=7)
        ax.set_title(f"{case} {sub}: модель у номинала против данных")
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8, ncol=5, loc="upper right")
    fig.tight_layout()
    fig.savefig(OUT / "fig_ctl_obs.png", dpi=100)
    plt.close(fig)
    # разрезы Perdigão: nom против adv1
    fs = [(sub, v) for sub in ("ne", "sw") for v in ("nom", "adv1") if (OUT / f"fields_pd_{sub}_{v}.npz").exists()]
    if fs:
        fig, axs = plt.subplots(2, 2, figsize=(14, 7.5), squeeze=False)
        for ax, (sub, v) in zip(axs.ravel(), fs):
            z = np.load(OUT / f"fields_pd_{sub}_{v}.npz")
            U = z["upar"] / float(z["sref"])
            q = ax.pcolormesh(z["s"], z["z"], U, cmap="RdBu_r", vmin=-1.2, vmax=1.2, shading="auto")
            ax.contour(z["s"], z["z"], np.nan_to_num(U, nan=1.0), levels=[-0.5 / float(z["sref"]), 0.0], colors=["k", "#888"],
                       linewidths=[1.2, 0.8])
            ax.fill_between(z["s"], z["hs"], z["z"][0], color="#bbb")
            ax.set_ylim(z["z"][0], z["hs"].max() + 450)
            ax.set_title(f"Perdigão {sub.upper()}, {'2-й порядок' if v == 'nom' else '1-й порядок (игра)'}: u_∥/S_ref, "
                         "чёрная — u_∥ = −0,5 м/с")
            ax.set_xlabel("вдоль ветра от центра долины, м")
            ax.set_ylabel("высота н. у. м., м")
            fig.colorbar(q, ax=ax)
        fig.tight_layout()
        fig.savefig(OUT / "fig_ctl_sections.png", dpi=100)
        plt.close(fig)


if __name__ == "__main__":
    main()
