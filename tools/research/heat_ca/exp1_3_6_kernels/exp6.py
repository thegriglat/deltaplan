#!/usr/bin/env python3
"""Опыт 6. «Ядро струи» (jet.py) против эталона автомата.

  ../.venv/bin/python exp6.py calib     # β (расслоение бассейна) — по профилю θ′ сценария 1, 50 м
  ../.venv/bin/python exp6.py compare   # 4 сценария × 200/100/50/25 м: ошибки, ключевые числа, картинки
  flock /tmp/heat_ca_gpu.lock ../.venv/bin/python exp6.py time   # время на GPU (CUDA Graph) + оценка 3D
  ../.venv/bin/python exp6.py kernels   # формы ядер: отклик на точечный нагрев (равнина/склон/гребень)

Эталон — сохранённые установившиеся поля ../out/refs (автомат остановлен штатным критерием, ~3,5 ч
модели); вторая колонка — автомат через 8 ч (кеш exp13: out/cache/t8h_*), где тёплый бассейн
досчитан до конца (закон сохранения тепла бассейна в jet.py — именно про полное установление).
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import SCENARIOS, Params, HeatCA  # noqa: E402
import plots  # noqa: E402
from plots import SERIES, MUTED, INK  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import TwoSlopeNorm  # noqa: E402
from jet import Jet  # noqa: E402
from exp13 import fixed_run, rel, OUT  # noqa: E402

REFS = os.path.join(HERE, "..", "out", "refs")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
TITLES = {"s1_sun_one_slope": "1. Солнце на крутой склон", "s2_both_slopes": "2. Оба склона",
          "s3_wind": "3. Ветер 3 м/с", "s4_inversion": "4. Инверсия 1,5 км"}
CELLS = [200.0, 100.0, 50.0, 25.0]
CALIB = os.path.join(OUT, "exp6_calib.json")
L3D, LEV3D = 40000.0, 32


def load_ref(name, cell):
    z = np.load(os.path.join(REFS, f"{name}_{cell:g}.npz"))
    return (z["uc"], z["wc"], z["th"]), json.loads(str(z["info"]))


def beta():
    if os.path.exists(CALIB):
        return json.load(open(CALIB))["beta"]
    return 0.6


# ---------------------------------------------------------------- калибровка β
def exp_calib():
    (ru, rw, rt), _ = load_ref("s1_sun_one_slope", 50.0)
    prof_ref = np.nanmean(rt, axis=1)
    rows = []
    for b in np.arange(0.35, 1.01, 0.05):
        j = Jet(SCENARIOS["s1_sun_one_slope"], 50.0, beta=float(b))
        j.compute()
        u, w, t = j.centers()
        prof = np.nanmean(t, axis=1)
        e = float(np.sqrt(np.mean((prof - prof_ref) ** 2)))
        rows.append((float(b), e, rel(t, rt), rel(w, rw)))
        print(f"   β = {b:.2f}: СКО профиля θ′ {e:.3f} К; ошибка θ′ {rel(t, rt):.2f}, w {rel(w, rw):.2f}")
    best = min(rows, key=lambda r: r[1])
    json.dump(dict(beta=round(best[0], 2), rows=rows, note="β по СКО горизонтально-среднего профиля θ′, "
                   "сценарий 1, 50 м, эталон out/refs"), open(CALIB, "w"), indent=1)
    print(f"β = {best[0]:.2f}")


# ---------------------------------------------------------------- сравнение
KEYS = [("w_max", "макс. подъём, м/с", "{:.2f}"), ("w_max_x", "x подъёма, км", "{:.2f}"),
        ("w_max_z", "z подъёма, м", "{:.0f}"), ("inflow_left", "приток слева, м/с", "{:+.2f}"),
        ("upslope_left", "вверх по склону слева, м/с", "{:+.2f}"),
        ("w_mean_valley_left", "опускание в долине, м/с", "{:+.3f}"), ("ascent_top_z", "высота подъёма, м", "{:.0f}")]


def exp_compare():
    b = beta()
    res = []
    for name in NAMES:
        for cell in CELLS:
            ref, info = load_ref(name, cell)
            ref8 = fixed_run(SCENARIOS[name], cell, name)[:3]
            j = Jet(SCENARIOS[name], cell, beta=b)
            j.compute()
            f = j.centers()
            m = j.m
            mr, mj = plots.metrics(m, *ref), plots.metrics(m, *f)
            e = [rel(f[i], ref[i]) for i in range(3)]
            e8 = [rel(f[i], ref8[i]) for i in range(3)]
            er = [rel(ref8[i], ref[i]) for i in range(3)]
            r = dict(name=name, cell=cell, e=e, e8=e8, e_ref_vs_8h=er, m_ref=mr, m_jet=mj, plume=j.plume_info(),
                     div=j.div_residual(), steady_wall=info["steady_wall"], steady_step=info["steady_step"])
            res.append(r)
            print(f"{name} {cell:g} м: u/w/θ′ {e[0]:.2f}/{e[1]:.2f}/{e[2]:.2f} (против 8 ч {e8[0]:.2f}/{e8[1]:.2f}/"
                  f"{e8[2]:.2f}); подъём {mj['w_max']:.2f} ({mr['w_max']:.2f}), верх {mj['ascent_top_z']:.0f} "
                  f"({mr['ascent_top_z']:.0f})", flush=True)
            if cell == 50.0:
                fig_compare(j, ref, f, name, cell)
    json.dump(res, open(os.path.join(OUT, "exp6_compare.json"), "w"), indent=1, default=float)
    # таблицы
    L = [f"β = {b:.2f} (калибровка — сценарий 1, 50 м). Ошибка = ‖jet − эталон‖/‖эталон‖ по воздушным клеткам.\n",
         "| Сценарий | Клетка | Ошибка u / w / θ′ (эталон out/refs) | то же против автомата через 8 ч | эталон 3,5 ч против 8 ч |",
         "|---|---|---|---|---|"]
    for r in res:
        L.append(f"| {TITLES[r['name']]} | {r['cell']:g} м | {r['e'][0]:.2f} / {r['e'][1]:.2f} / {r['e'][2]:.2f} | "
                 f"{r['e8'][0]:.2f} / {r['e8'][1]:.2f} / {r['e8'][2]:.2f} | "
                 f"{r['e_ref_vs_8h'][0]:.2f} / {r['e_ref_vs_8h'][1]:.2f} / {r['e_ref_vs_8h'][2]:.2f} |")
    L += ["", "Ключевые числа, клетка 50 м (jet / эталон):", "",
          "| Сценарий | " + " | ".join(k[1] for k in KEYS) + " |", "|---|" + "---|" * len(KEYS)]
    for r in res:
        if r["cell"] != 50.0:
            continue
        cells = []
        for k, _, fmt in KEYS:
            a, bb = r["m_jet"].get(k, np.nan), r["m_ref"].get(k, np.nan)
            if k == "w_max_x":
                a, bb = a / 1000, bb / 1000
            cells.append(f"{fmt.format(a)} / {fmt.format(bb)}")
        L.append(f"| {TITLES[r['name']]} | " + " | ".join(cells) + " |")
    r4 = [r for r in res if r["name"] == "s4_inversion" and r["cell"] == 50.0][0]
    L += ["", f"Инверсия (50 м): над инверсией |w| ≤ {r4['m_jet']['above_inv_wmax']:.2f} м/с "
          f"(эталон {r4['m_ref']['above_inv_wmax']:.2f}), |θ′| ≤ {r4['m_jet']['above_inv_thmax']:.2f} К "
          f"(эталон {r4['m_ref']['above_inv_thmax']:.2f}); растекание под инверсией "
          f"{r4['m_jet']['outflow_under_inv']:.2f} м/с (эталон {r4['m_ref']['outflow_under_inv']:.2f})."]
    with open(os.path.join(OUT, "exp6_compare.md"), "w") as fh:
        fh.write("\n".join(L) + "\n")
    print("\n".join(L))
    fig_errors(res)


def fig_compare(j, ref, f, name, cell):
    m = j.m
    d, xe, ze = plots.grid_info(m)
    fig, axs = plt.subplots(3, 3, figsize=(20, 9.6), constrained_layout=True)
    top = 2.8
    for c, (nm, unit, i) in enumerate((("w", "м/с", 1), ("u", "м/с", 0), ("θ′", "К", 2))):
        lim = float(np.nanmax(np.abs(ref[i]))) if nm != "θ′" else float(np.nanpercentile(np.abs(ref[i]), 99.5))
        for r, (t, fld) in enumerate((("эталон (автомат)", ref[i]), ("ядро струи", f[i]),
                                      ("разность: ядро струи − эталон", f[i] - ref[i]))):
            ax = axs[r, c]
            pm = ax.pcolormesh(xe / 1000, ze / 1000, fld, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim))
            plots.draw_ground(ax, m, stair=False)
            plots._inv_line(ax, m)
            ax.set_ylim(0, top)
            ax.set_title(f"{nm}: {t}", fontsize=10)
            ax.label_outer()
            fig.colorbar(pm, ax=ax, shrink=0.85, label=f"{nm}, {unit}")
    fig.suptitle(f"Опыт 6. {m.sc.title}: эталон, «ядро струи» и разность (клетка {cell:g} м; "
                 f"шкала — по эталону)")
    fig.savefig(os.path.join(OUT, f"exp6_compare_{name}.png"))
    plt.close(fig)


def fig_errors(res):
    fig, axs = plt.subplots(1, 3, figsize=(15, 4), constrained_layout=True)
    for ax, i, nm in zip(axs, range(3), ("u", "w", "θ′")):
        for c, name in zip(SERIES, NAMES):
            rr = [r for r in res if r["name"] == name]
            ax.plot([r["cell"] for r in rr], [r["e"][i] for r in rr], "o-", color=c, lw=2, label=TITLES[name])
        ax.set_xscale("log")
        ax.set_xticks(CELLS)
        ax.set_xticklabels([f"{c:g}" for c in CELLS])
        ax.minorticks_off()
        ax.invert_xaxis()
        ax.set_ylim(0, None)
        ax.grid(axis="y", color="#e5e5e5")
        ax.set_xlabel("клетка, м")
        ax.set_ylabel(f"‖{nm} − эталон‖ / ‖эталон‖")
        ax.set_title(f"ошибка {nm}")
    axs[0].legend(frameon=False, fontsize=9)
    fig.suptitle("Опыт 6. «Ядро струи»: ошибка против эталона по клетке")
    fig.savefig(os.path.join(OUT, "exp6_errors_vs_cell.png"))
    plt.close(fig)


# ---------------------------------------------------------------- формы ядер
def exp_kernels(cell=50.0):
    base = SCENARIOS["s1_sun_one_slope"]
    spots = {"равнина (x = 0,8 км)": 800.0, "середина склона (x = 2,2 км)": 2200.0, "у гребня (x = 2,75 км)": 2750.0}
    b = beta()
    fig, axs = plt.subplots(3, 4, figsize=(21, 8.6), constrained_layout=True)
    info = {}
    for r, (lab, x) in enumerate(spots.items()):
        sc = dataclasses.replace(base, name=f"pt_{x:g}", heating="point", point_x=x, q0_wm2=250.0, q_diffuse=0.0)
        ref = fixed_run(sc, cell, f"pt_{x:g}")[:3]
        j = Jet(sc, cell, beta=b)
        j.compute()
        f = j.centers()
        m = j.m
        d, xe, ze = plots.grid_info(m)
        info[lab] = dict(e=[rel(f[i], ref[i]) for i in range(3)], w_ref=float(np.nanmax(ref[1])),
                         w_jet=float(np.nanmax(f[1])), plume=j.plume_info())
        for c, (t, fld, i, sc_, unit) in enumerate((("w, автомат", ref, 1, 100, "см/с"), ("w, ядро струи", f, 1, 100, "см/с"),
                                                  ("θ′, автомат", ref, 2, 1000, "мК"), ("θ′, ядро струи", f, 2, 1000, "мК"))):
            ax = axs[r, c]
            lim = float(np.nanmax(np.abs(ref[i]))) * sc_
            pm = ax.pcolormesh(xe / 1000, ze / 1000, fld[i] * sc_, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim))
            plots.draw_ground(ax, m, stair=False)
            ax.plot([x / 1000], [m.terrain(np.array([x]))[0] / 1000 + 0.06], "v", color=INK, ms=8, zorder=9)
            ax.set_ylim(0, 2.4)
            ax.set_title(f"{t}; источник: {lab}", fontsize=10)
            ax.label_outer()
            fig.colorbar(pm, ax=ax, shrink=0.85, label=unit)
    fig.suptitle(f"Опыт 6. Формы ядер: отклик на нагрев одного столбца {cell:g} м (250 Вт/м²) — автомат через 8 ч "
                 f"и «ядро струи» (шкала — по автомату)")
    fig.savefig(os.path.join(OUT, "exp6_kernel_shapes.png"))
    plt.close(fig)
    json.dump(info, open(os.path.join(OUT, "exp6_kernels.json"), "w"), indent=1, default=float)
    for k, v in info.items():
        print(k, v)
    fig_jet_anatomy(b)


def fig_jet_anatomy(b):
    """Анатомия ядра струи на сценариях 2, 3, 4 (50 м): ось струи, ширина ±σ, слой Прандтля."""
    fig, axs = plt.subplots(1, 3, figsize=(19, 4.6), constrained_layout=True)
    for ax, name in zip(axs, ("s2_both_slopes", "s3_wind", "s4_inversion")):
        sc = SCENARIOS[name]
        if name == "s3_wind":
            # ветер слабее — струя «стоит» и видно наклон (при 3 м/с её кладёт ветер)
            sc = dataclasses.replace(sc, wind_ms=1.5, title="ветер 1,5 м/с (при 3 м/с струю кладёт ветер)")
        j = Jet(sc, 50.0, beta=b)
        j.compute()
        m = j.m
        u, w, t = j.centers()
        d, xe, ze = plots.grid_info(m)
        lim = float(np.nanmax(np.abs(w)))
        pm = ax.pcolormesh(xe / 1000, ze / 1000, w, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim))
        plots.draw_ground(ax, m, stair=False)
        plots._inv_line(ax, m)
        wf, sg, xf = j.wf.get(), j.sgf.get(), j.xf.get()
        k = np.nonzero(wf > 0)[0]
        zf = k * m.dx / 1000
        ax.plot(xf[k] / 1000, zf, color=INK, lw=1.5, label="ось струи")
        ax.plot((xf[k] - sg[k]) / 1000, zf, color=INK, lw=0.8, ls="--", label="±σ = √(σ0² + 2Kt)")
        ax.plot((xf[k] + sg[k]) / 1000, zf, color=INK, lw=0.8, ls="--")
        ax.set_ylim(0, 2.6)
        ax.set_xlim(0, min(m.pr.lx, 8000) / 1000)
        ax.set_title(sc.title, fontsize=10)
        ax.legend(frameon=False, fontsize=8, loc="upper right")
        fig.colorbar(pm, ax=ax, shrink=0.8, label="w, м/с")
    fig.suptitle("Опыт 6. Ядро струи: ось, ширина (диффузия K = 30 м²/с за время подъёма), наклон по ветру, "
                 "обрезка инверсией; у склонов — слой Прандтля")
    fig.savefig(os.path.join(OUT, "exp6_jet_anatomy.png"))
    plt.close(fig)


# ---------------------------------------------------------------- время
def exp_time():
    import cupy as cp
    b = beta()
    dev = cp.cuda.runtime.getDeviceProperties(0)["name"].decode()
    rows = []
    for name in NAMES:
        for cell in CELLS:
            _, info = load_ref(name, cell)
            j = Jet(SCENARIOS[name], cell, beta=b)
            nv = j.nv
            ms = j.timeit(300)
            ms_ng = None
            j2 = Jet(SCENARIOS[name], cell, beta=b)
            j2.compute()
            j2.stream.synchronize()
            t0 = time.perf_counter()
            for _ in range(30):
                j2.compute()
            j2.stream.synchronize()
            ms_ng = (time.perf_counter() - t0) / 30 * 1e3
            cells = int((~j.m.solid_np).sum())
            rows.append(dict(name=name, cell=cell, nx=j.m.nx, nz=j.m.nz, cells=cells, ms=ms, ms_nograph=ms_ng,
                             nv=nv, ref_wall=info["steady_wall"], ref_steps=info["steady_step"]))
            print(f"{name} {cell:g} м: {ms:.3f} мс (без графа {ms_ng:.2f}); эталон {info['steady_wall']:.2f} с", flush=True)
    # влияние числа V-циклов (сценарий 1, 25 м)
    vc = []
    (ru, rw, rt), _ = load_ref("s1_sun_one_slope", 25.0)
    for nv in (1, 2, 4, 8, 16):
        j = Jet(SCENARIOS["s1_sun_one_slope"], 25.0, beta=b, n_vcycles=nv)
        ms = j.timeit(200)
        u, w, t = j.centers()
        vc.append(dict(nv=nv, ms=ms, e_u=rel(u, ru), e_w=rel(w, rw), div=j.div_residual()))
        print(f"   V-циклов {nv}: {ms:.3f} мс, ошибка u {rel(u, ru):.3f} w {rel(w, rw):.3f}, div {j.div_residual():.1e}")
    json.dump(dict(device=dev, rows=rows, vcycles=vc), open(os.path.join(OUT, "exp6_time.json"), "w"), indent=1)
    L = [f"### Время на GPU ({dev}, CuPy RawKernel + CUDA Graph, float32; один расчёт поля; "
         f"неразрывность — {rows[0]['nv']} V-циклов многосеточного)\n",
         "| Сценарий | Клетка | Сетка (воздушных) | Ядро струи, мс (без графа) | Автомат до установления, с | Во сколько раз быстрее |",
         "|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {TITLES[r['name']]} | {r['cell']:g} м | {r['nx']}×{r['nz']} ({r['cells']}) | {r['ms']:.3f} "
                 f"({r['ms_nograph']:.1f}) | {r['ref_wall']:.2f} | {r['ref_wall'] * 1e3 / r['ms']:.0f} |")
    L += ["", "Число V-циклов (сценарий 1, 25 м):", "", "| V-циклов | мс | ошибка u | ошибка w | остаток дивергенции (отн.) |",
          "|---|---|---|---|---|"]
    for v in vc:
        L.append(f"| {v['nv']} | {v['ms']:.3f} | {v['e_u']:.3f} | {v['e_w']:.3f} | {v['div']:.1e} |")
    # 3D: пол накладных расходов (200 м) + нс на клетку по самой большой сетке ×1,5 за 3D
    big = max((r for r in rows if r["name"] == "s1_sun_one_slope"), key=lambda r: r["cells"])
    small = min((r for r in rows if r["name"] == "s1_sun_one_slope"), key=lambda r: r["cells"])
    ns_cell = (big["ms"] - small["ms"]) * 1e6 / max(big["cells"] - small["cells"], 1)
    L += ["", f"Оценка для 3D (40×40 км × {LEV3D} уровня): мс = {small['ms']:.2f} мс (пол накладных расходов) + "
          f"{ns_cell:.2f} нс на клетку (приращение 200 → 25 м в 2D) × 1,5 за 3D; эталон 3D — из общей таблицы "
          f"автомата (../out/summary.md). Струй в 3D — десятки (по максимумам размытой карты), их уравнения — "
          f"по потоку на струю, в счёт не входят.\n",
          "| Клетка | Ячеек 3D | Ядро струи 3D, мс (оценка) | Автомат 3D до установления, с (оценка базы) |", "|---|---|---|---|"]
    auto3d = {200.0: 7, 100.0: 61, 50.0: 509, 25.0: 4270}
    for c in CELLS:
        n3 = (L3D / c) ** 2 * LEV3D
        ms3 = small["ms"] + ns_cell * 1e-6 * n3 * 1.5
        L.append(f"| {c:g} м | {n3 / 1e6:.2f} млн | {ms3:.1f} | {auto3d[c]} |")
    with open(os.path.join(OUT, "exp6_time.md"), "w") as fh:
        fh.write("\n".join(L) + "\n")
    print("\n".join(L))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("what", choices=["calib", "compare", "time", "kernels", "all"])
    a = p.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if a.what in ("calib", "all"):
        exp_calib()
    if a.what in ("compare", "all"):
        exp_compare()
    if a.what in ("kernels", "all"):
        exp_kernels()
    if a.what == "time":
        exp_time()


if __name__ == "__main__":
    main()
