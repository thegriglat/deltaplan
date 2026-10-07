"""AP-5: откуда несходимость в GRID ap_v1 — ошибка override стратификации или физика (только CPU, по записанным частям).

1. Постановка случая на CPU (batch_solver._Setup → real.grid_domain, case с override; Air/GPU не строится): θ̄′(z) = case.gam
   на центрах ячеек решателя, z_i, H, верх области и губка, толщина слоя h_bl (повтор Air._bl_depth на numpy) против
   заданных N, z_i, H и против записанных inputs/hbl, n_bv, z_i_agl_m, froude_table.
2. Записанные случаи: доля несходимости по Fr, U10, h/z_i, H; разброс поздних итераций, невязка против порога, ход
   trace/resid и trace/du_max на поздних снимках; сравнение с SY-12 (out/per_case.npz) в том же окне U10 и Fr;
   пробный прогон ap_v1_trial (тот же override, Fr до 5) — сходится ли override при умеренном ветре.
3. Параметры порядка (order) по Fr.
→ out/diag_override.json, out/diag_override.md.

Запуск: /home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python diag_override.py
"""
from __future__ import annotations

import glob
import json
import math
import sys
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
DATA = Path.home() / "air_synth_data"
RUN = DATA / "phase/ap_v1__s1-74644c4"
TRIAL = DATA / "phase/ap_v1_trial__s1-74644c4"
PLAN = DATA / "phase/ap_v1"
OUT = HERE / "out"
TOL_ABS = 2e-5


def load(rdir):
    C, O, TR, TD, TI, HB = [], [], [], [], [], []
    for p in sorted(glob.glob(str(rdir / "part-*.h5"))):
        with h5py.File(p, "r") as f:
            C.append(f["cases"][:]); O.append(f["order"][:])
            TR.append(f["trace/resid"][:]); TD.append(f["trace/du_max"][:]); TI.append(f["trace/iter"][:])
            hb = f["inputs/hbl"][:].astype(np.float32)
            HB.append(np.stack([hb.min((1, 2)), np.median(hb, (1, 2)), hb.max((1, 2))], 1))
    cat = lambda L: np.concatenate(L) if L else None
    return cat(C), cat(O), cat(TR), cat(TD), cat(TI), cat(HB)


def rate(mask, nonconv):
    n = int(mask.sum())
    return dict(n=n, nonconv=round(float(nonconv[mask].mean()), 3) if n else None)


# ------------------------------------------------------------------ 1. постановка на CPU
def setup_check(cases):
    import batch_solver as S
    import air as A
    import real as R
    import phase_io as IO
    plan, sha, lines, rel, pcases = IO.load_plan(PLAN)
    src = IO.Sources(plan, rel)
    by_line = {c.line_id: [] for c in pcases}
    for c in pcases:
        by_line[c.line_id].append(c)
    seen, rows = set(), []
    for rec in cases:
        key = (int(rec["relief_id"]), round(float(rec["z_i_agl_m"])), round(float(rec["heat_flux_wm2"])))
        if key in seen or int(rec["k"]) not in (0, 6):
            continue
        seen.add(key)
        ln = lines[int(rec["line_id"])]
        r = rel[ln.relief_id]
        ph = IO.case_physics(plan, ln, r, float(rec["fr"]), src)
        spec = S.CaseSpec(g100=src.g100(ln.relief_id), ctx=ph["ctx"], u10=ph["u10"], wdir_from_deg=ph["wdir"], alpha=ph["alpha"],
                          max_profile=ph["max_profile"], n_bv_s=ph["ov_n"], z_i_agl_m=ph["ov_zi"], heat_flux_wm2=ph["ov_heat"])
        st = S._Setup(0, spec, S.Numerics(**IO.numerics_kwargs(ln.numerics)))
        g, hc = R.grid_domain(st.loc, 400)
        st.hc = hc
        cs = st.case(g, hc)
        zc = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
        gam = np.asarray(cs.gam(zc), float)
        base = float(hc.min())
        above = zc >= cs.z_i
        N_above = math.sqrt(A.G / A.THETA0 * gam[above].mean()) if above.any() else float("nan")
        ztop = g.z_bot + g.nz * g.dz
        # повтор Air._bl_depth (numpy)
        prm = st.prm
        U10 = cs.U10
        ustar = A.KAPPA * U10 / math.log(10.0 / prm.z0) if U10 > 0 else 0.0
        Hk = np.asarray(cs.H, float) / A.RHO_CP if cs.H is not None else np.zeros_like(hc)
        Hs = A.gauss2d(Hk, prm.k_smooth_m / g.dx) if np.any(Hk != 0) else np.zeros_like(hc)
        hs = A.gauss2d(hc, prm.k_smooth_m / g.dx)
        h_mech = 0.3 * ustar / prm.f_cor
        h_c = np.maximum(cs.z_i - hs, prm.zi_min)
        h_u = np.maximum(h_c, h_mech)
        h_bl = np.where(Hs > 1e-6, h_u, h_mech)
        # производные, как записывает решатель
        raw = dict(hour=st.hour, U10=st.u10, t_max=st.t_max, sky=st.sky)
        ov = dict(st.ov, alpha=st.alpha, max_profile=st.max_profile)
        import conditions as CN
        d = CN.derive(raw, st.ctx, hc, st.relief_m, ov)
        sel = (cases["line_id"] == rec["line_id"]) & (cases["k"] == rec["k"])
        rows.append(dict(
            relief_id=key[0], relief=r.name, k=int(rec["k"]), fr=float(rec["fr"]), u10=round(U10, 4), u_sat=round(U10 * st.max_profile, 3),
            z_i_spec_agl=float(ph["ov_zi"]), z_i_case_agl=round(cs.z_i - base, 2), base_m=base, hc_max_m=float(hc.max()),
            z_i_msl=round(cs.z_i, 1), z_top_msl=ztop, sponge_from_msl=ztop - prm.sponge_top_m, dz=g.dz, nz=g.nz,
            levels_above_zi_below_sponge=int(((zc >= cs.z_i) & (zc < ztop - prm.sponge_top_m)).sum()),
            gam_below_zi_max=float(np.abs(gam[~above]).max()) if (~above).any() else 0.0,
            gam_above_zi_K_per_km=round(1e3 * gam[above].mean(), 4), gam_expected_K_per_km=round(1e3 * A.THETA0 * 0.01 ** 2 / A.G, 4),
            N_above=round(N_above, 5), N_spec=0.01,
            H_spec=float(ph["ov_heat"]), H_case_mean=float(np.mean(cs.H)) if cs.H is not None else None,
            H_case_std=float(np.std(cs.H)) if cs.H is not None else None,
            froude_derive=round(float(d["froude"]), 4), n_derive=round(float(d["n_bv_s"]), 5),
            ustar=round(ustar, 4), h_mech=round(h_mech, 1), hbl_calc_min_med_max=[round(float(x), 1) for x in (h_bl.min(), np.median(h_bl), h_bl.max())],
            hbl_rec_min_med_max=None, rec_n_bv=float(cases["n_bv"][sel][0]), rec_z_i_agl=float(cases["z_i_agl_m"][sel][0]),
            rec_froude_table=float(cases["froude_table"][sel][0])))
    return rows


def main():
    c, o, tr, td, ti, hb = load(RUN)
    nonc = c["status"] != 0
    res = dict(run=str(RUN), n_cases=int(len(c)), n_nonconv=int(nonc.sum()), frac_nonconv=round(float(nonc.mean()), 3))
    res["written_ranges"] = {k: [round(float(c[k].min()), 3), round(float(c[k].max()), 3)] for k in ("fr", "froude_table", "u10", "u_sat", "n_bv", "z_i_agl_m", "heat_flux_wm2")}
    res["written_k"] = sorted(set(int(x) for x in c["k"]))
    # override на входе против записи
    res["record_check"] = dict(
        froude_table_over_fr=[round(float(x), 4) for x in np.percentile(c["froude_table"] / c["fr"], [0, 50, 100])],
        n_bv_unique=sorted(set(round(float(x), 5) for x in c["n_bv"])),
        z_i_agl_unique=sorted(set(round(float(x), 2) for x in c["z_i_agl_m"])),
        h_over_zi_unique=sorted(set(round(500.0 / float(x), 3) for x in c["z_i_agl_m"])))
    # 1. постановка
    rows = setup_check(c)
    for r in rows:
        sel = (c["relief_id"] == r["relief_id"]) & (np.round(c["z_i_agl_m"]) == round(r["z_i_spec_agl"])) & (np.round(c["heat_flux_wm2"]) == round(r["H_spec"])) & (c["k"] == r["k"])
        r["hbl_rec_min_med_max"] = [round(float(x), 1) for x in hb[sel][0]]
    res["setup"] = dict(n=len(rows),
                        max_abs_zi_err_m=max(abs(r["z_i_case_agl"] - r["z_i_spec_agl"]) for r in rows),
                        max_gam_below_zi=max(r["gam_below_zi_max"] for r in rows),
                        N_above_range=[min(r["N_above"] for r in rows), max(r["N_above"] for r in rows)],
                        max_froude_err=max(abs(r["froude_derive"] / r["fr"] - 1) for r in rows),
                        max_rec_froude_err=max(abs(r["rec_froude_table"] / r["fr"] - 1) for r in rows),
                        H_mean_err=max(abs((r["H_case_mean"] or 0) - r["H_spec"]) for r in rows),
                        H_std_max=max(r["H_case_std"] or 0 for r in rows),
                        hbl_med_abs_err_m=max(abs(r["hbl_calc_min_med_max"][1] - r["hbl_rec_min_med_max"][1]) for r in rows),
                        min_levels_above_zi_below_sponge=min(r["levels_above_zi_below_sponge"] for r in rows),
                        rows=rows)
    # 2. несходимость по осям
    by = {}
    by["k_fr"] = {f"{float(f):.3f}": rate(np.isclose(c["fr"], f), nonc) for f in sorted(set(c["fr"]))}
    by["h_over_zi"] = {f"{500 / z:.1f}": rate(np.isclose(c["z_i_agl_m"], z), nonc) for z in sorted(set(c["z_i_agl_m"]))}
    by["heat"] = {f"{h:.0f}": rate(np.isclose(c["heat_flux_wm2"], h), nonc) for h in sorted(set(c["heat_flux_wm2"]))}
    import phase_io as IO
    plan, _, lines, rel, _ = IO.load_plan(PLAN)
    shape = np.array([rel[int(x)].name.split("_s")[0] for x in c["relief_id"]])
    by["shape"] = {s: rate(shape == s, nonc) for s in sorted(set(shape))}
    by["slope"] = {}
    sl = np.array([float(rel[int(x)].slope) for x in c["relief_id"]])
    for s in sorted(set(sl)):
        by["slope"][f"{s:.2f}"] = rate(sl == s, nonc)
    res["nonconv_by"] = by
    # невязка и разброс поздних итераций у несошедшихся
    sp = c["late_spread60_p90"][nonc]
    usat = c["u_sat"][nonc]
    rf = c["resid_final"][nonc]
    late = ti[nonc] >= 500
    tr_late = np.where(late, tr[nonc], np.nan)
    td_late = np.where(late, td[nonc], np.nan)
    # тренд невязки на поздних снимках: отношение среднего 800..1000 к 500..650
    it = ti[nonc]
    a = np.nanmean(np.where((it >= 500) & (it <= 650), tr[nonc], np.nan), 1)
    b = np.nanmean(np.where(it >= 800, tr[nonc], np.nan), 1)
    res["nonconv_numbers"] = dict(
        spread_p90_ms=dict(p10=round(float(np.percentile(sp, 10)), 3), median=round(float(np.median(sp)), 3), p90=round(float(np.percentile(sp, 90)), 3)),
        spread_over_usat=dict(median=round(float(np.median(sp / usat)), 3), p10=round(float(np.percentile(sp / usat, 10)), 3), p90=round(float(np.percentile(sp / usat, 90)), 3)),
        frac_spread_lt_0p05=round(float((sp < 0.05).mean()), 3),
        resid_final_over_tol=dict(p10=round(float(np.percentile(rf / TOL_ABS, 10)), 1), median=round(float(np.median(rf / TOL_ABS)), 1), p90=round(float(np.percentile(rf / TOL_ABS, 90)), 1)),
        frac_resid_lt_2tol=round(float((rf < 2 * TOL_ABS).mean()), 3), frac_resid_lt_10tol=round(float((rf < 10 * TOL_ABS).mean()), 3),
        late_resid_cv_median=round(float(np.nanmedian(np.nanstd(tr_late, 1) / np.nanmean(tr_late, 1))), 3),
        late_resid_trend_800_1000_over_500_650_median=round(float(np.nanmedian(b / a)), 3),
        late_du_max_median_ms=round(float(np.nanmedian(np.nanmean(td_late, 1))), 3),
        late_du_max_over_usat_median=round(float(np.nanmedian(np.nanmean(td_late, 1) / usat)), 3))
    conv = ~nonc
    res["conv_numbers"] = dict(n=int(conv.sum()), iters_median=float(np.median(c["iters"][conv])) if conv.any() else None,
                               iters_by_fr={f"{float(f):.3f}": float(np.median(c["iters"][conv & np.isclose(c["fr"], f)])) for f in sorted(set(c["fr"])) if (conv & np.isclose(c["fr"], f)).any()})
    # 3. параметры порядка по Fr (несошедшиеся — цель «среднее поздних»)
    ordr = {}
    for f in sorted(set(c["fr"])):
        m = np.isclose(c["fr"], f)
        us = c["u_sat"][m]
        ordr[f"{float(f):.3f}"] = dict(stag25=round(float(np.median(o["f_stag25"][m])), 3), rev25=round(float(np.median(o["f_rev25"][m])), 3),
                                       wstd600_over_usat=round(float(np.median(o["f_wstd600"][m] / us)), 3), wstd800_over_usat=round(float(np.median(o["f_wstd800"][m] / us)), 3),
                                       wstd600_ms=round(float(np.median(o["f_wstd600"][m])), 3), speedup25=round(float(np.median(o["f_speedup25"][m])), 3))
    res["order_by_fr"] = ordr
    # SY-12 в том же окне
    d = np.load(OUT / "per_case.npz")
    u10, fr = d["u10_m_s"], d["froude"]
    nm, nh = d["status_m"] != 0, d["status_h"] != 0
    sy = {}
    for lo, hi in ((0.0, 0.5), (0.0, 0.8), (0.5, 1.0), (1.0, 2.0), (2.0, 3.0), (3.0, 99)):
        m = (u10 >= lo) & (u10 < hi)
        sy[f"U10 {lo}-{hi}"] = dict(n=int(m.sum()), nonconv_m=round(float(nm[m].mean()), 3) if m.any() else None, nonconv_h=round(float(nh[m].mean()), 3) if m.any() else None)
    m = (u10 < 0.8) & (fr >= 0.08) & (fr <= 0.4)
    sy["U10<0.8 & Fr 0.08-0.4"] = dict(n=int(m.sum()), nonconv_m=round(float(nm[m].mean()), 3) if m.any() else None, nonconv_h=round(float(nh[m].mean()), 3) if m.any() else None,
                                      spread_m_median=round(float(np.median(d["spread_m"][m & nm])), 3) if (m & nm).any() else None)
    m = (u10 < 0.8)
    sy["U10<0.8 spread_m_over_u_sat_median"] = round(float(np.median(d["spread_m"][m & nm] / d["u_sat_m_s"][m & nm])), 3)
    res["sy12_same_window"] = sy
    # пробный прогон с тем же override на всём диапазоне Fr
    tc, to, *_ = load(TRIAL)
    g = tc["series"] == tc["series"][0]
    trial = []
    for r in tc:
        trial.append(dict(series=int(r["series"]), fr=round(float(r["fr"]), 3), u10=round(float(r["u10"]), 3), u_sat=round(float(r["u_sat"]), 3),
                          z_i_agl=round(float(r["z_i_agl_m"]), 1), heat=float(r["heat_flux_wm2"]), status=int(r["status"]), iters=int(r["iters"]),
                          spread=round(float(r["late_spread60_p90"]), 3), cond_id=int(r["cond_id"])))
    gr = [t for t in trial if t["cond_id"] == -1 and t["z_i_agl"] > 0]
    res["trial_override_cases"] = dict(n=len(gr), rows=sorted(gr, key=lambda t: t["fr"]),
                                       nonconv_u10_lt_1=rate(np.array([t["u10"] < 1 for t in gr]), np.array([t["status"] != 0 for t in gr])) if gr else None,
                                       nonconv_u10_ge_1=rate(np.array([t["u10"] >= 1 for t in gr]), np.array([t["status"] != 0 for t in gr])) if gr else None)
    # вердикт
    s = res["setup"]
    override_ok = (s["max_abs_zi_err_m"] < 1 and s["max_gam_below_zi"] == 0 and abs(s["N_above_range"][0] - 0.01) < 1e-4 and abs(s["N_above_range"][1] - 0.01) < 1e-4
                   and s["max_rec_froude_err"] < 0.01 and s["H_mean_err"] < 1e-6 and s["hbl_med_abs_err_m"] < 1.0)
    res["override_ok"] = bool(override_ok)
    res["verdict"] = "physics" if override_ok else "bug"
    OUT.mkdir(exist_ok=True)
    (OUT / "diag_override.json").write_text(json.dumps(res, ensure_ascii=False, indent=1, default=float) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in res.items() if k not in ("setup", "trial_override_cases")}, ensure_ascii=False, indent=1, default=float))
    print(json.dumps({k: v for k, v in s.items() if k != "rows"}, ensure_ascii=False, default=float))
    print(json.dumps(s["rows"][:3], ensure_ascii=False, default=float))
    print(json.dumps(res["trial_override_cases"], ensure_ascii=False, default=float))


if __name__ == "__main__":
    main()
