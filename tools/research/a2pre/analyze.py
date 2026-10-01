"""Разведка перед А2: одна пакетная обработка out/matrix.jsonl и out/morris_rerun.jsonl.

  python3 analyze.py   (нужны numpy, matplotlib; GPU не нужен)
Выход: out/summary.json, out/tables.md, out/fig_*.png.
"""
from __future__ import annotations

import json
import math
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt   # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
COL = dict(old="#2a78d6", new="#eb6834", lam="#1baf7a", new_z003="#eda100", orig="#8a8984")
LBL = dict(old="старые (игра)", new="новые (перекалибровка)", lam="только λ/h 0,031", new_z003="новые, z0 0,03",
           orig="Моррис до А1")
TOL = dict(th=5e-7, mom=2e-5, div=1e-6)


def load(name):
    f = OUT / name
    return [json.loads(l) for l in f.read_text().splitlines() if l.strip()] if f.exists() else []


def fmt(x, n=3):
    if x is None or (isinstance(x, float) and not math.isfinite(x)):
        return "—"
    if isinstance(x, (int, np.integer)):
        return str(int(x))
    return f"{x:.{n}g}".replace(".", ",")


def holds(s):
    """Какой критерий держит несошедшееся решение (по доле проверок второй половины выше порога)."""
    if s["status"] == "ok":
        return ""
    a = s["plateau"].get("above", {})
    return "+".join(k for k in ("mom", "th", "div") if a.get(k, 0) > 0.5) or "—"


def cyc(s):
    """Плато: предельный цикл (невязка не убывает, качается) или медленное убывание."""
    p = s["plateau"]
    if s["status"] == "ok" or "slope_ln_th_per_1000" not in p:
        return ""
    sl = p["slope_ln_th_per_1000"]
    return f"{'цикл' if sl > -0.3 else 'убыв.'} ×{fmt(p['swing'], 2)} T≈{fmt(p['period_it'], 3)}"


# ------------------------------------------------------------------------------------------ матрица
def matrix(rows, md, S):
    md.append("## Матрица: Онгудай 12:00, 150°\n")
    md.append("Статус/итерации по решениям цепочки; подъём — max w на 200 м AGL в 1,5 км от старта (окно 50 м; для 200 м — "
              "область); баланс — |rel| остатка баланса тепла последнего решения цепочки; невязки второй половины "
              "истории: что держит (mom — импульс, th — тепло), характер плато.\n")
    md.append("| набор | цепочка | условия | heat_mode | d400/d200 | w100 | w50 | GPU, с | мс/итер (область) | подъём, м/с | баланс rel | держит | плато |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    S["matrix"] = []
    for r in rows:
        sv = r["solves"]
        if "err" in sv:
            md.append(f"| {r['pset']} | {r['dom']} | ошибка {sv['err']} |")
            continue
        cond = f"U{r['U']:g} {'нагрев' if r['heat'] else 'без нагрева'}"
        dn = f"d{r['dom']}"
        last = sv.get("w50", sv[dn])
        lift = last["key"].get("start_w200_max")
        tgpu = sum(v["t_solve"] for v in sv.values())
        bud = last["budget"].get("rel")
        cells = [f"{v['status']} {v['iters']}" for v in (sv[dn], sv.get("w100"), sv.get("w50")) if v is not None]
        while len(cells) < 3:
            cells.append("—")
        worst = max(sv.values(), key=lambda v: (v["status"] != "ok", v["iters"]))
        md.append(f"| {r['pset']} | {r['dom']} | {cond} | {r['heat_mode']} | {' | '.join(cells)} | {fmt(tgpu)} | "
                  f"{fmt(sv[dn]['it_ms'])} | {fmt(lift)} | {fmt(abs(bud) if bud is not None else None, 2)} | "
                  f"{holds(worst)} | {cyc(worst)} |")
        S["matrix"].append(dict(key=r["key"], pset=r["pset"], dom=r["dom"], U=r["U"], heat=r["heat"], heat_mode=r["heat_mode"],
                                status={k: v["status"] for k, v in sv.items()}, iters={k: v["iters"] for k, v in sv.items()},
                                t_solve={k: v["t_solve"] for k, v in sv.items()}, it_ms={k: v["it_ms"] for k, v in sv.items()},
                                lift=lift, lift_d=sv[dn]["key"].get("start_w200_max"), budget_rel=bud,
                                plateau={k: v["plateau"] for k, v in sv.items()},
                                where={k: v.get("where") for k, v in sv.items()}))
    md.append("")
    # сводка по наборам
    md.append("### Сводка матрицы по наборам\n")
    md.append("| набор | решений | не сошлось | медиана итер. | p90 итер. | GPU всего, с | мс/итер d400 | d200 | w100 | w50 |")
    md.append("|---|---|---|---|---|---|---|---|---|---|")
    agg = {}
    for ps in ("old", "new", "lam", "new_z003"):
        sol = [(k, v) for r in rows if r["pset"] == ps and "err" not in r["solves"] for k, v in r["solves"].items()]
        if not sol:
            continue
        it = np.array([v["iters"] for _, v in sol])
        nb = sum(v["status"] != "ok" for _, v in sol)
        cost = {g: np.median([v["it_ms"] for k, v in sol if k == g and v["iters"] > 50]) if any(k == g for k, _ in sol) else None
                for g in ("d400", "d200", "w100", "w50")}
        agg[ps] = dict(n=len(sol), bad=nb, it_med=float(np.median(it)), it_p90=float(np.percentile(it, 90)),
                       t=float(sum(v["t_solve"] for _, v in sol)), it_ms={g: (float(c) if c is not None else None) for g, c in cost.items()})
        md.append(f"| {ps} | {len(sol)} | {nb} | {fmt(agg[ps]['it_med'])} | {fmt(agg[ps]['it_p90'])} | {fmt(agg[ps]['t'])} | "
                  + " | ".join(fmt(cost[g]) for g in ("d400", "d200", "w100", "w50")) + " |")
    S["matrix_agg"] = agg
    md.append("")
    # подъём у старта: old против new
    md.append("### Подъём у старта (окно 50 м), м/с\n")
    md.append("| условия | heat_mode | old | new | lam | new_z003 |")
    md.append("|---|---|---|---|---|---|")
    idx = {(r["pset"], r["dom"], r["U"], r["heat"], r["heat_mode"]): r for r in rows if "err" not in r["solves"]}
    for U, heat, hm in ((0.0, True, "cbl"), (0.0, True, "surface"), (3.0, True, "cbl"), (3.0, True, "surface"),
                        (3.0, False, "cbl"), (0.0, False, "cbl")):
        vals = []
        for ps in ("old", "new", "lam", "new_z003"):
            r = idx.get((ps, 400, U, heat, hm))
            if r is None:
                vals.append("—")
                continue
            w = r["solves"]["w50"]
            vals.append(f"{fmt(w['key'].get('start_w200_max'))}{'' if w['status'] == 'ok' else ' (' + w['status'] + ')'}")
        md.append(f"| U{U:g} {'нагрев' if heat else 'без нагрева'} | {hm} | " + " | ".join(vals) + " |")
    md.append("")
    fig_matrix_hist(rows)
    fig_matrix_iters(rows)


def fig_matrix_hist(rows):
    """Истории невязок: штиль с нагревом cbl (цепочка 400) и 200 м 3 м/с с нагревом, old против new."""
    sel = [("d400→w50, штиль, нагрев cbl", 400, 0.0, True, "cbl", ("d400", "w100", "w50")),
           ("d200, 3 м/с, нагрев cbl", 200, 3.0, True, "cbl", ("d200",)),
           ("d400→w50, штиль, нагрев surface", 400, 0.0, True, "surface", ("d400", "w100", "w50")),
           ("d200, штиль, нагрев cbl", 200, 0.0, True, "cbl", ("d200",))]
    idx = {(r["pset"], r["dom"], r["U"], r["heat"], r["heat_mode"]): r for r in rows if "err" not in r["solves"]}
    fig, axs = plt.subplots(2, 4, figsize=(17, 7.5), sharex=False)
    for c, (title, dom, U, heat, hm, grids) in enumerate(sel):
        for ps in ("old", "new"):
            r = idx.get((ps, dom, U, heat, hm))
            if r is None:
                continue
            off = 0
            for g in grids:
                h = np.array(r["solves"][g]["hist"])
                if len(h) == 0:
                    continue
                x = h[:, 0] + off
                axs[0, c].semilogy(x, h[:, 1], color=COL[ps], lw=1.2, label=LBL[ps] if g == grids[0] else None)
                axs[1, c].semilogy(x, h[:, 3], color=COL[ps], lw=1.2)
                if len(grids) > 1:
                    axs[0, c].axvline(x[-1], color=COL[ps], lw=0.6, ls=":")
                off = x[-1]
        axs[0, c].axhline(TOL["th"], color="#52514e", lw=0.8, ls="--")
        axs[1, c].axhline(TOL["mom"], color="#52514e", lw=0.8, ls="--")
        axs[0, c].set_title(title, fontsize=10)
        axs[1, c].set_xlabel("итерация (цепочка подряд)")
    axs[0, 0].set_ylabel("невязка θ′ (rms), К/с")
    axs[1, 0].set_ylabel("невязка импульса (rms), м/с²")
    axs[0, 0].legend(frameon=False, fontsize=9)
    for a in axs.ravel():
        a.grid(alpha=0.25, lw=0.5)
        a.spines[["top", "right"]].set_visible(False)
    fig.suptitle("История невязок, пунктир — порог сходимости", fontsize=11)
    fig.tight_layout()
    fig.savefig(OUT / "fig_matrix_hist.png", dpi=120)
    plt.close(fig)


def fig_matrix_iters(rows):
    """Итерации по решениям матрицы: наборы рядом, сплошная — ok, пустая — max."""
    grids = ("d400", "w100", "w50", "d200")
    conds = [(0.0, True, "cbl"), (0.0, True, "surface"), (3.0, True, "cbl"), (3.0, True, "surface"), (3.0, False, "cbl")]
    idx = {(r["pset"], r["dom"], r["U"], r["heat"], r["heat_mode"]): r for r in rows if "err" not in r["solves"]}
    fig, axs = plt.subplots(1, len(grids), figsize=(16, 4.2), sharey=True)
    pss = ("old", "lam", "new", "new_z003")
    for a, g in zip(axs, grids):
        dom = 200 if g == "d200" else 400
        for ci, (U, heat, hm) in enumerate(conds):
            for pi, ps in enumerate(pss):
                r = idx.get((ps, dom, U, heat, hm))
                if r is None or g not in r["solves"]:
                    continue
                s = r["solves"][g]
                x = ci + (pi - 1.5) * 0.19
                ok = s["status"] == "ok"
                a.bar(x, s["iters"], width=0.17, color=COL[ps] if ok else "none", edgecolor=COL[ps], lw=1.5,
                      label=LBL[ps] if ci == 0 and g == "d400" else None)
        a.set_xticks(range(len(conds)))
        a.set_xticklabels([f"U{U:g}\n{'нагр.' if h else 'без'}\n{m if h else ''}" for U, h, m in conds], fontsize=8)
        a.set_title(g)
        a.set_yscale("log")
        a.grid(axis="y", alpha=0.25, lw=0.5)
        a.spines[["top", "right"]].set_visible(False)
    axs[0].set_ylabel("итераций (пустой столбец — max 3000)")
    axs[0].legend(frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(OUT / "fig_matrix_iters.png", dpi=120)
    plt.close(fig)


# ------------------------------------------------------------------------------------------ Моррис
def morris(rows, md, S):
    if not rows:
        return
    by = defaultdict(dict)
    for r in rows:
        by[r["morris_idx"]][r["pset"]] = r
    pairs = {i: d for i, d in by.items() if "old" in d and "new" in d and "err" not in d["old"]["solves"]
             and "err" not in d["new"]["solves"]}
    grids = ("d400", "w100", "w50")
    md.append(f"## Несошедшиеся конфигурации Морриса (heat0: штиль, 12:00), {len(pairs)} пар old/new\n")
    md.append("«orig» — те же конфигурации в прогоне Морриса (air.py до А1: Pr_t только по вертикали, τ на полный θ′, "
              "свои λ/h, z0, α точки); old/new — air.py после А1, три параметра заменены набором.\n")
    md.append("| | не сошлось (цепочка) | d400 | w100 | w50 | медиана итер. цепочки | p90 | медиана GPU цепочки, с | p90 |")
    md.append("|---|---|---|---|---|---|---|---|---|")
    stat = {}
    for ps in ("orig", "old", "new"):
        bad = {g: 0 for g in grids}
        anyb, its, ts = 0, [], []
        for i, d in pairs.items():
            if ps == "orig":
                runs = d["new"]["morris_orig"][0]["runs"]
                st = {g: runs[g]["status"] for g in grids}
                it = sum(runs[g]["iters"] for g in grids)
                t = sum(runs[g]["t"] for g in grids)
            else:
                sv = d[ps]["solves"]
                st = {g: sv[g]["status"] for g in grids}
                it = sum(sv[g]["iters"] for g in grids)
                t = sum(sv[g]["t_solve"] for g in grids)
            for g in grids:
                bad[g] += st[g] != "ok"
            anyb += any(v != "ok" for v in st.values())
            its.append(it)
            ts.append(t)
        stat[ps] = dict(bad_any=anyb, bad=bad, it_med=float(np.median(its)), it_p90=float(np.percentile(its, 90)),
                        t_med=float(np.median(ts)), t_p90=float(np.percentile(ts, 90)), t_sum=float(np.sum(ts)))
        md.append(f"| {ps} | {anyb}/{len(pairs)} | {bad['d400']} | {bad['w100']} | {bad['w50']} | {fmt(stat[ps]['it_med'])} | "
                  f"{fmt(stat[ps]['it_p90'])} | {fmt(stat[ps]['t_med'])} | {fmt(stat[ps]['t_p90'])} |")
    md.append("")
    # попарно
    trans = Counter()
    for i, d in pairs.items():
        a = all(d["old"]["solves"][g]["status"] == "ok" for g in grids)
        b = all(d["new"]["solves"][g]["status"] == "ok" for g in grids)
        trans[(a, b)] += 1
    md.append(f"Попарно (цепочка целиком): old ok → new ok {trans[(True, True)]}, old max → new ok {trans[(False, True)]}, "
              f"old ok → new max {trans[(True, False)]}, оба max {trans[(False, False)]}.\n")
    stat["transitions"] = {f"old_{'ok' if a else 'max'}->new_{'ok' if b else 'max'}": n for (a, b), n in trans.items()}
    # цена итерации
    md.append("Цена итерации (медиана, мс): " + "; ".join(
        f"{g}: old {fmt(np.median([d['old']['solves'][g]['it_ms'] for d in pairs.values()]))}, "
        f"new {fmt(np.median([d['new']['solves'][g]['it_ms'] for d in pairs.values()]))}" for g in grids) + ".\n")
    # что держит и характер плато
    md.append("### Что держит несошедшиеся решения и где невязка\n")
    md.append("| набор | сетка | не сошлось | держит mom / th / оба | цикл (наклон ln θ′ > −0,3 на 1000 ит.) | медиана размаха θ′ | медиана периода, итер. | доля Σr²(θ′) у граней | в полосе 0,75–1,1 z_i | медиана z max θ′ AGL, м |")
    md.append("|---|---|---|---|---|---|---|---|---|---|")
    ch = {}
    for ps in ("old", "new"):
        for g in grids:
            ss = [d[ps]["solves"][g] for d in pairs.values() if d[ps]["solves"][g]["status"] != "ok"]
            if not ss:
                md.append(f"| {ps} | {g} | 0 | | | | | | | |")
                continue
            hh = Counter(holds(s) for s in ss)
            ncyc = sum(s["plateau"].get("slope_ln_th_per_1000", -9) > -0.3 for s in ss)
            sw = np.median([s["plateau"].get("swing", np.nan) for s in ss])
            per = np.median([s["plateau"].get("period_it") or np.nan for s in ss])
            edge = np.median([s["where"]["th"]["edge_any"] for s in ss])
            zb = np.median([s["where"]["th"].get("zi_band", np.nan) for s in ss])
            za = np.median([s["where"]["th"]["z_argmax_agl"] for s in ss])
            ch[f"{ps}_{g}"] = dict(n=len(ss), holds=dict(hh), n_cycle=ncyc, swing=float(sw), period=float(per),
                                  edge=float(edge), zi_band=float(zb), z_agl=float(za))
            md.append(f"| {ps} | {g} | {len(ss)} | {hh.get('mom', 0)} / {hh.get('th', 0)} / {hh.get('mom+th', 0)} | {ncyc} | "
                      f"{fmt(sw, 2)} | {fmt(per, 3)} | {fmt(edge, 2)} | {fmt(zb, 2)} | {fmt(za, 3)} |")
    stat["character"] = ch
    md.append("")
    # факторы
    md.append("### Какие факторы Морриса связаны с несходимостью на new\n")
    md.append("Доля несошедшихся цепочек по уровням дискретных факторов и по половинам диапазона непрерывных "
              "(в подвыборке только исходно несошедшиеся точки — это условная доля).\n")
    md.append("| фактор | уровень/половина | n | не сошлось new | не сошлось old |")
    md.append("|---|---|---|---|---|")
    fac = {}
    cont = dict(lam=(15, 150), cs_h=(0, 0.3), pr_t=(0.5, 1.3), k_fa=(0.1, 3), tau_cool=(1800, 21600), zi_min=(100, 600),
                k_smooth_m=(500, 3000), nu_const=(5, 100))
    logf = {"lam", "pr_t", "k_fa", "tau_cool", "zi_min", "k_smooth_m", "nu_const"}

    def bad_of(d, ps):
        return any(d[ps]["solves"][g]["status"] != "ok" for g in grids)

    for f in ("adv2", "closure", "local_k", "heat_mode", "limiter") + tuple(cont):
        groups = defaultdict(list)
        for d in pairs.values():
            x = d["new"]["morris_fx"][f]
            if f in cont:
                lo, hi = cont[f]
                u = (math.log(x) - math.log(lo)) / (math.log(hi) - math.log(lo)) if f in logf else (x - lo) / (hi - lo)
                lev = "нижняя" if u < 0.5 else "верхняя"
            else:
                lev = str(x)
            groups[lev].append(d)
        fac[f] = {}
        for lev, ds in sorted(groups.items()):
            bn, bo = sum(bad_of(d, "new") for d in ds), sum(bad_of(d, "old") for d in ds)
            fac[f][lev] = dict(n=len(ds), bad_new=bn, bad_old=bo)
            md.append(f"| {f} | {lev} | {len(ds)} | {bn} ({fmt(bn / len(ds), 2)}) | {bo} ({fmt(bo / len(ds), 2)}) |")
    stat["factors"] = fac
    md.append("")
    S["morris"] = stat
    fig_morris(pairs, stat)


def fig_morris(pairs, stat):
    grids = ("d400", "w100", "w50")
    fig, axs = plt.subplots(1, 3, figsize=(15, 4.3))
    a = axs[0]
    n = len(pairs)
    for k, ps in enumerate(("orig", "old", "new")):
        vals = [stat[ps]["bad"][g] for g in grids] + [stat[ps]["bad_any"]]
        x = np.arange(4) + (k - 1) * 0.26
        a.bar(x, vals, width=0.24, color=COL[ps], label=LBL[ps])
        for xi, v in zip(x, vals):
            a.text(xi, v + 0.3, str(v), ha="center", fontsize=8, color="#0b0b0b")
    a.set_xticks(range(4))
    a.set_xticklabels(list(grids) + ["цепочка"])
    a.set_ylabel(f"не сошлось из {n}")
    a.legend(frameon=False, fontsize=8)
    a.set_title("Несошедшиеся точки Морриса (штиль 12:00)", fontsize=10)
    for j, g in enumerate(("d400", "w50")):
        a = axs[1 + j]
        for d in pairs.values():
            so, sn = d["old"]["solves"][g], d["new"]["solves"][g]
            a.scatter(so["iters"], sn["iters"], s=28, facecolor=COL["new"] if sn["status"] == "ok" else "none",
                      edgecolor=COL["new"], lw=1.2)
        a.plot([10, 3100], [10, 3100], color="#8a8984", lw=0.8, ls="--")
        a.set_xscale("log"); a.set_yscale("log")
        a.set_xlabel("итерации, старые параметры (после А1)")
        a.set_ylabel("итерации, новые параметры")
        a.set_title(f"{g}: пустой маркер — new не сошлось", fontsize=10)
    for a in axs:
        a.grid(alpha=0.25, lw=0.5)
        a.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "fig_morris.png", dpi=120)
    plt.close(fig)


def fig_maps():
    """Карты max_z невязки θ′ в конце решения: 200 м, 3 м/с с нагревом cbl, old и new; w50 штиль cbl."""
    mf = OUT / "matrix_maps.npz"
    if not mf.exists():
        return
    M = np.load(mf)
    sel = [("old|d200|U3|heat|cbl|d200|th_plan", "old: d200, 3 м/с, нагрев"), ("new|d200|U3|heat|cbl|d200|th_plan", "new: d200, 3 м/с, нагрев"),
           ("old|d400|U0|heat|cbl|w50|th_plan", "old: w50, штиль, нагрев"), ("new|d400|U0|heat|cbl|w50|th_plan", "new: w50, штиль, нагрев"),
           ("old|d400|U0|heat|cbl|w50|w_plan", "old: w50, штиль — невязка w"), ("new|d400|U0|heat|cbl|w50|w_plan", "new: w50, штиль — невязка w")]
    sel = [s for s in sel if s[0] in M.files]
    if not sel:
        return
    fig, axs = plt.subplots(1, len(sel), figsize=(3.6 * len(sel), 3.6))
    axs = np.atleast_1d(axs)
    for a, (k, t) in zip(axs, sel):
        m = M[k].astype(float)
        im = a.imshow(np.log10(np.maximum(m, 1e-12)), origin="lower", cmap="Blues", vmin=np.log10(max(m.max(), 1e-12)) - 3)
        a.set_title(t, fontsize=9)
        a.set_xticks([]); a.set_yticks([])
        fig.colorbar(im, ax=a, fraction=0.046, label="lg max_z |r|")
    fig.suptitle("Где невязка в конце (план, max по высоте; x — восток, y — север)", fontsize=10)
    fig.tight_layout()
    fig.savefig(OUT / "fig_maps.png", dpi=120)
    plt.close(fig)


def main():
    md, S = ["# Разведка перед А2 — таблицы (генерирует analyze.py)\n"], {}
    mrows = load("matrix.jsonl")
    matrix(mrows, md, S)
    # Моррис отложен (решение пользователя): 2 прерванные строки morris_rerun.jsonl не обрабатываются;
    # morris() оставлена для волны Б: morris(load("morris_rerun.jsonl"), md, S)
    fig_maps()
    (OUT / "tables.md").write_text("\n".join(md) + "\n")
    (OUT / "summary.json").write_text(json.dumps(S, ensure_ascii=False, indent=1, default=float))
    print("\n".join(md))


if __name__ == "__main__":
    main()
