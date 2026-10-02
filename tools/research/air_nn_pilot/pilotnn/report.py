"""Отчёт пилота (контракт П3 v3): картинки + report.md из metrics.json; все числа — раздельно для сошедшихся и
несошедшихся решений. Вывод ШП-2 — правилом из чисел (`config.yaml → eval.shp2`, функция `shp2_rule`; ею же пользуются
tests/check_report_v3.py и tests/test_verdict.py)."""
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
from .evaluate import GROUP_NAMES, NQ, PRED_NAMES, PREDS, SET_NAMES, SETS, Prog, at_level, level_weights  # noqa: E402

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
GR2 = ("conv", "nc")                       # группы таблиц: сошедшиеся, несошедшиеся
# разделы report.md (П3 v3) — проверяет tests/check_report_v3.py
SECTIONS = ("## Вывод ШП-2", "## ШП-2: сошедшиеся и несошедшиеся", "## Наборы и деление", "## Область на 60 м", "## Гребни на 60 м",
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


def grp(x, g):
    """Группа g («conv»/«nc»/«all») результата предсказания набора; None, если случаев группы нет."""
    return (x or {}).get(g)


def rule_checks(G, ec, sc, agl):
    """Правило v2 (доли «ок», смещение по высотам, корзинам U10 и гребням) на одной группе G = результат AreaAcc[g]
    (сеть). → (checks, n_bins). Проверки: dict(what, value, thr, ok, kind)."""
    checks = []
    a = G["area"]
    for k, nm in (("frac_wind_ok", f"доля «ок» ветра (≤ max({ec['wind_ok_ms']:g} м/с; {ec['wind_ok_rel'] * 100:g} % |V|))"),
                  ("frac_lift_m_ok", f"доля «ок» подъёма без нагрева (< {ec['lift_ok_ms']:g} м/с)"),
                  ("frac_lift_h_ok", f"доля «ок» подъёма с нагревом (< {ec['lift_ok_ms']:g} м/с)")):
        v = a.get(k)
        checks.append(dict(what=nm + ", область 60 м", value=v, thr=f"≥ {sc['frac_ok']:g}",
                           ok=v is not None and v >= sc["frac_ok"], kind="frac"))
    b = G["bias"]
    for i, z in enumerate(agl):
        if z > sc["bias_max_agl_m"]:
            continue
        t = bias_thr(b["v"][i], sc)
        checks.append(dict(what=f"|среднее e|, {z:g} м", value=abs(b["e"][i]), thr=f"≤ {t:.3f}", ok=abs(b["e"][i]) <= t,
                           kind="bias"))
    n_bins = 0
    for lab, bb in G["bias_bins"].items():
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
    r = G.get("ridge")
    if r and r.get("n_points"):
        t = bias_thr(r["v_mean"], sc)
        checks.append(dict(what="|среднее e| на гребнях, 60 м", value=abs(r["e_mean"]), thr=f"≤ {t:.3f}",
                           ok=abs(r["e_mean"]) <= t, kind="bias"))
    return checks, n_bins


def shp2_rule(M):
    """Вердикт ШП-2 (П3 v3, план §8.2) по числам metrics.json → dict(verdict, reason, checks, refuse, nc, ...).
    1. «отказ от направления»: медиана ошибки ветра сети на (г) (ВСЕ случаи, обе группы) ≥ refuse_ratio × наименьшей из
       медиан базовых линий (профиль притока, среднее; регрессия air-lite не входит — metrics.json → refuse_baselines);
    2. иначе «идём в волну 0»: правило v2 выполнено на СОШЕДШИХСЯ решениях (г);
    3. иначе «правим подход».
    Правило v2 на несошедшихся (`nc`) — отдельная строка таблицы, в вердикт не входит.
    checks — сначала проверка отказа (kind «ratio»), затем проверки правила v2 на сошедшихся."""
    ec = M["config_eval"]
    sc = ec["shp2"]
    agl = M["agl"]
    S = (M["sets"] or {}).get(sc["set"])
    out = dict(set=sc["set"], checks=[], n_bins_rated=0, refuse=None, nc=None)
    al = grp(S["net"], "all") if S else None
    if not al or not (al["area"] or {}).get("n_points"):
        return dict(out, verdict="правим подход",
                    reason=f"нет случаев набора {SET_NAMES[sc['set']]} — правило не применимо")
    net_med = al["area"]["wind"]["median"]
    bases = {p: S[p]["all"]["area"]["wind"]["median"] for p in ("inflow", "mean")}
    bname = min(bases, key=bases.get)
    base = bases[bname]
    ratio = net_med / base if base > 0 else float("inf")
    refuse = ratio >= sc["refuse_ratio"]
    out["refuse"] = dict(net_median=net_med, base_medians=bases, base=bname, base_median=base, ratio=ratio,
                         thr=sc["refuse_ratio"], refused=refuse, n_cases=S["net"]["all"]["n_cases"])
    out["checks"].append(dict(what="отказ: медиана ошибки ветра сети / лучшей базовой линии, все случаи (г)", value=ratio,
                              thr=f"< {sc['refuse_ratio']:g}", ok=not refuse, kind="ratio"))
    cv = grp(S["net"], "conv")
    cv_ok = bool(cv and (cv["area"] or {}).get("n_points"))
    if cv_ok:
        ck, nb = rule_checks(cv, ec, sc, agl)
        out["checks"] += ck
        out["n_bins_rated"] = nb
    nc = grp(S["net"], "nc")
    if nc and (nc["area"] or {}).get("n_points"):
        ck, nb = rule_checks(nc, ec, sc, agl)
        out["nc"] = dict(n_cases=nc["n_cases"], applicable=True, ok=all(c["ok"] for c in ck), n_failed=sum(not c["ok"] for c in ck),
                         n_checks=len(ck), checks=ck, n_bins_rated=nb, spread_ratio=nc.get("spread_ratio"),
                         frac_wind_ok=nc["area"].get("frac_wind_ok"), frac_lift_m_ok=nc["area"].get("frac_lift_m_ok"),
                         frac_lift_h_ok=nc["area"].get("frac_lift_h_ok"))
    else:
        out["nc"] = dict(n_cases=(nc or {}).get("n_cases", 0), applicable=False)
    rule = out["checks"][1:]
    if refuse:
        v, why = "отказ от направления", ("сеть на отложенных системах (все случаи) не лучше базовой линии — "
                                          f"{bname}: сжатия решателя нет")
    elif not cv_ok:
        v, why = "правим подход", "на отложенных системах нет сошедшихся решений — правило v2 не к чему применить"
    elif all(c["ok"] for c in rule):
        v, why = "идём в волну 0", "правило ШП-2 на сошедшихся решениях отложенных систем выполнено"
    else:
        bad = [c["what"] for c in rule if not c["ok"]]
        v, why = "правим подход", (f"на сошедшихся не выполнено {len(bad)} из {len(rule)}: " + "; ".join(bad[:4])
                                   + ("…" if len(bad) > 4 else ""))
    return dict(out, verdict=v, reason=why)


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
    cg = lambda c: (c or {}).get("conv")  # noqa: E731    # рисуем сошедшиеся (несошедшие — в таблице)
    for k, (name, fn, ref) in enumerate(panels):
        for s in ("holdout_sys", "holdout_place"):
            ys = [fn(cg(c.get(s))) if cg(c.get(s)) and (cg(c.get(s)).get("area") or {}).get("n_points") else np.nan
                  for c in cv]
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
    fig.suptitle("Кривая (в), сошедшиеся решения: незнакомый рельеф от числа рельефов в обучении (последняя точка — основная сеть)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_кривая_рельефов.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_cdf(rep: Path, M, idx):
    ec = M["config_eval"]
    sets = [s for s in ("holdout_sys", "holdout_place", "holdout_proc", "newcond_p6", "newcond_old")
            if (M["sets"].get(s) or {}).get("net", {}).get("conv")]
    if not sets:
        return None
    fig, ax = plt.subplots(len(sets), 3, figsize=(12, 2.9 * len(sets)), constrained_layout=True, squeeze=False)
    qq = np.linspace(0, 1, NQ)
    for r, s in enumerate(sets):
        for c, (key, name) in enumerate((("wind", "ошибка ветра с нагревом, м/с"), ("lift_m", "ошибка подъёма без нагрева, м/с"),
                                         ("lift_h", "ошибка подъёма с нагревом, м/с"))):
            for pn in PREDS:
                a = ((M["sets"][s][pn].get("conv") or {}).get("area") or {}).get(key)
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
    fig.suptitle("Сошедшиеся решения: распределение ошибок по клеткам области на 60 м: сеть против базовых линий "
                 "(пунктир — 0,3 и 0,1 м/с; для ветра порог ещё и 10 % |V|)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_распределения_ошибок.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_bias(rep: Path, M, idx):
    sets = [s for s in SETS if (M["sets"].get(s) or {}).get("net", {}).get("conv")]
    if not sets:
        return None
    sc = M["config_eval"]["shp2"]
    agl = M["agl"]
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.2), constrained_layout=True)
    for s in sets:
        ax[0].plot(M["sets"][s]["net"]["conv"]["bias"]["e"], agl, "-o", ms=4, color=SET_COLOR[s], label=SET_NAMES[s])
    S = grp((M["sets"].get(sc["set"]) or {}).get("net"), "conv")
    if S:
        t = [bias_thr(v, sc) for v in S["bias"]["v"]]
        bins = list(S["bias_bins"])
        for j, lab in enumerate(bins):
            bb = S["bias_bins"][lab]
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
    fig.suptitle("Сошедшиеся решения: смещение скорости ветра с нагревом (среднее по клеткам области)", fontsize=10)
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
def n_str(x):
    """Число случаев группы: h (ветер, w с нагревом) / m (w без нагрева)."""
    return f"{x['n_cases']} / {x['n_cases_m']}"


def area_row(x, lab, pn, g):
    """Строка таблицы области/гребней: x — результат группы g предсказания pn."""
    if not x:
        return None
    a = x.get("area") or {}
    if not a.get("n_points"):
        return None
    c = lambda k: f"{f2(a[k]['median'], 3)} ({f2(a[k]['p90'], 3)})" if a.get(k) else "—"  # noqa: E731
    return (f"| {lab} | {GROUP_NAMES[g]} | {PRED_NAMES[pn]} | {n_str(x)} / {a['n_points']} | {pct(a['frac_wind_ok'])} | "
            f"{pct(a.get('frac_lift_m_ok'))} | {pct(a['frac_lift_h_ok'])} | {pct(a.get('frac_all_ok'))} | {c('wind')} | "
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
              f"{C.git_commit()}); прогон `{run}`; наборов {len(M['datasets'])}, случаев {n_cases}; контракт отчёта П3 v3.\n")
    gn = M.get("groups_note") or {}
    md.append("**Группы решений (П3 v3).** Все числа ниже — раздельно: **сошедшиеся** — " + gn.get("conv", "") .split(": ", 1)[-1]
              + "; **несошедшиеся** — " + gn.get("nc", "").split(": ", 1)[-1] + ". " + gn.get("by", "").capitalize()
              + ". В таблицах «случаев» — h / m: число случаев группы по статусу `h` / по статусу `m`; «клеток» — клетки "
              "области (ветер, подъём с нагревом).\n")
    if prof:
        md.append(f"> **профиль {prof}**: малый набор и мало эпох (малый набор terrain на настоящих местах П6) — числа проверяют "
                  "конвейер, а не качество сети.\n")
    # --- вывод
    md.append("## Вывод ШП-2 (правилом из чисел, `config.yaml → eval.shp2`)\n")
    md.append(f"Главный набор — {SET_NAMES[R['set']]}. Порядок правила П3 v3: (1) **отказ**, если медиана ошибки ветра сети "
              f"на (г) по всем случаям ≥ {sc['refuse_ratio']:g} × наименьшей из медиан базовых линий (профиль притока, "
              "среднее по обучению; **регрессия air-lite в сравнение не входит** — она на окнах 100 м и старых фолдах, на "
              "отложенных системах и области 400 м её нет); (2) иначе **идём в волну 0**, если правило v2 выполнено на "
              f"сошедшихся решениях (г): ветер «ок» — |Δ(u,v)| ≤ max({ec['wind_ok_ms']:g} м/с; {ec['wind_ok_rel'] * 100:g} % "
              f"|V_решателя|), подъём «ок» — |Δw| < {ec['lift_ok_ms']:g} м/с, |среднее e| ≤ max({sc['bias_abs_ms']:g} м/с; "
              f"{sc['bias_rel'] * 100:g} % средней |V_решателя|) на высотах ≤ {sc['bias_max_agl_m']:g} м, в корзинах U10 с ≥ "
              f"{sc['bin_min_cases']} случаями (оценено корзин: {R.get('n_bins_rated', 0)}) и на гребнях; (3) иначе "
              "**правим подход**. Несошедшиеся — отдельной строкой ниже, в вердикт не входят.\n")
    if R["checks"]:
        md.append("| проверка | значение | порог | выполнено |")
        md.append("|---|---|---|---|")
        for c in R["checks"]:
            vs = "—" if c["value"] is None else pct(c["value"]) if c["kind"] == "frac" else f2(c["value"], 3)
            ts = f"≥ {pct(sc['frac_ok'])}" if c["kind"] == "frac" else c["thr"]
            md.append(f"| {c['what']} | {vs} | {ts} | {'да' if c['ok'] else '**нет**'} |")
    md.append(f"\n**ШП-2: {R['verdict']}** — {R['reason']}.\n")
    # --- таблица ШП-2 по группам
    md.append("## ШП-2: сошедшиеся и несошедшиеся\n")
    rf = R.get("refuse")
    if rf:
        md.append(f"Отказ: медиана ошибки ветра сети на (г) по всем случаям ({rf['n_cases']}) {f2(rf['net_median'], 3)} м/с; "
                  f"базовые линии — профиль притока {f2(rf['base_medians']['inflow'], 3)}, среднее {f2(rf['base_medians']['mean'], 3)} "
                  f"м/с (лучшая — {PRED_NAMES[rf['base']]}); отношение {f2(rf['ratio'], 3)}, порог < {rf['thr']:g} → "
                  f"**{'отказ' if rf['refused'] else 'не отказ'}**.\n")
    md.append("| группа решений (г) | случаев (h / m) | ветер ок | подъём б/н ок | подъём с/н ок | правило v2 | в вердикте |")
    md.append("|---|---|---|---|---|---|---|")
    S = (M["sets"].get(R["set"]) or {}).get("net") or {}
    cvr = grp(S, "conv")
    if cvr and (cvr["area"] or {}).get("n_points"):
        ck = [c for c in R["checks"] if c["kind"] != "ratio"]
        md.append(f"| сошедшиеся | {n_str(cvr)} | {pct(cvr['area']['frac_wind_ok'])} | {pct(cvr['area'].get('frac_lift_m_ok'))} | "
                  f"{pct(cvr['area']['frac_lift_h_ok'])} | {'выполнено' if all(c['ok'] for c in ck) else 'не выполнено'} "
                  f"({sum(not c['ok'] for c in ck)} из {len(ck)} проверок не выполнено) | да |")
    else:
        md.append("| сошедшиеся | 0 | — | — | — | не к чему применить | да |")
    nc = R.get("nc") or {}
    if nc.get("applicable"):
        md.append(f"| **несошедшиеся** | {n_str(grp(S, 'nc'))} | {pct(nc['frac_wind_ok'])} | {pct(nc['frac_lift_m_ok'])} | "
                  f"{pct(nc['frac_lift_h_ok'])} | {'выполнено' if nc['ok'] else 'не выполнено'} ({nc['n_failed']} из "
                  f"{nc['n_checks']} проверок не выполнено) | **нет** (цель шумит: свой разброс p90 ≈ 0,9 м/с против 0,3) |")
        sr = nc.get("spread_ratio") or {}
        md.append(f"\nНесошедшиеся: ошибка ветра сети относительно собственного разброса решения (медиана по случаям от "
                  f"медианы ошибки на 60 м к `late_spread60_p90`): "
                  + (f"медиана {f2(sr['median'], 2)}, p90 {f2(sr['p90'], 2)} по {sr['n']} случаям (цель late_mean)."
                     if sr.get("n") else "нет случаев с late_spread60_p90 (цель last у набора v1)."
                     ) + " Отношение ≈ 1 — ошибка сети сравнима с шумом цели; ≫ 1 — ошибка больше шума.\n")
    else:
        md.append(f"| **несошедшиеся** | {nc.get('n_cases', 0)} | — | — | — | не к чему применить | **нет** |")
        md.append("")
    # --- наборы и деление
    md.append("## Наборы и деление\n")
    md.append("| набор | контракт | каталог | случаев | ok / max | мест |")
    md.append("|---|---|---|---|---|---|")
    for d in M["datasets"]:
        md.append(f"| {d['name']} | {d['contract']} | `{d['root']}` | {d['n_rows']} | {d['status']['ok']} / "
                  f"{d['status']['max']} | {len(d['places'])} |")
    p6j = C.read_json(run / "p6.json", {}).get("places") or {}
    if 0 < len(p6j) <= 20:   # мини-наборы (smoke): места П6 по строкам; в полном прогоне (сотни мест) — только индекс
        sp0 = M["split"]
        md.append("\n| место П6 | система | часть | слой | уклон p50 | размах, м | в делении |")
        md.append("|---|---|---|---|---|---|---|")
        for l in sorted(p6j):
            r = p6j[l]
            role = "(г)" if l in sp0["holdout_sys"] else "пул" + (", кривая" if l in sp0.get("curve_order", []) else "")
            md.append(f"| {l} | {r.get('system')} | {r.get('part')} | {r.get('stratum')} | {float(r['slope_p50']):.3f} | "
                      f"{float(r['relief_m']):.0f} | {role} |")
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
    md.append("Группы по наборам оценки (случаев h: сошедшиеся / несошедшиеся; цели несошедшихся h — число решений по "
              "виду цели):\n")
    md.append("| набор | сошедшиеся | несошедшиеся | цели несошедшихся (h) |")
    md.append("|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        x = d["net"]
        n_nc = (x["nc"] or {}).get("n_cases", 0)
        tg = ", ".join(f"{k}: {v}" for k, v in ((x["nc"] or {}).get("targets_h") or {}).items()) or "—"
        md.append(f"| {SET_NAMES[s]} | {(x['conv'] or {}).get('n_cases', 0)} | {n_nc} | {tg} |")
    # --- область
    hdr = ("| набор | группа | предсказание | случаев (h / m) / клеток | ветер ок | подъём б/н ок | подъём с/н ок | всё ок | "
           "ветер, м/с медиана (p90) | подъём б/н | подъём с/н |")
    md.append(f"\n## Область на 60 м (все клетки без {ec['edge_cells']} у края)\n")
    md.append("Ошибка против решателя AM-01 на 60 м над рельефом (линейно между 50 и 75 м). Ветер — |Δ(u,v)| с нагревом; "
              "подъём — |Δw| без и с нагревом. «Всё ок» — клетки, где ок и ветер, и оба подъёма (случаи, где сошлись и `h`, и "
              "`m`; у несошедшихся — хотя бы одно не сошлось).\n")
    md.append(hdr)
    md.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            for pn in PREDS:
                for g in GR2:
                    r = area_row(d[pn][g], SET_NAMES[s], pn, g)
                    if r:
                        md.append(r)
    # --- гребни
    md.append(f"\n## Гребни на 60 м (tpi_2k случая ≥ p{ec['ridge_pct']:g} по области)\n")
    md.append(hdr + " среднее e, м/с | средняя |V|, м/с |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        for pn in PREDS:
            for g in GR2:
                x = d[pn][g]
                if not x:
                    continue
                x = dict(x, area=x.get("ridge"))
                r = area_row(x, SET_NAMES[s], pn, g)
                if r:
                    md.append(r + f" {sg(x['area'].get('e_mean'))} | {f2(x['area'].get('v_mean'))} |")
    # --- центры
    md.append("\n## Центры (plan.json → centers)\n")
    md.append("Точки v1 (старты и вершины встроенных мест; у мест П6 — точки наибольшего превышения над окрестностью 2 км; "
              "у синтетики/процедурных — центр рельефа), билинейно; RMS 1 км — по клеткам в 1 км от точки.\n")
    md.append("| набор | группа | предсказание | случаев / точек | ветер, м/с | подъём б/н | подъём с/н | RMS 1 км | ветер ок | "
              "подъём б/н ок | подъём с/н ок |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = (M.get("centers") or {}).get(s)
        if not d:
            continue
        for pn in PREDS:
            for g in GR2:
                x = d[pn][g]
                if not x or not x.get("n_points"):
                    continue
                cell = lambda k: f"{f2(x[k]['median'], 3)} ({f2(x[k]['p90'], 3)})" if x.get(k) else "—"  # noqa: E731
                md.append(f"| {SET_NAMES[s]} | {GROUP_NAMES[g]} | {PRED_NAMES[pn]} | {x['n_cases']} / {x['n_points']} | "
                          f"{cell('wind')} | {cell('lift_m')} | {cell('lift_h')} | {cell('rms1km')} | "
                          f"{pct(x['frac_wind_ok'])} | {pct(x.get('frac_lift_m_ok'))} | {pct(x['frac_lift_h_ok'])} |")
    # --- смещение по высотам
    md.append("\n## Смещение скорости по высотам\n")
    md.append("Среднее по клеткам области e = |V_сети| − |V_решателя| (с нагревом), м/с; в скобках — средняя |V_решателя|. "
              "Строка «порог» — max(0,1; 2 %·|V|) для (г), сошедшиеся.\n")
    md.append("| набор | группа | " + " | ".join(f"{a:g} м" for a in agl) + " |")
    md.append("|---|---|" + "---|" * len(agl))
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            for g in GR2:
                if d["net"][g]:
                    b = d["net"][g]["bias"]
                    md.append(f"| {SET_NAMES[s]} | {GROUP_NAMES[g]} | " + " | ".join(
                        f"{sg(e)} ({f2(v, 1)})" for e, v in zip(b["e"], b["v"])) + " |")
    Sc = grp((M["sets"].get(sc["set"]) or {}).get("net"), "conv")
    if Sc:
        md.append("| порог (г) | сошедшиеся | " + " | ".join(f"{bias_thr(v, sc):.3f}" for v in Sc["bias"]["v"]) + " |")
    md.append("\nСмещение w (среднее Δw сети, м/с; без нагрева [по `m`] / с нагревом [по `h`]):\n")
    md.append("| набор | группа | " + " | ".join(f"{a:g} м" for a in agl) + " |")
    md.append("|---|---|" + "---|" * len(agl))
    for s in SETS:
        d = M["sets"].get(s)
        if d:
            for g in GR2:
                if d["net"][g]:
                    b = d["net"][g]["bias"]
                    md.append(f"| {SET_NAMES[s]} | {GROUP_NAMES[g]} | " + " | ".join(
                        f"{sg(m)} / {sg(h)}" for m, h in zip(b["w_m"], b["w_h"])) + " |")
    cmp_ = []
    for s in SETS:
        d = M["sets"].get(s)
        if d and d["net"]["conv"]:
            cmp_.append(f"{SET_NAMES[s]} {sg(at_key(d['net']['conv']['bias']['e'], agl, a60))} / "
                        f"{sg(at_key(d['inflow']['conv']['bias']['e'], agl, a60))}")
    md.append(f"\nДля сравнения — смещение e на {a60:g} м (линейно между 50 и 75 м), сошедшиеся: сеть / профиль притока — "
              + "; ".join(cmp_) + ".\n")
    # --- корзины
    md.append("## Смещение по корзинам U10\n")
    md.append(f"Среднее e по клеткам области на высотах ≤ {sc['bias_max_agl_m']:g} м (сеть), в скобках — порог; корзины с < "
              f"{sc['bin_min_cases']} случаями в правило не входят.\n")
    md.append("| набор | группа | U10, м/с | случаев | " + " | ".join(f"{agl[j]:g} м" for j in low) + " |")
    md.append("|---|---|---|---|" + "---|" * len(low))
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        for g in GR2:
            if not d["net"][g]:
                continue
            for lab, bb in d["net"][g]["bias_bins"].items():
                md.append(f"| {SET_NAMES[s]} | {GROUP_NAMES[g]} | {lab} | {bb['cases']} | " + " | ".join(
                    f"{sg(bb['e'][j])} ({bias_thr(bb['v'][j], sc):.2f})" for j in low) + " |")
    # --- (г) по группам
    md.append("\n## (г) по системам и уклону\n")
    G = (M["sets"].get("holdout_sys") or {}).get("groups") or {}
    if G:
        md.append(f"Разбивка (г) по горным системам и корзинам уклона 400 м slope_p50 из индекса П6 (границы "
                  f"{ec.get('slope_bins')}); правило ШП-2 — по всему (г), разбивка — для понимания (отложенные системы положе "
                  "пула). Доли «ок» — клетки области на 60 м; e — среднее по клеткам области.\n")
        md.append(f"| группа рельефа | решения | предсказание | случаев (h / m) | ветер ок | подъём б/н ок | подъём с/н ок | "
                  f"медиана ветра, м/с | среднее e на {a60:g} м | max |e| ≤ {sc['bias_max_agl_m']:g} м (порог) | "
                  "e на гребнях |")
        md.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for gname, d in G.items():
            for pn in ("net", "inflow"):
                for g in GR2:
                    x = d.get(pn, {}).get(g)
                    if not x or not (x.get("area") or {}).get("n_points"):
                        continue
                    a = x["area"]
                    j = max(low, key=lambda j: abs(x["bias"]["e"][j]))
                    md.append(f"| {gname} | {GROUP_NAMES[g]} | {PRED_NAMES[pn]} | {n_str(x)} | {pct(a['frac_wind_ok'])} | "
                              f"{pct(a.get('frac_lift_m_ok'))} | {pct(a['frac_lift_h_ok'])} | {f2(a['wind']['median'], 3)} | "
                              f"{sg(at_key(x['bias']['e'], agl, a60))} | {f2(abs(x['bias']['e'][j]), 3)} @ {agl[j]:g} м "
                              f"({bias_thr(x['bias']['v'][j], sc):.3f}) | {sg((x.get('ridge') or {}).get('e_mean'))} |")
    else:
        md.append("Нет случаев (г) или индекса П6.\n")
    # --- кривая
    md.append("\n## Кривая (в): число рельефов П6 в обучении, оценка на (г) и (б)\n")
    if M["curve"]:
        md.append("| мест П6 | случаев обучения | лучшая проверка (эпоха) | набор | решения | случаев (h / m) | ветер ок | "
                  f"медиана ветра, м/с | медиана подъёма б/н / с/н | среднее e на {a60:g} м | max |e| ≤ {sc['bias_max_agl_m']:g} м |")
        md.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for c in M["curve"]:
            b = c.get("best") or {}
            for s in ("holdout_sys", "holdout_place"):
                for g in GR2:
                    x = (c.get(s) or {}).get(g)
                    if not x or not (x.get("area") or {}).get("n_points"):
                        continue
                    a = x["area"]
                    mx = max(abs(x["bias"]["e"][j]) for j in low)
                    lm = f2(a["lift_m"]["median"], 3) if a.get("lift_m") else "—"
                    md.append(f"| {c['n_places']}{' (= основная)' if c['is_main'] else ''} | {c['n_train']} | "
                              f"{f2(b.get('val'), 4)} ({(b.get('epoch') or 0) + 1}) | {SET_NAMES[s]} | {GROUP_NAMES[g]} | "
                              f"{n_str(x)} | {pct(a['frac_wind_ok'])} | {f2(a['wind']['median'], 3)} | "
                              f"{lm} / {f2(a['lift_h']['median'], 3)} | "
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
    md.append("Цели: механика (t_m*) — по статусу `m`, θ′ — по `h`, добавка нагрева (t_c*) — сошлись и `h`, и `m`. "
              "air-lite — одна общая оценка (его фолды без деления по сходимости).\n")
    md.append("| цель | сеть (а) сошедшиеся | сеть (а) несошедшиеся | air-lite lin «новые условия» | air-lite gbm | "
              "сеть (б) сошедшиеся | сеть (б) несошедшиеся | air-lite lin «место ongudai» | air-lite gbm |")
    md.append("|---|---|---|---|---|---|---|---|---|")
    ar = M.get("airlite_ref") or {}
    an = M.get("airlite_net") or {}
    for t in ("t_mpar", "t_mper", "t_mw", "t_cpar", "t_cper", "t_cw", "t_th"):
        def net(s, g):
            x = ((an.get(s) or {}).get(g) or {}).get(t)
            return f"{f2(x['rmse'], 3)} / {f2(x['skill'])} (n={x['n']})" if x else "—"

        def al(kind, fold):
            x = ((ar.get(t) or {}).get(kind) or {}).get(fold)
            return f"{f2(x['rmse'], 3)} / {f2(x['skill'])}" if x else "—"
        md.append(f"| {t} | {net('newcond', 'conv')} | {net('newcond', 'nc')} | {al('lin', 'новые условия')} | "
                  f"{al('gbm', 'новые условия')} | {net('holdout_place', 'conv')} | {net('holdout_place', 'nc')} | "
                  f"{al('lin', 'место ongudai')} | {al('gbm', 'место ongudai')} |")
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
    md.append("- Несошедшиеся решения (статус `max`): цель — среднее поздних состояний (late_mean, П1 v3) или последнее состояние "
              "(набор v1); у них свой разброс p90 ≈ 0,9 м/с (NN-P6) против порога «ок» 0,3 м/с, поэтому правило v2 на них — "
              "справочная строка, не вердикт.")
    md.append("- Отказ сравнивает сеть с лучшей из двух базовых линий (профиль притока, среднее); регрессия air-lite не входит "
              "(окна 100 м, старые фолды).")
    md.append("- Гребни — по процентилю tpi_2k своего случая: «гребни» есть у любого рельефа (у пологого — условные).")
    (rep / "report.md").write_text("\n".join(md) + "\n")
    C.atomic_write_json(rep / "shp2.json", R)
    m = C.read_json(rep / "manifest.json", {})
    C.write_manifest(rep, m.get("what", "оценка и отчёт пилота (П3 v3)"), m.get("inputs_hash", ""), True, run=str(run),
                     report_built=True, verdict=f"ШП-2: {R['verdict']}", figures=[p.name for p in figs])
    prog.put(len(figs), force=True)
    print(f"отчёт: {rep / 'report.md'}; {len(figs)} картинок; ШП-2: {R['verdict']}", flush=True)
    return C.EXIT_OK
