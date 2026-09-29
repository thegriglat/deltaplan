"""Картинки и таблицы опыта 4 (читают out/results, out/fields, out/timing.json, эталоны)."""
from __future__ import annotations

import json
import os

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker
from matplotlib.colors import TwoSlopeNorm

from model import SCENARIOS, Params, HeatCA
import plots
from plots import draw_ground, _quiver, _inv_line, grid_info, SERIES, MUTED, INK

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.dirname(HERE)
TITLES = {
    "s1_sun_one_slope": "1. Солнце на крутой склон, второй в тени, штиль",
    "s2_both_slopes": "2. Оба склона прогреты, штиль",
    "s3_wind": "3. Оба склона прогреты, ветер 3 м/с слева",
    "s4_inversion": "4. Оба склона прогреты, инверсия 1,5–1,8 км",
}
SHORT = {"s1_sun_one_slope": "1. солнце на склон", "s2_both_slopes": "2. оба склона",
         "s3_wind": "3. ветер 3 м/с", "s4_inversion": "4. инверсия"}


def refp(name, cell):
    p = os.path.join(BASE, "out", "refs", f"{name}_{cell:g}.npz")
    return p if os.path.exists(p) else os.path.join(HERE, "out", "refs_extra", f"{name}_{cell:g}.npz")


def model_cpu(name, cell):
    return HeatCA(SCENARIOS[name], Params(cell=cell, device="cpu"))


def load(path):
    d = np.load(path)
    return {k: d[k] for k in d.files}


def rel(a, b, air):
    return float(np.sqrt(np.nansum((a - b)[air] ** 2) / np.nansum(b[air] ** 2)))


def _panel_flow(ax, fig, m, uc, wc, th, lim, vlim, scale, title):
    d, xe, ze = grid_info(m)
    pm = ax.pcolormesh(xe / 1000, ze / 1000, np.clip(th, 0, None), cmap="Greys", vmin=0, vmax=lim * 2.2,
                       shading="flat")
    draw_ground(ax, m)
    _inv_line(ax, m)
    q, _ = _quiver(ax, m, uc, wc, spacing=200.0, scale_m_per_ms=scale, vlim=vlim)
    ax.set_title(title, fontsize=10.5)
    return pm, q


def fig_flow_pair(out, name, cell=50.0):
    m = model_cpu(name, cell)
    ref = load(refp(name, cell))
    f = load(os.path.join(out, "fields", f"{name}_{cell:g}.npz"))
    r = json.load(open(os.path.join(out, "results", f"{name}_{cell:g}.json")))
    lim = max(0.3, np.nanpercentile(np.abs(ref["th"]), 99.5))
    sp = np.hypot(ref["uc"], ref["wc"])
    scale = 1.0 * 200 / max(np.nanpercentile(sp[np.isfinite(sp)], 90), 0.2)
    vlim = float(np.nanmax(np.abs(ref["wc"])))
    fig, axs = plt.subplots(2, 1, figsize=(11.5, 10.4), sharex=True)
    fig.subplots_adjust(right=0.8, hspace=0.28, top=0.88)
    info = r["ref_info"]
    pm, q = _panel_flow(axs[0], fig, m, ref["uc"], ref["wc"], ref["th"], lim, vlim, scale,
                        f"эталон: автомат, шаги по времени ({info['steady_step']} шагов до установления)")
    n2 = r["n_conv2"]
    e = r["err_ref"]
    _, q = _panel_flow(axs[1], fig, m, f["uc"], f["wc"], f["th"], lim, vlim, scale,
                f"проходы по слоям: {n2} повторов «невязка → проход вверх → проход вниз»\n"
                f"отличие от эталона (L2): w {e['w']*100:.0f} %, u {e['u']*100:.0f} %, θ′ {e['th']*100:.0f} %")
    axs[0].set_xlabel("")
    axs[1].quiverkey(q, 0.93, -0.2, 1.0, "1 м/с", labelpos="W", coordinates="axes", color=INK)
    cax1 = fig.add_axes([0.83, 0.2, 0.014, 0.6])
    cax2 = fig.add_axes([0.92, 0.2, 0.014, 0.6])
    fig.colorbar(q, cax=cax1).set_label("w, м/с: красное — подъём, синее — опускание")
    fig.colorbar(pm, cax=cax2).set_label("θ′ > 0, К (серое)")
    fig.suptitle(f"{TITLES[name]} — клетка {cell:g} м\nскорость воздуха (стрелки через 200 м) над прогревом (серое)",
                 x=0.45)
    fig.savefig(os.path.join(out, f"flow_{name}.png"))
    plt.close(fig)


def fig_err(out, name, cell=50.0):
    m = model_cpu(name, cell)
    ref = load(refp(name, cell))
    pL = os.path.join(out, "refs_long", f"{name}_{cell:g}.npz")
    refL = load(pL) if os.path.exists(pL) else None
    f = load(os.path.join(out, "fields", f"{name}_{cell:g}.npz"))
    d, xe, ze = grid_info(m)
    panels = [("w: проходы − эталон, м/с", f["wc"] - ref["wc"], "PuOr_r")]
    if refL is not None:
        panels.append(("w: эталон через 12 ч − эталон (сам эталон ещё не установился), м/с", refL["wc"] - ref["wc"],
                       "PuOr_r"))
        panels.append(("w: проходы − эталон через 12 ч, м/с", f["wc"] - refL["wc"], "PuOr_r"))
    panels.append(("θ′: проходы − эталон, К", f["th"] - ref["th"], "RdBu_r"))
    fig, axs = plt.subplots(len(panels), 1, figsize=(10.5, 3.3 * len(panels)), sharex=True)
    wl = max(np.nanpercentile(np.abs(p[1]), 99.5) for p in panels if p[0].startswith("w"))
    for ax, (t, v, cm) in zip(axs, panels):
        lim = wl if t.startswith("w") else max(np.nanpercentile(np.abs(v), 99.5), 1e-3)
        pm = ax.pcolormesh(xe / 1000, ze / 1000, v, cmap=cm, norm=TwoSlopeNorm(0, -lim, lim), shading="flat")
        draw_ground(ax, m)
        _inv_line(ax, m)
        cb = fig.colorbar(pm, ax=ax, shrink=0.9, pad=0.015)
        cb.set_label("м/с" if t.startswith("w") else "К")
        ax.set_title(t, fontsize=10)
        if ax is not axs[-1]:
            ax.set_xlabel("")
    fig.suptitle(f"{TITLES[name]} — клетка {cell:g} м: где проходы расходятся с эталоном", y=1.0)
    fig.tight_layout()
    fig.savefig(os.path.join(out, f"err_{name}.png"))
    plt.close(fig)


def fig_convergence(out, names, cells):
    fig, axs = plt.subplots(1, len(names), figsize=(4.2 * len(names), 4.2), sharey=True)
    for ax, name in zip(axs, names):
        for c, cell in zip(SERIES, cells):
            p = os.path.join(out, "results", f"{name}_{cell:g}.json")
            if not os.path.exists(p):
                continue
            r = json.load(open(p))
            n = [h["n"] for h in r["hist"]]
            e = [max(h["fin"].values()) for h in r["hist"]]
            er = [h["ref"]["w"] for h in r["hist"]]
            ax.semilogy(n, np.maximum(e, 1e-5), color=c, lw=1.8, label=f"{cell:g} м")
            ax.semilogy(n, er, color=c, lw=1.0, ls=":")
        ax.axhline(0.02, color="#c00000", lw=0.8, ls="--")
        ax.set_xlim(0, 400)
        ax.set_ylim(1e-3, 3)
        ax.set_title(SHORT[name])
        ax.set_xlabel("повторов (невязка + 2 прохода)")
    axs[0].set_ylabel("ошибка (отн. L2)")
    axs[0].legend(frameon=False, title="клетка", fontsize=8)
    axs[-1].text(0.98, 0.97, "сплошная — наибольшая из w, u, θ′ против\nокончательного решения; пунктир — w против\n"
                 "эталона (эталон сам не доустановился);\nкрасная — порог «сошлось» 2 %",
                 transform=axs[-1].transAxes, ha="right", va="top", fontsize=7.5, color=MUTED)
    fig.suptitle("Сходимость повторов «невязка → проход вверх → проход вниз» (Андерсон)")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "convergence.png"))
    plt.close(fig)


def fig_time(out, names, cells):
    p = os.path.join(out, "timing.json")
    if not os.path.exists(p):
        return
    T = json.load(open(p))
    rows = T["rows"]
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.2))
    for c, name in zip(SERIES, names):
        rr = [r for r in rows if r["scenario"] == name]
        cs = [r["cell"] for r in rr]
        axs[0].loglog(cs, [r["ref_wall"] for r in rr], "o--", color=c, lw=1.2, ms=4)
        axs[0].loglog(cs, [r["t_gpu"] for r in rr], "o-", color=c, lw=2, ms=5, label=SHORT[name])
        axs[1].semilogx(cs, [r["ref_steps"] / r["n_conv2"] for r in rr], "o-", color=c, lw=2, label=SHORT[name])
    for ax in axs:
        ax.set_xlabel("клетка, м")
        ax.invert_xaxis()
        cs_all = sorted({r["cell"] for r in rows}, reverse=True)
        ax.set_xticks(cs_all)
        ax.set_xticklabels([f"{c:g}" for c in cs_all])
        ax.xaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
        ax.xaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    axs[0].set_ylabel("время на GPU до установления, с")
    axs[0].set_title("сплошная — проходы, пунктир — шаги по времени")
    axs[0].legend(frameon=False, fontsize=8)
    axs[1].set_ylabel("шагов эталона / повторов проходов")
    axs[1].set_title("во сколько раз меньше повторов, чем шагов")
    fig.suptitle(f"Цена установившегося поля, {T['gpu']} (CuPy + CUDA Graph, float32)")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "time.png"))
    plt.close(fig)


def anim_iters(out, name="s1_sun_one_slope", cell=50.0):
    """Как повторы собирают поле: кадр — повтор."""
    from matplotlib import animation
    m = model_cpu(name, cell)
    f = load(os.path.join(out, "snaps", f"{name}_{cell:g}.npz"))
    ref = load(refp(name, cell))
    d, xe, ze = grid_info(m)
    lim = max(0.3, np.nanpercentile(np.abs(ref["th"]), 99.5))
    sp = np.hypot(ref["uc"], ref["wc"])
    scale = 1.0 * 200 / max(np.nanpercentile(sp[np.isfinite(sp)], 90), 0.2)
    vlim = float(np.nanmax(np.abs(ref["wc"])))
    fig, ax = plt.subplots(figsize=(10.5, 5.6))
    th0 = f["snap_th"][0]
    pm = ax.pcolormesh(xe / 1000, ze / 1000, np.clip(th0, 0, None), cmap="Greys", vmin=0, vmax=lim * 2.2,
                       shading="flat")
    draw_ground(ax, m)
    _inv_line(ax, m)
    cb = fig.colorbar(pm, ax=ax, shrink=0.8, pad=0.02)
    cb.set_label("θ′ > 0, К (серое)")
    state = {"q": None}
    ttl = ax.set_title("")

    def upd(i):
        if state["q"] is not None:
            state["q"].remove()
        pm.set_array(np.clip(f["snap_th"][i], 0, None).ravel())
        state["q"], _ = _quiver(ax, m, f["snap_uc"][i], f["snap_wc"][i], spacing=200.0, scale_m_per_ms=scale,
                                vlim=vlim)
        ttl.set_text(f"{TITLES[name]}, клетка {cell:g} м\nповтор {int(f['snap_n'][i])} "
                     f"(каждый — невязка + проход вверх + проход вниз); стрелки — ветер, цвет — w")
        return pm,

    ani = animation.FuncAnimation(fig, upd, frames=len(f["snap_n"]), blit=False)
    ani.save(os.path.join(out, f"iterations_{name}.mp4"),
             writer=animation.FFMpegWriter(fps=4, bitrate=900, extra_args=["-pix_fmt", "yuv420p"]), dpi=90)
    plt.close(fig)


def fig_transfer(out, name="s2_both_slopes", cell=50.0):
    """Сами матрицы перехода: как далеко вверх «дотягивается» ответ сверху (‖E_k‖) по гармоникам."""
    from steady4 import SteadyOp
    op = SteadyOp(SCENARIOS[name], Params(cell=cell, device="cpu"))
    E = op.pE                               # [m, k, 4, 4]
    nrm = np.linalg.norm(E, axis=(2, 3))    # [m, k]
    lam = 2 * op.nx * op.d / np.maximum(np.arange(op.M), 1) / 1000   # длина волны, км
    fig, axs = plt.subplots(1, 2, figsize=(12, 4.3))
    axs = [None] + list(axs)
    Dn = np.linalg.norm(op.pDinv, axis=(2, 3))
    for c, mm in zip(SERIES, [1, 4, 16, 64]):
        if mm < op.M:
            axs[1].semilogy(op.m.zc / 1000, Dn[mm], color=c, lw=2, label=f"m = {mm} (λ ≈ {lam[mm]:.1f} км)")
    axs[1].set_xlabel("слой, км")
    axs[1].set_ylabel("‖D_k⁻¹‖ (проход вверх)")
    axs[1].legend(frameon=False, fontsize=8)
    axs[1].set_title("проход вверх: нормы ограничены (нет разгона «стрельбы»)", fontsize=10)
    # та же матрица в клетках: насколько далеко по горизонтали связь слоя k со слоем k+1
    Tc = op.gTc
    Ic = op.gIc
    i0 = op.nx // 2
    dist = (np.arange(op.nx) - i0) * op.d / 1000
    for c, (k, a, b, lab) in zip(SERIES, [(op.nz // 4, 3, 3, "w←w"), (op.nz // 4, 2, 2, "θ′←θ′"),
                                          (op.nz // 4, 3, 1, "w←p")]):
        Ep = Ic @ (E[:, k, a, b][:, None] * Tc)
        row = np.abs(Ep[i0])
        axs[2].semilogy(dist, row / row.max(), color=c, lw=2, label=f"{lab}, слой {op.m.zc[k]:.0f} м")
    axs[2].set_xlabel("расстояние по горизонтали, км")
    axs[2].set_ylabel("|E_k| в клетках (доля максимума)")
    axs[2].set_ylim(1e-6, 1.5)
    axs[2].legend(frameon=False, fontsize=8)
    axs[2].set_title("в клетках матрица полная: связь на весь слой", fontsize=10)
    fig.suptitle(f"Матрицы перехода 4×4 (u, p, θ′, w) по слоям, {SHORT[name]}, клетка {cell:g} м")
    del nrm
    fig.tight_layout()
    fig.savefig(os.path.join(out, "transfer_matrices.png"))
    plt.close(fig)


def fig_passes(out, name="s1_sun_one_slope", cell=50.0):
    """Что делают два прохода: первый повтор с покоя (невязка = нагрев земли)."""
    from steady4 import SteadyOp
    op = SteadyOp(SCENARIOS[name], Params(cell=cell, device="cpu"))
    m = op.m
    r = op.residual(op.x0())
    rhs, Ru = op.to_harm(r)
    nz = op.nz
    g = np.empty_like(rhs)
    prev = None
    for k in range(nz):
        rk = rhs[:, k] - (np.einsum("mij,mj->mi", op.gA[:, k], prev) if prev is not None else 0)
        prev = np.einsum("mij,mj->mi", op.gDinv[:, k], rk)
        g[:, k] = prev
    y = op.solve_blocks(rhs)
    up = op.unpack(op.from_harm(g, Ru))
    dn = op.unpack(op.from_harm(y, Ru))
    f = load(os.path.join(out, "fields", f"{name}_{cell:g}.npz"))
    d, xe, ze = grid_info(m)
    s_ = m.solid_np
    cen = lambda u, w: (np.where(s_, np.nan, 0.5 * (u[:, 1:] + u[:, :-1])), np.where(s_, np.nan, 0.5 * (w[1:] + w[:-1])))
    panels = [("после прохода вверх (только накоплено снизу: слой «не знает», что над ним)", *cen(up[0], up[1]), up[3]),
              ("после прохода вниз (первый повтор: линейный отклик без рельефа и переноса θ′ ветром)",
               *cen(dn[0], dn[1]), dn[3]),
              (f"после {int(f['n_conv2'])} повторов (установившееся)", f["uc"], f["wc"], f["th"])]
    fig, axs = plt.subplots(3, 1, figsize=(10.5, 12), sharex=True)
    for ax, (t, uc, wc, th) in zip(axs, panels):
        th = np.where(s_, np.nan, th)
        lim = max(0.3, np.nanpercentile(np.abs(th), 99.5))
        pm = ax.pcolormesh(xe / 1000, ze / 1000, np.clip(th, 0, None), cmap="Greys", vmin=0, vmax=lim * 2.2,
                           shading="flat")
        draw_ground(ax, m)
        q, _ = _quiver(ax, m, uc, wc, spacing=200.0)
        ax.quiverkey(q, 0.95, 0.9, 1.0, "1 м/с", labelpos="W", coordinates="axes", color=INK)
        fig.colorbar(pm, ax=ax, shrink=0.85, pad=0.015).set_label("θ′ > 0, К")
        ax.set_title(t, fontsize=10)
        if ax is not axs[-1]:
            ax.set_xlabel("")
    fig.suptitle(f"{TITLES[name]}, клетка {cell:g} м: что делают проходы (стрелки — ветер, цвет — w)", y=0.995)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "passes_explained.png"))
    plt.close(fig)


def fig_streams(out, name, cells=(50.0, 25.0, 12.5)):
    """Линии тока: эталон и проходы рядом, по клеткам. Фон — w, линии — скорость."""
    cells = [c for c in cells if os.path.exists(os.path.join(out, "fields", f"{name}_{c:g}.npz"))
             and os.path.exists(refp(name, c))]
    if not cells:
        return
    fig, axs = plt.subplots(len(cells), 2, figsize=(15, 3.0 * len(cells) + 1.0), squeeze=False)
    vl = None
    for row, cell in enumerate(cells):
        m = model_cpu(name, cell)
        ref = load(refp(name, cell))
        f = load(os.path.join(out, "fields", f"{name}_{cell:g}.npz"))
        r = json.load(open(os.path.join(out, "results", f"{name}_{cell:g}.json")))
        d, xe, ze = grid_info(m)
        if vl is None:
            vl = float(np.nanpercentile(np.abs(ref["wc"]), 99.8))
        for col, (lab, uc, wc) in enumerate((("эталон (шаги по времени)", ref["uc"], ref["wc"]),
                                             (f"проходы ({r['n_conv2']} повторов)", f["uc"], f["wc"]))):
            ax = axs[row, col]
            # для показа: клетки под «лесенкой» заполняем значением первой воздушной клетки столбца,
            # поверх рисуем гладкий рельеф (иначе между лесенкой и контуром — белые щели)
            ii = np.arange(m.nx)
            fillc = lambda a: np.where(m.solid_np, a[m.kb, ii][None, :], a)
            uc, wc = fillc(uc), fillc(wc)
            pm = ax.pcolormesh(m.xc / 1000, m.zc / 1000, wc, cmap="RdBu_r", norm=TwoSlopeNorm(0, -vl, vl),
                               shading="gouraud", rasterized=True)
            U = np.nan_to_num(uc)
            W = np.nan_to_num(wc)
            sp = np.hypot(U, W)
            st = ax.streamplot(m.xc / 1000, m.zc / 1000, U, W, color=sp, cmap="Greys", norm=plt.Normalize(0, vl),
                               density=(2.4, 1.3), linewidth=0.8, arrowsize=0.6, zorder=6)
            x = np.linspace(0, m.pr.lx, 800)
            ax.fill_between(x / 1000, 0, m.terrain(x) / 1000, color="#5b4a3a", zorder=7, lw=0)
            ax.set_xlim(0, m.pr.lx / 1000)
            ax.set_ylim(0, 2.4)
            ax.set_aspect("equal")
            _inv_line(ax, m)
            ax.set_title(f"{lab}, клетка {cell:g} м", fontsize=10)
            if row == len(cells) - 1:
                ax.set_xlabel("x поперёк хребта, км")
            if col == 0:
                ax.set_ylabel("высота, км")
    fig.subplots_adjust(right=0.88, hspace=0.12, wspace=0.08, top=0.93)
    cax1 = fig.add_axes([0.9, 0.55, 0.012, 0.35])
    cax2 = fig.add_axes([0.9, 0.12, 0.012, 0.35])
    fig.colorbar(pm, cax=cax1).set_label("w, м/с (фон)")
    fig.colorbar(st.lines, cax=cax2).set_label("скорость, м/с (линии тока)")
    fig.suptitle(f"{TITLES[name]}: линии тока, эталон и проходы по слоям (рельеф — гладкий контур; "
                 "в модели он лесенкой из клеток)", fontsize=11)
    fig.savefig(os.path.join(out, f"streams_{name}.png"), dpi=110)
    plt.close(fig)


def all_figs(out, names, cells):
    for name in names:
        fig_flow_pair(out, name)
        fig_err(out, name)
    fig_convergence(out, names, cells)
    fig_time(out, names, cells)
    for nm in ("s1_sun_one_slope", "s4_inversion"):
        fig_streams(out, nm)
    fig_transfer(out)
    fig_passes(out)
    anim_iters(out)


# ------------------------------------------------------------------ таблицы
def fmt(v, nd=2, sign=False):
    if v is None or (isinstance(v, float) and not np.isfinite(v)):
        return "—"
    return f"{v:+.{nd}f}" if sign else f"{v:.{nd}f}"


def tables(out, names, cells):
    L = []
    T = json.load(open(os.path.join(out, "timing.json"))) if os.path.exists(os.path.join(out, "timing.json")) else None
    trow = {(r["scenario"], r["cell"]): r for r in T["rows"]} if T else {}
    L.append("### Точность против эталона (относительная L2 по воздушным клеткам) и цена\n")
    L.append("«Эталон» — `out/refs` базы (автомат, остановлен по признаку установления); «эталон 12 ч» — тот же "
             "автомат, досчитанный до 12 ч модельного времени (`exp4_transfer_sweeps/out/refs_long`). "
             "Повторов — до «сошлось»: w, u, θ′ отличаются от окончательного решения проходов меньше 2 %.\n")
    L.append("| Сценарий | Клетка | Повторов (2 % / 5 %) | Ошибка w / u / θ′ против эталона | против эталона 12 ч | "
             "эталон против эталона 12 ч | GPU, с (проходы) | Эталон: шагов / с | Выигрыш по времени |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for name in names:
        for cell in cells:
            p = os.path.join(out, "results", f"{name}_{cell:g}.json")
            if not os.path.exists(p):
                continue
            r = json.load(open(p))
            ref = load(refp(name, cell))
            air = ~ref["solid"]
            f = load(os.path.join(out, "fields", f"{name}_{cell:g}.npz"))
            pL = os.path.join(out, "refs_long", f"{name}_{cell:g}.npz")
            eL = eRL = None
            if os.path.exists(pL):
                refL = load(pL)
                eL = [rel(f[k], refL[k], air) for k in ("wc", "uc", "th")]
                eRL = [rel(ref[k], refL[k], air) for k in ("wc", "uc", "th")]
            e = r["err_ref"]
            info = r["ref_info"]
            t = trow.get((name, cell))
            tg = fmt(t["t_gpu"], 3) if t else "—"
            gain = f"×{info['steady_wall'] / t['t_gpu']:.0f}" if t else "—"
            L.append(f"| {SHORT[name]} | {cell:g} м | {r['n_conv2']} / {r['n_conv5']} | "
                     f"{e['w']:.3f} / {e['u']:.3f} / {e['th']:.3f} | "
                     + (" / ".join(f"{v:.3f}" for v in eL) if eL else "—") + " | "
                     + (" / ".join(f"{v:.3f}" for v in eRL) if eRL else "—") + f" | {tg} | "
                     f"{info['steady_step']} / {info['steady_wall']:.2f} | {gain} |")
    L.append("")
    L.append("### Ключевые числа: проходы (эталон)\n")
    L.append("| Сценарий | Клетка | Макс. подъём, м/с (где: x км, над землёй м) | Приток у подножия слева, м/с | "
             "Вверх по склону слева, м/с | Опускание в долине слева (ср.), м/с | Высота подъёма, м | "
             "|w| выше инверсии, м/с |")
    L.append("|---|---|---|---|---|---|---|---|")
    for name in names:
        for cell in cells:
            p = os.path.join(out, "results", f"{name}_{cell:g}.json")
            if not os.path.exists(p):
                continue
            r = json.load(open(p))
            a, b = r["metrics"], r["metrics_ref"]
            inv = f"{a['above_inv_wmax']:.3f} ({b['above_inv_wmax']:.3f})" if "above_inv_wmax" in a else "—"
            L.append(f"| {SHORT[name]} | {cell:g} м | {a['w_max']:.2f} ({b['w_max']:.2f}); {a['w_max_x']/1000:.2f} км, "
                     f"{a['w_max_agl']:.0f} м ({b['w_max_x']/1000:.2f} км, {b['w_max_agl']:.0f} м) | "
                     f"{a['inflow_left']:+.2f} ({b['inflow_left']:+.2f}) | {a['upslope_left']:+.2f} ({b['upslope_left']:+.2f}) | "
                     f"{a['w_mean_valley_left']:+.3f} ({b['w_mean_valley_left']:+.3f}) | "
                     f"{a['ascent_top_z']:.0f} ({b['ascent_top_z']:.0f}) | {inv} |")
    L.append("")
    if T:
        L.append(f"### Время на GPU ({T['gpu']}, CuPy + CUDA Graph, float32; замер под замком)\n")
        L.append("| Сценарий | Клетка | Сетка (гармоник × слоёв) | Неизвестных | Повторов | мс/повтор | ядро двух проходов, мкс | "
                 "До установления, с | Эталон: мс/шаг, шагов, с | Память GPU, МБ |")
        L.append("|---|---|---|---|---|---|---|---|---|---|")
        for r in T["rows"]:
            L.append(f"| {SHORT[r['scenario']]} | {r['cell']:g} м | {r['nx']}×{r['nz']} ({r['M']}×{r['nz']}) | {r['N']} | "
                     f"{r['n_conv2']} | {r['ms_iter']:.3f} | {r['ms_two_pass_kernel']*1e3:.0f} | {r['t_gpu']:.3f} | "
                     f"{r['ref_ms_step']:.3f}, {r['ref_steps']}, {r['ref_wall']:.2f} | {r['mem_mb']:.0f} |")
        L.append("")
    if T:
        L.append("### Масштабирование по клетке: сколько повторов и сколько времени GPU\n")
        L.append("| Сценарий | Клетка | Повторов до 2 % | до 1 % | мс/повтор | GPU до 2 %, с | до 1 %, с | "
                 "Эталон: шагов, с |")
        L.append("|---|---|---|---|---|---|---|---|")
        for name in names:
            for cell in cells:
                p = os.path.join(out, "results", f"{name}_{cell:g}.json")
                t = trow.get((name, cell))
                if not os.path.exists(p) or not t:
                    continue
                r = json.load(open(p))
                n1 = r["n_conv1"]
                L.append(f"| {SHORT[name]} | {cell:g} м | {r['n_conv2']} | {n1} | {t['ms_iter']:.3f} | "
                         f"{r['n_conv2'] * t['ms_iter'] / 1e3:.3f} | "
                         + (f"{n1 * t['ms_iter'] / 1e3:.3f}" if n1 else "—")
                         + f" | {t['ref_steps']}, {t['ref_wall']:.2f} |")
        L.append("")
    wp = os.path.join(out, "warm.json")
    if os.path.exists(wp):
        W = json.load(open(wp))
        L.append("### Тёплый старт (с соседнего решения, как при смене часа)\n")
        L.append("| Смена условий | Клетка | Повторов с покоя | Повторов с соседнего решения | Начальная ошибка тёплого старта w / u / θ′ |")
        L.append("|---|---|---|---|---|")
        for r in W:
            e0 = r["warm_err0"]
            L.append(f"| {r['case']} | {r['cell']:g} м | {r['cold']} | {r['warm']} | "
                     f"{e0['w']:.2f} / {e0['u']:.2f} / {e0['th']:.2f} |")
        L.append("")
    open(os.path.join(out, "tables.md"), "w").write("\n".join(L))
    print("\n".join(L))
