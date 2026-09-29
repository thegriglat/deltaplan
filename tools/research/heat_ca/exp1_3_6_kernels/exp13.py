#!/usr/bin/env python3
"""Опыты 1 и 3: линейность отклика автомата и «один широкий слой» (ядра).

  ../.venv/bin/python exp13.py linear    # 1. F(A+B) против F(A)+F(B) при 15/60/250/600 Вт/м²
  ../.venv/bin/python exp13.py kernels   # 3. ядра (точечный нагрев) и сборка сценария 1 из ядер
  ../.venv/bin/python exp13.py all

Все прогоны автомата — до ОДНОГО и того же модельного времени T_FIX = 8 ч (≈ 4τ выхолаживания),
без досрочной остановки: у штатного критерия установления порог абсолютный (0,02 м/с за 10 мин), и слабые
отклики (слабый нагрев, один столбец) «устанавливались» уже за 30–40 мин — задолго до настоящего
установления (тёплый «бассейн» копится часами). Предварительный заход координатора сравнивал такие
недосчитанные поля — его числа для слабого нагрева и для ядер поэтому не годятся (см. summary.md).

Кеш прогонов: out/cache/t8h_*.npz. Картинки и таблицы: out/.
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
from model import SCENARIOS, Params, run, HeatCA  # noqa: E402
import plots  # noqa: E402
from plots import SERIES, MUTED, INK  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import TwoSlopeNorm  # noqa: E402

OUT = os.path.join(HERE, "out")
CACHE = os.path.join(OUT, "cache")
T_FIX = 8 * 3600.0
REFS = os.path.join(HERE, "..", "out", "refs")


def rel(a, b):
    ok = np.isfinite(a) & np.isfinite(b)
    return float(np.linalg.norm(a[ok] - b[ok]) / max(np.linalg.norm(b[ok]), 1e-12))


def fixed_run(sc, cell, tag):
    """Прогон автомата до T_FIX без досрочной остановки (с кешем)."""
    os.makedirs(CACHE, exist_ok=True)
    f = os.path.join(CACHE, f"t8h_{tag}_{cell:g}.npz")
    if os.path.exists(f):
        z = np.load(f)
        return z["uc"], z["wc"], z["th"], json.loads(str(z["info"]))
    pr = Params(cell=cell, t_max=T_FIX, steady_dv=0.0, steady_dT=0.0)
    model, _, series, info = run(sc, pr, record=False, verbose=False)
    uc, wc, th = model.centers()
    meta = dict(steps=info["steps"], t=info["t_model"], wall=info["wall"], ms_step=info["wall"] / info["steps"] * 1e3,
                h_res=series[-1]["h_res"])
    np.savez_compressed(f, uc=uc, wc=wc, th=th, info=json.dumps(meta))
    print(f"   прогон {tag} {cell:g} м: {info['steps']} шагов, {info['wall']:.1f} с", flush=True)
    return uc, wc, th, meta


def settle_check(sc, cell, tag):
    """Насколько поле при T_FIX отличается от поля при T_FIX − 1 ч (оценка недоустановления)."""
    f = os.path.join(CACHE, f"t7h_{tag}_{cell:g}.npz")
    if not os.path.exists(f):
        pr = Params(cell=cell, t_max=T_FIX - 3600.0, steady_dv=0.0, steady_dT=0.0)
        model, _, _, _ = run(sc, pr, record=False, verbose=False)
        uc, wc, th = model.centers()
        np.savez_compressed(f, uc=uc, wc=wc, th=th)
    z = np.load(f)
    a = fixed_run(sc, cell, tag)
    return [rel(z[k], a[j]) for j, k in enumerate(("uc", "wc", "th"))]


# ================================================================ 1. линейность
def exp_linear(cell=50.0):
    os.makedirs(OUT, exist_ok=True)
    base = SCENARIOS["s1_sun_one_slope"]
    pr = Params(cell=cell)
    foot, crest = pr.ridge_x - pr.half_left, pr.ridge_x
    mid = 0.5 * (foot + crest)
    segs = {"A": [(foot, mid)], "B": [(mid, crest)], "AB": [(foot, crest)]}
    strengths = [("очень слабый", 15.0), ("слабый", 60.0), ("средний", 250.0), ("сильный", 600.0)]
    rows, maps = [], {}
    for lab, q in strengths:
        F = {}
        for k, sg in segs.items():
            sc = dataclasses.replace(base, name=f"lin_{k}_{q:g}", heating="sun_segments", segments=tuple(sg),
                                     q0_wm2=q, q_diffuse=0.0)
            F[k] = fixed_run(sc, cell, f"lin_{k}_{q:g}")[:3]
        e = {nm: rel(F["A"][j] + F["B"][j], F["AB"][j]) for j, nm in enumerate(("u", "w", "th"))}
        wmax = float(np.nanmax(F["AB"][1]))
        thmax = float(np.nanmax(F["AB"][2]))
        rows.append(dict(label=lab, q=q, wmax=wmax, thmax=thmax, **e))
        print(f"   {lab} {q:g} Вт/м²: ошибка суперпозиции u {e['u']:.1%}, w {e['w']:.1%}, θ′ {e['th']:.1%}; "
              f"w_max {wmax:.2f}", flush=True)
        maps[q] = F
    sc_ab = dataclasses.replace(base, name="lin_AB_250", heating="sun_segments", segments=tuple(segs["AB"]),
                                q0_wm2=250.0, q_diffuse=0.0)
    unsettled = settle_check(sc_ab, cell, "lin_AB_250")
    model = HeatCA(base, dataclasses.replace(pr, device="cpu"))
    d, xe, ze = plots.grid_info(model)

    # карта: для w, u, θ′ — A+B, A+B суперпозицией, разность (250 Вт/м²) + разность при 15 Вт/м²
    fig, axs = plt.subplots(3, 4, figsize=(19, 9.2), constrained_layout=True)
    for r, (j, nm, unit) in enumerate(((1, "w", "м/с"), (0, "u", "м/с"), (2, "θ′", "К"))):
        for c, (q, kind) in enumerate(((250.0, "AB"), (250.0, "sum"), (250.0, "diff"), (15.0, "diff"))):
            F = maps[q]
            ab = F["AB"][j]
            sm = F["A"][j] + F["B"][j]
            f = {"AB": ab, "sum": sm, "diff": ab - sm}[kind]
            lim = float(np.nanmax(np.abs(ab)))
            if nm == "θ′":
                lim = float(np.nanpercentile(np.abs(ab), 99.5))
            ax = axs[r, c]
            pm = ax.pcolormesh(xe / 1000, ze / 1000, f, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim))
            plots.draw_ground(ax, model, stair=False)
            ax.set_ylim(0, 2.4)
            for xv in (foot, mid, crest):
                ax.axvline(xv / 1000, color=MUTED, lw=0.6, ls=":")
            t = {"AB": f"{nm}: нагрев A+B (автомат)", "sum": f"{nm}(A) + {nm}(B) — суперпозиция",
                 "diff": f"разность = нелинейная часть"}[kind]
            ax.set_title(f"{t}, {q:g} Вт/м²", fontsize=10)
            ax.label_outer()
            fig.colorbar(pm, ax=ax, shrink=0.85, label=f"{nm}, {unit}")
    fig.suptitle(f"Опыт 1. Линейность: A — нижняя половина солнечного склона, B — верхняя (клетка {cell:g} м, "
                 f"поля через 8 ч). Шкала каждой строки — по полю A+B этой силы нагрева")
    fig.savefig(os.path.join(OUT, "exp1_linearity_map.png"))
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(7.5, 4.2))
    qs = [r["q"] for r in rows]
    for c, nm, lab in zip(SERIES, ("w", "u", "th"), ("w", "u", "θ′")):
        ax.plot(qs, [100 * r[nm] for r in rows], "o-", color=c, lw=2, ms=7, label=lab)
    ax.set_xscale("log")
    ax.set_xticks(qs)
    ax.set_xticklabels([f"{q:g}" for q in qs])
    ax.set_xlabel("поток тепла от солнца при нормальном падении, Вт/м² (лог. шкала)")
    ax.set_ylabel("‖F(A+B) − F(A) − F(B)‖ / ‖F(A+B)‖, %")
    ax.set_ylim(0, None)
    ax.grid(axis="y", color="#e5e5e5")
    ax.legend(frameon=False)
    ax2 = ax.twiny()
    ax2.set_xscale("log")
    ax2.set_xlim(ax.get_xlim())
    ax2.set_xticks(qs)
    ax2.set_xticklabels([f"{r['wmax']:.2f}" for r in rows], color=MUTED)
    ax2.set_xlabel("макс. подъём A+B, м/с", color=MUTED)
    ax2.minorticks_off()
    ax.minorticks_off()
    ax.set_title("Опыт 1. Ошибка суперпозиции против силы нагрева", pad=28)
    fig.savefig(os.path.join(OUT, "exp1_linearity_vs_strength.png"))
    plt.close(fig)

    L = [f"| Нагрев | Макс. подъём A+B, м/с | Макс. θ′ A+B, К | Ошибка суперпозиции w | u | θ′ |",
         "|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {r['label']}, {r['q']:g} Вт/м² | {r['wmax']:.2f} | {r['thmax']:.2f} | {r['w']:.1%} | "
                 f"{r['u']:.1%} | {r['th']:.1%} |")
    L.append("")
    L.append(f"Недоустановление (поле 8 ч против 7 ч, A+B 250 Вт/м²): u {unsettled[0]:.1%}, w {unsettled[1]:.1%}, "
             f"θ′ {unsettled[2]:.1%}.")
    with open(os.path.join(OUT, "exp1_linear.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    json.dump(dict(rows=rows, unsettled=unsettled), open(os.path.join(OUT, "exp1_linear.json"), "w"), indent=1)
    print("\n".join(L))
    return rows


# ================================================================ 3. ядра
def decay_radius(model, f, x0, cell):
    X, Z = np.meshgrid(model.xc, model.zc)
    z0 = model.terrain(np.array([x0]))[0]
    R = np.hypot(X - x0, Z - z0)
    a = np.nan_to_num(np.abs(f))
    bins = np.arange(0, 7000, cell)
    env = np.array([a[(R >= b) & (R < b + cell)].max() if ((R >= b) & (R < b + cell)).any() else 0 for b in bins])
    env = np.maximum.accumulate(env[::-1])[::-1] / max(env.max(), 1e-12)
    r5 = float(bins[np.argmax(env < 0.05)]) if (env < 0.05).any() else float("nan")
    r1 = float(bins[np.argmax(env < 0.01)]) if (env < 0.01).any() else float("nan")
    return r5, r1, bins, env


def exp_kernels(cell=50.0, cell_rec=100.0):
    os.makedirs(OUT, exist_ok=True)
    base = SCENARIOS["s1_sun_one_slope"]
    pr = Params(cell=cell, device="cpu")
    spots = {"равнина (x = 0,8 км)": 800.0, "середина склона (x = 2,2 км)": 2200.0, "у гребня (x = 2,75 км)": 2750.0}
    Q = 250.0
    kern = {}
    model = HeatCA(base, pr)
    for lab, x in spots.items():
        sc = dataclasses.replace(base, name=f"pt_{x:g}", heating="point", point_x=x, q0_wm2=Q, q_diffuse=0.0)
        kern[lab] = fixed_run(sc, cell, f"pt_{x:g}")[:3]
    d, xe, ze = plots.grid_info(model)
    dec = {}
    fig, axs = plt.subplots(len(spots), 3, figsize=(19, 9.5), constrained_layout=True)
    for r, (lab, (u, w, th)) in enumerate(kern.items()):
        x0 = spots[lab]
        dec[lab] = {}
        for c, (f, nm, unit, sc_) in enumerate(((w, "w", "см/с", 100), (u, "u", "см/с", 100), (th, "θ′", "мК", 1000))):
            ax = axs[r, c]
            lim = float(np.nanmax(np.abs(f)))
            pm = ax.pcolormesh(xe / 1000, ze / 1000, f * sc_, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim * sc_, lim * sc_))
            plots.draw_ground(ax, model, stair=False)
            ax.set_ylim(0, 2.6)
            ax.plot([x0 / 1000], [model.terrain(np.array([x0]))[0] / 1000 + 0.06], "v", color=INK, ms=8, zorder=9)
            r5, r1, bins, env = decay_radius(model, f, x0, cell)
            dec[lab][nm] = dict(r5=r5, r1=r1, peak=lim, env=env.tolist(), bins=bins.tolist())
            ax.set_title(f"{nm}, источник: {lab}; пик {lim * sc_:.1f} {unit}", fontsize=10)
            ax.label_outer()
            fig.colorbar(pm, ax=ax, shrink=0.85, label=f"{nm}, {unit}")
    fig.suptitle(f"Опыт 3. Ядра: установившийся отклик на нагрев одного столбца ({cell:g} м) потоком {Q:g} Вт/м², 8 ч")
    fig.savefig(os.path.join(OUT, "exp3_kernels.png"))
    plt.close(fig)

    fig, axs = plt.subplots(1, 3, figsize=(15, 4), constrained_layout=True)
    for ax, nm in zip(axs, ("w", "u", "θ′")):
        for c, (lab, dd) in zip(SERIES, dec.items()):
            ax.semilogy(np.array(dd[nm]["bins"]) / 1000, np.maximum(dd[nm]["env"], 1e-4), color=c, lw=2, label=lab)
        ax.axhline(0.05, color=MUTED, ls=":", lw=1)
        ax.axhline(0.01, color=MUTED, ls="--", lw=1)
        ax.set_xlabel("расстояние от источника, км")
        ax.set_ylabel(f"макс. |{nm}| дальше этого расстояния / пик")
        ax.set_ylim(1e-3, 1.2)
        ax.set_title(f"затухание ядра {nm}")
    axs[0].legend(frameon=False, fontsize=9)
    fig.suptitle("Опыт 3. Затухание ядер: уровни 5 % (точки) и 1 % (штрих)")
    fig.savefig(os.path.join(OUT, "exp3_kernel_decay.png"))
    plt.close(fig)

    # ---- сборка сценария 1 из ядер (клетка cell_rec)
    prr = Params(cell=cell_rec, device="cpu")
    mr = HeatCA(base, prr)
    ref = fixed_run(base, cell_rec, "s1_sun_one_slope")[:3]
    zr = np.load(os.path.join(REFS, f"s1_sun_one_slope_{cell_rec:g}.npz"))
    e_ref8 = [rel(ref[j], zr[k]) for j, k in enumerate(("uc", "wc", "th"))]
    q = mr.q_np * 1.2 * 1005            # Вт/м² по столбцам
    cols = np.nonzero(q > 1e-6)[0]
    Ks = {}
    for i in cols:
        xi = mr.xc[i]
        sc = dataclasses.replace(base, name=f"pt_{xi:g}", heating="point", point_x=xi, q0_wm2=Q, q_diffuse=0.0)
        Ks[i] = [np.nan_to_num(a) for a in fixed_run(sc, cell_rec, f"pt_{xi:g}")[:3]]
    # матрица ядер: (3·клеток) × (нагретых столбцов) — «один широкий слой»
    Kmat = np.stack([np.concatenate([Ks[i][j].ravel() for j in range(3)]) for i in cols], axis=1)
    lin_flat = Kmat @ (q[cols] / Q)
    n = mr.nz * mr.nx
    lin = [np.where(mr.solid_np, np.nan, lin_flat[j * n:(j + 1) * n].reshape(mr.nz, mr.nx)) for j in range(3)]
    # цена одной свёртки на GPU
    import cupy as cp
    Kg = cp.asarray(Kmat, cp.float32)
    qg = cp.asarray(q[cols] / Q, cp.float32)
    for _ in range(3):
        Kg @ qg
    cp.cuda.Device().synchronize()
    t0 = time.perf_counter()
    for _ in range(200):
        Kg @ qg
    cp.cuda.Device().synchronize()
    t_mv = (time.perf_counter() - t0) / 200 * 1e3
    mem_mb = Kmat.size * 4 / 2**20

    # три ядра (равнина/склон/гребень), сдвинутые к столбцу-источнику
    cls_x = {"flat": 800.0, "slope": 2200.0, "crest": 2750.0}
    cls_i = {c: int(np.argmin(np.abs(mr.xc - x))) for c, x in cls_x.items()}

    def cls(i):
        x = mr.xc[i]
        if abs(mr.hx[i]) < 0.08:
            return "flat" if abs(x - prr.ridge_x) > 400 else "crest"
        return "crest" if abs(x - prr.ridge_x) < 300 else "slope"
    conv = [np.zeros((mr.nz, mr.nx)) for _ in range(3)]
    for i in cols:
        i0 = cls_i[cls(i)]
        k = Ks[i0]
        di = i - i0
        dk = mr.kb[i] - mr.kb[i0]
        for j in range(3):
            src = k[j]
            sh = np.zeros_like(src)
            ys = slice(max(0, dk), mr.nz + min(0, dk))
            yd = slice(max(0, -dk), mr.nz + min(0, -dk))
            xs = slice(max(0, di), mr.nx + min(0, di))
            xd = slice(max(0, -di), mr.nx + min(0, -di))
            sh[ys, xs] = src[yd, xd]
            conv[j] += sh * q[i] / Q
    conv = [np.where(mr.solid_np, np.nan, c) for c in conv]
    e_lin = [rel(lin[j], ref[j]) for j in range(3)]
    e_conv = [rel(conv[j], ref[j]) for j in range(3)]
    ml = plots.metrics(mr, *lin)
    mc = plots.metrics(mr, *conv)
    mref = plots.metrics(mr, *ref)
    # во сколько раз надо усилить линейную сборку, чтобы совпал подъём (для справки)
    gain = mref["w_max"] / ml["w_max"]

    fig, axs = plt.subplots(3, 2, figsize=(17, 9.5), constrained_layout=True)
    d2, xe2, ze2 = plots.grid_info(mr)
    vlim = float(np.nanmax(np.abs(ref[1])))
    tl = float(np.nanpercentile(np.abs(ref[2]), 99.5))
    for r, (t, f) in enumerate((("эталон: автомат", ref), ("сумма точных ядер всех столбцов (линейный отклик)", lin),
                                ("свёртка тремя ядрами (равнина/склон/гребень)", conv))):
        ax = axs[r, 0]
        plots.draw_ground(ax, mr)
        qv, _ = plots._quiver(ax, mr, f[0], f[1], spacing=200.0, scale_m_per_ms=200.0, vlim=vlim)
        ax.set_ylim(0, 2.5)
        ax.set_title(f"{t}: ветер")
        ax.label_outer()
        ax = axs[r, 1]
        pm = ax.pcolormesh(xe2 / 1000, ze2 / 1000, f[2], cmap="RdBu_r", norm=TwoSlopeNorm(0, -tl, tl))
        plots.draw_ground(ax, mr, stair=False)
        ax.set_ylim(0, 2.5)
        ax.set_title(f"{t}: θ′")
        ax.label_outer()
    fig.colorbar(qv, ax=axs[:, 0], shrink=0.5, label="w, м/с (цвет стрелок); 200 м стрелки = 1 м/с")
    fig.colorbar(pm, ax=axs[:, 1], shrink=0.5, label="θ′, К")
    fig.suptitle(f"Опыт 3. Сценарий 1 из ядер (клетка {cell_rec:g} м, поля через 8 ч)")
    fig.savefig(os.path.join(OUT, "exp3_kernel_reconstruction.png"))
    plt.close(fig)
    fig, axs = plt.subplots(1, 2, figsize=(14, 4), constrained_layout=True)
    for c, (lab, f) in zip(SERIES, (("эталон", ref), ("сумма точных ядер", lin), ("свёртка 3 ядрами", conv))):
        axs[0].plot(mr.xc / 1000, plots.sample_agl(mr, f[1], 300), color=c, lw=2, label=lab)
        axs[1].plot(np.nanmean(np.where(mr.solid_np, np.nan, f[2]), axis=1), mr.zc / 1000, color=c, lw=2, label=lab)
    axs[0].axhline(0, color=MUTED, lw=0.8)
    axs[0].set_xlabel("x поперёк хребта, км")
    axs[0].set_ylabel("w на 300 м над землёй, м/с")
    axs[0].legend(frameon=False)
    axs[1].set_xlabel("θ′, среднее по горизонтали, К")
    axs[1].set_ylabel("высота над подножием, км")
    fig.suptitle("Опыт 3. Сценарий 1: эталон против сборки из ядер")
    fig.savefig(os.path.join(OUT, "exp3_kernel_reconstruction_profiles.png"))
    plt.close(fig)

    L = [f"Ядра — отклик на нагрев одного столбца {cell:g} м потоком {Q:g} Вт/м² (поля через 8 ч):\n",
         "| Источник | Пик |w|, см/с | w < 5 % дальше, км (клеток) | w < 1 %, км (клеток) | Пик |u|, см/с | u < 5 % / 1 %, км | Пик θ′, мК | θ′ < 5 % / 1 %, км |",
         "|---|---|---|---|---|---|---|---|"]
    for lab, dd in dec.items():
        w_, u_, t_ = dd["w"], dd["u"], dd["θ′"]
        L.append(f"| {lab} | {w_['peak'] * 100:.1f} | {w_['r5'] / 1000:.2f} ({w_['r5'] / cell:.0f}) | "
                 f"{w_['r1'] / 1000:.2f} ({w_['r1'] / cell:.0f}) | {u_['peak'] * 100:.1f} | "
                 f"{u_['r5'] / 1000:.2f} / {u_['r1'] / 1000:.2f} | {t_['peak'] * 1000:.0f} | "
                 f"{t_['r5'] / 1000:.2f} / {t_['r1'] / 1000:.2f} |")
    L.append("")
    L.append(f"Сборка сценария 1 (клетка {cell_rec:g} м, {len(cols)} нагретых столбцов; эталон — автомат через 8 ч; "
             f"он отличается от сохранённого эталона out/refs на u {e_ref8[0]:.1%}, w {e_ref8[1]:.1%}, "
             f"θ′ {e_ref8[2]:.1%}):\n")
    L.append("| Способ | Ошибка u / w / θ′ | Макс. подъём, м/с | Приток у подножия, м/с | Высота подъёма, м | Опускание в долине, м/с |")
    L.append("|---|---|---|---|---|---|")
    L.append(f"| эталон (автомат) | — | {mref['w_max']:.2f} | {mref['inflow_left']:+.2f} | {mref['ascent_top_z']:.0f} | "
             f"{mref['w_mean_valley_left']:+.3f} |")
    L.append(f"| сумма точных ядер столбцов | {e_lin[0]:.2f} / {e_lin[1]:.2f} / {e_lin[2]:.2f} | {ml['w_max']:.2f} | "
             f"{ml['inflow_left']:+.2f} | {ml['ascent_top_z']:.0f} | {ml['w_mean_valley_left']:+.3f} |")
    L.append(f"| свёртка тремя ядрами | {e_conv[0]:.2f} / {e_conv[1]:.2f} / {e_conv[2]:.2f} | {mc['w_max']:.2f} | "
             f"{mc['inflow_left']:+.2f} | {mc['ascent_top_z']:.0f} | {mc['w_mean_valley_left']:+.3f} |")
    L.append("")
    L.append(f"Цена «одного широкого слоя»: умножение матрицы ядер {Kmat.shape[0]}×{Kmat.shape[1]} на вектор нагрева — "
             f"{t_mv:.3f} мс на GPU, матрица {mem_mb:.1f} МБ (float32). Недостающее усиление подъёма: ×{gain:.1f}.")
    with open(os.path.join(OUT, "exp3_kernels.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L))
    json.dump(dict(decay={k: {nm: {kk: vv for kk, vv in v.items() if kk not in ("env", "bins")} for nm, v in dd.items()}
                          for k, dd in dec.items()},
                   e_lin=e_lin, e_conv=e_conv, e_ref8=e_ref8, t_mv_ms=t_mv, mem_mb=mem_mb, shape=list(Kmat.shape),
                   m_ref=mref, m_lin=ml, m_conv=mc, gain=gain),
              open(os.path.join(OUT, "exp3_kernels.json"), "w"), indent=1, default=float)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("what", choices=["linear", "kernels", "all"])
    a = p.parse_args()
    if a.what in ("linear", "all"):
        exp_linear()
    if a.what in ("kernels", "all"):
        exp_kernels()


if __name__ == "__main__":
    main()
