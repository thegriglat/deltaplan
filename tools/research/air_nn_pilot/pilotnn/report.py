"""Отчёт пилота (контракт П3 v2): картинки + report.md из metrics.json. Вывод ШП-2 — правилом из чисел
(`config.yaml → eval.shp2`, функция `shp2_rule`; ею же пользуется tests/check_report_v2.py)."""
from __future__ import annotations

import datetime as dt
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from . import common as C  # noqa: E402
from .evaluate import NQ, PRED_NAMES, PREDS, SET_NAMES, SETS, Prog, at_level, level_weights  # noqa: E402

# категориальные слоты 1–6 (порядок фиксирован; цвет — за набором, не за рангом)
SLOTS = ("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300")
SET_COLOR = dict(zip(SETS, SLOTS))
PRED_COLOR = dict(zip(PREDS, SLOTS[:3]))
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#e4e3df"
plt.rcParams.update({"font.size": 9, "axes.edgecolor": MUTED, "axes.labelcolor": INK, "xtick.color": MUTED,
                     "ytick.color": MUTED, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
                     "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 110, "savefig.dpi": 110,
                     "lines.linewidth": 2.0})
VERDICTS = ("идём в волну 0", "правим подход", "отказ от направления")
# разделы report.md (П3 v2) — проверяет tests/check_report_v2.py
SECTIONS = ("## Вывод ШП-2", "## Наборы и деление", "## Область на 60 м", "## Гребни на 60 м",
            "## Центры (plan.json → centers)", "## Смещение скорости по высотам", "## Смещение по корзинам U10",
            "## (г) по системам и уклону", "## Кривая (в)", "## Признаки рельефа наборов", "## Сравнение с регрессией air-lite", "## Картинки",
            "## ONNX и время на CPU", "## Обучение и время", "## Границы")


def f2(x, n=2):
    return "—" if x is None or (isinstance(x, float) and not math.isfinite(x)) else f"{x:.{n}f}"


def pct(x):
    return "—" if x is None else f"{100 * x:.0f} %"


def at_key(vals, agl, a_key):
    """Профиль по 13 высотам → значение на a_key (линейно между соседними уровнями, как поля)."""
    i, w0, w1 = level_weights(agl, a_key)
    return w0 * vals[i] + w1 * vals[i + 1]


def sg(x, n=3):
    return "—" if x is None else f"{x:+.{n}f}"


# ------------------------------------------------------------------------------------------- правило ШП-2
def bias_thr(v, sc):
    return max(sc["bias_abs_ms"], sc["bias_rel"] * v)


def shp2_rule(M):
    """Правило ШП-2 (П3 v2, план §8.2) по числам metrics.json → dict(verdict, reason, checks[...]).
    checks: (что, значение, порог, выполнено). Вердикт: «идём в волну 0» — все проверки на (г) выполнены;
    «отказ от направления» — медиана ошибки ветра сети на (г) ≥ refuse_ratio × лучшей базовой линии;
    иначе «правим подход»."""
    ec = M["config_eval"]
    sc = ec["shp2"]
    agl = M["agl"]
    S = (M["sets"] or {}).get(sc["set"])
    checks = []
    if not S or not (S["net"].get("area") or {}).get("n_points"):
        return dict(verdict="правим подход", reason=f"нет случаев набора {SET_NAMES[sc['set']]} — правило не применимо",
                    checks=checks, set=sc["set"], n_bins_rated=0)
    a = S["net"]["area"]
    for k, nm in (("frac_wind_ok", f"доля «ок» ветра (≤ max({ec['wind_ok_ms']:g} м/с; {ec['wind_ok_rel'] * 100:g} % |V|))"),
                  ("frac_lift_m_ok", f"доля «ок» подъёма без нагрева (< {ec['lift_ok_ms']:g} м/с)"),
                  ("frac_lift_h_ok", f"доля «ок» подъёма с нагревом (< {ec['lift_ok_ms']:g} м/с)")):
        checks.append(dict(what=nm + ", область 60 м", value=a[k], thr=f"≥ {sc['frac_ok']:g}", ok=a[k] >= sc["frac_ok"],
                           kind="frac"))
    b = S["net"]["bias"]
    for i, z in enumerate(agl):
        if z > sc["bias_max_agl_m"]:
            continue
        t = bias_thr(b["v"][i], sc)
        checks.append(dict(what=f"|среднее e|, {z:g} м", value=abs(b["e"][i]), thr=f"≤ {t:.3f}", ok=abs(b["e"][i]) <= t,
                           kind="bias"))
    n_bins = 0
    for lab, bb in S["net"]["bias_bins"].items():
        if bb["cases"] < sc["bin_min_cases"]:
            continue
        n_bins += 1
        worst = None
        for i, z in enumerate(agl):
            if z > sc["bias_max_agl_m"]:
                continue
            t = bias_thr(bb["v"][i], sc)
            r = abs(bb["e"][i]) / t
            if worst is None or r > worst[0]:
                worst = (r, z, abs(bb["e"][i]), t)
        checks.append(dict(what=f"|среднее e|, U10 {lab} м/с ({bb['cases']} случаев), худшая высота {worst[1]:g} м",
                           value=worst[2], thr=f"≤ {worst[3]:.3f}", ok=worst[2] <= worst[3], kind="bias"))
    r = S["net"].get("ridge")
    if r and r.get("n_points"):
        t = bias_thr(r["v_mean"], sc)
        checks.append(dict(what="|среднее e| на гребнях, 60 м", value=abs(r["e_mean"]), thr=f"≤ {t:.3f}",
                           ok=abs(r["e_mean"]) <= t, kind="bias"))
    net_med = a["wind"]["median"]
    base = min(S[p]["area"]["wind"]["median"] for p in ("inflow", "mean"))
    ratio = net_med / base if base > 0 else float("inf")
    refuse = ratio >= sc["refuse_ratio"]
    checks.append(dict(what="медиана ошибки ветра сети / лучшей базовой линии (отказ — если ≥ порога)", value=ratio,
                       thr=f"< {sc['refuse_ratio']:g}", ok=not refuse, kind="ratio"))
    if refuse:
        v, why = "отказ от направления", "сеть на отложенных системах не лучше базовой линии (сжатия решателя нет)"
    elif all(c["ok"] for c in checks):
        v, why = "идём в волну 0", "все проверки ШП-2 на отложенных системах выполнены"
    else:
        bad = [c["what"] for c in checks if not c["ok"]]
        v, why = "правим подход", (f"не выполнено {len(bad)} из {len(checks)}: " + "; ".join(bad[:4])
                                   + ("…" if len(bad) > 4 else ""))
    return dict(verdict=v, reason=why, checks=checks, set=sc["set"], n_bins_rated=n_bins)


# ----------------------------------------------------------------------------------------- картинки
def fig_slices(rep: Path, F, cid, agl, a_key, idx):
    meta = json.loads(str(F[f"{cid}|meta"]))
    lw = level_weights(agl, a_key)
    th, tm = at_level(F[f"{cid}|truth_h"], lw), at_level(F[f"{cid}|truth_m"], lw)
    ph, pm = at_level(F[f"{cid}|net_h"], lw), at_level(F[f"{cid}|net_m"], lw)
    hc = F[f"{cid}|hc"]
    g = meta["g"]
    n = hc.shape[0]
    ext = [g["x0"] / 1000, (g["x0"] + n * g["dx"]) / 1000, g["y0"] / 1000, (g["y0"] + n * g["dx"]) / 1000]
    rows = [("скорость ветра с нагревом, м/с", np.hypot(th[0], th[1]), np.hypot(ph[0], ph[1]), "Blues", False),
            ("w без нагрева, м/с", tm[2], pm[2], "RdBu_r", True),
            ("w с нагревом, м/с", th[2], ph[2], "RdBu_r", True)]
    rid = F[f"{cid}|ridge"] if f"{cid}|ridge" in F.files else None
    e = int(meta.get("edge", 0))
    xs = np.linspace(ext[0], ext[1], n)
    fig, ax = plt.subplots(3, 3, figsize=(11, 10.2), constrained_layout=True)
    for r, (name, T, Pn, cmap, sym) in enumerate(rows):
        if sym:
            v = float(np.percentile(np.abs(np.concatenate([T.ravel(), Pn.ravel()])), 99.5)) or 1e-3
            lo, hi = -v, v
        else:
            lo, hi = 0.0, float(np.percentile(np.concatenate([T.ravel(), Pn.ravel()]), 99.5))
        D = Pn - T
        dv = float(np.percentile(np.abs(D), 99.5)) or 1e-3
        for c, (A, ttl, cm, a, b) in enumerate(((T, "решатель", cmap, lo, hi), (Pn, "сеть", cmap, lo, hi),
                                                (D, "сеть − решатель", "RdBu_r", -dv, dv))):
            im = ax[r, c].imshow(A, origin="lower", extent=ext, cmap=cm, vmin=a, vmax=b, interpolation="nearest")
            ax[r, c].contour(xs, xs, hc, levels=10, colors=MUTED, linewidths=0.4, alpha=0.6)
            if rid is not None and c == 2:
                full = np.zeros(hc.shape)
                full[e:n - e, e:n - e] = rid
                ax[r, c].contour(xs, xs, full, levels=[0.5], colors=INK, linewidths=0.6)
            if e:
                w = (n - 2 * e) * g["dx"] / 1000
                ax[r, c].add_patch(plt.Rectangle((ext[0] + e * g["dx"] / 1000, ext[2] + e * g["dx"] / 1000), w, w,
                                                 fill=False, ec=MUTED, lw=0.8, ls="--"))
            for (x, y) in meta["starts"]:
                ax[r, c].plot(x / 1000, y / 1000, marker="^", ms=8, color=INK, mec="white", mew=1.2, ls="none")
            ax[r, c].set_title(f"{ttl}: {name}", fontsize=9, color=INK)
            ax[r, c].grid(False)
            fig.colorbar(im, ax=ax[r, c], shrink=0.8)
            if r == 2:
                ax[r, c].set_xlabel("x (восток), км")
            if c == 0:
                ax[r, c].set_ylabel("y (север), км")
    fig.suptitle(f"{cid} — {SET_NAMES.get(meta['set'], meta['set'])}; срез {a_key:g} м над рельефом; пунктир — граница "
                 "области оценки; чёрный контур в разнице — гребни; ▲ — центры", fontsize=10, color=INK)
    p = rep / "figures" / f"{idx:02d}_срез_{cid}.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_curve(rep: Path, M, idx):
    cv = M["curve"]
    if len(cv) < 2:
        return None
    ec = M["config_eval"]
    a60 = ec["agl_key_m"]
    xs = [c["n_places"] for c in cv]
    fig, ax = plt.subplots(1, 3, figsize=(12, 3.8), constrained_layout=True)
    panels = (("доля «ок» ветра, область 60 м", lambda a: a["area"]["frac_wind_ok"], ec["shp2"]["frac_ok"]),
              ("медиана ошибки ветра, м/с", lambda a: a["area"]["wind"]["median"], None),
              (f"среднее e на {a60:g} м, м/с", lambda a: at_key(a["bias"]["e"], M["agl"], a60), 0.0))
    for k, (name, fn, ref) in enumerate(panels):
        for s in ("holdout_sys", "holdout_place"):
            ys = [fn(c[s]) if c.get(s) and (c[s].get("area") or {}).get("n_points") else np.nan for c in cv]
            if np.all(np.isnan(ys)):
                continue
            ax[k].plot(xs, ys, "-o", color=SET_COLOR[s], ms=6, label=SET_NAMES[s])
        if ref is not None:
            ax[k].axhline(ref, color=MUTED, ls="--", lw=1)
        ax[k].set_xscale("log", base=2)
        ax[k].set_xticks(xs, [str(x) for x in xs])
        ax[k].set_xlabel("мест П6 в обучении (+ прежние места пула)")
        ax[k].set_title(name, fontsize=9)
    ax[0].legend(frameon=False)
    fig.suptitle("Кривая (в): незнакомый рельеф от числа рельефов в обучении (последняя точка — основная сеть)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_кривая_рельефов.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_cdf(rep: Path, M, idx):
    ec = M["config_eval"]
    sets = [s for s in ("holdout_sys", "holdout_place", "holdout_proc", "newcond_p6", "newcond_old") if M["sets"].get(s)]
    if not sets:
        return None
    fig, ax = plt.subplots(len(sets), 3, figsize=(12, 2.9 * len(sets)), constrained_layout=True, squeeze=False)
    qq = np.linspace(0, 1, NQ)
    for r, s in enumerate(sets):
        for c, (key, name) in enumerate((("wind", "ошибка ветра с нагревом, м/с"), ("lift_m", "ошибка подъёма без нагрева, м/с"),
                                         ("lift_h", "ошибка подъёма с нагревом, м/с"))):
            for pn in PREDS:
                a = (M["sets"][s][pn].get("area") or {}).get(key)
                if a and a.get("q"):
                    ax[r, c].plot(a["q"], qq, color=PRED_COLOR[pn], lw=1.6, label=PRED_NAMES[pn])
            thr = ec["wind_ok_ms"] if key == "wind" else ec["lift_ok_ms"]
            ax[r, c].axvline(thr, color=MUTED, ls="--", lw=1)
            ax[r, c].axhline(ec["shp2"]["frac_ok"], color=GRID, lw=1)
            ax[r, c].set_xlim(left=0)
            ax[r, c].set_ylim(0, 1.02)
            ax[r, c].set_xlabel(name)
            if c == 0:
                ax[r, c].set_ylabel(f"{SET_NAMES[s]}\nдоля клеток")
    ax[0, 0].legend(frameon=False, loc="lower right")
    fig.suptitle("Распределение ошибок по клеткам области на 60 м: сеть против базовых линий "
                 "(пунктир — 0,3 и 0,1 м/с; для ветра порог ещё и 10 % |V|)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_распределения_ошибок.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_bias(rep: Path, M, idx):
    sets = [s for s in SETS if M["sets"].get(s)]
    if not sets:
        return None
    sc = M["config_eval"]["shp2"]
    agl = M["agl"]
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.2), constrained_layout=True)
    for s in sets:
        ax[0].plot(M["sets"][s]["net"]["bias"]["e"], agl, "-o", ms=4, color=SET_COLOR[s], label=SET_NAMES[s])
    S = M["sets"].get(sc["set"])
    if S:
        t = [bias_thr(v, sc) for v in S["net"]["bias"]["v"]]
        bins = list(S["net"]["bias_bins"])
        for j, lab in enumerate(bins):
            bb = S["net"]["bias_bins"][lab]
            ax[1].plot(bb["e"], agl, "-o", ms=4, color=SLOTS[j % len(SLOTS)], label=f"U10 {lab} м/с ({bb['cases']} сл.)")
        for k in (0, 1):
            ax[k].plot(t, agl, ls="--", color=MUTED, lw=1, label="порог ШП-2 (г)" if k == 0 else None)
            ax[k].plot([-x for x in t], agl, ls="--", color=MUTED, lw=1)
    for k, ttl in enumerate(("по наборам (сеть)", f"{SET_NAMES[sc['set']]} по корзинам U10")):
        ax[k].axvline(0, color=INK, lw=0.6)
        ax[k].set_yscale("log")
        ax[k].set_yticks(agl, [f"{a:g}" for a in agl])
        ax[k].axhline(sc["bias_max_agl_m"], color=GRID, lw=1)
        ax[k].set_xlabel("среднее e = |V сети| − |V решателя|, м/с")
        ax[k].set_ylabel("высота над рельефом, м")
        ax[k].set_title(ttl, fontsize=9)
        ax[k].legend(frameon=False, fontsize=7)
    fig.suptitle("Смещение скорости ветра с нагревом (среднее по клеткам области)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_смещение.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_terrain(rep: Path, M, idx):
    pl = (M.get("terrain") or {}).get("places") or {}
    if not pl:
        return None
    groups = sorted({f["group"] for f in pl.values()})
    fig, ax = plt.subplots(figsize=(6.8, 4.4), constrained_layout=True)
    for i, g in enumerate(groups):
        mine = [f for f in pl.values() if f["group"] == g]
        ax.plot([f["slope_p50"] for f in mine], [f["relief_m"] for f in mine], "o", ms=8, ls="none",
                color=SLOTS[i % len(SLOTS)], mec="white", mew=1.0, label=f"{g} ({len(mine)})")
    ax.set_xlabel("уклон 400 м, p50")
    ax.set_ylabel("размах высот, м")
    ax.legend(frameon=False, fontsize=7)
    ax.set_title("Признаки рельефа мест (П6 — из index.csv, прочие — из d400_hc)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_признаки_рельефа.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_history(rep: Path, M, idx):
    h = M["main"].get("history") or []
    if not h:
        return None
    fig, ax = plt.subplots(figsize=(6.5, 3.6), constrained_layout=True)
    e = [x["epoch"] + 1 for x in h]
    ax.plot(e, [x["train"] for x in h], color=SLOTS[0], label="обучение")
    ax.plot(e, [x["val"] for x in h], color=SLOTS[1], label="проверка (EMA)")
    ax.set_yscale("log")
    ax.set_xlabel("эпоха")
    ax.set_ylabel("потери (норм. MSE)")
    ax.legend(frameon=False)
    ax.set_title("Основная сеть: кривая обучения", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_кривая_обучения.png"
    fig.savefig(p)
    plt.close(fig)
    return p


# ------------------------------------------------------------------------------------------- оценка времени
def estimate(M):
    """Оценка полного обучения П-2: время на образец (tests/bench_epoch.py, иначе этот прогон) × образцы × эпохи."""
    es, mn = M.get("config_estimate") or {}, M["main"]
    if not es or "p6_pool_places" not in es:
        return None
    tps, src = mn.get("t_per_sample_ms"), "обучение этого прогона"
    bp = C.PILOT / es.get("bench", "tests/out/bench_epoch.json")
    b = None
    if bp.exists():
        b = json.loads(bp.read_text())
        tps, src = b["t_per_sample_ms"], (f"tests/bench_epoch.py ({b['n_train']} образцов, батч {b['batch']}, "
                                          f"{b.get('n_maps', '?')} карт)")
    if not tps:
        return None
    keep = 1 - es["newcond_frac"] - es["val_frac"]
    n_cond = es["n_cond"]
    NP = es["p6_pool_places"]
    n_train = (es["n_old_pool"] + NP * n_cond) * keep
    sizes = [s for s in es["curve_sizes"] if s < NP]
    n_curve = sum((es["n_old_pool"] + s * n_cond) * keep for s in sizes)
    t_main = tps / 1000 * n_train * es["max_epochs"]
    t_curve = tps / 1000 * n_curve * es["curve_max_epochs"]
    n_hold = es["n_old_hold"] + es["p6_holdout_places"] * n_cond
    n_eval_full = n_hold * (1 + len(sizes)) + (es["n_old_pool"] + NP * n_cond) * es["newcond_frac"] + 60
    t_eval = M["t_eval_s"] / max(M["n_eval_cases"], 1) * n_eval_full + 60
    return dict(src=src, t_per_sample_ms=tps, n_train_full=n_train, n_curve_samples=n_curve, curve_sizes=sizes,
                epochs_main=es["max_epochs"], epochs_curve=es["curve_max_epochs"], h_main=t_main / 3600,
                h_curve=t_curve / 3600, h_eval=t_eval / 3600, h_total=(t_main + t_curve + t_eval) / 3600,
                t_epoch_full_s=tps / 1000 * n_train,
                n_cases_full=es["n_old_pool"] + es["n_old_hold"] + (NP + es["p6_holdout_places"]) * n_cond)


# ------------------------------------------------------------------------------------------------ отчёт
def area_row(x, lab, pn):
    a = x.get("area") or {}
    if not a.get("n_points"):
        return None
    c = lambda k: f"{f2(a[k]['median'], 3)} ({f2(a[k]['p90'], 3)})"  # noqa: E731
    return (f"| {lab} | {PRED_NAMES[pn]} | {x['n_cases']} / {a['n_points']} | {pct(a['frac_wind_ok'])} | "
            f"{pct(a['frac_lift_m_ok'])} | {pct(a['frac_lift_h_ok'])} | {pct(a['frac_all_ok'])} | {c('wind')} | "
            f"{c('lift_m')} | {c('lift_h')} |")


def build_report(run: Path, rep: Path):
    M = json.loads((rep / "metrics.json").read_text())
    ec = M["config_eval"]
    sc = ec["shp2"]
    agl = M["agl"]
    a60 = ec["agl_key_m"]
    low = [i for i, a in enumerate(agl) if a <= sc["bias_max_agl_m"]]
    F = np.load(rep / "eval_fields.npz")
    order = list(SETS)
    cids = sorted({k.split("|")[0] for k in F.files},
                  key=lambda c: (order.index(json.loads(str(F[f"{c}|meta"]))["set"]), c))
    (rep / "figures").mkdir(exist_ok=True)
    for p in (rep / "figures").glob("*.png"):
        p.unlink()
    prog = Prog(rep, len(cids) + 5, "картинок", "отчёт")
    figs = []
    i = 1
    for cid in cids:
        figs.append(fig_slices(rep, F, cid, agl, ec["agl_key_m"], i)); i += 1
        prog.put(len(figs))
    for fn in (fig_curve, fig_bias, fig_cdf, fig_terrain, fig_history):
        p = fn(rep, M, i)
        if p:
            figs.append(p); i += 1
        prog.put(len(figs))
    R = shp2_rule(M)
    est = estimate(M)
    info = json.loads((run / "run_info.json").read_text())
    prof = info.get("profile") or ""
    md = []
    md.append(f"# Пилот air-nn П-2: отчёт `{rep.name}`" + (f" (профиль {prof})" if prof else "") + "\n")
    n_cases = sum(d["n_rows"] for d in M["datasets"])
    md.append(f"Построен {dt.datetime.now().isoformat(timespec='minutes')} скриптом `pilotnn/report.py` (коммит "
              f"{C.git_commit()}); прогон `{run}`; наборов {len(M['datasets'])}, случаев {n_cases}; контракт отчёта П3 v2.\n")
    if prof:
        md.append(f"> **профиль {prof}**: малый набор и мало эпох (подставной индекс П6 и набор terrain) — числа проверяют "
                  "конвейер, а не качество сети.\n")
    # --- вывод
    md.append("## Вывод ШП-2 (правилом из чисел, `config.yaml → eval.shp2`)\n")
    md.append(f"Главный набор — {SET_NAMES[R['set']]}. Ветер «ок» — |Δ(u,v)| ≤ max({ec['wind_ok_ms']:g} м/с; "
              f"{ec['wind_ok_rel'] * 100:g} % |V_решателя|); подъём «ок» — |Δw| < {ec['lift_ok_ms']:g} м/с; смещение — "
              f"|среднее e| ≤ max({sc['bias_abs_ms']:g} м/с; {sc['bias_rel'] * 100:g} % средней |V_решателя|) на высотах "
              f"≤ {sc['bias_max_agl_m']:g} м, в корзинах U10 с ≥ {sc['bin_min_cases']} случаями (оценено корзин: "
              f"{R.get('n_bins_rated', 0)}) и на гребнях; отказ — медиана ошибки ветра сети ≥ {sc['refuse_ratio']:g} × "
              "лучшей базовой линии.\n")
    if R["checks"]:
        md.append("| проверка | значение | порог | выполнено |")
        md.append("|---|---|---|---|")
        for c in R["checks"]:
            vs = pct(c["value"]) if c["kind"] == "frac" else f2(c["value"], 3)
            ts = f"≥ {pct(sc['frac_ok'])}" if c["kind"] == "frac" else c["thr"]
            md.append(f"| {c['what']} | {vs} | {ts} | {'да' if c['ok'] else '**нет**'} |")
    md.append(f"\n**ШП-2: {R['verdict']}** — {R['reason']}.\n")
    # --- наборы и деление
    md.append("## Наборы и деление\n")
    md.append("| набор | контракт | каталог | случаев | ok / max | мест |")
    md.append("|---|---|---|---|---|---|")
    for d in M["datasets"]:
        md.append(f"| {d['name']} | {d['contract']} | `{d['root']}` | {d['n_rows']} | {d['status']['ok']} / "
                  f"{d['status']['max']} | {len(d['places'])} |")
    sz, sp = M["split_sizes"], M["split"]
    systems = sorted(set(M["p6_systems"].values()))
    md.append(f"\nИндекс П6: `{M.get('p6_index')}`. Деление v3 (зерно {sp['seed']}): обучение {sz.get('train_ids')}, "
              f"проверка {sz.get('val_ids')}, (а) {sz.get('newcond_ids')} (места П6 {sz.get('newcond_p6_ids')}, прежние "
              f"{sz.get('newcond_old_ids')}), (г) {sz.get('holdout_sys_ids')} — {len(sp['holdout_sys'])} мест ("
              + (", ".join(f"{s}: {sum(1 for v in M['p6_systems'].values() if v == s)}" for s in systems) or "—")
              + f"), (б) {sz.get('holdout_place_ids')} ({', '.join(sp['holdout_places']) or '—'}), (б′) "
              f"{sz.get('holdout_proc_ids')} ({', '.join(sp['holdout_proc']) or '—'}); пул — мест П6 {len(sp['p6_pool'])} "
              f"+ прежних {len(sp['others'])}.\n")
    md.append("Оценено случаев: " + ", ".join(f"{SET_NAMES[k]} — {v}" for k, v in M["eval_sizes"].items()) + ".\n")
    # --- область
    hdr = ("| набор | предсказание | случаев / клеток | ветер ок | подъём б/н ок | подъём с/н ок | всё ок | ветер, м/с "
           "медиана (p90) | подъём б/н | подъём с/н |")
    md.append(f"## Область на 60 м (все клетки без {ec['edge_cells']} у края)\n")
    md.append("Ошибка против решателя AM-01 на 60 м над рельефом (линейно между 50 и 75 м). Ветер — |Δ(u,v)| с нагревом; "
              "подъём — |Δw| без и с нагревом.\n")
    md.append(hdr)
    md.append("|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            for pn in PREDS:
                r = area_row(d[pn], SET_NAMES[s], pn)
                if r:
                    md.append(r)
    # --- гребни
    md.append(f"\n## Гребни на 60 м (tpi_2k случая ≥ p{ec['ridge_pct']:g} по области)\n")
    md.append(hdr + " среднее e, м/с | средняя |V|, м/с |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        for pn in PREDS:
            x = dict(d[pn], area=d[pn].get("ridge"))
            r = area_row(x, SET_NAMES[s], pn)
            if r:
                md.append(r + f" {sg(x['area'].get('e_mean'))} | {f2(x['area'].get('v_mean'))} |")
    # --- центры
    md.append("\n## Центры (plan.json → centers)\n")
    md.append("Точки v1 (старты и вершины встроенных мест; у мест П6 — точки наибольшего превышения над окрестностью 2 км; "
              "у синтетики/процедурных — центр рельефа), билинейно; RMS 1 км — по клеткам в 1 км от точки.\n")
    md.append("| набор | предсказание | случаев / точек | ветер, м/с | подъём б/н | подъём с/н | RMS 1 км | ветер ок | "
              "подъём б/н ок | подъём с/н ок |")
    md.append("|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = (M.get("centers") or {}).get(s)
        if not d:
            continue
        for pn in PREDS:
            x = d[pn]
            if not x:
                continue
            cell = lambda k: f"{f2(x[k]['median'], 3)} ({f2(x[k]['p90'], 3)})" if x.get(k) else "—"  # noqa: E731
            md.append(f"| {SET_NAMES[s]} | {PRED_NAMES[pn]} | {x['n_cases']} / {x['n_points']} | {cell('wind')} | "
                      f"{cell('lift_m')} | {cell('lift_h')} | {cell('rms1km')} | {pct(x['frac_wind_ok'])} | "
                      f"{pct(x['frac_lift_m_ok'])} | {pct(x['frac_lift_h_ok'])} |")
    # --- смещение по высотам
    md.append("\n## Смещение скорости по высотам\n")
    md.append("Среднее по клеткам области e = |V_сети| − |V_решателя| (с нагревом), м/с; в скобках — средняя |V_решателя|. "
              "Строка «порог» — max(0,1; 2 %·|V|) для (г).\n")
    md.append("| набор | " + " | ".join(f"{a:g} м" for a in agl) + " |")
    md.append("|---|" + "---|" * len(agl))
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            b = d["net"]["bias"]
            md.append(f"| {SET_NAMES[s]} | " + " | ".join(f"{sg(e)} ({f2(v, 1)})" for e, v in zip(b["e"], b["v"])) + " |")
    S = M["sets"].get(sc["set"])
    if S:
        md.append("| порог (г) | " + " | ".join(f"{bias_thr(v, sc):.3f}" for v in S["net"]["bias"]["v"]) + " |")
    md.append("\nСмещение w (среднее Δw сети, м/с; без нагрева / с нагревом):\n")
    md.append("| набор | " + " | ".join(f"{a:g} м" for a in agl) + " |")
    md.append("|---|" + "---|" * len(agl))
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            b = d["net"]["bias"]
            md.append(f"| {SET_NAMES[s]} | " + " | ".join(f"{sg(m)} / {sg(h)}" for m, h in zip(b["w_m"], b["w_h"])) + " |")
    md.append(f"\nДля сравнения — смещение e на {a60:g} м (линейно между 50 и 75 м): сеть / профиль притока — "
              + "; ".join(f"{SET_NAMES[s]} {sg(at_key(M['sets'][s]['net']['bias']['e'], agl, a60))} / "
                          f"{sg(at_key(M['sets'][s]['inflow']['bias']['e'], agl, a60))}" for s in SETS if M["sets"].get(s))
              + ".\n")
    # --- корзины
    md.append("## Смещение по корзинам U10\n")
    md.append(f"Среднее e по клеткам области на высотах ≤ {sc['bias_max_agl_m']:g} м (сеть), в скобках — порог; корзины с < "
              f"{sc['bin_min_cases']} случаями в правило не входят.\n")
    md.append("| набор | U10, м/с | случаев | " + " | ".join(f"{agl[j]:g} м" for j in low) + " |")
    md.append("|---|---|---|" + "---|" * len(low))
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        for lab, bb in d["net"]["bias_bins"].items():
            md.append(f"| {SET_NAMES[s]} | {lab} | {bb['cases']} | " + " | ".join(
                f"{sg(bb['e'][j])} ({bias_thr(bb['v'][j], sc):.2f})" for j in low) + " |")
    # --- (г) по группам
    md.append("\n## (г) по системам и уклону\n")
    G = (M["sets"].get("holdout_sys") or {}).get("groups") or {}
    if G:
        md.append(f"Разбивка (г) по горным системам и корзинам уклона 400 м slope_p50 из индекса П6 (границы "
                  f"{ec.get('slope_bins')}); правило ШП-2 — по всему (г), разбивка — для понимания (отложенные системы положе "
                  "пула). Доли «ок» — клетки области на 60 м; e — среднее по клеткам области.\n")
        md.append(f"| группа | предсказание | случаев | ветер ок | подъём б/н ок | подъём с/н ок | медиана ветра, м/с | "
                  f"среднее e на {a60:g} м | max |e| ≤ {sc['bias_max_agl_m']:g} м (порог) | e на гребнях |")
        md.append("|---|---|---|---|---|---|---|---|---|---|")
        for g, d in G.items():
            for pn in ("net", "inflow"):
                x = d.get(pn)
                if not x or not (x.get("area") or {}).get("n_points"):
                    continue
                a = x["area"]
                j = max(low, key=lambda j: abs(x["bias"]["e"][j]))
                md.append(f"| {g} | {PRED_NAMES[pn]} | {x['n_cases']} | {pct(a['frac_wind_ok'])} | {pct(a['frac_lift_m_ok'])} | "
                          f"{pct(a['frac_lift_h_ok'])} | {f2(a['wind']['median'], 3)} | {sg(at_key(x['bias']['e'], agl, a60))} | "
                          f"{f2(abs(x['bias']['e'][j]), 3)} @ {agl[j]:g} м ({bias_thr(x['bias']['v'][j], sc):.3f}) | "
                          f"{sg((x.get('ridge') or {}).get('e_mean'))} |")
    else:
        md.append("Нет случаев (г) или индекса П6.\n")
    # --- кривая
    md.append("\n## Кривая (в): число рельефов П6 в обучении, оценка на (г) и (б)\n")
    if M["curve"]:
        md.append("| мест П6 | случаев обучения | лучшая проверка (эпоха) | набор | ветер ок | медиана ветра, м/с | медиана подъёма "
                  f"б/н / с/н | среднее e на {a60:g} м | max |e| ≤ {sc['bias_max_agl_m']:g} м |")
        md.append("|---|---|---|---|---|---|---|---|---|")
        for c in M["curve"]:
            b = c.get("best") or {}
            for s in ("holdout_sys", "holdout_place"):
                x = c.get(s)
                if not x or not (x.get("area") or {}).get("n_points"):
                    continue
                a = x["area"]
                mx = max(abs(x["bias"]["e"][j]) for j in low)
                md.append(f"| {c['n_places']}{' (= основная)' if c['is_main'] else ''} | {c['n_train']} | "
                          f"{f2(b.get('val'), 4)} ({(b.get('epoch') or 0) + 1}) | {SET_NAMES[s]} | {pct(a['frac_wind_ok'])} | "
                          f"{f2(a['wind']['median'], 3)} | {f2(a['lift_m']['median'], 3)} / {f2(a['lift_h']['median'], 3)} | "
                          f"{sg(at_key(x['bias']['e'], agl, a60))} | {f2(mx, 3)} |")
        md.append(f"\nПорядок мест П6 (слои `stratum` по кругу, внутри слоя — по хешу; зерно {sp['seed']}): "
                  + ", ".join(sp["curve_order"]) + f". В каждую точку входят прежние места пула ({len(sp['curve_base'])}).\n")
    else:
        md.append("Нет точек кривой (нет мест пула).\n")
    # --- рельеф
    md.append("## Признаки рельефа наборов\n")
    md.append("Уклон 400 м — |∇hc400| центральными разностями без 1 клетки у края (p50, p95 по клеткам места), размах — "
              "h_max − h_min; места П6 — из `index.csv`, прочие — из `d400_hc` теми же формулами. Медиана [мин–макс] по местам.\n")
    md.append("| группа | мест | уклон p50 | уклон p95 | размах, м |")
    md.append("|---|---|---|---|---|")
    for g, t in (M.get("terrain") or {}).get("groups", {}).items():
        cell = lambda k, n=3: f"{f2(t[k]['median'], n)} [{f2(t[k]['min'], n)}–{f2(t[k]['max'], n)}]"  # noqa: E731
        md.append(f"| {g} | {t['n_places']} | {cell('slope_p50')} | {cell('slope_p95')} | {cell('relief_m', 0)} |")
    # --- air-lite
    md.append("\n## Сравнение с регрессией air-lite (цели `build.py`)\n")
    md.append("Цели air-lite: механика (U10 ≥ 0,5 м/с) — вдоль/поперёк ветра и w без нагрева, м/с; нагрев — добавка "
              "(с нагревом − без) вдоль/поперёк, w_conv, м/с; θ′, К. rmse и skill = 1 − mse/var по всем высотам 25–2000 м. "
              f"**Оговорка: air-lite — окна 100 м у стартов, сеть — область 400 м (без {ec['edge_cells']} клеток у края); "
              "(а) здесь — места П6 и прежние вместе.**\n")
    md.append("| цель | сеть (а) rmse / skill | air-lite lin «новые условия» | air-lite gbm | сеть (б) rmse / skill | "
              "air-lite lin «место ongudai» | air-lite gbm |")
    md.append("|---|---|---|---|---|---|---|")
    ar = M.get("airlite_ref") or {}
    an = M.get("airlite_net") or {}
    for t in ("t_mpar", "t_mper", "t_mw", "t_cpar", "t_cper", "t_cw", "t_th"):
        def net(s):
            x = (an.get(s) or {}).get(t)
            return f"{f2(x['rmse'], 3)} / {f2(x['skill'])}" if x else "—"

        def al(kind, fold):
            x = ((ar.get(t) or {}).get(kind) or {}).get(fold)
            return f"{f2(x['rmse'], 3)} / {f2(x['skill'])}" if x else "—"
        md.append(f"| {t} | {net('newcond')} | {al('lin', 'новые условия')} | {al('gbm', 'новые условия')} | "
                  f"{net('holdout_place')} | {al('lin', 'место ongudai')} | {al('gbm', 'место ongudai')} |")
    # --- картинки
    md.append("\n## Картинки\n")
    for p in figs:
        md.append(f"![{p.stem}](figures/{p.name})")
    md.append("")
    o = M["onnx"]
    md.append("## ONNX и время на CPU\n")
    md.append(f"- `{o['path']}` (opset {o['opset']}, {f2(o['size_mb'])} МБ, вход maps {o['inputs']['maps']}, nums "
              f"{o['inputs']['nums']}, выход out (1, 91, 96, 96)); onnxruntime {o['onnxruntime']}.")
    md.append(f"- ORT ↔ PyTorch (fp32, CPU, 3 случая): max |Δ| = {o['ort_vs_torch_max_abs']:.2e} → "
              f"**{'≤ 1e-4, ок' if o['ort_vs_torch_ok'] else '> 1e-4, НЕ ок'}**.")
    for th, t in o["time_ms"].items():
        md.append(f"- Время ORT, {th} поток(а) intra-op: медиана {f2(t['median'], 1)} мс, мин {f2(t['min'], 1)} мс ({o['cpu']}).")
    mn = M["main"]
    md.append("\n## Обучение и время\n")
    md.append(f"- Сеть: U-Net + FiLM, каналы {M['config_train']['model']['channels']}, {mn['n_params'] / 1e6:.2f} млн "
              f"параметров; обучение {mn['n_train']} случаев, проверка {mn['n_val']}; эпох {mn['epochs']}, лучшая — "
              f"{mn['best']['epoch'] + 1} (проверка {f2(mn['best']['val'], 4)}); {mn['gpu']}, torch {mn['torch']}, "
              "детерминированный режим.")
    md.append(f"- Время эпохи (медиана): {f2(mn['t_epoch_median_s'])} с, на образец {f2(mn['t_per_sample_ms'])} мс "
              f"(с проверкой, без ожидания замка GPU). Оценка {M['n_eval_cases']} предсказаний: {f2(M['t_eval_s'], 0)} с "
              f"(сеть на GPU {f2(M.get('t_eval_gpu_s'), 0)} с).")
    if est:
        md.append(f"- **Оценка полного обучения П-2** (на образец {f2(est['t_per_sample_ms'])} мс — {est['src']}; случаев "
                  f"≈ {est['n_cases_full']}, обучающих ≈ {est['n_train_full']:.0f}; эпоха ≈ {f2(est['t_epoch_full_s'], 0)} с; "
                  f"эпох: основная {est['epochs_main']}, кривая {est['epochs_curve']}; точки кривой {est['curve_sizes']} мест П6 "
                  f"+ прежние места, {est['n_curve_samples']:.0f} образцов суммарно): основная сеть {f2(est['h_main'])} ч, "
                  f"кривая {f2(est['h_curve'])} ч, оценка {f2(est['h_eval'])} ч, **итого ≈ {f2(est['h_total'])} ч** "
                  "(верхняя граница — без ранней остановки; счёт набора — отдельно).")
    md.append("\n## Границы\n")
    md.append("- Эталон — решатель AM-01 «как игра» (400 м, 1-й порядок), не измерения: числа — точность сжатия решателя "
              "сетью, а не точность ветра в природе. Места П6 — своя широта/дата (`ctx`), прежние места — июль, широта Онгудая.")
    md.append("- Проверка по типам рельефа, линейная теория и паттерны — не в пилоте П-2 (решение пользователя 02.10).")
    md.append(f"- «Обучающие» — до {ec.get('max_train_eval', 60)} случаев обучения (проверка, что сеть учится; не оценка "
              "качества).")
    md.append("- Гребни — по процентилю tpi_2k своего случая: «гребни» есть у любого рельефа (у пологого — условные).")
    (rep / "report.md").write_text("\n".join(md) + "\n")
    C.atomic_write_json(rep / "shp2.json", R)
    m = C.read_json(rep / "manifest.json", {})
    C.write_manifest(rep, m.get("what", "оценка и отчёт пилота (П3 v2)"), m.get("inputs_hash", ""), True, run=str(run),
                     report_built=True, verdict=f"ШП-2: {R['verdict']}", figures=[p.name for p in figs])
    prog.put(len(figs), force=True)
    print(f"отчёт: {rep / 'report.md'}; {len(figs)} картинок; ШП-2: {R['verdict']}", flush=True)
    return C.EXIT_OK
