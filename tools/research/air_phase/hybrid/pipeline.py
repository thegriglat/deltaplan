"""P9 v1 (docs/contracts/air-phase.md): «фазы + Пикар» — шаги на случай без GPU (классификатор, сборка, сшивка).

Шаги (P9): (1) классификатор → веса фаз `weights` (K, 96, 96), карта ω `omega_map`, маска механизмов `freeze_mask`;
(2) сборка механизмов — P8 `assembly.assemble` (A, D, LEE, E/F, H) + G (`hybrid.drainage`, вечерний сток);
(3) тёплый старт Пикара — `batch_solver.solve_batch` (P4 v6: init = {"agl": сборка}, omega_map, freeze_mask,
    omega_fallback = (300, 0,5), max_outer 1000) — вызывает `run_hybrid.py`;
(4) сшивка проекцией — `stitch`.

Фазы и кто их считает (решение пользователя 06.10, план §9): Пикар — A (обтекание, наветренные склоны), B = LEE (срыв),
C (волны / переход D↔A у Fr ≈ 1) и слабое D; механизмы — H (штиль), сильное D, F (свободная конвекция), G (вечерний сток).

Классификатор (оси и пороги — air_phase_results.md §0; Fr, U10 — по случаю, остальное — по клеткам):
  * веса A, D, LEE, EF, H — P8 `assemble.classify` (AP-17, без изменений);
  * G — вес `drainage.evening_drainage` (стоковый ветер против фона); остальные веса × (1 − w_G);
  * карта ω: полоса границ b = max(b_Fr, b_U), b_Fr = σ((lg Fr − lg 0,3)/w)·σ((lg 1,1 − lg Fr)/w),
    b_U = σ((lg U10 − lg 0,6)/w)·σ((lg 1,5 − lg U10)/w), w = 0,05 дек (резкие границы §0 — 0,01–0,04 дек; 0,05 — чтобы карта
    не была ступенькой на шаге сетки по Fr), ω = 1 − 0,5·b (у границ 0,5, в чистом обтекании 1). Fr и U10 — величины
    случая (классификатор P8 тоже берёт Fr по случаю), поэтому карта ω одна на всю область случая; по колоннам она
    различается только в замороженных клетках (там ω не действует). Местного Fr у классификатора нет — оговорка в разборе.
  * freeze_mask (механизмы):
      - H и сильное D: Fr < FR_FREEZE = 0,3 (σ ≥ 0,5, ширина 0,05 дек): ниже полосы ω (H — Fr ≲ 0,25, поле Пикара там
        блуждание, §0; 0,25–0,3 — глубокое блокирование, порог сходимости 0,32 при h/z_i = 0,3) — вся область;
      - F (свободная конвекция): w_EF ≥ 0,5 и w* ≥ U_sat в клетке — конвективная скорость больше фонового ветра: течение —
        ячейки свободной конвекции, а не валы и не обтекание (−z_i/L ≳ 25: Weckwerth et al. 1999, MWR 127; Grossman 1982;
        w*/U ≥ 1 соответствует −z_i/L ≈ (w*/u*)³/κ ≳ 10³ при u*/U ≈ 0,1); смешанная конвекция (w* < U) остаётся Пикару;
      - G: w_G ≥ 0,5 (стоковый ветер сильнее фона).
    Решение «m» (без нагрева, для w_mech) — только H/сильное D (F и G — от потока тепла).
  * Полностью механический случай (заморожена вся область) Пикара не зовёт: поле = сборка (+ G).
Сшивка (шаг 4): поле Пикара (замороженные колонны в нём = init = сборка) + приращение G в незамороженных клетках с
w_G < 0,5: δu = w_G·member·(u_G − u_П), δθ′ = w_G·θ′_G; δ(u, v, w) проецируется на ∇·δu = 0 (`mechanisms.project`, MAC в
ζ = z − h) — так проекция не трогает уже бездивергентное поле Пикара, а убирает только дивергенцию вставки.
"""
from __future__ import annotations

import json
import math
import time

import numpy as np

from assembly import assemble as AS
from assembly import mechanisms as M
from . import drainage as DR

PHASES = ("A", "D", "LEE", "EF", "H", "G")
DEFAULT_CFG = dict(
    version="hybrid_v1",
    fr_band=(0.3, 1.1), u_band=(0.6, 1.5), band_w_dec=0.05, omega_band=0.5, omega_snap=0.01,
    fr_freeze=0.3, freeze_w_dec=0.05,
    ef_freeze=0.5, wstar_over_usat=1.0,
    g_freeze=0.5,
    omega_fallback=(300, 0.5), max_outer=1000,
)


def _sig(x, xc, w):
    return 1.0 / (1.0 + math.exp(-(math.log10(max(x, 1e-12)) - math.log10(xc)) / w))


def band(x, lo, hi, w):
    """Принадлежность полосе [lo, hi] по lg x: σ((lg x − lg lo)/w)·σ((lg hi − lg x)/w)."""
    return _sig(x, lo, w) * (1.0 - _sig(x, hi, w))


def classify(hc, heat, cond, asm, g, cfg):
    """→ dict: weights (6, ny, nx), weights_m (6, …), omega_map (ny, nx), freeze_h, freeze_m (ny, nx) bool, info."""
    c = cfg
    fr, u10 = float(cond["froude"]), float(cond["u10_m_s"])
    wG = g["w"]
    W = np.concatenate([asm["weights"] * (1.0 - wG)[None], wG[None]]).astype(np.float64)
    Wm = np.concatenate([asm["weights_m"], np.zeros_like(wG)[None]]).astype(np.float64)
    b_fr = band(fr, *c["fr_band"], c["band_w_dec"])
    b_u = band(u10, *c["u_band"], c["band_w_dec"])
    b = max(b_fr, b_u)
    om = 1.0 - (1.0 - c["omega_band"]) * b
    om = 1.0 if om > 1.0 - c["omega_snap"] else om                  # хвост сигмоиды (b < 2 %) — чистое обтекание, ω = 1
    omega = np.full(hc.shape, om)
    low = 1.0 - _sig(fr, c["fr_freeze"], c["freeze_w_dec"])         # Fr < 0,3
    full = low >= 0.5
    bl = M.bl_state(hc, heat, float(cond["z_i_m"]), u10)
    usat = float(cond["u_sat_m_s"])
    f_free = (asm["weights"][AS.PHASES.index("EF")] >= c["ef_freeze"]) & (bl["wstar"] >= c["wstar_over_usat"] * usat)
    g_on = wG >= c["g_freeze"]
    fz_h = np.full(hc.shape, full) | f_free | g_on
    fz_m = np.full(hc.shape, full)
    info = dict(b_fr=b_fr, b_u=b_u, b=b, omega=float(omega.mean()), low=low, full=bool(full),
                f_free_frac=float(f_free.mean()), g_frac=float(g_on.mean()), freeze_h_frac=float(fz_h.mean()),
                freeze_m_frac=float(fz_m.mean()))
    return dict(weights=W, weights_m=Wm, omega_map=omega, freeze_h=fz_h, freeze_m=fz_m, info=info)


def blend_g(u, v, th, g):
    """Поле с G: u = (1 − w_G·member)·u + w_G·member·u_G; θ′ += w_G·θ′_G (w — дальше проекция)."""
    a = g["w"][None] * g["member"]
    return (1.0 - a) * u + a * g["u"], (1.0 - a) * v + a * g["v"], th + g["w"][None] * g["th"]


def prepare(hc, heat, cond, cfg=None):
    """Шаги 1–2 на CPU. hc (96, 96) м; heat (96, 96) Вт/м² (вход решателя); cond — строка S2.
    → dict: init_h (4, 13, ny, nx) f4 (сборка + G, спроецировано), init_m (3, 13, …), weights/weights_m (6, …), omega_map,
    freeze_h, freeze_m, g (поле G для сшивки), info, seconds (по шагам), cfg (JSON)."""
    c = dict(DEFAULT_CFG)
    if cfg:
        c.update(cfg)
    t0 = time.perf_counter()
    hc = np.asarray(hc, np.float64)
    asm = AS.assemble(hc, cond, heat=heat)
    t1 = time.perf_counter()
    g = DR.evening_drainage(hc, heat, cond)
    t2 = time.perf_counter()
    cl = classify(hc, heat, cond, asm, g, c)
    u, v, w, th = (asm["fields"][k].astype(np.float64) for k in range(4))
    if g["diag"]["active"] and g["w"].max() > 0:
        u2, v2, th = blend_g(u, v, th, g)
        du, dv, dw, _ = M.project(u2 - u, v2 - v, np.zeros_like(w), hc)
        u, v, w = u + du, v + dv, w + dw
    t3 = time.perf_counter()
    return dict(init_h=np.stack([u, v, w, th]).astype(np.float32), init_m=asm["fields_m"].astype(np.float32),
                weights=cl["weights"].astype(np.float32), weights_m=cl["weights_m"].astype(np.float32),
                omega_map=cl["omega_map"].astype(np.float32), freeze_h=cl["freeze_h"], freeze_m=cl["freeze_m"],
                g=g, info=dict(cl["info"], g=g["diag"], asm_meta=asm["meta"]),
                seconds=dict(assemble=t1 - t0, drainage=t2 - t1, classify_blend=t3 - t2, total=t3 - t0),
                cfg=json.dumps(c, ensure_ascii=False))


def numerics_kwargs(prep, decision, cfg=None, variant="hybrid"):
    """Опции решателя P4 v6 для шага 3. variant: hybrid — карта ω + заморозка + запасное правило; fallback — ω = 1 +
    запасное правило + заморозка (вклад карты ω); cold_omap — как hybrid, но без заморозки (с холодным стартом — вклад
    тёплого старта); cold — Numerics() как S5."""
    c = dict(DEFAULT_CFG)
    if cfg:
        c.update(cfg)
    fz = prep["freeze_h"] if decision == "h" else prep["freeze_m"]
    kw = dict(max_outer=int(c["max_outer"]))
    if variant == "cold":
        return kw
    kw["omega_fallback"] = tuple(c["omega_fallback"])
    if variant in ("hybrid", "cold_omap") and float(np.min(prep["omega_map"])) < 1.0:
        kw["omega_map"] = np.asarray(prep["omega_map"], np.float32)
    if variant in ("hybrid", "fallback") and fz.any():
        kw["freeze_mask"] = np.asarray(fz, bool)
    return kw


def stitch(pic_h, pic_m, prep, hc):
    """Шаг 4. pic_h (4, 13, ny, nx), pic_m (3, 13, …) — поля Пикара (или None — полностью механический случай: поле = init).
    → (fields (4, 13, ny, nx) f4, fields_m (3, 13, ny, nx) f4, info: ∇·u приращения до/после)."""
    hc = np.asarray(hc, np.float64)
    if pic_h is None:
        return prep["init_h"].copy(), prep["init_m"].copy(), dict(stitched=False)
    f = np.asarray(pic_h, np.float64).copy()
    fm = np.asarray(pic_m, np.float64).copy() if pic_m is not None else prep["init_m"].astype(np.float64)
    g = prep["g"]
    info = dict(stitched=False)
    if g["diag"]["active"]:
        wg = np.where(prep["freeze_h"], 0.0, g["w"])
        if wg.max() > 0:
            gg = dict(g, w=wg)
            u2, v2, th2 = blend_g(f[0], f[1], f[3], gg)
            du, dv, dw, dinfo = M.project(u2 - f[0], v2 - f[1], np.zeros_like(f[2]), hc)
            f[0] += du; f[1] += dv; f[2] += dw; f[3] = th2
            info = dict(stitched=True, div=dinfo)
    return f.astype(np.float32), fm.astype(np.float32), info


def hybrid_case(hc, heat, cond, solve, cfg=None, variant="hybrid"):
    """Шаги 1–4 P9 на один случай с заданным решателем: solve(decision, numerics_kwargs, init) → dict(fields (4|3, 13, ny, nx),
    status, iters) — `batch_solver.solve_batch` (run_hybrid.py собирает случаи в пакет сам) или заглушка в тестах.
    → dict: fields, fields_m, prep, runs {m|h: результат или None — механизм}, stitch."""
    prep = prepare(hc, heat, cond, cfg)
    runs = {}
    for dec in ("m", "h"):
        fz = prep["freeze_h"] if dec == "h" else prep["freeze_m"]
        if fz.all():
            runs[dec] = None
            continue
        init = {"agl": prep["init_h"] if dec == "h" else prep["init_m"]}
        runs[dec] = solve(dec, numerics_kwargs(prep, dec, cfg, variant), init)
    pic_h = None if runs["h"] is None else runs["h"]["fields"]
    pic_m = None if runs["m"] is None else runs["m"]["fields"][:3]
    if pic_h is None and pic_m is not None:
        pic_h = prep["init_h"]
    f, fm, info = stitch(pic_h, pic_m, prep, hc)
    return dict(fields=f, fields_m=fm, prep=prep, runs=runs, stitch=info)
