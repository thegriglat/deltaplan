"""Картинки и числа для прототипа клеточного автомата тепла и массы."""
from __future__ import annotations

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import animation
from matplotlib.colors import TwoSlopeNorm

SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
INK = "#222222"
MUTED = "#6b6b6b"
GROUND = "#5b4a3a"
plt.rcParams.update({
    "font.size": 10, "axes.titlesize": 11, "axes.labelcolor": INK, "text.color": INK,
    "axes.edgecolor": "#999999", "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.grid": False, "figure.dpi": 110, "savefig.bbox": "tight",
})


# ---------------------------------------------------------------- геометрия
def grid_info(model):
    d = model.dx
    xe = np.arange(model.nx + 1) * d
    ze = np.arange(model.nz + 1) * d
    return d, xe, ze


def draw_ground(ax, model, stair=True):
    x = np.linspace(0, model.pr.lx, 800)
    h = model.terrain(x)
    ax.fill_between(x / 1000, 0, h / 1000, color=GROUND, zorder=5, lw=0)
    d = model.dx
    xs = np.repeat(np.arange(model.nx + 1) * d, 2)[1:-1]
    zs = np.repeat(model.ground_stair, 2)
    # клетки «лесенки» модели — тем же цветом, чтобы не было белых щелей; контур — если просили
    ax.fill_between(xs / 1000, 0, zs / 1000, color=GROUND, zorder=5, lw=0)
    if stair:
        ax.plot(xs / 1000, zs / 1000, color="#000000", lw=0.8, zorder=6)
    ax.set_xlim(0, model.pr.lx / 1000)
    ax.set_ylim(0, model.pr.lz / 1000)
    ax.set_aspect("equal")
    ax.set_xlabel("x поперёк хребта, км")
    ax.set_ylabel("высота над подножием, км")


def sample_agl(model, f, agl):
    """Поле f (центры клеток) по столбцам на высоте agl над «лесенкой» рельефа."""
    d = model.dx
    out = np.full(model.nx, np.nan)
    for i in range(model.nx):
        kb = model.kb[i]
        z = model.ground_stair[i] + agl
        fk = z / d - 0.5
        fk = min(max(fk, kb), model.nz - 1)
        k0 = int(np.floor(fk))
        k1 = min(k0 + 1, model.nz - 1)
        a = fk - k0
        out[i] = (1 - a) * f[k0, i] + a * f[k1, i]
    return out


# ---------------------------------------------------------------- метрики
def metrics(model, uc, wc, thp):
    pr, sc = model.pr, model.sc
    d = model.dx
    X = np.repeat(model.xc[None, :], model.nz, 0)
    Z = np.repeat(model.zc[:, None], model.nx, 1)
    AGL = Z - model.ground_stair[None, :]
    if model.open_sides:
        # губки у боков — не часть картины
        cut = (X < pr.side_sponge_m) | (X > pr.lx - pr.side_sponge_m)
        uc, wc, thp = (np.where(cut, np.nan, f) for f in (uc, wc, thp))
    out = {}
    k = np.nanargmax(wc)
    kk, ii = np.unravel_index(k, wc.shape)
    out["w_max"] = float(wc[kk, ii])
    out["w_max_x"] = float(X[kk, ii])
    out["w_max_z"] = float(Z[kk, ii])
    out["w_max_agl"] = float(AGL[kk, ii])
    # приток у подножий: нижние ~100 м (минимум одна клетка), ±300 м от подножия
    low = AGL <= max(100.0, d)
    feet = {"left": pr.ridge_x - pr.half_left, "right": pr.ridge_x + pr.half_right}
    for side, xf in feet.items():
        sel = low & (np.abs(X - xf) <= max(300.0, d)) & np.isfinite(uc)
        toward = 1.0 if side == "left" else -1.0
        out[f"inflow_{side}"] = float(np.nanmean(uc[sel]) * toward)
    # ветер вдоль склона (середина склона, нижняя клетка): + — вверх по склону
    for side, (x0, x1, sgn) in {"left": (pr.ridge_x - 0.8 * pr.half_left, pr.ridge_x - 0.2 * pr.half_left, 1),
                                 "right": (pr.ridge_x + 0.2 * pr.half_right, pr.ridge_x + 0.8 * pr.half_right, -1)}.items():
        sel = low & (X >= x0) & (X <= x1) & np.isfinite(uc)
        out[f"upslope_{side}"] = float(np.nanmean(uc[sel]) * sgn)
    # опускание: долина слева (x < подножия − 200 м), справа — над пологим/теневым склоном и за ним
    mid = (AGL >= 200) & (Z <= 2000)
    regions = {"valley_left": X < feet["left"] - 200,
               "right_side": X > pr.ridge_x + 0.3 * pr.half_right}
    for name, r in regions.items():
        sel = mid & r & np.isfinite(wc)
        out[f"w_min_{name}"] = float(np.nanmin(wc[sel]))
        out[f"w_mean_{name}"] = float(np.nanmean(wc[sel]))
    # высота подъёма: верх области, где w > 20 % максимума (над склонами/гребнем)
    hot = (X > feet["left"] - 300) & (X < pr.ridge_x + 0.6 * pr.half_right)
    up = hot & (wc > 0.2 * out["w_max"])
    out["ascent_top_z"] = float(Z[up].max() + 0.5 * d) if up.any() else float("nan")
    warm = hot & (thp > 0.1)
    out["warm_top_z"] = float(Z[warm].max() + 0.5 * d) if warm.any() else float("nan")
    if sc.inversion_z is not None:
        top = sc.inversion_z + sc.inversion_dz
        above = Z > top + 100
        below = (Z < sc.inversion_z) & (AGL > 50)
        out["above_inv_wmax"] = float(np.nanmax(np.abs(wc[above])))
        out["above_inv_thmax"] = float(np.nanmax(np.abs(thp[above])))
        out["below_inv_wmax"] = float(np.nanmax(np.abs(wc[below])))
        # растекание: |u| в слое под инверсией (−300…0 м) против середины 600–900 м
        lay = (Z > sc.inversion_z - 300) & (Z < sc.inversion_z)
        out["outflow_under_inv"] = float(np.nanmax(np.abs(uc[lay])))
    # наклон подъёма: x максимума w на высотах 300…1500 м над подножием
    xs, zs = [], []
    for kz in range(model.nz):
        z = model.zc[kz]
        if 300 <= z <= 1500:
            row = np.where(np.isfinite(wc[kz]), wc[kz], -np.inf)
            if row.max() > 0.2 * out["w_max"]:
                xs.append(model.xc[np.argmax(row)])
                zs.append(z)
    if len(zs) >= 3:
        out["tilt_dx_dz"] = float(np.polyfit(zs, xs, 1)[0])
    return out


# ---------------------------------------------------------------- картинки
def fig_temp(model, thp, path, title):
    d, xe, ze = grid_info(model)
    fig, ax = plt.subplots(figsize=(11, 5.6))
    lim = max(0.3, np.nanpercentile(np.abs(thp), 99.5))
    pm = ax.pcolormesh(xe / 1000, ze / 1000, thp, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim),
                       shading="flat")
    draw_ground(ax, model)
    cb = fig.colorbar(pm, ax=ax, shrink=0.8, pad=0.02)
    cb.set_label("θ′ — теплее (+) / холоднее (−) фона на той же высоте, К")
    _inv_line(ax, model)
    ax.set_title(title + "\nтемпература относительно фона (установившееся)")
    fig.savefig(path)
    plt.close(fig)


def _inv_line(ax, model):
    sc = model.sc
    if sc.inversion_z is not None:
        for z in (sc.inversion_z, sc.inversion_z + sc.inversion_dz):
            ax.axhline(z / 1000, color=MUTED, ls="--", lw=0.8, zorder=4)
        ax.text(0.08, (sc.inversion_z + sc.inversion_dz) / 1000 + 0.04, "инверсия", color=MUTED, zorder=7)


def _quiver(ax, model, uc, wc, spacing=200.0, scale_m_per_ms=None, color_by_w=True, vlim=None):
    d = model.dx
    step = max(1, int(round(spacing / d)))
    off = step // 2
    X = model.xc[off::step] / 1000
    Z = model.zc[off::step] / 1000
    U = uc[off::step, off::step]
    W = wc[off::step, off::step]
    XX, ZZ = np.meshgrid(X, Z)
    sp = np.hypot(U, W)
    ok = np.isfinite(sp) & (sp > 0.03)
    if scale_m_per_ms is None:
        scale_m_per_ms = 1.0 * spacing / max(np.nanpercentile(sp[np.isfinite(sp)], 90), 0.2)
    # quiver: scale = (м/с) на единицу длины оси (км)
    sc = 1000.0 / scale_m_per_ms
    if color_by_w:
        vlim = vlim or max(np.nanmax(np.abs(W[ok])), 0.1)
        q = ax.quiver(XX[ok], ZZ[ok], U[ok], W[ok], W[ok], cmap="coolwarm",
                      norm=TwoSlopeNorm(0, -vlim, vlim), angles="xy", scale_units="xy", scale=sc,
                      width=0.0028, headwidth=3.5, headlength=4, zorder=8)
    else:
        q = ax.quiver(XX[ok], ZZ[ok], U[ok], W[ok], angles="xy", scale_units="xy", scale=sc,
                      width=0.0022, color="#111111", zorder=8)
    return q, scale_m_per_ms


def fig_flow(model, uc, wc, thp, path, title, spacing=200.0):
    d, xe, ze = grid_info(model)
    fig, ax = plt.subplots(figsize=(11.5, 5.8))
    lim = max(0.3, np.nanpercentile(np.abs(thp), 99.5))
    pm = ax.pcolormesh(xe / 1000, ze / 1000, np.clip(thp, 0, None), cmap="Greys", vmin=0, vmax=lim * 2.2,
                       shading="flat")
    draw_ground(ax, model)
    _inv_line(ax, model)
    q, s = _quiver(ax, model, uc, wc, spacing=spacing)
    ref = 1.0 if np.nanmax(np.hypot(uc, wc)) < 4 else 2.0
    ax.quiverkey(q, 0.93, -0.16, ref, f"{ref:g} м/с", labelpos="W", coordinates="axes", color=INK)
    cb2 = fig.colorbar(pm, ax=ax, shrink=0.75, pad=0.015, aspect=25)
    cb2.set_label("θ′ > 0, К (серое)")
    cb = fig.colorbar(q, ax=ax, shrink=0.75, pad=0.02, aspect=25)
    cb.set_label("w, м/с: красное — подъём, синее — опускание")
    ax.set_title(title + f"\nскорость воздуха (стрелки через {spacing:g} м) над прогревом (серое)")
    fig.savefig(path)
    plt.close(fig)


def fig_w_profile(model, wc, path, title):
    fig, axs = plt.subplots(3, 1, figsize=(10, 7.5), sharex=True,
                            gridspec_kw=dict(height_ratios=[3, 1, 1], hspace=0.12))
    x = model.xc / 1000
    ax = axs[0]
    for c, agl in zip(SERIES, (50, 150, 300, 600)):
        w = sample_agl(model, wc, agl)
        ax.plot(x, w, color=c, lw=2, label=f"{agl} м над землёй")
    ax.axhline(0, color=MUTED, lw=0.8)
    ax.set_ylabel("w, м/с")
    ax.legend(frameon=False, ncol=4, loc="upper right")
    ax.set_title(title + "\nвертикальная скорость по X на высотах над рельефом")
    if model.dx > 50:
        ax.text(0.01, 0.03, f"клетка {model.dx:g} м: ниже центра первой клетки берётся её значение",
                transform=ax.transAxes, color=MUTED, fontsize=8)
    axs[1].fill_between(x, 0, model.h, color=GROUND)
    axs[1].set_ylabel("рельеф, м")
    axs[1].set_ylim(0, model.pr.ridge_h * 1.2)
    axs[2].plot(x, model.q_np * 1.2 * 1005, color=SERIES[1], lw=2)
    axs[2].set_ylabel("нагрев, Вт/м²")
    axs[2].set_ylim(0, None)
    axs[2].set_xlabel("x поперёк хребта, км")
    fig.savefig(path)
    plt.close(fig)


def fig_mass_balance(series, path, title):
    t = np.array([s["t"] for s in series]) / 60
    g = lambda k: np.array([s[k] for s in series])
    fig, axs = plt.subplots(2, 2, figsize=(12, 7), sharex=True)
    ax = axs[0, 0]
    ax.plot(t, g("M"), color=SERIES[0], lw=2, label="масса в области − начальная")
    ax.plot(t, g("m_in"), color=SERIES[1], lw=2, ls="--", label="сумма притока через бока")
    ax.set_ylabel("масса, м² (на метр ширины, ρ=1)")
    ax.legend(frameon=False)
    ax.set_title("масса: изменение = приток через границы")
    ax = axs[0, 1]
    ax.plot(t, g("H") / 1e6, color=SERIES[0], lw=2, label="тепло в области − начальное")
    ax.plot(t, g("h_heat") / 1e6, color=SERIES[1], lw=2, label="нагрев от земли (сумма)")
    ax.plot(t, g("h_in") / 1e6, color=SERIES[2], lw=2, label="вынос/внос через бока")
    ax.plot(t, g("h_cool") / 1e6, color=SERIES[3], lw=2, label="выхолаживание к фону")
    if np.any(g("h_sponge") != 0):
        ax.plot(t, g("h_sponge") / 1e6, color=SERIES[4], lw=2, label="губки у краёв (θ → фон)")
    ax.set_ylabel("тепло, 10⁶ К·м²")
    ax.legend(frameon=False, fontsize=8)
    ax.set_title("тепло: изменение = нагрев + границы + стоки")
    ax = axs[1, 0]
    ax.semilogy(t, np.maximum(np.abs(g("m_res")), 1e-17), color=SERIES[0], lw=2,
                label="невязка массы / масса области")
    ax.semilogy(t, np.maximum(g("m_anom"), 1e-17), color=SERIES[4], lw=2,
                label="макс. |m−1| в клетке (недовыравнено)")
    ax.axhline(1e-3, color="#c00000", lw=1, ls=":", label="допуск 0,1 %")
    ax.set_ylabel("доля")
    ax.set_xlabel("время, мин")
    ax.legend(frameon=False, fontsize=8)
    ax = axs[1, 1]
    ax.semilogy(t, np.maximum(np.abs(g("h_res")), 1e-17), color=SERIES[0], lw=2,
                label="невязка тепла / суммарный нагрев")
    ax.axhline(1e-3, color="#c00000", lw=1, ls=":", label="допуск 0,1 %")
    ax.set_xlabel("время, мин")
    ax.legend(frameon=False, fontsize=8)
    fig.suptitle(title + " — баланс массы и тепла")
    fig.savefig(path)
    plt.close(fig)


def anim_evolution(model, frames, path, title, fps=8):
    d, xe, ze = grid_info(model)
    fig, ax = plt.subplots(figsize=(10, 5.4))
    lim = max(0.3, max(np.nanpercentile(np.abs(f[3]), 99.5) for f in frames))
    t, uc, wc, thp = frames[0]
    pm = ax.pcolormesh(xe / 1000, ze / 1000, thp, cmap="RdBu_r", norm=TwoSlopeNorm(0, -lim, lim), shading="flat")
    draw_ground(ax, model, stair=False)
    _inv_line(ax, model)
    cb = fig.colorbar(pm, ax=ax, shrink=0.8, pad=0.02)
    cb.set_label("θ′ относительно фона, К")
    smax = max(np.nanpercentile(np.hypot(f[1], f[2]), 98) for f in frames)
    scale = 0.9 * 200 / max(smax, 0.2)
    q, _ = _quiver(ax, model, uc, wc, color_by_w=False, scale_m_per_ms=scale)
    ttl = ax.set_title("")
    step = max(1, int(round(200 / d)))
    off = step // 2

    def update(n):
        t, uc, wc, thp = frames[n]
        pm.set_array(thp.ravel())
        U = np.nan_to_num(uc[off::step, off::step])
        W = np.nan_to_num(wc[off::step, off::step])
        XX, ZZ = np.meshgrid(model.xc[off::step], model.zc[off::step])
        ok = np.isfinite(uc[off::step, off::step]) & (np.hypot(U, W) > 0.03)
        q.set_offsets(np.c_[XX[ok] / 1000, ZZ[ok] / 1000])
        q.set_UVC(U[ok], W[ok])
        ttl.set_text(f"{title}\nt = {t / 60:5.0f} мин (стрелки: ветер, {scale:.0f} м длины на 1 м/с)")
        return pm, q, ttl

    # set_offsets требует постоянного числа стрелок — перерисовываем стрелки заново
    def update_full(n):
        nonlocal q
        q.remove()
        t, uc, wc, thp = frames[n]
        pm.set_array(thp.ravel())
        q, _ = _quiver(ax, model, uc, wc, color_by_w=False, scale_m_per_ms=scale)
        ttl.set_text(f"{title}\nt = {t / 60:4.0f} мин; цвет — θ′, стрелки — ветер ({scale:.0f} м на 1 м/с)")
        return pm, q, ttl

    ani = animation.FuncAnimation(fig, update_full, frames=len(frames), blit=False)
    if path.endswith(".mp4"):
        ani.save(path, writer=animation.FFMpegWriter(fps=fps, bitrate=900,
                                                      extra_args=["-pix_fmt", "yuv420p"]), dpi=90)
    else:
        ani.save(path, writer=animation.PillowWriter(fps=fps), dpi=70)
    plt.close(fig)
