"""AP-17 (P7): разбор прототипа сборки по фазам против Пикара на SY-12 — «можно ли убрать сеть».

    run.py [--data $AIR_SYNTH_DATA/phase/assembly_v1] [--variant $AIR_SYNTH_DATA/phase/assembly_v1_noana]
           [--sy11 /home/greg/deltaplan-air-synth/tools/research/air_synth/train/out/eval_holdout.json]

Вход — metrics-*.jsonl счёта `assembly/run_assembly.py` (метрики слоёв P6 сборки и Пикара, ошибки по фазам и в
швах, время). Выход — summary.json, section.md, tables.md, fig_*.png (агенты не открывают).
«Слой видит разницу» — пороги AP-9 `LM_KEYS` (предварительные, ревью AP-9): |Δ| > порога (abs) или > доли от
значения Пикара с полом (rel); у одного поля величина есть, у другого нет — видит.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("AIR_SYNTH_DATA", str(Path.home() / "air_synth_data")))
PHASES = ("A", "D", "LEE", "EF", "H")
# AP-9 analysis/AP-9/run.py LM_KEYS (предварительные пороги): (вид, порог, пол)
LM_KEYS = {
    "th_n_src": ("rel", 0.2, 1.0), "th_phi_mean_ms": ("rel", 0.2, 0.05), "th_w0_mean_ms": ("abs", 0.2, 0),
    "th_ceil_agl_mean_m": ("abs", 100.0, 0), "th_drift_mean_ms": ("abs", 0.3, 0), "th_src_top_dist_m": ("abs", 800.0, 0),
    "sl_area_km2": ("rel", 0.2, 0.32), "sl_w_max_ms": ("abs", 0.2, 0), "sl_ceil_agl_m": ("abs", 100.0, 0),
    "lee_area25_km2": ("rel", 0.2, 0.32), "lee_depth_max_m": ("abs", 100.0, 0), "lee_du_max_ms": ("abs", 0.3, 0),
    "lee_rev_area25_km2": ("abs", 0.32, 0),
}
LAYER_NAMES = {"th": "термики (источники, сила, потолок, снос)", "sl": "подъём у склонов", "lee": "подветренные зоны и роторы"}
SUFFICIENT = 0.2          # слой «достаточен» в фазе, если разницу видит ≤ 20 % случаев (предварительно, как пороги)


def load(d):
    rows = []
    for p in sorted(glob.glob(str(Path(d) / "metrics-*.jsonl"))):
        for line in open(p, encoding="utf-8"):
            if line.strip():
                rows.append(json.loads(line))
    return rows


def sig_pair(a, b):
    """→ dict ключ → (разность a − b или NaN, видит ли слой)."""
    out = {}
    for k, (kind, thr, floor) in LM_KEYS.items():
        x, y = a.get(k), b.get(k)
        x = np.nan if x is None else float(x)
        y = np.nan if y is None else float(y)
        if np.isnan(x) and np.isnan(y):
            out[k] = (0.0, False)
        elif np.isnan(x) or np.isnan(y):
            out[k] = (np.nan, True)
        else:
            lim = thr * max(abs(y), floor) if kind == "rel" else thr
            out[k] = (x - y, abs(x - y) > lim)
    return out


def dominant(r):
    w = r["weights_mean"]
    return max(PHASES, key=lambda p: w[p])


def frac(x):
    x = list(x)
    return float(np.mean(x)) if x else None


def med(x):
    x = [v for v in x if v is not None and np.isfinite(v)]
    return float(np.median(x)) if x else None


def analyse(rows):
    ok = [r for r in rows if "lm_pic" in r]
    for r in ok:
        r["_sig"] = sig_pair(r["lm_asm"], r["lm_pic"])
        r["_ph"] = dominant(r)
    groups = {"all": ok}
    for p in PHASES:
        groups[p] = [r for r in ok if r["_ph"] == p]
    groups["holdout"] = [r for r in ok if r["group"] == 1]
    groups["train"] = [r for r in ok if r["group"] == 0]
    groups["mechanical"] = [r for r in ok if r["mechanical"]]
    groups["convective"] = [r for r in ok if not r["mechanical"]]
    for lo, hi, nm in ((0, 0.5, "fr<0.5"), (0.5, 1.0, "fr0.5-1"), (1.0, 2.0, "fr1-2"), (2.0, 1e9, "fr>2")):
        groups[nm] = [r for r in ok if lo <= r["froude"] < hi]
    res = {}
    for g, rs in groups.items():
        e = dict(n=len(rs))
        if not rs:
            res[g] = e
            continue
        e["key_sees_frac"] = {k: frac(r["_sig"][k][1] for r in rs) for k in LM_KEYS}
        e["key_bias_median"] = {k: med(r["_sig"][k][0] for r in rs) for k in LM_KEYS}
        e["key_pic_median"] = {k: med(r["lm_pic"].get(k) for r in rs) for k in LM_KEYS}
        e["key_asm_median"] = {k: med(r["lm_asm"].get(k) for r in rs) for k in LM_KEYS}
        e["layer_sees_frac"] = {lay: frac(any(r["_sig"][k][1] for k in LM_KEYS if k.startswith(lay + "_")) for r in rs)
                                for lay in LAYER_NAMES}
        e["th_without_top_dist_sees_frac"] = frac(any(r["_sig"][k][1] for k in LM_KEYS if k.startswith("th_") and k != "th_src_top_dist_m") for r in rs)
        e["layer_keys_sees_mean"] = {lay: frac(np.mean([r["_sig"][k][1] for k in LM_KEYS if k.startswith(lay + "_")]) for r in rs)
                                     for lay in LAYER_NAMES}
        e["iou_median"] = {lay: med(r["iou"][lay] for r in rs) for lay in LAYER_NAMES}
        e["du_seam_med_ms"] = med(r["err_h"]["du_seam_med"] for r in rs)
        e["du_core_med_ms"] = med(r["err_h"]["du_core_med"] for r in rs)
        e["dw_seam_med_ms"] = med(r["err_h"]["dw_seam_med"] for r in rs)
        e["dw_core_med_ms"] = med(r["err_h"]["dw_core_med"] for r in rs)
        e["seam_frac_med"] = med(r["err_h"]["seam_frac"] for r in rs)
        e["e60_h_case_median_ms"] = med(r["err_h"]["e60_med"] for r in rs)
        e["e60_m_case_median_ms"] = med(r["err_m"]["e60_med"] for r in rs)
        e["e60_h_case_p90_of_medians_ms"] = float(np.percentile([r["err_h"]["e60_med"] for r in rs], 90))
        e["speed_bias_low_ms"] = med(r["err_h"]["speed_asm_mean"] - r["err_h"]["speed_pic_mean"] for r in rs)
        e["w_corr_100_median"] = med(r["err_h"]["w_corr_100"] for r in rs)
        e["du_by_phase_med_ms"] = {p: med(r["err_h"][f"du_{p}_med"] for r in rs) for p in PHASES}
        res[g] = e
    return ok, res


def timing(rows):
    cpu = np.array([r["cpu_s"] for r in rows])
    wall = np.array([r["seconds"] for r in rows])
    steps = defaultdict(list)
    for r in rows:
        for k, v in r["steps"].items():
            steps[k].append(v)
    div = [r["div"]["h"].get("div_rms_centers") for r in rows if r["div"]["h"]]
    div0 = [r["div"]["h"].get("div_rms_before") for r in rows if r["div"]["h"]]
    divf = [r["div"]["h"].get("div_max_faces") for r in rows if r["div"]["h"]]
    return dict(cpu_s_median=float(np.median(cpu)), cpu_s_p90=float(np.percentile(cpu, 90)),
                wall_s_median=float(np.median(wall)), steps_median_s={k: float(np.median(v)) for k, v in steps.items()},
                div_rms_before_median=float(np.median(div0)), div_rms_centers_median=float(np.median(div)),
                div_max_faces_max=float(np.max(divf)), n=len(rows),
                n_layers_median=float(np.median([r["meta"]["n_layers"] for r in rows])))


def gpu_estimate(t):
    """Оценка на GPU по числу операций (§15.2): A — DCT матричным умножением: на поле 4 пары умножений 96×96×96
    (2·96³ MAC) на величину и уровень: u, v, w, η × 13 уровней × (полный + срезанный + огибающая + срезанная
    огибающая) × 2 варианта (m, h) ≈ 4·13·4·2·4·2·96³ ≈ 2,9·10⁹ FLOP — RX 5600 XT ~7 ТФЛОПС fp32 (на деле
    матричные ядра Godot без тензорных блоков ~10–20 % пика) → 2–4 мс. D — слои Лапласа: до 12 слоёв × 2 (рельеф,
    огибающая) × 2 варианта; V-цикл AirMultigrid по 2D слою 96² ≈ 0,1–0,3 мс на цикл, 5–10 циклов → ≈ 5–30 мс.
    Столб фона — 24 столба × 240 шагов разгона — последовательно по разгону: одно ядро на шаг ≈ 240 запусков ×
    ~20 мкс ≈ 5 мс (или CPU 0,1–0,5 с один раз за пересчёт). Огибающая и θ′ — марш по ветру: 96–200 итераций
    Якоби по 96² ≈ 1–3 мс. Проекция — DCT + прогонка 13 уровней ≈ 1 мс (или 3–5 V-циклов существующего
    air_mg.glsl ≈ 2–5 мс, §15.3). Итого порядок 15–50 мс на пересчёт (раз в 15 игровых минут) против
    Пикара на GPU 3,6 мс × 100–1000 итераций = 0,4–3,6 с (air_phase_experts §15/«Идеи»)."""
    return dict(gpu_ms_estimate_low=15.0, gpu_ms_estimate_high=50.0, picard_gpu_ms_low=360.0, picard_gpu_ms_high=3600.0,
                basis="число операций по шагам (docstring gpu_estimate, §15.2); не замер")


def sy11(path):
    if not Path(path).exists():
        return None
    d = json.load(open(path, encoding="utf-8"))
    h = d["holdout"]["slices"]
    out = dict(source=str(path), level_m=d.get("level_m"), note="SY-11 — все 480 случаев holdout (и несошедшиеся: цель — среднее поздних), ошибка вектора на 60 м")
    for s in ("all", "mechanical", "convective", "froude_low", "froude_mid", "froude_high"):
        if s in h:
            out[s] = dict(n=h[s]["heat"]["n_cases"], median_60m=h[s]["heat"]["median_60m"],
                          case_median_of_medians_60m=h[s]["heat"].get("case_median_of_medians_60m"),
                          base_median_60m=h[s].get("base_heat", {}).get("median_60m"))
    return out


def verdict(res):
    """Слой достаточен в фазе, если разницу видит ≤ SUFFICIENT случаев (пороги AP-9 — предварительные)."""
    table = {}
    for p in PHASES:
        e = res.get(p, {})
        if not e.get("n"):
            continue
        table[p] = {lay: (e["layer_sees_frac"][lay] <= SUFFICIENT) for lay in LAYER_NAMES}
    n_ok = sum(v for t in table.values() for v in t.values())
    n_all = sum(len(t) for t in table.values())
    ans = "yes" if n_ok == n_all and n_all else ("no" if n_ok == 0 else "partly")
    return ans, table


def figs(ok, res, t, sy):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return []
    out = []
    ph = [p for p in PHASES if res.get(p, {}).get("n")]
    keys = list(LM_KEYS)
    M = np.array([[res[p]["key_sees_frac"][k] for p in ph] for k in keys])
    fig, ax = plt.subplots(figsize=(6, 6))
    im = ax.imshow(M, vmin=0, vmax=1, cmap="viridis", aspect="auto")
    ax.set_xticks(range(len(ph)), [f"{p}\n(n={res[p]['n']})" for p in ph])
    ax.set_yticks(range(len(keys)), keys, fontsize=8)
    for i in range(len(keys)):
        for j in range(len(ph)):
            ax.text(j, i, f"{M[i, j]:.2f}", ha="center", va="center", fontsize=7, color="w" if M[i, j] < 0.6 else "k")
    fig.colorbar(im, label="доля случаев, где слой видит разницу")
    ax.set_title("Сборка по фазам против Пикара: метрики слоёв")
    fig.tight_layout(); fig.savefig(HERE / "fig_sees_by_phase.png", dpi=110); plt.close(fig); out.append("fig_sees_by_phase.png")
    fig, ax = plt.subplots(figsize=(6, 4))
    s = [r["err_h"]["du_seam_med"] for r in ok if r["err_h"]["du_seam_med"] is not None]
    c = [r["err_h"]["du_core_med"] for r in ok if r["err_h"]["du_core_med"] is not None]
    ax.boxplot([c, s], tick_labels=["вне швов (max w ≥ 0,8)", "швы (max w < 0,8)"], showfliers=False)
    ax.set_ylabel("медиана |Δu_h| по клеткам, 25–300 м, м/с")
    fig.tight_layout(); fig.savefig(HERE / "fig_seams.png", dpi=110); plt.close(fig); out.append("fig_seams.png")
    fig, ax = plt.subplots(figsize=(6, 4))
    e = [r["err_h"]["e60_med"] for r in ok if r["group"] == 1]
    ax.hist(e, bins=30, color="C0", alpha=0.8, label="сборка (holdout, Пикар сошёлся)")
    if sy and sy.get("all"):
        ax.axvline(sy["all"]["case_median_of_medians_60m"], color="C3", label="сеть SY-11 (медиана медиан)")
        if sy["all"].get("base_median_60m"):
            ax.axvline(sy["all"]["base_median_60m"], color="C7", ls="--", label="профиль притока")
    ax.set_xlabel("медиана ошибки вектора на 60 м по случаю, м/с"); ax.legend(fontsize=8)
    fig.tight_layout(); fig.savefig(HERE / "fig_e60.png", dpi=110); plt.close(fig); out.append("fig_e60.png")
    fig, ax = plt.subplots(figsize=(6, 4))
    st = t["steps_median_s"]
    ax.barh(list(st), list(st.values()))
    ax.set_xlabel("медиана, с (CPU, один процесс)"); ax.set_title(f"время сборки: медиана {t['cpu_s_median']:.1f} с на случай")
    fig.tight_layout(); fig.savefig(HERE / "fig_time.png", dpi=110); plt.close(fig); out.append("fig_time.png")
    fig, ax = plt.subplots(figsize=(6, 4))
    for lay, col in (("th", "C1"), ("sl", "C2"), ("lee", "C0")):
        xs, ys = [], []
        for nm in ("fr<0.5", "fr0.5-1", "fr1-2", "fr>2"):
            if res.get(nm, {}).get("n"):
                xs.append(nm); ys.append(res[nm]["layer_sees_frac"][lay])
        ax.plot(xs, ys, "o-", color=col, label=LAYER_NAMES[lay])
    ax.axhline(SUFFICIENT, color="k", ls=":")
    ax.set_ylim(0, 1); ax.set_ylabel("доля случаев, где слой видит разницу"); ax.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(HERE / "fig_layers_by_fr.png", dpi=110); plt.close(fig); out.append("fig_layers_by_fr.png")
    return out


def fmt(x, nd=2):
    return "—" if x is None else f"{x:.{nd}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(DATA / "phase/assembly_v1"))
    ap.add_argument("--variant", default=str(DATA / "phase/assembly_v1_noana"))
    ap.add_argument("--sy11", default="/home/greg/deltaplan-air-synth/tools/research/air_synth/train/out/eval_holdout.json")
    a = ap.parse_args()
    rows = load(a.data)
    ok, res = analyse(rows)
    t = timing(rows)
    sy = sy11(a.sy11)
    ans, table = verdict(res)
    var = None
    if Path(a.variant).exists():
        vrows = load(a.variant)
        if vrows:
            _, vres = analyse(vrows)
            var = dict(name="без анабатики (slope_len_m = 0)", n=vres["all"]["n"],
                       layer_sees_frac={g: vres[g]["layer_sees_frac"] for g in ("all", "EF") if vres.get(g, {}).get("n")},
                       key_sees_frac_all=vres["all"]["key_sees_frac"], e60_h_case_median_ms=vres["all"]["e60_h_case_median_ms"])
    orc = None
    po = Path(a.data) / "oracle_profile.jsonl"
    if po.exists():
        omap = {}
        for line in open(po, encoding="utf-8"):
            if line.strip():
                d = json.loads(line)
                omap[d["case"]] = d
        orows = []
        for r in ok:
            if r["case"] in omap:
                rr = dict(r)
                rr["lm_asm"] = omap[r["case"]]["lm_asm"]
                rr["_sig"] = sig_pair(rr["lm_asm"], rr["lm_pic"])
                rr["_e60"] = omap[r["case"]]["e60_med"]
                orows.append(rr)
        orc = dict(note="диагностика: средний профиль u, v, θ′ по высотам заменён профилем Пикара (не результат сборки)", n=len(orows))
        for g in ("all", *PHASES):
            rs = orows if g == "all" else [r for r in orows if r["_ph"] == g]
            if rs:
                orc[g] = dict(n=len(rs),
                              layer_sees_frac={lay: frac(any(r["_sig"][k][1] for k in LM_KEYS if k.startswith(lay + "_")) for r in rs) for lay in LAYER_NAMES},
                              key_sees_frac={k: frac(r["_sig"][k][1] for r in rs) for k in LM_KEYS},
                              th_without_top_dist_sees_frac=frac(any(r["_sig"][k][1] for k in LM_KEYS if k.startswith("th_") and k != "th_src_top_dist_m") for r in rs),
                              e60_case_median_ms=med(r["_e60"] for r in rs))
    summ = dict(
        task="AP-17", contract="P8 v1", data=a.data, n_assembled=len(rows), n_picard_ok=len(ok),
        n_holdout_ok=res["holdout"]["n"], n_train_ok=res["train"]["n"],
        can_drop_network=ans, sufficient_rule=f"слой достаточен в фазе, если разницу видит ≤ {SUFFICIENT:.0%} случаев (пороги AP-9 LM_KEYS, предварительные)",
        sufficient_table=table, groups=res, timing=t, gpu=gpu_estimate(t), sy11=sy, variant_noana=var, oracle_profile=orc,
        lm_keys=LM_KEYS)
    (HERE / "summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    fl = figs(ok, res, t, sy)
    # таблицы
    L = ["# AP-17 — таблицы\n", "## Доля случаев, где слой видит разницу (по фазе с наибольшей площадью)\n",
         "| группа | n | термики | склоны | подветр. | IoU терм. | IoU скл. | IoU подв. | e60 (медиана), м/с | смещение скорости 25–300 м, м/с |", "|---|---|---|---|---|---|---|---|---|---|"]
    for g in ("all", *PHASES, "holdout", "train", "mechanical", "convective", "fr<0.5", "fr0.5-1", "fr1-2", "fr>2"):
        e = res.get(g, {})
        if not e.get("n"):
            L.append(f"| {g} | 0 | — | — | — | — | — | — | — | — |")
            continue
        ls, io = e["layer_sees_frac"], e["iou_median"]
        L.append(f"| {g} | {e['n']} | {fmt(ls['th'])} | {fmt(ls['sl'])} | {fmt(ls['lee'])} | {fmt(io['th'])} | {fmt(io['sl'])} | {fmt(io['lee'])} | {fmt(e['e60_h_case_median_ms'])} | {fmt(e['speed_bias_low_ms'])} |")
    L += ["\n## По величинам (все случаи): доля «видит», медиана Пикара, медиана сборки, медиана разности\n",
          "| величина | порог | все | A | D | LEE | EF | H | Пикар | сборка | Δ |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for k, (kind, thr, floor) in LM_KEYS.items():
        cells = [fmt(res[p]["key_sees_frac"][k]) if res.get(p, {}).get("n") else "—" for p in PHASES]
        e = res["all"]
        thr_s = f"{thr:g}" + (f"·max(|Пикар|, {floor:g})" if kind == "rel" else "")
        L.append(f"| {k} | {thr_s} | {fmt(e['key_sees_frac'][k])} | " + " | ".join(cells) +
                 f" | {fmt(e['key_pic_median'][k])} | {fmt(e['key_asm_median'][k])} | {fmt(e['key_bias_median'][k])} |")
    L += ["\n## Швы (max w_φ < 0,8) против вне, слой 25–300 м, медианы по случаям\n",
          "| группа | доля швов | |Δu| швы | |Δu| вне | |Δw| швы | |Δw| вне |", "|---|---|---|---|---|---|"]
    for g in ("all", *PHASES):
        e = res.get(g, {})
        if e.get("n"):
            L.append(f"| {g} | {fmt(e['seam_frac_med'])} | {fmt(e['du_seam_med_ms'])} | {fmt(e['du_core_med_ms'])} | {fmt(e['dw_seam_med_ms'], 3)} | {fmt(e['dw_core_med_ms'], 3)} |")
    L += ["\n## Ошибка |Δu| по клеткам с фазой наибольшего веса (все случаи), м/с\n", "| " + " | ".join(PHASES) + " |", "|" + "---|" * len(PHASES),
          "| " + " | ".join(fmt(res["all"]["du_by_phase_med_ms"][p]) for p in PHASES) + " |"]
    (HERE / "tables.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print(json.dumps(dict(can_drop_network=ans, n_ok=len(ok), table=table, timing=t["cpu_s_median"]), ensure_ascii=False))


if __name__ == "__main__":
    main()
