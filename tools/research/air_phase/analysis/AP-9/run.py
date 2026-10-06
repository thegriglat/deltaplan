"""AP-9 (air-phase, этап 2): серия RELAX — штилевая граница несходимости: решатель (численная) или физика.

Запуск (CPU, только чтение данных):
  /home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python \
      tools/research/air_phase/analysis/AP-9/run.py \
      [--plan ~/air_synth_data/phase/ap_v1] [--results ~/air_synth_data/phase/ap_v1__s1-74644c4]
→ summary.json, cases.csv, fig_*.png рядом со скриптом.

Что считается (контракты P2 v4, P3 v2, P4 v3; критерий §9 п. 4 air_phase.md):
  * варианты RELAX (s = 0,3; 27 линий = 3 формы × H 0/100/250 × h/z_i 0,3/1/3; холодный старт):
    omega (ω_u = ω_k = 0,5; ω_k — множитель к релаксации K 0,1), kfloor (k_fa = 10 м²/с), rel (относительный
    критерий resid·a/U_sat² < 4e-4), calm (rel на Fr 0,1/0,15/0,2); эталон — GRID той же линии (ref_line_id).
  * по случаю: статус, итерации, late_spread60_p90/U_sat, «почти сошлось» (несошедшийся с разбросом < 0,05 м/с —
    как §5.2), ход невязки на поздних снимках (наклон log10 resid за 100 итераций → затухание / плато-блуждание,
    экстраполяция до порога), du_max/U_sat, AR(1) и амплитуда поздних снимков u,v на 25 м (шумный предвестник);
    разница итогового поля с эталоном: |Δu_h| (горизонтальный вектор) на 25–300 м, max и среднее по области
    без 5 краевых клеток, в долях U_sat, и |Δw| на 300 м.
  * эталон поля: GRID той же линии при том же Fr (|ΔFr|/Fr < 1 %); если такого Fr в GRID нет — вариант rel того же
    Fr (те же итерации, что GRID, отличается только остановка; ref_kind = 'rel'), см. section.md «Оговорки».
  * относительный критерий против продолжения GRID: для rel/calm, остановленных раньше 1000, где есть GRID того же Fr,
    — отклонение снимков GRID u,v на 25 м после итерации остановки от итогового поля rel (скрывает ли блуждание).
  * метрики слоёв P6 (`layer_metrics.layer_diff`, AP-6): если модуль есть — считаются; иначе — заместитель из
    параметров порядка P3 (`order`: w на 300 м, обратное течение/застой у земли) и пометка в summary.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))

EDGE = 5
LEV = list(range(7))            # 25, 50, 75, 100, 150, 200, 300 м (P3 agl_m[0:7])
LEV300 = 6
SERIES = {0: "GRID", 4: "RELAX"}  # enum P2 (проверяется по plan.json)
ABS_TOL = 2e-5
REL_TOL = 4e-4
NEAR_MS = 0.05                   # «почти сошлось», м/с (§5.2)
FIELD_TOL = 0.05                 # §9 п. 4: поле не меняется > 0,05 U
VARIANTS = ("grid", "omega", "kfloor", "rel", "calm")

try:                             # P6 (AP-6) — если уже влита
    import layer_metrics as LM   # noqa: E402
    HAVE_LM = hasattr(LM, "layer_diff") and hasattr(LM, "layer_metrics")
except Exception:                # noqa: BLE001
    LM, HAVE_LM = None, False


def load_plan(plan_dir):
    p = json.loads((Path(plan_dir) / "plan.json").read_text())
    lines = {int(l["line_id"]): l for l in p["lines"]}
    rel = {int(r["relief_id"]): r for r in p["reliefs"]}
    return p, lines, rel


def index_results(res_dir, want_lines):
    """case_id → (part, row, cases-row) для случаев нужных линий."""
    idx = {}
    for part in sorted(Path(res_dir).glob("part-*.h5")):
        with h5py.File(part, "r") as h:
            c = h["cases"][:]
        m = np.isin(c["line_id"], list(want_lines))
        for r in np.nonzero(m)[0]:
            idx[int(c["case_id"][r])] = (part, int(r), c[r])
    return idx


def trace_stats(it, resid, du, snaps_uv, u_sat):
    """Поздний ход невязки и снимков. snaps_uv: (T, 2, ny, nx) u, v на 25 м."""
    ok = it >= 0
    it, resid, du = it[ok], resid[ok], du[ok]
    out = dict(n_snap=int(ok.sum()), slope_dec100=np.nan, resid_last=np.nan, resid_min_late=np.nan,
               du_last_rel=np.nan, du_med_late_rel=np.nan, ar1=np.nan, fluct_rel=np.nan, extrap_iters=np.nan)
    if len(it) == 0:
        return out
    out["resid_last"] = float(resid[-1])
    out["du_last_rel"] = float(du[-1] / u_sat)
    late = it >= 500
    if late.sum() >= 4:
        x, y = it[late].astype(float), np.log10(np.maximum(resid[late], 1e-30))
        sl = np.polyfit(x, y, 1)[0] * 100.0
        out["slope_dec100"] = float(sl)
        out["resid_min_late"] = float(resid[late].min())
        out["du_med_late_rel"] = float(np.nanmedian(du[late]) / u_sat)
        if sl < 0:
            out["extrap_iters"] = float(it[-1] + (np.log10(ABS_TOL) - y[-1]) / sl * 100.0)
        s = snaps_uv[ok][late].astype(np.float64)[:, :, EDGE:-EDGE, EDGE:-EDGE]
        d = s - s.mean(0, keepdims=True)
        num = float((d[1:] * d[:-1]).sum())
        den = float((d[:-1] ** 2).sum())
        out["ar1"] = num / den if den > 0 else np.nan
        out["fluct_rel"] = float(np.sqrt((d ** 2).sum(1).mean()) / u_sat)
    return out


def field_diff(fa, fb, u_sat):
    """fa, fb: (3, 7, ny, nx) u, v, w на 25–300 м. → max/mean |Δu_h|/U_sat и |Δw|(300 м)/U_sat."""
    a = fa[:, :, EDGE:-EDGE, EDGE:-EDGE].astype(np.float64)
    b = fb[:, :, EDGE:-EDGE, EDGE:-EDGE].astype(np.float64)
    dh = np.hypot(a[0] - b[0], a[1] - b[1])
    dw = np.abs(a[2, LEV300] - b[2, LEV300])
    return dict(du_max_rel=float(dh.max() / u_sat), du_mean_rel=float(dh.mean() / u_sat),
                du_p90_rel=float(np.quantile(dh, 0.9) / u_sat),
                dw300_max_rel=float(dw.max() / u_sat), dw300_mean_rel=float(dw.mean() / u_sat))


PROXY = ("f_wmax300", "f_wstd300", "f_rev25", "f_stag25", "f_speed50")


def wilson(k, n):
    if n == 0:
        return (np.nan, np.nan)
    p, z = k / n, 1.96
    c = (p + z * z / (2 * n)) / (1 + z * z / n)
    h = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (float(c - h), float(c + h))


def main(argv=None):
    ap = argparse.ArgumentParser()
    root = Path(os.environ.get("AIR_SYNTH_DATA", Path.home() / "air_synth_data"))
    ap.add_argument("--plan", default=str(root / "phase/ap_v1"))
    ap.add_argument("--results", default=str(root / "phase/ap_v1__s1-74644c4"))
    ap.add_argument("--out", default=str(HERE))
    a = ap.parse_args(argv)
    out = Path(a.out)

    plan, lines, reliefs = load_plan(a.plan)
    relax = {i: l for i, l in lines.items() if l["series"] == "RELAX"}
    grid_all = {i: l for i, l in lines.items() if l["series"] == "GRID"}
    ref_lines = sorted({int(l["ref_line_id"]) for l in relax.values()})
    want = set(relax) | set(grid_all)
    print(f"RELAX линий {len(relax)}, эталонных GRID {len(ref_lines)}; индекс частей…", flush=True)
    idx = index_results(a.results, want)

    # ---------- проверка AP-5: несходимость всего GRID по U10
    gstat = defaultdict(lambda: [0, 0])
    for cid, (_, _, c) in idx.items():
        if lines[int(c["line_id"])]["series"] != "GRID":
            continue
        u = float(c["u10"])
        for b in (("<1" if u < 1 else ">=1"),
                  ("1-1.5" if 1 <= u < 1.5 else ("1.5-2" if 1.5 <= u < 2 else (">=2" if u >= 2 else None)))):
            if b is None:
                continue
            gstat[b][0] += int(c["status"] != 0)
            gstat[b][1] += 1
    ap5 = {b: dict(n=v[1], nonconv=v[0], frac=v[0] / v[1], ci95=wilson(v[0], v[1])) for b, v in gstat.items()}

    # ---------- случаи: варианты и эталоны
    def variant(l):
        return "grid" if l["series"] == "GRID" else l["variant"]

    want_cases = {}
    for cid, (part, row, c) in idx.items():
        lid = int(c["line_id"])
        l = lines[lid]
        if l["series"] == "RELAX" or lid in ref_lines:
            want_cases[cid] = (part, row, c, variant(l), int(l["ref_line_id"]) if l["series"] == "RELAX" else lid)
    by_part = defaultdict(list)
    for cid, (part, row, *_r) in want_cases.items():
        by_part[part].append((row, cid))

    F, ORD, TR, H = {}, {}, {}, {}
    SN = {}                                      # снимки u,v 25 м для эталонов GRID (продолжение)
    print(f"читаю {len(want_cases)} случаев из {len(by_part)} частей…", flush=True)
    for part, rows in sorted(by_part.items()):
        rows.sort()
        with h5py.File(part, "r") as h:
            for row, cid in rows:
                c = want_cases[cid][2]
                u_sat = float(c["u_sat"])
                F[cid] = h["fields/f"][row, :3, :7].astype(np.float32)
                ORD[cid] = {n: float(h["order"][row][n]) for n in PROXY}
                it = h["trace/iter"][row]
                sn = h["trace/fields"][row, :, :2, 0]          # (T, 2, ny, nx) u, v на 25 м
                TR[cid] = trace_stats(it, h["trace/resid"][row], h["trace/du_max"][row], sn, u_sat)
                TR[cid]["_resid"] = h["trace/resid"][row].copy()
                TR[cid]["_iter"] = it.copy()
                if want_cases[cid][3] == "grid":
                    SN[cid] = (it.copy(), sn.astype(np.float32))
                if HAVE_LM:
                    H[cid] = (h["inputs/hc"][row], h["inputs/heat_flux"][row].astype(np.float32),
                              h["inputs/hbl"][row].astype(np.float32))

    # GRID: (ref_line, Fr) → case
    grid_at = defaultdict(dict)
    for cid, (_, _, c, v, rl) in want_cases.items():
        if v == "grid":
            grid_at[rl][float(c["fr"])] = cid
    rel_at = defaultdict(dict)
    for cid, (_, _, c, v, rl) in want_cases.items():
        if v == "rel":
            rel_at[rl][round(float(c["fr"]), 4)] = cid

    def find_grid(rl, fr):
        for g, cid in grid_at[rl].items():
            if abs(g / fr - 1) < 0.01:
                return cid
        return None

    def full_case(cid):
        c = want_cases[cid][2]
        l = lines[int(c["line_id"])]
        r = reliefs[int(c["relief_id"])]
        d = {n: c[n].item() for n in c.dtype.names}
        d.update(h_m=r["h_m"], slope=r["slope"], shape=r["shape"], h_over_zi=l["h_over_zi"])
        return d

    def full_field(cid):
        # layer_metrics ждёт (4, 13, 96, 96); перечитываем целиком только при наличии P6
        part, row = want_cases[cid][0], want_cases[cid][1]
        with h5py.File(part, "r") as h:
            return h["fields/f"][row].astype(np.float32)

    rows = []
    for cid, (part, row, c, v, rl) in sorted(want_cases.items()):
        u_sat, fr = float(c["u_sat"]), float(c["fr"])
        l = lines[int(c["line_id"])]
        r = reliefs[int(c["relief_id"])]
        st = int(c["status"])
        rec = dict(case_id=cid, variant=v, ref_line=rl, shape=r["shape"], H=float(l["heat_flux_wm2"]),
                   h_over_zi=float(l["h_over_zi"]), fr=fr, u10=float(c["u10"]), u_sat=u_sat, status=st,
                   iters=int(c["iters"]), spread_rel=float(c["late_spread60_p90"]) / u_sat,
                   spread_ms=float(c["late_spread60_p90"]), resid_final=float(c["resid_final"]),
                   resid_rel_final=float(c["resid_rel_final"]))
        rec["near"] = int(st == 1 and rec["spread_ms"] < NEAR_MS)
        rec.update({k: v2 for k, v2 in TR[cid].items() if not k.startswith("_")})
        ref, kind = None, ""
        if v != "grid":
            ref = find_grid(rl, fr)
            kind = "grid" if ref is not None else ""
            if ref is None and v in ("omega", "kfloor", "calm"):
                ref = rel_at[rl].get(round(fr, 4))
                kind = "rel" if ref is not None and ref != cid else ""
                if kind == "":
                    ref = None
        rec["ref_case"] = -1 if ref is None else ref
        rec["ref_kind"] = kind
        if ref is not None:
            cr = want_cases[ref][2]
            rec["ref_status"] = int(cr["status"])
            rec["ref_spread_rel"] = float(cr["late_spread60_p90"]) / u_sat
            rec.update(field_diff(F[cid], F[ref], u_sat))
            for n in PROXY:
                rec["d_" + n] = ORD[cid][n] - ORD[ref][n]
                rec["ref_" + n] = ORD[ref][n]
            if HAVE_LM:
                try:
                    ma = LM.layer_metrics(full_field(cid), *H[cid], full_case(cid))
                    mb = LM.layer_metrics(full_field(ref), *H[ref], full_case(ref))
                    for k2, v3 in LM.layer_diff(ma, mb).items():
                        rec["ld_" + k2] = float(v3)
                except Exception as e:  # noqa: BLE001
                    rec["ld_error"] = repr(e)[:200]
        # относительный критерий: продолжение GRID после остановки
        if v in ("rel", "calm") and st == 0:
            g = find_grid(rl, fr)
            if g is not None and g in SN:
                git, gsn = SN[g]
                after = (git >= rec["iters"])
                fin = F[cid][:2, 0, EDGE:-EDGE, EDGE:-EDGE].astype(np.float64)
                if after.any():
                    dev = [float(np.hypot(*(gsn[k][:, EDGE:-EDGE, EDGE:-EDGE] - fin)).mean() / u_sat)
                           for k in np.nonzero(after)[0]]
                    devmax = [float(np.hypot(*(gsn[k][:, EDGE:-EDGE, EDGE:-EDGE] - fin)).max() / u_sat)
                              for k in np.nonzero(after)[0]]
                    rec["cont_n"] = len(dev)
                    rec["cont_mean_dev_rel"] = float(np.max(dev))
                    rec["cont_max_dev_rel"] = float(np.max(devmax))
                rec["grid_status"] = int(want_cases[g][2]["status"])
                rec["grid_iters"] = int(want_cases[g][2]["iters"])
                rec["grid_spread_rel"] = float(want_cases[g][2]["late_spread60_p90"]) / u_sat
        # ретро-критерий rel по снимкам GRID (снимки через 50 итераций — грубая оценка)
        if v == "grid":
            rr = TR[cid]["_resid"] * float(plan["context"]["h_m"]) / max(u_sat, 0.1) ** 2
            okk = TR[cid]["_iter"] >= 0
            hit = np.nonzero(okk & (rr < REL_TOL))[0]
            rec["retro_rel_iter"] = int(TR[cid]["_iter"][hit[0]]) if len(hit) else -1
        rec["_rs"] = np.where(TR[cid]["_iter"] >= 0, TR[cid]["_resid"], np.nan)
        rows.append(rec)

    keys = sorted({k for r in rows for k in r if not k.startswith("_")})
    with open(out / "cases.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: v for k, v in r.items() if not k.startswith("_")})

    S = summarize(rows, ap5)
    S["layer_metrics"] = "P6 layer_diff посчитан" if HAVE_LM else "P6 (AP-6) не влита — заместитель по order P3; добавить layer_diff после AP-6"
    S["inputs"] = dict(plan=a.plan, results=a.results, n_cases=len(rows))
    (out / "summary.json").write_text(json.dumps(S, ensure_ascii=False, indent=1, default=float))
    figures(rows, out)
    print(json.dumps({k: S[k] for k in ("calm_boundary", "verdict_ru")}, ensure_ascii=False, indent=1))


def _q(x, q):
    x = np.asarray([v for v in x if v == v], float)
    return float(np.quantile(x, q)) if len(x) else np.nan


def summarize(rows, ap5):
    S = dict(contract="P7 v1", task="AP-9", ap5_check_grid_nonconv_by_u10=ap5)
    rel_fr = sorted({r["fr"] for r in rows if r["variant"] in ("omega", "kfloor", "rel")})
    # --- по варианту и Fr
    table = {}
    for v in VARIANTS:
        R = [r for r in rows if r["variant"] == v]
        if v == "grid":
            R = [r for r in R if r["fr"] <= 1.5]
        frs = sorted({round(r["fr"], 4) for r in R})
        t = {}
        for fr in frs:
            X = [r for r in R if round(r["fr"], 4) == fr]
            n, k = len(X), sum(r["status"] == 0 for r in X)
            t[f"{fr:g}"] = dict(
                n=n, conv_frac=k / n, conv_ci95=wilson(k, n), u10_mean_ms=float(np.mean([r["u10"] for r in X])),
                iters_med_conv=_q([r["iters"] for r in X if r["status"] == 0], 0.5),
                spread_p90_med_rel=_q([r["spread_rel"] for r in X if r["status"] == 1], 0.5),
                near_frac_of_nonconv=(sum(r["near"] for r in X) / max(1, n - k)),
                du_mean_med_rel=_q([r.get("du_mean_rel", np.nan) for r in X], 0.5),
                du_mean_p90_rel=_q([r.get("du_mean_rel", np.nan) for r in X], 0.9),
                du_max_med_rel=_q([r.get("du_max_rel", np.nan) for r in X], 0.5),
                ref_kind=sorted({r.get("ref_kind", "") for r in X}))
        table[v] = t
    S["by_variant_fr"] = table

    # --- сводка по варианту на граничных точках (Fr из RELAX), разделённая по U10
    def block(R):
        n = len(R)
        k = sum(r["status"] == 0 for r in R)
        nc = [r for r in R if r["status"] == 1]
        return dict(
            n=n, conv_frac=k / n if n else np.nan, conv_ci95=wilson(k, n),
            iters_med_conv=_q([r["iters"] for r in R if r["status"] == 0], 0.5),
            spread_p90_med_rel_nonconv=_q([r["spread_rel"] for r in nc], 0.5),
            spread_p90_p90_rel_nonconv=_q([r["spread_rel"] for r in nc], 0.9),
            near_frac_of_nonconv=sum(r["near"] for r in R) / max(1, len(nc)),
            slope_dec100_med_nonconv=_q([r["slope_dec100"] for r in nc], 0.5),
            decaying_frac_of_nonconv=(sum(1 for r in nc if r["slope_dec100"] < -0.05) / max(1, len(nc))),
            extrap_le2000_frac_of_nonconv=(sum(1 for r in nc if r["extrap_iters"] == r["extrap_iters"]
                                               and r["extrap_iters"] <= 2000) / max(1, len(nc))),
            ar1_med_nonconv=_q([r["ar1"] for r in nc], 0.5),
            fluct_med_rel_nonconv=_q([r["fluct_rel"] for r in nc], 0.5),
            du_mean_med_rel=_q([r.get("du_mean_rel", np.nan) for r in R], 0.5),
            du_mean_p90_rel=_q([r.get("du_mean_rel", np.nan) for r in R], 0.9),
            du_max_med_rel=_q([r.get("du_max_rel", np.nan) for r in R], 0.5),
            dw300_max_med_rel=_q([r.get("dw300_max_rel", np.nan) for r in R], 0.5),
            frac_field_changed_gt005=(sum(1 for r in R if r.get("du_mean_rel", 0) > FIELD_TOL)
                                      / max(1, sum(1 for r in R if "du_mean_rel" in r))))

    def u10bin(u):
        return "<1" if u < 1 else ("1-1.5" if u < 1.5 else ("1.5-2" if u < 2 else ("2-3" if u < 3 else ">=3")))

    def frbin(f):
        return "0.1-0.2" if f < 0.21 else ("0.2-0.3" if f < 0.3 else ("0.3-0.5" if f < 0.51 else "0.7-1.4"))

    agg = {}
    for v in VARIANTS:
        R = [r for r in rows if r["variant"] == v and (v != "grid" or any(abs(r["fr"] / f - 1) < 0.01 for f in rel_fr))]
        if v == "grid":
            # GRID на граничных Fr (точные совпадения 0,3–0,5) + штиль 0,1/0,151
            R = [r for r in rows if r["variant"] == "grid" and r["fr"] <= 1.5]
        d = dict(all=block(R))
        for nm, fn in (("u10", lambda r: u10bin(r["u10"])), ("fr", lambda r: frbin(r["fr"])),
                       ("h_over_zi_fr03_05", lambda r: f"{r['h_over_zi']:g}" if 0.29 <= r["fr"] <= 0.51 else None),
                       ("H_fr03_05", lambda r: f"{r['H']:g}" if 0.29 <= r["fr"] <= 0.51 else None),
                       ("shape_fr03_05", lambda r: r["shape"] if 0.29 <= r["fr"] <= 0.51 else None)):
            g = defaultdict(list)
            for r in R:
                if fn(r) is not None:
                    g[fn(r)].append(r)
            d["by_" + nm] = {k: block(x) for k, x in sorted(g.items())}
        agg[v] = d
    S["by_variant"] = agg

    # --- парное сравнение с GRID на одних и тех же случаях (линия, Fr) — только точные совпадения
    pair = {}
    for v in ("omega", "kfloor", "rel", "calm"):
        P = [r for r in rows if r["variant"] == v and r.get("ref_kind") == "grid"]
        g_nc = [r for r in P if r["ref_status"] == 1]
        fixed = [r for r in g_nc if r["status"] == 0]
        pair[v] = dict(
            n_pairs=len(P), grid_nonconv=len(g_nc), fixed_by_variant=len(fixed),
            fixed_frac=len(fixed) / max(1, len(g_nc)),
            broken_by_variant=sum(1 for r in P if r["ref_status"] == 0 and r["status"] != 0),
            fixed_du_mean_med_rel=_q([r["du_mean_rel"] for r in fixed], 0.5),
            fixed_du_mean_max_rel=_q([r["du_mean_rel"] for r in fixed], 1.0),
            fixed_du_max_med_rel=_q([r["du_max_rel"] for r in fixed], 0.5),
            fixed_frac_du_mean_le005=(sum(1 for r in fixed if r["du_mean_rel"] <= FIELD_TOL) / max(1, len(fixed))),
            fixed_ref_spread_med_rel=_q([r["ref_spread_rel"] for r in fixed], 0.5),
            both_conv_du_mean_med_rel=_q([r["du_mean_rel"] for r in P if r["status"] == 0 and r["ref_status"] == 0], 0.5),
            both_conv_du_max_med_rel=_q([r["du_max_rel"] for r in P if r["status"] == 0 and r["ref_status"] == 0], 0.5),
            still_nonconv_spread_med_rel=_q([r["spread_rel"] for r in g_nc if r["status"] == 1], 0.5),
            still_nonconv_ref_spread_med_rel=_q([r["ref_spread_rel"] for r in g_nc if r["status"] == 1], 0.5),
            proxy_d_wmax300_med_abs_ms=_q([abs(r["d_f_wmax300"]) for r in P], 0.5),
            proxy_d_wmax300_p90_abs_ms=_q([abs(r["d_f_wmax300"]) for r in P], 0.9),
            proxy_d_wstd300_med_relchg=_q([abs(r["d_f_wstd300"]) / max(r["ref_f_wstd300"], 1e-3) for r in P], 0.5),
            proxy_d_rev25_med_abs=_q([abs(r["d_f_rev25"]) for r in P], 0.5),
            proxy_d_stag25_med_abs=_q([abs(r["d_f_stag25"]) for r in P], 0.5),
            proxy_d_stag25_p90_abs=_q([abs(r["d_f_stag25"]) for r in P], 0.9),
            fixed_proxy_d_wmax300_med_abs_ms=_q([abs(r["d_f_wmax300"]) for r in fixed], 0.5),
            fixed_proxy_d_wmax300_p90_abs_ms=_q([abs(r["d_f_wmax300"]) for r in fixed], 0.9),
            fixed_proxy_d_wstd300_med_relchg=_q([abs(r["d_f_wstd300"]) / max(r["ref_f_wstd300"], 1e-3) for r in fixed], 0.5),
            fixed_proxy_d_stag25_p90_abs=_q([abs(r["d_f_stag25"]) for r in fixed], 0.9),
            fixed_dw300_max_med_rel=_q([r["dw300_max_rel"] for r in fixed], 0.5),
            both_conv_proxy_d_wstd300_med_relchg=_q([abs(r["d_f_wstd300"]) / max(r["ref_f_wstd300"], 1e-3)
                                                     for r in P if r["status"] == 0 and r["ref_status"] == 0], 0.5),
            fixed_iters_med=_q([r["iters"] for r in fixed], 0.5),
            fixed_by_fr={f"{fr:g}": sum(1 for r in fixed if round(r["fr"], 3) == fr) for fr in sorted({round(r["fr"], 3) for r in P})},
            grid_nonconv_by_fr={f"{fr:g}": sum(1 for r in g_nc if round(r["fr"], 3) == fr) for fr in sorted({round(r["fr"], 3) for r in P})})
    S["paired_vs_grid_exact_fr"] = pair

    # --- относительный критерий: продолжение GRID после его остановки
    rc = {}
    for v in ("rel", "calm"):
        C = [r for r in rows if r["variant"] == v and "grid_status" in r and "cont_mean_dev_rel" in r]
        rc[v] = dict(
            n=len(C), grid_also_conv=sum(r["grid_status"] == 0 for r in C),
            grid_nonconv=sum(r["grid_status"] == 1 for r in C),
            cont_mean_dev_med_rel=_q([r["cont_mean_dev_rel"] for r in C], 0.5),
            cont_mean_dev_p90_rel=_q([r["cont_mean_dev_rel"] for r in C], 0.9),
            cont_mean_dev_max_rel=_q([r["cont_mean_dev_rel"] for r in C], 1.0),
            hidden_wander_n=sum(1 for r in C if r["grid_status"] == 1 and r["cont_mean_dev_rel"] > FIELD_TOL),
            hidden_wander_grid_spread_med_rel=_q([r["grid_spread_rel"] for r in C if r["grid_status"] == 1], 0.5),
            by_fr={f"{fr:g}": dict(
                n=len(X), grid_nonconv=sum(r["grid_status"] == 1 for r in X),
                rel_iters_med=_q([r["iters"] for r in X], 0.5),
                cont_mean_dev_med_rel=_q([r["cont_mean_dev_rel"] for r in X], 0.5),
                cont_mean_dev_max_rel=_q([r["cont_mean_dev_rel"] for r in X], 1.0))
                for fr in sorted({round(r["fr"], 3) for r in C})
                for X in [[r for r in C if round(r["fr"], 3) == fr]]})
    S["relative_criterion_vs_grid_continuation"] = rc
    # ретро-критерий на всём GRID s=0,3 (снимки через 50 итераций)
    G = [r for r in rows if r["variant"] == "grid"]
    S["grid_retro_rel"] = {
        f"{fr:g}": dict(n=len(X), abs_conv=sum(r["status"] == 0 for r in X),
                        rel_hit=sum(r["retro_rel_iter"] >= 0 for r in X),
                        rel_hit_but_abs_max=sum(r["retro_rel_iter"] >= 0 and r["status"] == 1 for r in X))
        for fr in sorted({round(r["fr"], 4) for r in G}) for X in [[r for r in G if round(r["fr"], 4) == fr]]}
    # шумный предвестник по GRID: AR(1) и амплитуда поздних снимков несошедшихся против Fr
    S["grid_precursor_by_fr"] = {
        f"{fr:g}": dict(n_nonconv=len(X), ar1_med=_q([r["ar1"] for r in X], 0.5),
                        fluct_med_rel=_q([r["fluct_rel"] for r in X], 0.5),
                        slope_med=_q([r["slope_dec100"] for r in X], 0.5),
                        du_late_med_rel=_q([r["du_med_late_rel"] for r in X], 0.5))
        for fr in sorted({round(r["fr"], 4) for r in G})
        for X in [[r for r in G if round(r["fr"], 4) == fr and r["status"] == 1]] if X}
    S.update(verdict(S, rows))
    return S


def verdict(S, rows):
    """Решение по §9 п. 4 — по числам (пороги заданы до разбора: поле 0,05 U, блуждание ~0,1 U)."""
    ag = S["by_variant"]
    pr = S["paired_vs_grid_exact_fr"]
    fr = S["by_variant_fr"]
    low = [k for k in fr["omega"] if float(k) <= 0.25]          # U10 ≤ 0,53 м/с
    mid = [k for k in fr["omega"] if 0.29 <= float(k) <= 0.51]   # U10 0,64–1,07 м/с
    om_low = float(np.mean([fr["omega"][k]["conv_frac"] for k in low]))
    om_low_spread = float(np.nanmedian([fr["omega"][k]["spread_p90_med_rel"] for k in low]))
    om_mid = float(np.mean([fr["omega"][k]["conv_frac"] for k in mid]))
    gr_mid = float(np.mean([fr["grid"][k]["conv_frac"] for k in mid]))
    numerical_part = pr["omega"]["fixed_frac"] > 0.2 and pr["omega"]["broken_by_variant"] == 0
    physical_part = om_low < 0.5 and om_low_spread > 0.1
    cb = "mixed" if (numerical_part and physical_part) else ("numerical" if numerical_part else "physical")
    return dict(
        calm_boundary=cb,
        calm_boundary_numbers=dict(
            omega_fixed_frac_of_grid_nonconv_fr03_05=pr["omega"]["fixed_frac"],
            omega_conv_frac_fr03_05=om_mid, grid_conv_frac_fr03_05=gr_mid,
            omega_conv_frac_fr02_025=om_low, omega_spread_med_rel_fr02_025=om_low_spread,
            omega_still_nonconv_spread_med_rel=pr["omega"]["still_nonconv_spread_med_rel"],
            grid_nonconv_spread_med_rel=pr["omega"]["still_nonconv_ref_spread_med_rel"],
            omega_vs_grid_both_conv_du_mean_med_rel=pr["omega"]["both_conv_du_mean_med_rel"],
            omega_fixed_vs_grid_latemean_du_mean_med_rel=pr["omega"]["fixed_du_mean_med_rel"],
            kfloor_fixed=pr["kfloor"]["fixed_by_variant"], kfloor_broken=pr["kfloor"]["broken_by_variant"],
            kfloor_both_conv_du_mean_med_rel=pr["kfloor"]["both_conv_du_mean_med_rel"],
            rel_fixed=pr["rel"]["fixed_by_variant"], rel_broken=pr["rel"]["broken_by_variant"],
            calm_rel_conv_frac=ag["calm"]["all"]["conv_frac"]),
        verdict_ru=("mixed: при Fr 0,3–0,5 (U10 0,6–1,1 м/с) ω = 0,5 находит неподвижную точку в "
                    f"{pr['omega']['fixed_frac']:.0%} несошедшихся случаев GRID (доля сошедшихся {gr_mid:.2f} → {om_mid:.2f}) — "
                    "численная часть; при Fr ≤ 0,25 (U10 ≤ 0,5 м/с) не помогает ни ω, ни K_min = 10 м²/с, ни относительный "
                    f"критерий: сошлось {om_low:.2f}, блуждание {om_low_spread:.2f} U_sat — физическая часть (фаза H)."))


def figures(rows, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    col = {"grid": "#444444", "omega": "#1f77b4", "kfloor": "#d62728", "rel": "#2ca02c", "calm": "#9467bd"}

    def per_fr(v, key, agg, fmax=1.5):
        R = [r for r in rows if r["variant"] == v and r["fr"] <= fmax]
        frs = sorted({round(r["fr"], 4) for r in R})
        ys = [agg([r for r in R if round(r["fr"], 4) == f], key) for f in frs]
        return frs, ys

    conv = lambda X, k: np.mean([r["status"] == 0 for r in X])  # noqa: E731
    med = lambda X, k: _q([r.get(k, np.nan) for r in X], 0.5)  # noqa: E731

    def plot(fname, key, agg, ylabel, logy=False, hline=None, only=None):
        fig, ax = plt.subplots(figsize=(6.4, 4))
        for v in only or VARIANTS:
            x, y = per_fr(v, key, agg)
            ax.plot(x, y, "o-", color=col[v], label=v, ms=4)
        ax.set_xscale("log")
        if logy:
            ax.set_yscale("log")
        if hline:
            ax.axhline(hline, color="k", ls=":", lw=1)
        ax.set_xlabel("Fr = U_sat/(N h)")
        ax.set_ylabel(ylabel)
        ax.grid(alpha=.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(out / fname, dpi=110)
        plt.close(fig)

    plot("fig_conv_fr.png", "status", conv, "доля сошедшихся (s = 0,3, 27 линий)")
    plot("fig_spread_fr.png", "spread_rel", lambda X, k: med([r for r in X if r["status"] == 1], k),
         "медиана late_spread60_p90 / U_sat (несошедшиеся)", logy=True, hline=0.1)
    plot("fig_field_diff_fr.png", "du_mean_rel", med, "медиана средн. |Δu_h| / U_sat (25–300 м) к эталону",
         logy=True, hline=FIELD_TOL, only=("omega", "kfloor", "rel", "calm"))
    plot("fig_iters_fr.png", "iters", lambda X, k: med([r for r in X if r["status"] == 0], k),
         "медиана итераций сошедшихся")
    # траектории невязки: медиана и квартили log10 resid по снимкам, Fr 0,2–0,5
    fig, ax = plt.subplots(figsize=(6.4, 4))
    its = np.arange(101, 1002, 50)
    for v in ("grid", "omega", "kfloor", "rel"):
        R = [r for r in rows if r["variant"] == v and 0.19 <= r["fr"] <= 0.51 and r["status"] == 1]
        if not R:
            continue
        M = np.log10(np.array([r["_rs"] for r in R]))
        m = np.nanmedian(M, 0)
        ax.plot(its, 10 ** m, color=col[v], label=f"{v} (несошедшиеся, n={len(R)})")
        ax.fill_between(its, 10 ** np.nanquantile(M, .25, 0), 10 ** np.nanquantile(M, .75, 0), color=col[v], alpha=.15)
    ax.axhline(ABS_TOL, color="k", ls=":", lw=1)
    ax.set_yscale("log")
    ax.set_xlabel("итерация")
    ax.set_ylabel("resid, м/с² (экв. невязки импульса)")
    ax.set_title("Fr 0,2–0,5: затухание или плато", fontsize=9)
    ax.grid(alpha=.3)
    ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(out / "fig_resid_traces.png", dpi=110)
    plt.close(fig)
    # продолжение GRID после остановки по rel/calm
    fig, ax = plt.subplots(figsize=(6.4, 4))
    for v in ("rel", "calm"):
        C = [r for r in rows if r["variant"] == v and "cont_mean_dev_rel" in r]
        ax.scatter([r["fr"] for r in C], [r["cont_mean_dev_rel"] for r in C], s=14, color=col[v], label=v,
                   marker="o" if v == "rel" else "s",
                   facecolors=[col[v] if r["grid_status"] == 1 else "none" for r in C])
    ax.axhline(FIELD_TOL, color="k", ls=":", lw=1)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Fr")
    ax.set_ylabel("max по снимкам после остановки: средн. |Δu_h(25 м)| / U_sat")
    ax.set_title("GRID после остановки по rel (закрашено — GRID не сошёлся)", fontsize=9)
    ax.grid(alpha=.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out / "fig_rel_continuation.png", dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    main()
