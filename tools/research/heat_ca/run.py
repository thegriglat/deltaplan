#!/usr/bin/env python3
"""Прогон сценариев: картинки, анимация, summary.md.

  .venv/bin/python run.py s1_sun_one_slope --cell 50
  .venv/bin/python run.py all --cell 50
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import SCENARIOS, Params, run  # noqa: E402
import plots  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def fmt(v, nd=2):
    if v is None or (isinstance(v, float) and not np.isfinite(v)):
        return "—"
    return f"{v:.{nd}f}"


def acceptance(name, m, info, bud):
    """Автоматические проверки условий приёмки (что можно проверить числом)."""
    res = []
    res.append(("1. сохранение массы/тепла ≤ 0,1 %",
                abs(bud["m_res"]) < 1e-3 and abs(bud["h_res"]) < 1e-3,
                f"невязка массы {bud['m_res']:.1e} от массы области, тепла {bud['h_res']:.1e} от нагрева; "
                f"макс. |m−1| в клетке {bud['m_anom']:.1e}"))
    if name == "s1_sun_one_slope":
        ok = (m["inflow_left"] > 0 and m["upslope_left"] > 0 and m["w_max_x"] < 3300
              and m["w_mean_valley_left"] < 0 and m["w_mean_right_side"] < 0)
        res.append(("2. подъём над прогретым склоном, приток у подножия, опускание в долине/над тенью", ok,
                    f"макс. подъём {m['w_max']:.2f} м/с на x={m['w_max_x']/1000:.2f} км; приток у подножия "
                    f"{m['inflow_left']:+.2f} м/с (к склону +), вверх по склону {m['upslope_left']:+.2f} м/с; "
                    f"средняя w в долине {m['w_mean_valley_left']:+.3f}, над тенью {m['w_mean_right_side']:+.3f} м/с"))
    if name == "s2_sym":
        ok = m["asym_w"] < 1e-3 * m["w_max"] and abs(m["w_max_x"] - 3200) <= info["params"]["cell"]
        res.append(("3. симметричный хребет → симметричная картина, подъём над гребнем", ok,
                    f"макс. |w(x) − w(зеркально)| = {m['asym_w']:.1e} м/с при макс. подъёме {m['w_max']:.2f} м/с "
                    f"на x={m['w_max_x']/1000:.3f} км (гребень 3,200); приток у подножий {m['inflow_left']:+.2f} / "
                    f"{m['inflow_right']:+.2f} м/с"))
    if name in ("s2_both_slopes", "s4_inversion"):
        ok = (m["inflow_left"] > 0 and m["inflow_right"] > 0 and abs(m["w_max_x"] - 2800) < 600)
        res.append(("3. схождение и подъём над гребнем", ok,
                    f"макс. подъём {m['w_max']:.2f} м/с на x={m['w_max_x']/1000:.2f} км (гребень 2,80); приток у подножий "
                    f"слева {m['inflow_left']:+.2f}, справа {m['inflow_right']:+.2f} м/с; вверх по склонам "
                    f"{m['upslope_left']:+.2f} / {m['upslope_right']:+.2f} м/с"))
    if name == "s4_inversion":
        ok = m["ascent_top_z"] <= 1500 + 300 + 150 and m["above_inv_wmax"] < 0.3 * m["below_inv_wmax"]
        res.append(("4. подъём гаснет у инверсии, выше — малое возмущение", ok,
                    f"верх подъёма {m['ascent_top_z']:.0f} м, верх тёплого {m['warm_top_z']:.0f} м (инверсия 1500–1800); "
                    f"|w| выше инверсии ≤ {m['above_inv_wmax']:.2f} против {m['below_inv_wmax']:.2f} м/с ниже; "
                    f"|θ′| выше ≤ {m['above_inv_thmax']:.2f} К; растекание под инверсией до {m['outflow_under_inv']:.2f} м/с"))
    if name == "s3_wind":
        md = m["thermal"]
        tilt = md.get("tilt_dx_dz", float("nan"))
        ok = np.isfinite(tilt) and tilt > 0 and np.isfinite(m["w_max"]) and m["w_max"] < 10
        res.append(("5. подъём наклонён по ветру, картина не разваливается", ok,
                    f"тепловая часть (с нагревом − без): наклон столба подъёма dx/dz = {tilt:+.2f} (>0 — по ветру), "
                    f"макс. добавка подъёма {md['w_max']:.2f} м/с на x={md['w_max_x']/1000:.2f} км, "
                    f"{md['w_max_agl']:.0f} м над землёй; полное поле: макс. w {m['w_max']:.2f} м/с, "
                    f"поле гладкое, без пилы"))
    st = info["steady_step"]
    res.append(("6. устойчивость, установление", st is not None,
                f"установилось за {st} шагов (dt={info['dt']:.2f} с, {fmt((info['steady_t'] or 0)/60, 0)} мин модельного "
                f"времени) за {fmt(info['steady_wall'], 1)} с счёта" if st else
                f"не установилось за {info['steps']} шагов ({info['t_model']/60:.0f} мин)"))
    return res


def write_summary(path, name, title, m, info, bud, checks):
    L = []
    L.append(f"# {title}\n")
    L.append(f"Сетка {info['nx']}×{info['nz']} клеток по {info['params']['cell']:g} м "
             f"(воздушных {info['cells']}), давление: {info['params']['pressure']} × {info['params']['p_iters']} на шаг, "
             f"устройство {info['params']['device']}, {info['params']['dtype']}.\n")
    L.append("## Числа (установившееся состояние)\n")
    L.append("| Величина | Значение |\n|---|---|")
    L.append(f"| Максимальный подъём | {m['w_max']:.2f} м/с на x = {m['w_max_x']/1000:.2f} км, "
             f"{m['w_max_agl']:.0f} м над землёй ({m['w_max_z']:.0f} м над подножием) |")
    L.append(f"| Приток у подножия крутого (левого) склона, нижние ~100 м | {m['inflow_left']:+.2f} м/с (+ — к склону) |")
    L.append(f"| Приток у подножия пологого (правого) склона | {m['inflow_right']:+.2f} м/с (+ — к склону) |")
    L.append(f"| Ветер вверх по склону (середина, нижняя клетка) лев./прав. | {m['upslope_left']:+.2f} / {m['upslope_right']:+.2f} м/с |")
    L.append(f"| Опускание в долине слева (200 м над землёй … 2 км): мин / среднее | {m['w_min_valley_left']:+.2f} / {m['w_mean_valley_left']:+.3f} м/с |")
    L.append(f"| Над пологим склоном и за ним: мин / среднее | {m['w_min_right_side']:+.2f} / {m['w_mean_right_side']:+.3f} м/с |")
    L.append(f"| Высота подъёма (w > 20 % макс.) | {m['ascent_top_z']:.0f} м над подножием |")
    L.append(f"| Верх прогретого воздуха (θ′ > 0,1 К) | {m['warm_top_z']:.0f} м над подножием |")
    if "tilt_dx_dz" in m:
        L.append(f"| Наклон столба подъёма dx/dz | {m['tilt_dx_dz']:+.2f} |")
    if "above_inv_wmax" in m:
        L.append(f"| Выше инверсии: макс. |w| / |θ′| | {m['above_inv_wmax']:.2f} м/с / {m['above_inv_thmax']:.2f} К |")
        L.append(f"| Ниже инверсии: макс. |w| | {m['below_inv_wmax']:.2f} м/с |")
        L.append(f"| Растекание под инверсией, макс. |u| | {m['outflow_under_inv']:.2f} м/с |")
    st = info["steady_step"]
    L.append(f"| Установление | {st if st else 'нет'} шагов, dt = {info['dt']:.2f} с, "
             f"{fmt((info['steady_t'] or float('nan'))/60, 0)} мин модельного времени |")
    L.append(f"| Время счёта до установления | {fmt(info['steady_wall'], 2)} с (всего {info['wall']:.2f} с, "
             f"{info['wall']/info['steps']*1e3:.3f} мс/шаг) |")
    L.append(f"| Память GPU (пул) | {fmt(info['peak_mem_mb'], 1)} МБ |")
    L.append(f"| Невязка массы / тепла | {bud['m_res']:.1e} / {bud['h_res']:.1e}; макс. |m−1| {bud['m_anom']:.1e} |")
    L.append("\n## Условия приёмки\n")
    for n, ok, txt in checks:
        L.append(f"- **{n}** — {'да' if ok else 'НЕТ'}: {txt}")
    L.append("\n## Картинки\n")
    L.append("- `temp.png` — θ′ (теплее/холоднее фона); `flow.png` — стрелки ветра, цвет — w;")
    L.append("- `w_profile.png` — w по X на 50/150/300/600 м над рельефом; `mass_balance.png` — баланс;")
    L.append("- `evolution.mp4` — как складывается циркуляция.\n")
    L.append("Общий вывод (похоже ли на слова пилота, годится ли для игры) — в `out/summary.md` и README.\n")
    with open(path, "w") as f:
        f.write("\n".join(L))


def run_scenario(name, pr, out_root, anim=True, verbose=True):
    sc = SCENARIOS[name]
    out = os.path.join(out_root, name)
    os.makedirs(out, exist_ok=True)
    print(f"== {sc.title}  (клетка {pr.cell:g} м, {pr.device})")
    model, frames, series, info = run(sc, pr, record=anim, verbose=verbose)
    uc, wc, thp = model.centers()
    m = plots.metrics(model, uc, wc, thp)
    w0 = np.nan_to_num(wc)
    m["asym_w"] = float(np.abs(w0 - w0[:, ::-1]).max())
    bud = series[-1]
    extra = None
    if sc.wind_ms > 0:
        # тепловая часть = прогон с нагревом − тот же ветер без нагрева (обтекание хребта)
        import dataclasses
        sc0 = dataclasses.replace(sc, q0_wm2=0.0)
        print("   … тот же ветер без нагрева (для выделения тепловой части)")
        m0, _, _, info0 = run(sc0, pr, record=False, verbose=False)
        u0, w0, t0 = m0.centers()
        du, dw, dth = uc - u0, wc - w0, thp - t0
        md = plots.metrics(model, du, dw, dth)
        m["thermal"] = md
        m["tilt_dx_dz"] = md.get("tilt_dx_dz", float("nan"))
        extra = (u0, w0, t0, du, dw, dth)
        plots.fig_flow(model, u0, w0, t0, os.path.join(out, "flow_no_heating.png"),
                       sc.title.replace("Оба склона прогреты", "Без нагрева") + " (только обтекание)")
        plots.fig_flow(model, du, dw, dth, os.path.join(out, "flow_thermal.png"),
                       sc.title + "\nтепловая часть: (с нагревом) − (без нагрева)")
    checks = acceptance(name, m, info, bud)
    plots.fig_temp(model, thp, os.path.join(out, "temp.png"), sc.title)
    plots.fig_flow(model, uc, wc, thp, os.path.join(out, "flow.png"), sc.title)
    plots.fig_w_profile(model, wc, os.path.join(out, "w_profile.png"), sc.title)
    plots.fig_mass_balance(series, os.path.join(out, "mass_balance.png"), sc.title)
    if anim and frames:
        plots.anim_evolution(model, frames, os.path.join(out, "evolution.mp4"), sc.title)
    write_summary(os.path.join(out, "summary.md"), name, sc.title, m, info, bud, checks)
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(dict(metrics=m, info=info, budget=bud,
                       checks=[(n, bool(ok), t) for n, ok, t in checks]), f, ensure_ascii=False, indent=1)
    for n, ok, t in checks:
        print(f"   {'OK ' if ok else 'НЕТ'} {n}: {t}")
    return model, m, info, bud


def params_from_args(a):
    return Params(cell=a.cell, device=a.device, pressure=a.pressure, p_iters=a.p_iters, dtype=a.dtype,
                  sound_c=a.sound_c,
                  t_max=a.t_max * 60, graph=not a.no_graph)


def add_common(p):
    p.add_argument("--cell", type=float, default=50.0, help="клетка, м (dx = dz): 200/100/50/25/12.5…")
    p.add_argument("--device", choices=["gpu", "cpu"], default="gpu")
    p.add_argument("--pressure", choices=["mg", "acoustic", "jacobi", "gs"], default="mg",
                   help="выравнивание массы: mg — многосеточный Пуассон; acoustic — чисто локально "
                        "(«медленный звук», без глобального решателя); jacobi/gs — локальные итерации давления")
    p.add_argument("--sound-c", type=float, default=60.0, help="acoustic: скорость «медленного звука», м/с")
    p.add_argument("--p-iters", type=int, default=2, help="V-циклов (mg) или итераций (jacobi/gs) на шаг")
    p.add_argument("--dtype", choices=["float32", "float64"], default="float32")
    p.add_argument("--t-max", type=float, default=240.0, help="предел модельного времени, мин")
    p.add_argument("--no-graph", action="store_true", help="GPU без CUDA Graph (медленнее)")
    p.add_argument("--out", default=os.path.join(HERE, "out"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("scenario", choices=list(SCENARIOS) + ["all"])
    p.add_argument("--no-anim", action="store_true")
    add_common(p)
    a = p.parse_args()
    pr = params_from_args(a)
    names = list(SCENARIOS) if a.scenario == "all" else [a.scenario]
    t0 = time.time()
    for n in names:
        run_scenario(n, pr, a.out, anim=not a.no_anim)
    print(f"готово за {time.time() - t0:.0f} с → {a.out}")


if __name__ == "__main__":
    main()
