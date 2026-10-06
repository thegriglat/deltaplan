"""AP-18 (P7, P9): разбор прототипа «фазы + Пикар» против холодного Пикара той же версии решателя на SY-12.

    run.py [--data $AIR_SYNTH_DATA/phase/hybrid_v1]

Вход — metrics-*.jsonl и runs_summary.json счёта `hybrid/run_hybrid.py` (final). Выход — summary.json (поля P9 обязательны),
tables.md, fig_*.png (агенты не открывают). section.md пишется по числам summary.json.
Определения:
  * сошёлся (случай) — status = ok в обоих решениях (m — без нагрева, h — с нагревом); гибрид: решения, отданные механизму
    целиком (вся область заморожена, Fr < 0,3), — «закрыты механизмом», Пикар не звался;
  * iter_reduction — медиана по случаям iters_cold/iters (iters — сумма m + h), где сошлись оба и гибрид звал Пикара;
    плюс отношение сумм (работа GPU в целом);
  * «слой видит разницу» — пороги AP-9 `LM_KEYS` (предварительные) между гибридом и холодным Пикаром нынешней версии, где
    холодный сошёлся; пол шума — то же между холодным нынешним и S5 (s0-939a467, та же постановка, другая версия решателя
    и порядок операций): разница, которую слой видит у двух «правильных» решений;
  * layers_not_worse: по группам термики / склоны / подветренные зоны — доля «видит» у гибрида ≤ пол шума + 0,05 →
    не хуже; yes — во всех группах и во всех случаях; partly — в случаях, где работал Пикар, не хуже, а в механических
    (заморозка) — хуже; no — хуже и там, где работал Пикар.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("AIR_SYNTH_DATA", str(Path.home() / "air_synth_data")))
LM_KEYS = {   # AP-9 analysis/AP-9/run.py (предварительные пороги): (вид, порог, пол) — как AP-17
    "th_n_src": ("rel", 0.2, 1.0), "th_phi_mean_ms": ("rel", 0.2, 0.05), "th_w0_mean_ms": ("abs", 0.2, 0),
    "th_ceil_agl_mean_m": ("abs", 100.0, 0), "th_drift_mean_ms": ("abs", 0.3, 0), "th_src_top_dist_m": ("abs", 800.0, 0),
    "sl_area_km2": ("rel", 0.2, 0.32), "sl_w_max_ms": ("abs", 0.2, 0), "sl_ceil_agl_m": ("abs", 100.0, 0),
    "lee_area25_km2": ("rel", 0.2, 0.32), "lee_depth_max_m": ("abs", 100.0, 0), "lee_du_max_ms": ("abs", 0.3, 0),
    "lee_rev_area25_km2": ("abs", 0.32, 0),
}
LAYERS = ("th", "sl", "lee")
MARGIN = 0.05
# игра (AM-03, docs/guide/air-model-gpu.md «Замеры»): итерация 400 м на RTX 4070 SUPER — 3,3 мс, проверка раз в 10 — 0,40 мс
GAME_MS_ITER_4070S, GAME_MS_CHECK_4070S = 3.3, 0.40
# RX 5600 XT против RTX 4070 SUPER: память 288 против 504 ГБ/с (×1,75), L2 3 против 48 МБ (набор 400 м ~95 МБ — у 4070S
# частично в L2, у 5600 XT весь в DRAM), FP32 7,2 против 35 TFLOPS (ядра лёгкие, упор — запуски/барьеры и память)
RX_FACTOR, RX_FACTOR_LO, RX_FACTOR_HI = 2.0, 1.6, 2.6
STEP_GAME_MIN = 15.0


def load(d):
    rows = []
    for p in sorted(glob.glob(str(Path(d) / "metrics-*.jsonl"))):
        rows += [json.loads(x) for x in open(p, encoding="utf-8") if x.strip()]
    return rows


def sees(a, b):
    """→ {ключ: видит ли слой разницу a против b}."""
    out = {}
    for k, (kind, thr, floor) in LM_KEYS.items():
        x, y = a.get(k), b.get(k)
        x = np.nan if x is None else float(x)
        y = np.nan if y is None else float(y)
        if np.isnan(x) and np.isnan(y):
            out[k] = False
        elif np.isnan(x) or np.isnan(y):
            out[k] = True
        else:
            out[k] = abs(x - y) > (thr * max(abs(y), floor) if kind == "rel" else thr)
    return out


def layer_frac(pairs):
    """pairs — список словарей sees → доля случаев, где слой (любая величина группы) видит разницу, и по величинам."""
    if not pairs:
        return None
    lay = {L: float(np.mean([any(v for k, v in s.items() if k.startswith(L + "_")) for s in pairs])) for L in LAYERS}
    lay["th_no_topdist"] = float(np.mean([any(v for k, v in s.items() if k.startswith("th_") and k != "th_src_top_dist_m") for s in pairs]))
    key = {k: float(np.mean([s[k] for s in pairs])) for k in LM_KEYS}
    return dict(n=len(pairs), layer=lay, key=key)


def ok2(d):
    return d is not None and all(d.get(x, {}).get("status", 1) == 0 for x in ("m", "h"))


def it2(d):
    return sum(d[x]["iters"] for x in ("m", "h") if x in d)


def solved_ok(r, v="hybrid"):
    """Гибрид: все решения, отданные Пикару, сошлись (механические — не считаются)."""
    d = r.get(v) or {}
    return all(x["status"] == 0 for x in d.values())


def med(x):
    x = [v for v in x if v is not None and np.isfinite(v)]
    return float(np.median(x)) if x else None


def analyse(rows, rs):
    N = len(rows)
    for r in rows:
        r["_cold_ok"] = ok2(r["cold"])
        r["_s5_ok"] = r["s5"]["status_m"] == 0 and r["s5"]["status_h"] == 0
        r["_mech_full"] = not r.get("hybrid")                                   # Пикар не звался ни в одном решении
        r["_hyb_ok"] = solved_ok(r)
        r["_kind"] = "mech" if r["_mech_full"] else ("frozen" if r["freeze_h_frac"] > 0 else "picard")
    S = dict(task="AP-18", contract="P9 v1", n_cases=N)
    S["solver_version"] = rs["variants"].get("cold", {}).get("solver_version")
    S["n_mech_full"] = sum(r["_mech_full"] for r in rows)
    S["n_partly_frozen"] = sum(r["_kind"] == "frozen" for r in rows)
    S["n_picard_only"] = sum(r["_kind"] == "picard" for r in rows)
    # --- сходимость
    S["conv_rate_cold"] = float(np.mean([r["_cold_ok"] for r in rows]))
    S["conv_rate_cold_s5"] = float(np.mean([r["_s5_ok"] for r in rows]))
    S["conv_rate_hybrid"] = float(np.mean([r["_hyb_ok"] for r in rows]))              # механизмы — закрыто
    sol = [r for r in rows if not r["_mech_full"]]
    S["conv_rate_hybrid_picard"] = float(np.mean([r["_hyb_ok"] for r in sol])) if sol else None
    S["conv_rate_cold_on_picard_cases"] = float(np.mean([r["_cold_ok"] for r in sol])) if sol else None
    nc = [r for r in rows if not r["_cold_ok"]]
    S["n_cold_nonconv"] = len(nc)
    S["nonconv_closed_frac"] = float(np.mean([r["_hyb_ok"] for r in nc])) if nc else None
    S["nonconv_closed_by"] = dict(mechanism_full=sum(r["_hyb_ok"] and r["_mech_full"] for r in nc),
                                  picard_converged=sum(r["_hyb_ok"] and not r["_mech_full"] for r in nc),
                                  open=sum(not r["_hyb_ok"] for r in nc))
    S["hybrid_nonconv_where_cold_ok"] = sum((not r["_hyb_ok"]) and r["_cold_ok"] for r in rows)
    # --- итерации
    both = [r for r in rows if r["_cold_ok"] and r["_hyb_ok"] and not r["_mech_full"] and set(r["hybrid"]) == {"m", "h"}]
    ratio = [it2(r["cold"]) / max(it2(r["hybrid"]), 1) for r in both]
    S["iter_reduction"] = med(ratio)
    S["iter_reduction_n"] = len(both)
    S["iter_reduction_p10_p90"] = [float(np.percentile(ratio, 10)), float(np.percentile(ratio, 90))] if ratio else None
    S["iter_sum_ratio_cold_over_hybrid"] = float(sum(it2(r["cold"]) for r in both) / max(sum(it2(r["hybrid"]) for r in both), 1)) if both else None
    S["iters_median"] = dict(cold=med([it2(r["cold"]) for r in both]), hybrid=med([it2(r["hybrid"]) for r in both]))
    for dec in ("m", "h"):
        bd = [r for r in rows if r["cold"][dec]["status"] == 0 and dec in (r.get("hybrid") or {}) and r["hybrid"][dec]["status"] == 0]
        S[f"iter_reduction_{dec}"] = med([r["cold"][dec]["iters"] / max(r["hybrid"][dec]["iters"], 1) for r in bd])
        S[f"iters_{dec}_median"] = dict(cold=med([r["cold"][dec]["iters"] for r in bd]), hybrid=med([r["hybrid"][dec]["iters"] for r in bd]),
                                        n=len(bd))
    # среднее число итераций гибрида на случай по всей выборке (механические — 0), только сошедшиеся решения и все
    S["iters_hybrid_mean_all_cases"] = float(np.mean([it2(r["hybrid"]) if r.get("hybrid") else 0 for r in rows]))
    S["iters_cold_mean_all_cases"] = float(np.mean([it2(r["cold"]) for r in rows]))
    S["omega_switch_frac_hybrid"] = float(np.mean([any(x["switch"] >= 0 for x in r["hybrid"].values()) for r in sol])) if sol else None
    # --- по полосам Fr
    bins = ((0, 0.3, "Fr<0,3"), (0.3, 0.5, "0,3–0,5"), (0.5, 1.1, "0,5–1,1"), (1.1, 3, "1,1–3"), (3, 1e9, ">3"))
    S["by_fr"] = {}
    for lo, hi, nm in bins:
        g = [r for r in rows if lo <= r["froude"] < hi]
        if not g:
            continue
        bb = [r for r in g if r in both]
        S["by_fr"][nm] = dict(n=len(g), conv_cold=float(np.mean([r["_cold_ok"] for r in g])), conv_hybrid=float(np.mean([r["_hyb_ok"] for r in g])),
                              mech_full=sum(r["_mech_full"] for r in g), iters_cold_med=med([it2(r["cold"]) for r in bb]),
                              iters_hybrid_med=med([it2(r["hybrid"]) for r in bb]), iter_reduction=med([it2(r["cold"]) / max(it2(r["hybrid"]), 1) for r in bb]),
                              omega_mean=float(np.mean([r["omega"] for r in g])))
    # --- ω по карте против запасного правила (случаи, где карта ω < 1 и Пикар звался)
    fb = [r for r in rows if r.get("fallback") and r.get("hybrid") and set(r["fallback"]) == set(r["hybrid"])]
    if fb:
        S["omega_map_vs_fallback"] = dict(
            n=len(fb), conv_map=float(np.mean([solved_ok(r) for r in fb])), conv_fallback=float(np.mean([solved_ok(r, "fallback") for r in fb])),
            iters_map_med=med([it2(r["hybrid"]) for r in fb]), iters_fallback_med=med([it2(r["fallback"]) for r in fb]),
            iters_map_sum=int(sum(it2(r["hybrid"]) for r in fb)), iters_fallback_sum=int(sum(it2(r["fallback"]) for r in fb)),
            fallback_switch_frac=float(np.mean([any(x["switch"] >= 0 for x in r["fallback"].values()) for r in fb])),
            ratio_fallback_over_map_med=med([it2(r["fallback"]) / max(it2(r["hybrid"]), 1) for r in fb if solved_ok(r) and solved_ok(r, "fallback")]))
        if any("lm_fallback" in r for r in fb):
            S["omega_map_vs_fallback"]["layers_fallback_vs_cold"] = layer_frac([sees(r["lm_fallback"], r["lm_cold"]) for r in fb if r["_cold_ok"] and "lm_fallback" in r])
    # --- тёплый старт: гибрид против холодного с той же картой ω (только случаи без заморозки — иначе это разные задачи)
    wc = [r for r in rows if r.get("cold_omap") and r["_kind"] == "picard" and set(r["cold_omap"]) == set(r["hybrid"])
          and solved_ok(r) and solved_ok(r, "cold_omap")]
    if wc:
        S["warm_start_effect"] = dict(n=len(wc), iters_cold_omap_med=med([it2(r["cold_omap"]) for r in wc]),
                                      iters_hybrid_med=med([it2(r["hybrid"]) for r in wc]),
                                      ratio_med=med([it2(r["cold_omap"]) / max(it2(r["hybrid"]), 1) for r in wc]),
                                      ratio_sum=float(sum(it2(r["cold_omap"]) for r in wc) / max(sum(it2(r["hybrid"]) for r in wc), 1)))
    # --- слои (там, где холодный сошёлся)
    cok = [r for r in rows if r["_cold_ok"]]
    L = {}
    L["noise_s5_vs_cold"] = layer_frac([sees(r["lm_s5"], r["lm_cold"]) for r in cok if "lm_s5" in r])
    L["hybrid_vs_cold_all"] = layer_frac([sees(r["lm_hyb"], r["lm_cold"]) for r in cok])
    for kind in ("picard", "frozen", "mech"):
        L[f"hybrid_vs_cold_{kind}"] = layer_frac([sees(r["lm_hyb"], r["lm_cold"]) for r in cok if r["_kind"] == kind])
        L[f"noise_{kind}"] = layer_frac([sees(r["lm_s5"], r["lm_cold"]) for r in cok if r["_kind"] == kind and "lm_s5" in r])
    L["mech_only_vs_cold_all"] = layer_frac([sees(r["lm_mech"], r["lm_cold"]) for r in cok])
    L["hybrid_vs_cold_picard_hybok"] = layer_frac([sees(r["lm_hyb"], r["lm_cold"]) for r in cok if r["_kind"] == "picard" and r["_hyb_ok"]])
    S["layers"] = L

    def verdict(h, nz):
        if h is None or nz is None:
            return None
        return {lay: bool(h["layer"][lay] <= nz["layer"][lay] + MARGIN) for lay in LAYERS}
    vp = verdict(L["hybrid_vs_cold_picard"], L["noise_picard"] or L["noise_s5_vs_cold"])
    vf = verdict(L["hybrid_vs_cold_frozen"], L["noise_frozen"] or L["noise_s5_vs_cold"])
    vm = verdict(L["hybrid_vs_cold_mech"], L["noise_mech"] or L["noise_s5_vs_cold"])
    S["layers_verdict_by_kind"] = dict(picard=vp, frozen=vf, mech=vm)
    allp = vp is not None and all(vp.values())
    allm = all(v is None or all(v.values()) for v in (vf, vm))
    S["layers_not_worse"] = "yes" if (allp and allm) else ("partly" if allp else "no")
    S["layers_rule"] = f"доля «видит» гибрид↔холодный ≤ пол шума (S5↔холодный нынешний) + {MARGIN} по группе; пороги AP-9 предварительные"
    S["du_low_med_ms"] = {k: med([r["du_low_med_ms"] for r in cok if r["_kind"] == k]) for k in ("picard", "frozen", "mech")}
    S["iou_median"] = {k: {lay: med([r["iou_hyb_cold"][lay] for r in cok if r["_kind"] == k]) for lay in ("th", "sl", "lee")}
                       for k in ("picard", "frozen", "mech")}
    # --- G
    gr = [r for r in rows if r["g_w_mean"] > 0]
    S["g"] = dict(n_active=len(gr), n_evening=sum(r["hs_w_m2"] <= 0 for r in rows), w_mean_med=med([r["g_w_mean"] for r in gr]),
                  n_w_mean_ge_0_1=sum(r["g_w_mean"] >= 0.1 for r in gr))
    # --- время
    tm = rs.get("timing") or []
    T = {}
    if tm:
        it = np.array([x["iters"] for x in tm], float); w = np.array([x["wall_own"] for x in tm], float)
        A = np.vstack([np.ones_like(it), it]).T
        (a, b), *_ = np.linalg.lstsq(A, w, rcond=None)
        T.update(n=len(tm), setup_s=float(a), ms_per_iter_b1=1000.0 * float(b), device=rs["variants"]["timing"]["device"],
                 wall_own_med_s=float(np.median(w)), iters_med=float(np.median(it)))
        n_solves = np.mean([len(r.get("hybrid") or {}) for r in rows])
        T["gpu_ms_case_cupy"] = 1000.0 * (a * n_solves) + T["ms_per_iter_b1"] * S["iters_hybrid_mean_all_cases"]
        T["gpu_ms_case_cold_cupy"] = 1000.0 * (a * 2) + T["ms_per_iter_b1"] * S["iters_cold_mean_all_cases"]
    for v in ("cold", "hybrid"):
        if v in rs["variants"]:
            T[f"batch_{v}"] = rs["variants"][v]
    it_case = S["iters_hybrid_mean_all_cases"]
    game_4070 = it_case * (GAME_MS_ITER_4070S + GAME_MS_CHECK_4070S / 10.0)
    T["game_ms_case_4070s_est"] = game_4070
    T["game_ms_case_cold_4070s_est"] = S["iters_cold_mean_all_cases"] * (GAME_MS_ITER_4070S + GAME_MS_CHECK_4070S / 10.0)
    T["rx_factor"] = [RX_FACTOR_LO, RX_FACTOR, RX_FACTOR_HI]
    S["gpu_ms_case"] = T.get("gpu_ms_case_cupy")
    S["gpu_ms_rx5600xt_est"] = game_4070 * RX_FACTOR
    S["gpu_ms_rx5600xt_range"] = [game_4070 * RX_FACTOR_LO, game_4070 * RX_FACTOR_HI]
    p90 = float(np.percentile([it2(r["hybrid"]) if r.get("hybrid") else 0 for r in rows], 90))
    S["gpu_ms_rx5600xt_p90_case"] = p90 * (GAME_MS_ITER_4070S + GAME_MS_CHECK_4070S / 10.0) * RX_FACTOR
    S["gpu_rationale"] = ("gpu_ms_case — CuPy-решатель исследований (air3d), B = 1, setup + мс/итер × среднее число итераций пары m + h "
                          "на случай (механические — 0). RX 5600 XT — от игрового GLSL-Пикара (AM-03: 400 м, 3,3 мс/итер + 0,4 мс проверка "
                          "на 10 итераций на RTX 4070 SUPER; набор ~95 МБ, время — запуски и барьеры) × 2,0 (1,6–2,6): память 288 против "
                          "504 ГБ/с — ×1,75, L2 3 против 48 МБ — весь набор в DRAM, FP32 7,2 против 35 TFLOPS — ядра лёгкие; "
                          "запуски/барьеры Vulkan на RDNA1 — того же порядка. Не замер на карте.")
    S["timing"] = T
    S["budget_per_15min"] = dict(step_game_min=STEP_GAME_MIN, rx_ms_mean=S["gpu_ms_rx5600xt_est"], rx_ms_p90=S["gpu_ms_rx5600xt_p90_case"],
                                 gpu_share_at_1x=S["gpu_ms_rx5600xt_est"] / (STEP_GAME_MIN * 60e3),
                                 chunks_25ms=S["gpu_ms_rx5600xt_est"] / 25.0)
    return S


def tables(S):
    L = S["layers"]
    out = ["# AP-18: таблицы (генерирует run.py)", ""]
    out.append("## Сходимость и итерации по полосам Fr")
    out.append("| Fr | n | сошёлся холодный | гибрид (Пикар сошёлся или механизм) | механизм целиком | итераций холодный (мед.) | гибрид (мед.) | сокращение (мед.) | ω ср. |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for nm, b in S["by_fr"].items():
        out.append(f"| {nm} | {b['n']} | {b['conv_cold']:.2f} | {b['conv_hybrid']:.2f} | {b['mech_full']} | {b['iters_cold_med']} | "
                   f"{b['iters_hybrid_med']} | {(b['iter_reduction'] or float('nan')):.2f} | {b['omega_mean']:.2f} |")
    out.append("")
    out.append("## Слои: доля случаев, где слой видит разницу с холодным Пикаром (где он сошёлся)")
    out.append("| сравнение | n | термики | термики без положения источника | склоны | подветренные зоны |")
    out.append("|---|---|---|---|---|---|")
    names = [("noise_s5_vs_cold", "пол шума: S5 ↔ холодный нынешний"), ("hybrid_vs_cold_all", "гибрид, все"),
             ("hybrid_vs_cold_picard", "гибрид, только Пикар"), ("noise_picard", "  пол шума там же"),
             ("hybrid_vs_cold_frozen", "гибрид, частичная заморозка"), ("noise_frozen", "  пол шума там же"),
             ("hybrid_vs_cold_mech", "механизм целиком (Fr < 0,3)"), ("noise_mech", "  пол шума там же"),
             ("mech_only_vs_cold_all", "только механизмы (сборка + G), все")]
    for k, nm in names:
        x = L.get(k)
        if not x:
            continue
        y = x["layer"]
        out.append(f"| {nm} | {x['n']} | {y['th']:.2f} | {y['th_no_topdist']:.2f} | {y['sl']:.2f} | {y['lee']:.2f} |")
    out.append("")
    out.append("## По величинам (гибрид ↔ холодный, только Пикар; пол шума)")
    out.append("| величина | гибрид | пол шума |")
    out.append("|---|---|---|")
    hp, nz = L.get("hybrid_vs_cold_picard"), L.get("noise_picard")
    if hp and nz:
        for k in LM_KEYS:
            out.append(f"| {k} | {hp['key'][k]:.2f} | {nz['key'][k]:.2f} |")
    return "\n".join(out) + "\n"


def figures(rows, S):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return []
    out = []
    both = [r for r in rows if r["_cold_ok"] and r["_hyb_ok"] and not r["_mech_full"] and set(r["hybrid"]) == {"m", "h"}]
    if both:
        fig, ax = plt.subplots(figsize=(5.5, 5))
        x = [it2(r["cold"]) for r in both]; y = [it2(r["hybrid"]) for r in both]
        sc = ax.scatter(x, y, c=[np.log10(r["froude"]) for r in both], s=8, cmap="viridis")
        m = max(max(x), max(y))
        ax.plot([0, m], [0, m], "k--", lw=0.8)
        ax.set_xlabel("итераций, холодный Пикар (m + h)"); ax.set_ylabel("итераций, гибрид (m + h)")
        fig.colorbar(sc, label="lg Fr"); ax.set_title("Итерации: гибрид против холодного")
        fig.tight_layout(); fig.savefig(HERE / "fig_iters.png", dpi=110); plt.close(fig); out.append("fig_iters.png")
    if S["by_fr"]:
        fig, ax = plt.subplots(figsize=(6, 4))
        nm = list(S["by_fr"]); xx = np.arange(len(nm))
        ax.bar(xx - 0.2, [S["by_fr"][k]["conv_cold"] for k in nm], 0.4, label="холодный")
        ax.bar(xx + 0.2, [S["by_fr"][k]["conv_hybrid"] for k in nm], 0.4, label="гибрид (Пикар или механизм)")
        ax.set_xticks(xx); ax.set_xticklabels(nm); ax.set_ylabel("доля сошедшихся"); ax.legend(); ax.set_ylim(0, 1.05)
        fig.tight_layout(); fig.savefig(HERE / "fig_conv_by_fr.png", dpi=110); plt.close(fig); out.append("fig_conv_by_fr.png")
    L = S["layers"]
    ks = [k for k in ("noise_s5_vs_cold", "hybrid_vs_cold_picard", "hybrid_vs_cold_frozen", "hybrid_vs_cold_mech", "mech_only_vs_cold_all") if L.get(k)]
    if ks:
        fig, ax = plt.subplots(figsize=(7, 4))
        xx = np.arange(3); wd = 0.8 / len(ks)
        lab = {"noise_s5_vs_cold": "пол шума", "hybrid_vs_cold_picard": "гибрид: Пикар", "hybrid_vs_cold_frozen": "гибрид: заморозка",
               "hybrid_vs_cold_mech": "механизм целиком", "mech_only_vs_cold_all": "только механизмы"}
        for i, k in enumerate(ks):
            ax.bar(xx + i * wd - 0.4 + wd / 2, [L[k]["layer"][lay] for lay in LAYERS], wd, label=lab[k])
        ax.set_xticks(xx); ax.set_xticklabels(["термики", "склоны", "подветренные зоны"]); ax.set_ylabel("доля «слой видит разницу»")
        ax.legend(fontsize=8); ax.set_ylim(0, 1.05)
        fig.tight_layout(); fig.savefig(HERE / "fig_layers.png", dpi=110); plt.close(fig); out.append("fig_layers.png")
    fb = [r for r in rows if r.get("fallback") and r.get("hybrid") and set(r["fallback"]) == set(r["hybrid"])]
    if fb:
        fig, ax = plt.subplots(figsize=(5.5, 5))
        x = [it2(r["fallback"]) for r in fb]; y = [it2(r["hybrid"]) for r in fb]
        ax.scatter(x, y, s=8)
        m = max(max(x), max(y)); ax.plot([0, m], [0, m], "k--", lw=0.8)
        ax.set_xlabel("итераций, ω = 1 + запасное правило"); ax.set_ylabel("итераций, ω по карте фаз")
        ax.set_title("Карта ω против запасного правила")
        fig.tight_layout(); fig.savefig(HERE / "fig_omega.png", dpi=110); plt.close(fig); out.append("fig_omega.png")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(DATA / "phase/hybrid_v1"))
    a = ap.parse_args()
    rows = load(a.data)
    rs = json.loads((Path(a.data) / "runs_summary.json").read_text())
    S = analyse(rows, rs)
    S["data"] = a.data
    S["figures"] = figures(rows, S)
    (HERE / "summary.json").write_text(json.dumps(S, ensure_ascii=False, indent=1, default=float))
    (HERE / "tables.md").write_text(tables(S), encoding="utf-8")
    print(json.dumps({k: S[k] for k in ("iter_reduction", "conv_rate_hybrid", "conv_rate_cold", "nonconv_closed_frac", "layers_not_worse",
                                        "gpu_ms_case", "gpu_ms_rx5600xt_est")}, ensure_ascii=False, default=float))


if __name__ == "__main__":
    main()
