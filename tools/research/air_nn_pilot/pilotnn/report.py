"""Отчёт пилота (контракт П3): картинки + report.md из metrics.json. Вывод по ориентирам ШП — правилом из чисел
(config.yaml → eval: wind_ok_ms, lift_ok_ms, frac_ok, better_than_baseline, curve_drop)."""
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
from .evaluate import PRED_NAMES, PREDS, SET_NAMES, SETS, Prog, level_weights, at_level  # noqa: E402

S1, S2, S3 = "#2a78d6", "#eb6834", "#1baf7a"       # категориальные слоты 1–3 (порядок фиксирован)
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#e4e3df"
plt.rcParams.update({"font.size": 9, "axes.edgecolor": MUTED, "axes.labelcolor": INK, "xtick.color": MUTED,
                     "ytick.color": MUTED, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
                     "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 110, "savefig.dpi": 110,
                     "lines.linewidth": 2.0})


def f2(x, n=2):
    return "—" if x is None or (isinstance(x, float) and not math.isfinite(x)) else f"{x:.{n}f}"


def pct(x):
    return "—" if x is None else f"{100 * x:.0f} %"


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
            ax[r, c].contour(np.linspace(ext[0], ext[1], n), np.linspace(ext[2], ext[3], n), hc, levels=10,
                             colors=MUTED, linewidths=0.4, alpha=0.6)
            for (x, y) in meta["starts"]:
                ax[r, c].plot(x / 1000, y / 1000, marker="^", ms=8, color=INK, mec="white", mew=1.2, ls="none")
            ax[r, c].set_title(f"{ttl}: {name}", fontsize=9, color=INK)
            ax[r, c].grid(False)
            fig.colorbar(im, ax=ax[r, c], shrink=0.8)
            if r == 2:
                ax[r, c].set_xlabel("x (восток), км")
            if c == 0:
                ax[r, c].set_ylabel("y (север), км")
    fig.suptitle(f"{cid} — {SET_NAMES.get(meta['set'], meta['set'])}; срез {a_key:g} м над рельефом; ▲ — точки оценки",
                 fontsize=10, color=INK)
    p = rep / "figures" / f"{idx:02d}_срез_{cid}.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_curve(rep: Path, M, idx):
    cv = M["curve"]
    if not cv:
        return None
    ec = M["config_eval"]
    xs = [c["n_places"] for c in cv]
    fig, ax = plt.subplots(1, 3, figsize=(12, 3.8), constrained_layout=True)
    for k, (key, name, thr) in enumerate((("wind", "ошибка ветра с нагревом", ec["wind_ok_ms"]),
                                          ("lift_m", "ошибка подъёма без нагрева", ec["lift_ok_ms"]),
                                          ("lift_h", "ошибка подъёма с нагревом", ec["lift_ok_ms"]))):
        for s, col, lab in (("holdout_place", S1, "ongudai"), ("holdout_proc", S2, "отложенные рельефы")):
            ys = [(c.get(s) or {}).get(key) for c in cv]
            ys = [y["median"] if y else np.nan for y in ys]
            if np.all(np.isnan(ys)):
                continue
            ax[k].plot(xs, ys, "-o", color=col, ms=6, label=lab)
        ax[k].axhline(thr, color=MUTED, ls="--", lw=1)
        ax[k].text(xs[0], thr, f" ориентир {thr:g}", color=MUTED, va="bottom", fontsize=8)
        ax[k].set_xscale("log", base=2)
        ax[k].set_xticks(xs, [str(x) for x in xs])
        ax[k].set_xlabel("рельефов в обучении")
        ax[k].set_ylabel("медиана, м/с (60 м над стартом)")
        ax[k].set_title(name, fontsize=9)
        ax[k].set_ylim(bottom=0)
    ax[0].legend(frameon=False)
    fig.suptitle("Кривая (в): ошибка на незнакомом рельефе от числа рельефов в обучении", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_кривая_рельефов.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_cdf(rep: Path, M, idx):
    ec = M["config_eval"]
    pts = M["per_point"]
    sets = [s for s in ("newcond", "holdout_place", "holdout_proc") if M["sets"].get(s)]
    if not sets:
        return None
    fig, ax = plt.subplots(len(sets), 3, figsize=(12, 3.2 * len(sets)), constrained_layout=True, squeeze=False)
    for r, s in enumerate(sets):
        for c, (key, name, thr) in enumerate((("wind", "ошибка ветра с нагревом, м/с", ec["wind_ok_ms"]),
                                              ("lift_m", "ошибка подъёма без нагрева, м/с", ec["lift_ok_ms"]),
                                              ("lift_h", "ошибка подъёма с нагревом, м/с", ec["lift_ok_ms"]))):
            for pn, col in zip(PREDS, (S1, S2, S3)):
                v = np.sort([p[key] for p in pts if p["set"] == s and p["pred"] == pn])
                if v.size:
                    ax[r, c].step(v, np.arange(1, v.size + 1) / v.size, where="post", color=col, label=PRED_NAMES[pn])
            ax[r, c].axvline(thr, color=MUTED, ls="--", lw=1)
            ax[r, c].axhline(ec["frac_ok"], color=GRID, lw=1)
            ax[r, c].set_xlim(left=0)
            ax[r, c].set_ylim(0, 1.02)
            ax[r, c].set_xlabel(name)
            if c == 0:
                ax[r, c].set_ylabel(f"{SET_NAMES[s]}\nдоля точек")
    ax[0, 0].legend(frameon=False, loc="lower right")
    fig.suptitle("Распределение ошибок на 60 м над стартами: сеть против базовых линий (пунктир — ориентир ШП)", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_распределения_ошибок.png"
    fig.savefig(p)
    plt.close(fig)
    return p


def fig_history(rep: Path, M, idx):
    h = M["main"].get("history") or []
    if not h:
        return None
    fig, ax = plt.subplots(figsize=(6.5, 3.6), constrained_layout=True)
    e = [x["epoch"] + 1 for x in h]
    ax.plot(e, [x["train"] for x in h], color=S1, label="обучение")
    ax.plot(e, [x["val"] for x in h], color=S2, label="проверка (EMA)")
    ax.set_yscale("log")
    ax.set_xlabel("эпоха")
    ax.set_ylabel("потери (норм. MSE)")
    ax.legend(frameon=False)
    ax.set_title("Основная сеть: кривая обучения", fontsize=10)
    p = rep / "figures" / f"{idx:02d}_кривая_обучения.png"
    fig.savefig(p)
    plt.close(fig)
    return p


# ------------------------------------------------------------------------------------------- вывод
def verdict(M):
    ec = M["config_eval"]
    lines, ok = [], {}
    a = (M["sets"].get("newcond") or {}).get("net")
    if a:
        fa = [a["frac_wind_ok"], a["frac_lift_m_ok"], a["frac_lift_h_ok"]]
        ok["a"] = all(f >= ec["frac_ok"] for f in fa)
        lines.append(f"- **(а) знакомый рельеф, новые условия:** ветер < {ec['wind_ok_ms']:g} м/с — {pct(fa[0])}, подъём без "
                     f"нагрева < {ec['lift_ok_ms']:g} м/с — {pct(fa[1])}, с нагревом — {pct(fa[2])} точек; ориентир "
                     f"≥ {pct(ec['frac_ok'])} по всем трём → **{'выполнен' if ok['a'] else 'не выполнен'}**.")
    else:
        lines.append("- **(а)**: нет случаев «новые условия».")
    for s, tag in (("holdout_place", "б"), ("holdout_proc", "б′")):
        b = M["sets"].get(s)
        if not b:
            continue
        res, parts = [], []
        for key, nm in (("wind", "ветер"), ("lift_m", "подъём без нагрева"), ("lift_h", "подъём с нагревом")):
            net = b["net"][key]["median"]
            base = min(b[p][key]["median"] for p in ("inflow", "mean"))
            r = net / base if base > 0 else float("inf")
            res.append(r <= ec["better_than_baseline"])
            parts.append(f"{nm} {f2(net)} против {f2(base)} (×{f2(r)})")
        ok[tag] = all(res)
        lines.append(f"- **({tag}) {SET_NAMES[s].split(') ', 1)[1]}:** медиана ошибки сети против лучшей базовой линии — "
                     + "; ".join(parts) + f"; правило: все три ≤ ×{ec['better_than_baseline']:g} → "
                     f"**{'заметно лучше' if ok[tag] else 'не заметно лучше'}**.")
    cv = M["curve"]
    if len(cv) >= 2 and cv[0].get("holdout_all"):
        res, parts = [], []
        for key, nm in (("wind", "ветер"), ("lift_m", "подъём без нагрева")):
            ys = [c["holdout_all"][key]["median"] for c in cv]
            mono = all(ys[i + 1] <= ys[i] * 1.05 for i in range(len(ys) - 1))
            drop = ys[-1] <= ec["curve_drop"] * ys[0]
            res.append(mono and drop)
            parts.append(f"{nm}: " + " → ".join(f2(y, 3) for y in ys) + f" ({'падает' if mono and drop else 'не падает'})")
        ok["c"] = all(res)
        lines.append(f"- **(в) кривая по числу рельефов** ({', '.join(str(c['n_places']) for c in cv)}): " + "; ".join(parts)
                     + f"; правило: на max n ≤ ×{ec['curve_drop']:g} от min n и без роста > 5 % между точками → "
                     f"**{'ошибка падает' if ok['c'] else 'полка/рост'}**.")
    else:
        ok["c"] = None
        lines.append("- **(в)**: меньше двух точек кривой — не оценено.")
    if not ok.get("a"):
        concl = "«правим подход и повторяем пилот» — (а) не выполнен: сеть или вход не годятся, разбираться до всего остального."
    elif ok.get("b") and ok.get("c"):
        concl = "«идём в волну 0» — (а) выполнен, (б) заметно лучше базовых линий, (в) ошибка падает с числом рельефов."
    elif ok.get("c") is False:
        concl = "«правим подход» — полка на (в): менять вход/архитектуру, а не считать больше."
    else:
        concl = "«правим подход» — (б) не заметно лучше базовых линий на незнакомом месте."
    return lines, concl, ok


def estimate(M):
    """Оценка полного прогона по замеру этого прогона: время эпохи на образец × образцы × эпохи."""
    es, mn = M.get("config_estimate") or {}, M["main"]
    tps = mn.get("t_per_sample_ms")
    if not tps or not es:
        return None
    n_full = es["n_cases_full"]
    tr = M["config_train"]
    pool_frac = es.get("pool_frac", 0.86)
    n_train = n_full * pool_frac * (1 - es.get("newcond_frac", 0.15) - es.get("val_frac", 0.10))
    pool_places = es.get("pool_places", 43)
    sizes = es.get("curve_sizes", [5, 10, 20, 40])
    curve_frac = sum(min(s, pool_places) for s in sizes) / pool_places
    ep_main = es.get("max_epochs", tr["max_epochs"])
    ep_curve = es.get("curve_max_epochs", ep_main)
    t_main = tps / 1000 * n_train * ep_main
    t_curve = tps / 1000 * n_train * curve_frac * ep_curve
    n_eval_full = n_full * (1 - pool_frac) * (1 + len(sizes)) + n_full * pool_frac * es.get("newcond_frac", 0.15) + 60
    t_eval = M["t_eval_s"] / max(M["n_eval_cases"], 1) * n_eval_full + 60
    return dict(t_per_sample_ms=tps, n_train_full=n_train, epochs_main=ep_main, epochs_curve=ep_curve,
                curve_frac=curve_frac, h_main=t_main / 3600, h_curve=t_curve / 3600, h_eval=t_eval / 3600,
                h_total=(t_main + t_curve + t_eval) / 3600)


def build_report(run: Path, rep: Path):
    M = json.loads((rep / "metrics.json").read_text())
    ec = M["config_eval"]
    F = np.load(rep / "eval_fields.npz")
    cids = sorted({k.split("|")[0] for k in F.files}, key=lambda c: ["holdout_place", "newcond", "holdout_proc"].index(
        json.loads(str(F[f"{c}|meta"]))["set"]) if json.loads(str(F[f"{c}|meta"]))["set"] in
        ("holdout_place", "newcond", "holdout_proc") else 9)
    (rep / "figures").mkdir(exist_ok=True)
    for p in (rep / "figures").glob("*.png"):
        p.unlink()
    agl = tuple(json.loads((run / "run_info.json").read_text())["agl"])
    prog = Prog(rep, len(cids) + 3, "картинок", "отчёт")
    figs = []
    i = 1
    for cid in cids:
        figs.append(fig_slices(rep, F, cid, agl, ec["agl_key_m"], i)); i += 1
        prog.put(len(figs))
    for fn in (fig_curve, fig_cdf, fig_history):
        p = fn(rep, M, i)
        if p:
            figs.append(p); i += 1
        prog.put(len(figs))
    lines, concl, ok = verdict(M)
    est = estimate(M)
    info = json.loads((run / "run_info.json").read_text())
    md = []
    md.append(f"# Пилот air-nn: отчёт `{rep.name}`{' (smoke)' if info.get('smoke') else ''}\n")
    md.append(f"Построен {dt.datetime.now().isoformat(timespec='minutes')} скриптом `pilotnn/report.py` (коммит "
              f"{C.git_commit()}); прогон `{run}`; набор `{M['dataset']['root']}` — {M['dataset']['n_cases']} случаев "
              f"(решения области: ok {M['dataset']['status']['ok']}, max {M['dataset']['status']['max']}), "
              f"{len(M['dataset']['places'])} мест.\n")
    if info.get("smoke"):
        md.append("> **smoke**: крошечный набор разработки и несколько эпох — числа проверяют конвейер, а не качество сети.\n")
    md.append("## Вывод по ориентирам ШП (правилом из чисел, план §8.2)\n")
    md += lines
    md.append(f"\n**Итог по правилу: {concl}**\n")
    md.append("## Ключевые числа: 60 м над точками оценки\n")
    md.append("Ошибка против решателя (AM-01 «как игра», область 400 м). ветер — |Δ(u,v)| с нагревом; подъём — |Δw| без "
              "и с нагревом; RMS 1 км — RMS |Δ(u,v)| с нагревом по клеткам в 1 км. Медиана (90-й процентиль); доли — точек "
              f"с ошибкой < {ec['wind_ok_ms']:g} м/с (ветер) и < {ec['lift_ok_ms']:g} м/с (подъём).\n")
    md.append("| набор | предсказание | случаев / точек | ветер, м/с | подъём без нагрева | подъём с нагревом | RMS 1 км | "
              "ветер ок | подъём б/н ок | подъём с/н ок | всё ок |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for s in SETS:
        d = M["sets"].get(s)
        if not d:
            continue
        for pn in PREDS:
            x = d[pn]
            if not x:
                continue
            cell = lambda k: f"{f2(x[k]['median'])} ({f2(x[k]['p90'])})" if x.get(k) else "—"  # noqa: E731
            md.append(f"| {SET_NAMES[s]} | {PRED_NAMES[pn]} | {x['n_cases']} / {x['n_points']} | {cell('wind')} | "
                      f"{cell('lift_m')} | {cell('lift_h')} | {cell('rms1km')} | {pct(x['frac_wind_ok'])} | "
                      f"{pct(x['frac_lift_m_ok'])} | {pct(x['frac_lift_h_ok'])} | {pct(x['frac_all_ok'])} |")
    md.append("\nТочки оценки — центры окон 100 м плана набора (`plan.json → centers`): старты места (слитые ближе 3 км) и, у "
              "встроенных мест, точки наибольшего превышения над окрестностью 2 км; у синтетики/процедурных — центр рельефа.\n")
    md.append("## Сравнение с регрессией air-lite (цели `build.py`)\n")
    md.append("Цели air-lite: механика (U10 ≥ 0,5 м/с) — вдоль/поперёк ветра и w без нагрева, м/с; нагрев — добавка "
              "(с нагревом − без) вдоль/поперёк, w_conv, м/с; θ′, К. rmse и skill = 1 − mse/var по всем высотам 25–2000 м. "
              f"**Оговорка: air-lite — окна 100 м у стартов, сеть — область 400 м (без {ec['edge_cells']} клеток у края); "
              "фолды близки по смыслу («место ongudai» ↔ (б), «новые условия» ↔ (а)), но наборы и масштаб разные.**\n")
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
    md.append("\n## Кривая (в): ошибка на незнакомом рельефе от числа рельефов в обучении\n")
    if M["curve"]:
        md.append("| рельефов | обучающих случаев | лучшая проверка (эпоха) | ongudai: ветер / подъём б/н / с/н | "
                  "отложенные рельефы: ветер / подъём б/н / с/н | все отложенные: RMS поля ветра / подъёма б/н |")
        md.append("|---|---|---|---|---|---|")
        for c in M["curve"]:
            def tri(x):
                return " / ".join(f2(x[k]["median"], 3) for k in ("wind", "lift_m", "lift_h")) if x else "—"
            fa = c.get("holdout_all_field") or {}
            b = c.get("best") or {}
            md.append(f"| {c['n_places']} | {c['n_train']} | {f2(b.get('val'), 4)} ({(b.get('epoch') or 0) + 1}) | "
                      f"{tri(c.get('holdout_place'))} | {tri(c.get('holdout_proc'))} | {f2(fa.get('f_wind'), 3)} / "
                      f"{f2(fa.get('f_lift_m'), 3)} |")
        md.append(f"\nМеста по порядку добавления (вложенные подмножества, зерно {M['split']['seed']}): "
                  + ", ".join(M["split"]["pool_order"]) + ".\n")
    md.append("## Картинки\n")
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
    md.append(f"- Сеть: U-Net + FiLM, каналы {M['config_train']['model']['channels']}, {mn['n_params'] / 1e6:.2f} млн параметров; "
              f"обучение {mn['n_train']} случаев, проверка {mn['n_val']}; эпох {mn['epochs']}, лучшая — "
              f"{mn['best']['epoch'] + 1} (проверка {f2(mn['best']['val'], 4)}); {mn['gpu']}, torch {mn['torch']}, "
              "детерминированный режим.")
    md.append(f"- Время эпохи (медиана): {f2(mn['t_epoch_median_s'])} с, на образец {f2(mn['t_per_sample_ms'])} мс "
              f"(с проверкой в конце эпохи). Оценка {M['n_eval_cases']} предсказаний: {f2(M['t_eval_s'], 0)} с.")
    if est:
        md.append(f"- **Оценка полного прогона** ({M['config_estimate']['n_cases_full']} случаев, обучающих ≈ "
                  f"{est['n_train_full']:.0f}; эпох: основная {est['epochs_main']}, кривая {est['epochs_curve']}, кривая = "
                  f"{est['curve_frac']:.2f} основной по объёму): основная сеть {f2(est['h_main'])} ч, кривая {f2(est['h_curve'])} ч, "
                  f"оценка {f2(est['h_eval'])} ч, **итого ≈ {f2(est['h_total'])} ч** (верхняя граница — без ранней остановки; "
                  "досчёт набора — отдельно, шаг P1).")
    md.append("\n## Деление и границы\n")
    sz = M["split_sizes"]
    md.append(f"- Деление (зерно {M['split']['seed']}): обучение {sz.get('train_ids')}, проверка {sz.get('val_ids')}, (а) "
              f"{sz.get('newcond_ids')}, (б) {sz.get('holdout_place_ids')} (места {', '.join(M['split']['holdout_places'])}), "
              f"(б′) {sz.get('holdout_proc_ids')} (места {', '.join(M['split']['holdout_proc']) or '—'}).")
    md.append("- Эталон — решатель AM-01 «как игра» (400 м, 1-й порядок), не измерения: числа — точность сжатия решателя "
              "сетью, а не точность ветра в природе. Набор — июль, широта Онгудая; вне диапазонов набора (U10 > 8 м/с, "
              "другие широты/сезоны) сеть не проверялась.")
    md.append("- «Обучающие» — до 60 случаев обучения (проверка, что сеть учится; не оценка качества).")
    (rep / "report.md").write_text("\n".join(md) + "\n")
    m = C.read_json(rep / "manifest.json", {})
    C.write_manifest(rep, m.get("what", "оценка и отчёт пилота (П3)"), m.get("inputs_hash", ""), True, run=str(run),
                     report_built=True, verdict=concl, figures=[p.name for p in figs])
    prog.put(len(figs), force=True)
    print(f"отчёт: {rep / 'report.md'}; {len(figs)} картинок; {concl}", flush=True)
    return C.EXIT_OK
