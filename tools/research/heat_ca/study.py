#!/usr/bin/env python3
"""Исследования: сходимость по размеру клетки (+ время на GPU, оценка для 3D) и
сравнение способов выравнивания массы (локальный Якоби против многосеточного).

  .venv/bin/python study.py cells   [--cells 200 100 50 25 12.5 6.25]
  .venv/bin/python study.py solvers
Таблицы → out/study_*.md, картинки → out/convergence/, out/solvers/.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import SCENARIOS, Params, run  # noqa: E402
import plots  # noqa: E402
from plots import SERIES, MUTED, GROUND  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
SC = "s1_sun_one_slope"
L3D = 40000.0     # 3D: квадрат 40×40 км
LEV3D = 32        # уровней по высоте
F3D = 1.5         # 3D-шаг дороже 2D на клетку: 7 соседей вместо 5, третья компонента скорости


def gpu_name():
    try:
        import cupy as cp
        return cp.cuda.runtime.getDeviceProperties(0)["name"].decode()
    except Exception:
        return "?"


def study_cells(cells, device, pressure="mg", probe_cells=(3.125,)):
    sfx = "" if pressure == "mg" else "_" + pressure
    out = os.path.join(OUT, "convergence" + sfx)
    os.makedirs(out, exist_ok=True)
    rows, fields = [], []
    for c in cells:
        pr = Params(cell=c, device=device, pressure=pressure)
        print(f"== клетка {c:g} м")
        model, _, series, info = run(SCENARIOS[SC], pr, record=False, verbose=False)
        uc, wc, thp = model.centers()
        m = plots.metrics(model, uc, wc, thp)
        ms_step = info["wall"] / info["steps"] * 1e3
        rows.append(dict(cell=c, nx=model.nx, nz=model.nz, cells=model.nx * model.nz, air=info["cells"],
                         dt=info["dt"], steady_step=info["steady_step"], steady_t=info["steady_t"],
                         steady_wall=info["steady_wall"], ms_step=ms_step, mem=info["peak_mem_mb"],
                         m_res=series[-1]["m_res"], h_res=series[-1]["h_res"], **m))
        fields.append((c, model, uc, wc, thp))
        r = rows[-1]
        print(f"   {model.nx}×{model.nz}, шагов до установления {r['steady_step']}, {r['steady_wall']:.2f} с, "
              f"{ms_step:.3f} мс/шаг, w_max {m['w_max']:.2f}, приток {m['inflow_left']:+.2f}")
    # ---- замер скорости на больших сетках (без счёта до установления): там GPU загружен
    # работой, а не ждёт запусков, — отсюда нс на клетку·шаг для оценки 3D
    probes = []
    if device == "gpu":
        import time
        from model import HeatCA
        for c in probe_cells:
            model = HeatCA(SCENARIOS[SC], Params(cell=c, device=device, pressure=pressure))
            model.capture_graph()
            for _ in range(20):
                model.step()
            model.sync()
            t0 = time.perf_counter()
            n = 300
            for _ in range(n):
                model.step()
            model.sync()
            ms = (time.perf_counter() - t0) / n * 1e3
            probes.append(dict(cell=c, nx=model.nx, nz=model.nz, cells=model.nx * model.nz, ms_step=ms,
                               mem=model.peak_mem_mb()))
            print(f"   замер {c:g} м: {model.nx}×{model.nz}, {ms:.3f} мс/шаг, {probes[-1]['mem']:.0f} МБ")
            del model
    big = max(rows + probes, key=lambda r: r["cells"])
    ns_cell = big["ms_step"] * 1e6 / big["cells"]
    floor_ms = min(r["ms_step"] for r in rows)
    bytes_cell = big["mem"] * 2**20 / big["cells"]
    for r in rows:
        n3 = (L3D / r["cell"]) ** 2 * LEV3D
        r["cells3d"] = n3
        r["ms_step3d"] = max(floor_ms, ns_cell * F3D * n3 / 1e6)
        steps = r["steady_step"] or 0
        r["t3d_s"] = steps * r["ms_step3d"] / 1e3
        r["mem3d_mb"] = bytes_cell * 1.3 * n3 / 2**20
    with open(os.path.join(out, "convergence.json"), "w") as f:
        json.dump(dict(rows=rows, probes=probes, ns_cell=ns_cell, floor_ms=floor_ms, bytes_cell=bytes_cell, gpu=gpu_name()),
                  f, ensure_ascii=False, indent=1, default=float)
    fig_cells(fields, rows, out)
    write_cells_md(rows, ns_cell, floor_ms, bytes_cell, probes, pressure)
    return rows


def fig_cells(fields, rows, out):
    # 1) w по X на 150 и 600 м над рельефом для всех клеток
    fig, axs = plt.subplots(3, 1, figsize=(10, 8.5), sharex=True,
                            gridspec_kw=dict(height_ratios=[3, 3, 1], hspace=0.15))
    colors = SERIES + ["#555555"]
    for ax, agl in zip(axs[:2], (150, 600)):
        for (c, model, uc, wc, thp), col in zip(fields, colors):
            ax.plot(model.xc / 1000, plots.sample_agl(model, wc, agl), color=col, lw=1.8, label=f"клетка {c:g} м")
        ax.axhline(0, color=MUTED, lw=0.8)
        ax.set_ylabel(f"w на {agl} м над землёй, м/с")
    axs[0].legend(frameon=False, ncol=2, loc="upper left")
    axs[0].set_title("Сходимость по клетке: сценарий 1 (солнце на крутой склон)\nвертикальная скорость по X; "
                     + ("многосеточный Пуассон" if fields[0][1].pr.pressure == "mg" else "локальный режим («медленный звук»)"))
    m0 = fields[-1][1]
    axs[2].fill_between(m0.xc / 1000, 0, m0.h, color=GROUND)
    axs[2].set_ylabel("рельеф, м")
    axs[2].set_xlabel("x поперёк хребта, км")
    fig.savefig(os.path.join(out, "conv_w_profile.png"))
    plt.close(fig)
    # 2) стрелки рядом (одинаковый масштаб)
    n = len(fields)
    ncol = 2
    nrow = (n + 1) // 2
    fig, axs = plt.subplots(nrow, ncol, figsize=(13, 2.45 * nrow), squeeze=False)
    vlim = max(np.nanmax(np.abs(f[3])) for f in fields)
    for ax, (c, model, uc, wc, thp) in zip(axs.ravel(), fields):
        plots.draw_ground(ax, model)
        q, _ = plots._quiver(ax, model, uc, wc, spacing=200.0, scale_m_per_ms=200.0, vlim=vlim)
        ax.set_ylim(0, 2.2)
        ax.set_title(f"клетка {c:g} м ({model.nx}×{model.nz})")
        ax.label_outer()
    for ax in axs.ravel()[n:]:
        ax.axis("off")
    cb = fig.colorbar(q, ax=axs, shrink=0.6, pad=0.02)
    cb.set_label("w, м/с (красное — подъём)")
    fig.suptitle("Сценарий 1 при разных клетках: стрелки через 200 м, 200 м длины = 1 м/с")
    fig.savefig(os.path.join(out, "conv_flow.png"))
    plt.close(fig)


def write_cells_md(rows, ns_cell, floor_ms, bytes_cell, probes, pressure="mg"):
    how = {"mg": "выравнивание массы — многосеточный Пуассон, 2 V-цикла на шаг",
           "acoustic": "выравнивание массы — чисто локально («медленный звук» 60 м/с)"}[pressure]
    L = []
    L.append(f"### Сходимость по клетке и время на GPU ({gpu_name()}, CuPy + CUDA Graph, float32; сценарий 1; {how})\n")
    L.append("| Клетка | Сетка (воздушных) | dt, с | Шагов до установления | Время до установления, с | мс/шаг | Память GPU, МБ | "
             "Макс. подъём, м/с (где) | Приток у подножия, м/с | Вверх по склону, м/с | Опускание в долине (ср.), м/с | Высота подъёма, м |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        L.append(f"| {r['cell']:g} м | {r['nx']}×{r['nz']} ({r['air']}) | {r['dt']:.2f} | {r['steady_step']} "
                 f"({(r['steady_t'] or 0)/60:.0f} мин) | {r['steady_wall']:.2f} | {r['ms_step']:.3f} | {r['mem']:.1f} | "
                 f"{r['w_max']:.2f} ({r['w_max_x']/1000:.2f} км, {r['w_max_agl']:.0f} м) | {r['inflow_left']:+.2f} | "
                 f"{r['upslope_left']:+.2f} | {r['w_mean_valley_left']:+.3f} | {r['ascent_top_z']:.0f} |")
    for pb in probes:
        L.append(f"| {pb['cell']:g} м (только замер скорости) | {pb['nx']}×{pb['nz']} | | | | {pb['ms_step']:.3f} | "
                 f"{pb['mem']:.0f} | | | | | |")
    L.append("")
    L.append(f"Оценка для 3D (квадрат 40×40 км × {LEV3D} уровня, та же физика, тот же GPU): мс/шаг = "
             f"max({floor_ms:.2f} мс — пол накладных расходов, {ns_cell:.2f} нс на клетку·шаг по самой большой 2D-сетке × {F3D} за 3D); "
             f"шагов — как в 2D при той же клетке; память — {bytes_cell:.0f} байт на клетку × 1,3.\n")
    L.append("| Клетка | Ячеек 3D | мс/шаг (оценка) | Шагов | До установления, с (оценка) | Память как в прототипе, МБ | Память компактно (~64 байт/клетка), МБ |")
    L.append("|---|---|---|---|---|---|---|")
    for r in rows:
        if r["cell"] < 25:
            continue
        L.append(f"| {r['cell']:g} м | {r['cells3d']/1e6:.2f} млн | {r['ms_step3d']:.1f} | {r['steady_step']} | "
                 f"{r['t3d_s']:.0f} | {r['mem3d_mb']:.0f} | {64 * r['cells3d'] / 2**20:.0f} |")
    L.append("")
    L.append("Прототип держит в пуле CuPy все временные массивы шага (CUDA Graph) — отсюда ~430 байт на клетку; "
             "в вычислительном шейдере нужно ~12–16 чисел float32 на клетку (u, v, w, m, H, p, правая часть, невязка, "
             "уровни многосеточного) ≈ 64 байт.")
    with open(os.path.join(OUT, "study_cells" + ("" if pressure == "mg" else "_" + pressure) + ".md"), "w") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L))


def label(meth, it, kw, long=False):
    if meth == "mg":
        return "многосеточный V-цикл (Пуассон)" if long else f"mg × {it}"
    if meth == "jacobi":
        a = kw.get("mass_relax", 1.0)
        if long:
            return f"Якоби, локальные итерации давления, {'снимать накопленный избыток массы' if a else 'без возврата накопленной массы'}"
        return f"Якоби × {it}, возврат массы {a:g}"
    if meth == "acoustic":
        c = kw.get("sound_c")
        return f"локально: «медленный звук» c = {c:g} м/с" if long else f"локально c={c:g}"
    return meth


def study_solvers(device, cell=50.0):
    out = os.path.join(OUT, "solvers")
    os.makedirs(out, exist_ok=True)
    variants = [("mg", 1, {}), ("mg", 2, {}), ("mg", 4, {}),
                ("jacobi", 50, {"mass_relax": 1.0}),
                ("jacobi", 50, {"mass_relax": 0.0}), ("jacobi", 500, {"mass_relax": 0.0}),
                ("acoustic", 0, {"sound_c": 30.0}), ("acoustic", 0, {"sound_c": 60.0}),
                ("acoustic", 0, {"sound_c": 120.0})]
    rows, fields = [], []
    for meth, it, kw in variants:
        pr = Params(cell=cell, device=device, pressure=meth, p_iters=it, **kw)
        print(f"== {meth} × {it} {kw}")
        try:
            model, _, series, info = run(SCENARIOS[SC], pr, record=False, verbose=False)
        except RuntimeError as e:
            print("   ", e)
            rows.append(dict(meth=meth, it=it, kw=kw, fail=str(e)))
            continue
        uc, wc, thp = model.centers()
        m = plots.metrics(model, uc, wc, thp)
        manom = max(s["m_anom"] for s in series[len(series) // 4:])
        if meth == "acoustic":
            it = model.n_sub
        rows.append(dict(meth=meth, it=it, kw=kw, steady_step=info["steady_step"], steady_wall=info["steady_wall"],
                         ms_step=info["wall"] / info["steps"] * 1e3, m_anom=manom, m_res=series[-1]["m_res"], **m))
        fields.append((label(meth, it, kw), model, wc))
        r = rows[-1]
        print(f"   макс |m−1| {manom:.1e}, w_max {m['w_max']:.2f}, шагов {r['steady_step']}, {r['ms_step']:.3f} мс/шаг")
    # картинка: w на 300 м над землёй
    fig, ax = plt.subplots(figsize=(10, 4.5))
    cols = SERIES + ["#555555", "#9b59b6"]
    for (lab, model, wc), c in zip(fields, cols):
        ax.plot(model.xc / 1000, plots.sample_agl(model, wc, 300), color=c, lw=1.6, label=lab)
    ax.axhline(0, color=MUTED, lw=0.8)
    ax.set_xlabel("x поперёк хребта, км")
    ax.set_ylabel("w на 300 м над землёй, м/с")
    ax.legend(frameon=False, ncol=4, fontsize=8)
    ax.set_title("Способ выравнивания массы: многосеточный Пуассон (mg), итерации Якоби, локальный «медленный звук»\n"
                 f"сценарий 1, клетка {cell:g} м")
    fig.savefig(os.path.join(out, "solvers_w300.png"))
    plt.close(fig)
    L = [f"### Выравнивание массы: сколько итераций нужно (сценарий 1, клетка {cell:g} м, GPU)\n",
         "| Способ | Итераций (подшагов) на шаг | Макс. |m−1| в клетке (недовыравнено) | Шагов до установления | мс/шаг | Макс. подъём, м/с | Приток у подножия, м/с | Высота подъёма, м |",
         "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if "fail" in r:
            L.append(f"| {label(r['meth'], r['it'], r['kw'], long=True)} | {r['it']} | {r['fail']} | | | | | |")
            continue
        L.append(f"| {label(r['meth'], r['it'], r['kw'], long=True)} | {r['it']} | {r['m_anom']:.1e} | {r['steady_step']} | {r['ms_step']:.3f} | "
                 f"{r['w_max']:.2f} | {r['inflow_left']:+.2f} | {r['ascent_top_z']:.0f} |")
    with open(os.path.join(OUT, "study_solvers.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L))


def tables_from_json(pressure="mg"):
    sfx = "" if pressure == "mg" else "_" + pressure
    d = json.load(open(os.path.join(OUT, "convergence" + sfx, "convergence.json")))
    write_cells_md(d["rows"], d["ns_cell"], d["floor_ms"], d["bytes_cell"], d.get("probes", []), pressure)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("what", choices=["cells", "solvers", "all", "tables"])
    p.add_argument("--cells", type=float, nargs="+", default=[200, 100, 50, 25, 12.5, 6.25])
    p.add_argument("--device", choices=["gpu", "cpu"], default="gpu")
    p.add_argument("--pressure", choices=["mg", "acoustic"], default="mg")
    a = p.parse_args()
    if a.what == "tables":
        tables_from_json(a.pressure)
    if a.what in ("cells", "all"):
        study_cells(a.cells, a.device, a.pressure)
    if a.what in ("solvers", "all"):
        study_solvers(a.device)


if __name__ == "__main__":
    main()
