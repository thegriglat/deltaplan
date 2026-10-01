"""А2: одна обработка матрицы вариантов сходимости (out/matrix_a2.jsonl) против исходной (out/matrix.jsonl, old/new).

  python3 analyze_a2.py   (numpy, matplotlib; GPU не нужен)
Выход: out/a2_tables.md, out/a2_summary.json, out/fig_a2_*.png.

Цена цепочки игры — область 400 → окно 100 → окно 50 м, штиль и 3 м/с, с нагревом и без (heat_mode cbl):
Σ итераций и Σ итераций × мс/итер варианта (медиана его решений с нагревом по сетке: heat_sweeps 8 и потолок окна
меняют цену итерации, k_relax — нет), плюс измеренное GPU-время решателя (шумное: GPU делили с тестами).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt   # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
KEYS = ("start_w200_max", "start_speed50", "start_th50", "w_max", "th_max", "w200_p99")
GAME = [(U, heat) for U in (0.0, 3.0) for heat in (True, False)]
GRIDS = ("d400", "w100", "w50")


def load(name):
    f = OUT / name
    return [json.loads(l) for l in f.read_text().splitlines() if l.strip()] if f.exists() else []


def fmt(x, n=3):
    if x is None or (isinstance(x, float) and not math.isfinite(x)):
        return "—"
    if isinstance(x, (int, np.integer)):
        return str(int(x))
    return f"{x:.{n}g}".replace(".", ",")


def rows_all():
    base = [dict(r, base=r["pset"], variant="—") for r in load("matrix.jsonl") if r["pset"] in ("old", "new")]
    a2 = load("matrix_a2.jsonl")
    return base + a2


def main():
    rows = [r for r in rows_all() if "err" not in r["solves"]]
    variants = []
    for r in rows:
        if r["variant"] not in variants:
            variants.append(r["variant"])
    idx = {(r["base"], r["variant"], r["dom"], r["U"], r["heat"], r["heat_mode"]): r for r in rows}
    # мс/итер по сеткам (медиана решений > 50 итераций)
    ms = {}
    for g in ("d400", "d200", "w100", "w50"):
        v = [s["it_ms"] for r in rows for k, s in r["solves"].items() if k == g and s["iters"] > 50]
        ms[g] = float(np.median(v)) if v else None
    md = ["# А2 — варианты сходимости (генерирует analyze_a2.py)\n",
          "Онгудай 12:00, 150°. Базовые old/new — `out/matrix.jsonl` (разведка), варианты — `out/matrix_a2.jsonl`. "
          "Критерий: mom 2e-5, θ′ 5e-7, div 1e-6, предел 3000 итераций.\n",
          "мс/итер (медиана по всем прогонам, float32, CuPy): " +
          ", ".join(f"{g} {fmt(ms[g])}" for g in ms) + "\n"]
    S = dict(it_ms=ms, variants={})
    # ---- сводка
    md.append("## Сводка по вариантам\n")
    md.append("cbl — все решения cbl (цепочка 400/100/50 и область 200 м; штиль и 3 м/с, с нагревом и без — 16 решений); "
              "surface — штиль и 3 м/с с нагревом (8 решений; у top3000 — только цепочка). Цена цепочки игры — cbl, "
              "400/100/50, штиль и 3 м/с, с нагревом и без (12 решений).\n")
    md.append("мс/итер варианта — медиана решений с нагревом > 50 итераций (без нагрева у kr10/kr15 air.py уже "
              "пропускал проход θ′_d — их не берём); замер шумный (GPU делили с тестами), сравнивать итерации.\n")
    md.append("| вариант | набор | cbl: не сошлось / решений | surface: не сошлось / решений | Σ итер. цепочки игры | "
              "цена цепочки, с (Σ итер × мс/итер варианта) | GPU цепочки (замер), с | мс/итер варианта d400 / w100 / w50 | GPU всей матрицы, с |")
    md.append("|---|---|---|---|---|---|---|---|---|")
    for vn in variants:
        for b in ("old", "new"):
            rr = [r for r in rows if r["variant"] == vn and r["base"] == b]
            if not rr:
                continue
            cb = [s for r in rr if r["heat_mode"] == "cbl" for s in r["solves"].values()]
            sf = [s for r in rr if r["heat_mode"] == "surface" for s in r["solves"].values()]
            vm = {}
            for g in GRIDS:
                v = [s["it_ms"] for r in rr if r["heat"] for k, s in r["solves"].items() if k == g and s["iters"] > 50]
                vm[g] = float(np.median(v)) if v else ms[g]
            it_g, cost_g, t_g, full = 0, 0.0, 0.0, True
            for U, heat in GAME:
                r = idx.get((b, vn, 400, U, heat, "cbl"))
                if r is None:
                    full = False
                    continue
                for g in GRIDS:
                    s = r["solves"][g]
                    it_g += s["iters"]
                    cost_g += s["iters"] * vm[g] / 1000.0
                    t_g += s["t_solve"]
            tall = sum(s["t_solve"] for r in rr for s in r["solves"].values())
            nbc = sum(s["status"] != "ok" for s in cb)
            nbs = sum(s["status"] != "ok" for s in sf)
            S["variants"].setdefault(vn, {})[b] = dict(cbl_bad=nbc, cbl_n=len(cb), surf_bad=nbs, surf_n=len(sf),
                                                        game_iters=it_g if full else None, game_cost_s=cost_g if full else None,
                                                        game_gpu_s=t_g if full else None, gpu_all_s=tall)
            vms = [fmt(vm[g]) for g in GRIDS]
            S["variants"][vn][b]["it_ms"] = vms
            md.append(f"| {vn} | {b} | {nbc} / {len(cb)} | {nbs} / {len(sf)} | {it_g if full else '—'} | "
                      f"{fmt(cost_g) if full else '—'} | {fmt(t_g) if full else '—'} | {' / '.join(vms)} | {fmt(tall)} |")
    md.append("")
    # ---- решения по вариантам
    md.append("## Итерации по решениям (статус, если не ok)\n")
    conds = [(400, 0.0, True, "cbl"), (400, 3.0, True, "cbl"), (400, 3.0, False, "cbl"), (400, 0.0, False, "cbl"),
             (200, 0.0, True, "cbl"), (200, 3.0, True, "cbl"), (200, 3.0, False, "cbl"), (200, 0.0, False, "cbl"),
             (400, 0.0, True, "surface"), (400, 3.0, True, "surface"), (200, 0.0, True, "surface"), (200, 3.0, True, "surface")]
    head = "| вариант | набор | " + " | ".join(f"{d} U{U:g} {'н' if h else 'бн'} {m[:4]}" for d, U, h, m in conds) + " |"
    md.append(head)
    md.append("|" + "---|" * (2 + len(conds)))
    for vn in variants:
        for b in ("old", "new"):
            cells = []
            for d, U, h, m in conds:
                r = idx.get((b, vn, d, U, h, m))
                if r is None:
                    cells.append("—")
                    continue
                sv = r["solves"]
                gg = GRIDS if d == 400 else ("d200",)
                cells.append("/".join((str(sv[g]["iters"]) if sv[g]["status"] == "ok" else f"**{sv[g]['status']}**")
                                      for g in gg))
            if any(c != "—" for c in cells):
                md.append(f"| {vn} | {b} | " + " | ".join(cells) + " |")
    md.append("")
    # ---- физика: сошедшиеся решения варианта против базового
    md.append("## Физика: сошедшиеся решения варианта против базового (тот же набор)\n")
    md.append("Подъём у старта — max w на 200 м AGL в 1,5 км от старта (окно 50 м; область 200 м — сама область). "
              "Δ — наибольшее |разность| по ключевым числам " + ", ".join(KEYS) + " среди решений, сошедшихся в обоих.\n")
    md.append("| вариант | набор | пар сошедшихся | max |Δ| подъёма, м/с | max |Δ| ключевых чисел | где max |")
    md.append("|---|---|---|---|---|---|")
    lifts = {}
    for vn in variants:
        if vn == "—":
            continue
        for b in ("old", "new"):
            n, dl, dk, where = 0, 0.0, 0.0, ""
            for (bb, v, d, U, h, m), r in idx.items():
                if bb != b or v != vn:
                    continue
                r0 = idx.get((b, "—", d, U, h, m))
                if r0 is None:
                    continue
                for g, s in r["solves"].items():
                    s0 = r0["solves"].get(g)
                    if s0 is None or s["status"] != "ok" or s0["status"] != "ok":
                        continue
                    n += 1
                    for k in KEYS:
                        a, a0 = s["key"].get(k), s0["key"].get(k)
                        if a is None or a0 is None:
                            continue
                        if abs(a - a0) > dk:
                            dk, where = abs(a - a0), f"{d} U{U:g} {'н' if h else 'бн'} {m} {g} {k}"
                    if abs(s["key"]["start_w200_max"] - s0["key"]["start_w200_max"]) > dl:
                        dl = abs(s["key"]["start_w200_max"] - s0["key"]["start_w200_max"])
            if n:
                md.append(f"| {vn} | {b} | {n} | {fmt(dl, 2)} | {fmt(dk, 2)} | {where} |")
                S["variants"][vn][b].update(phys_pairs=n, dlift=dl, dkey=dk)
    md.append("")
    md.append("### Подъём у старта, м/с (окно 50 м; в скобках статус, если не ok)\n")
    lc = [(0.0, True, "cbl"), (3.0, True, "cbl"), (3.0, False, "cbl"), (0.0, True, "surface"), (3.0, True, "surface")]
    md.append("| вариант | набор | " + " | ".join(f"U{U:g} {'нагрев' if h else 'без нагрева'} {m}" for U, h, m in lc) +
              " | 200 м U3 нагрев cbl | 200 м U0 нагрев cbl |")
    md.append("|---|---|" + "---|" * (len(lc) + 2))
    for vn in variants:
        for b in ("old", "new"):
            cells = []
            for U, h, m in lc:
                r = idx.get((b, vn, 400, U, h, m))
                s = r["solves"]["w50"] if r else None
                cells.append("—" if s is None else fmt(s["key"]["start_w200_max"]) + ("" if s["status"] == "ok" else f" ({s['status']})"))
            for U in (3.0, 0.0):
                r = idx.get((b, vn, 200, U, True, "cbl"))
                s = r["solves"]["d200"] if r else None
                cells.append("—" if s is None else fmt(s["key"]["start_w200_max"]) + ("" if s["status"] == "ok" else f" ({s['status']})"))
            if any(c != "—" for c in cells):
                md.append(f"| {vn} | {b} | " + " | ".join(cells) + " |")
                lifts[f"{vn}|{b}"] = cells
    md.append("")
    S["lifts"] = lifts
    (OUT / "a2_tables.md").write_text("\n".join(md) + "\n")
    (OUT / "a2_summary.json").write_text(json.dumps(S, ensure_ascii=False, indent=1, default=float))
    fig_hist(idx, variants)
    fig_cost(S, variants)
    print("\n".join(md))


def fig_hist(idx, variants):
    """Истории невязки θ′ и импульса по вариантам: new, штиль, нагрев cbl, окно 50 м и old, 200 м, 3 м/с, нагрев cbl."""
    sel = [("new: окно 50 м, штиль, нагрев cbl", "new", 400, 0.0, "w50"),
           ("old: область 200 м, 3 м/с, нагрев cbl", "old", 200, 3.0, "d200")]
    fig, ax = plt.subplots(2, 2, figsize=(12, 7), sharex="col")
    cmap = plt.get_cmap("tab10")
    for j, (title, b, d, U, g) in enumerate(sel):
        for n, vn in enumerate(variants):
            r = idx.get((b, vn, d, U, True, "cbl"))
            if r is None:
                continue
            h = np.array(r["solves"][g]["hist"])
            st = r["solves"][g]["status"]
            lab = f"{'база' if vn == '—' else vn} ({st} {r['solves'][g]['iters']})"
            ax[0, j].semilogy(h[:, 0], h[:, 1], color=cmap(n), lw=1, label=lab)
            ax[1, j].semilogy(h[:, 0], h[:, 3], color=cmap(n), lw=1, label=lab)
        ax[0, j].axhline(5e-7, color="k", ls=":", lw=0.8)
        ax[1, j].axhline(2e-5, color="k", ls=":", lw=0.8)
        ax[0, j].set_title(title)
        ax[0, j].set_ylabel("невязка θ′ (rms)")
        ax[1, j].set_ylabel("невязка импульса (rms)")
        ax[1, j].set_xlabel("итерация")
        ax[0, j].legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(OUT / "fig_a2_hist.png", dpi=110)
    plt.close(fig)


def fig_cost(S, variants):
    fig, ax = plt.subplots(1, 2, figsize=(12, 4))
    x = np.arange(len(variants))
    for k, b in enumerate(("old", "new")):
        it = [S["variants"].get(v, {}).get(b, {}).get("game_iters") or 0 for v in variants]
        bad = [S["variants"].get(v, {}).get(b, {}).get("cbl_bad", 0) for v in variants]
        ax[0].bar(x + (k - 0.5) * 0.4, it, 0.4, label=b)
        for xi, yi, bb in zip(x + (k - 0.5) * 0.4, it, bad):
            if bb:
                ax[0].text(xi, yi, f"не сошл. {bb}", ha="center", va="bottom", fontsize=7, rotation=90)
        c = [S["variants"].get(v, {}).get(b, {}).get("game_cost_s") or 0 for v in variants]
        ax[1].bar(x + (k - 0.5) * 0.4, c, 0.4, label=b)
    for a, t in zip(ax, ("Σ итераций цепочки игры (cbl, 400/100/50, 4 условия)", "цена цепочки, с (Σ итер × мс/итер CuPy)")):
        a.set_xticks(x)
        a.set_xticklabels(["база" if v == "—" else v for v in variants], rotation=30, fontsize=8)
        a.set_title(t, fontsize=9)
        a.legend()
    fig.tight_layout()
    fig.savefig(OUT / "fig_a2_cost.png", dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    main()
