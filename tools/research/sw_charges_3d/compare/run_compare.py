"""SWD-5: сравнение panels3d (potential, potential_jh) с мачтами и Пикаром → out/compare/points.json (+csv), tables.md.

  ./py compare/run_compare.py all        # скан + основной набор + сборка (~10 мин на RTX 4070 SUPER)
Интерпретатор — tools/research/sw_charges_3d/py (без -I).
"""
from __future__ import annotations

import csv
import json
import math
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import core as C  # noqa: E402

VARIANTS = ("potential", "potential_jh")
SCAN_SIGMA = (0.0, 20.0, 25.0, 40.0, 50.0, 60.0, 80.0, 120.0, 160.0)
SCAN_DS = (25.0, 35.0, 50.0)
Z_LEVELS = (10.0, 20.0, 50.0, 100.0, 200.0, 300.0)


def git_rev():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=C.ROOT3D, text=True).strip()
    except Exception:
        return "unknown"


def fnum(v):
    return None if v is None or not np.isfinite(v) else float(v)


def norm_info(case, refs):
    nm = refs["norm"][case]
    ukey = C.pkey(nm["x"], nm["y"], nm["z_agl"])
    Ud = None
    for r in refs["rows"]:
        if r["case"] == case and r["ref_kind"] == "mast" and r["name"] == nm["name"] and abs(r["z_agl"] - nm["z_agl"]) < 1e-6:
            Ud = r["speed"]
            break
    return ukey, Ud


def make_rows(run, variant, f, refs):
    case = run.case
    ex, ey = run.wt
    nkey, Ud = norm_info(case, refs)
    sn = C.hspeed(f, nkey)
    rows = []
    for r in refs["rows"]:
        if r["case"] != case:
            continue
        k = C.pkey(r["x"], r["y"], r["z_agl"])
        sp = C.hspeed(f, k)
        u, v, _ = f[k]
        s_pan = sp / sn
        u_par_pan = (u * ex + v * ey) / sn * Ud
        dS_pan = None
        if case == "ASK_TU03B":
            dS_pan = sp / C.hspeed(f, C.pkey(*C.P.RS_ASK, r["z_agl"])) - 1.0
        s_ref = r["s_norm"]
        pic = r["ref_kind"].startswith("picard")
        if pic and r["u"] is not None and r["speed"]:
            u_par_ref = (r["u"] * ex + r["v"] * ey) / r["speed"] * s_ref * Ud
        elif (not pic) and r["u"] is not None:
            u_par_ref = r["u"] * ex + r["v"] * ey
        else:
            u_par_ref = None
        err = s_pan - s_ref
        ref_err = r["ref_err"]
        rows.append(dict(
            case=case, variant=variant, point=r["point"], name=r["name"], x=r["x"], y=r["y"], z_agl=r["z_agl"],
            ref_kind=r["ref_kind"], ref_source=r["ref_source"], ref_reliability=r["ref_reliability"], ref_err=ref_err,
            ref_use="справочно" if (pic and r["z_agl"] < 50.0) else "эталон",
            s_ref=s_ref, s_pan=fnum(s_pan), dS_ref=r["dS"], dS_pan=fnum(dS_pan),
            u_par_ref=fnum(u_par_ref), u_par_pan=fnum(u_par_pan), err=fnum(err),
            within_tol=(bool(abs(err) <= C.TOL * abs(s_ref) + 1e-12) if pic else None),
            within_tol_ref=bool(abs(err) <= max(C.TOL, ref_err or 0.0) * abs(s_ref) + 1e-12),
            ds_min=run.ds_min, N=run.N, smooth_m=run.smooth_m))
    return rows


def rmse(a):
    a = np.array([x for x in a if x is not None], float)
    return float(np.sqrt(np.mean(a * a))) if a.size else None


def metrics(rows):
    out = {}
    mast = [r for r in rows if r["ref_kind"] == "mast"]
    nom = [r for r in rows if r["ref_kind"] == "picard_nom" and r["z_agl"] >= 50]
    out["rmse_s_mast"] = rmse([r["err"] for r in mast])
    out["bias_s_mast"] = float(np.mean([r["err"] for r in mast]))
    out["frac_tol_ref_mast"] = float(np.mean([r["within_tol_ref"] for r in mast]))
    out["frac_tol_picard_ge50"] = float(np.mean([r["within_tol"] for r in nom]))
    out["rmse_s_picard_ge50"] = rmse([r["err"] for r in nom])
    cr = [r for r in rows if r["ref_kind"] == "picard_nom" and r["point"] == "crest" and r["name"] == "P_crest_0"
          and abs(r["z_agl"] - 50) < 1e-6]
    if cr:
        out["err_crest_50_vs_picard_nom"] = cr[0]["err"]
    ht = [r for r in mast if r["name"] == "HT" and abs(r["z_agl"] - 10) < 1e-6 and r["dS_pan"] is not None]
    if ht:
        out["dS_HT_10"] = ht[0]["dS_pan"]
        out["dS_HT_10_err"] = ht[0]["dS_pan"] - ht[0]["dS_ref"]
    return out


def zH_metrics(rows, case):
    """Метрики по высоте сравнения z_agl/H: Пикар nom (все точки на уровне) и профиль HT (Askervein, dS мачты)."""
    H = C.H_of(case)
    res = []
    for z in Z_LEVELS:
        pr = [r for r in rows if r["ref_kind"] == "picard_nom" and abs(r["z_agl"] - z) < 1e-6]
        if pr:
            res.append(("rmse_s_picard_nom", z / H, rmse([r["err"] for r in pr])))
            res.append(("frac_tol_picard_nom", z / H, float(np.mean([r["within_tol"] for r in pr]))))
    for r in rows:
        if r["ref_kind"] == "mast" and r["name"] == "HT" and r["dS_pan"] is not None and r["dS_ref"] is not None:
            res.append(("dS_HT_err", r["z_agl"] / H, r["dS_pan"] - r["dS_ref"]))
    mz = sorted({r["z_agl"] for r in rows if r["ref_kind"] == "mast"})
    for z in mz:
        mm = [r["err"] for r in rows if r["ref_kind"] == "mast" and abs(r["z_agl"] - z) < 1e-6]
        if len(mm) >= 4:
            res.append(("rmse_s_mast_z", z / H, rmse(mm)))
    return res


def gauss_diag():
    """Контроль 2D №1: осесимметричный гаусс H/L = 0,1 (H = 100 м, L = 1000 м) — отрыва быть не должно (прокси, не C4)."""
    x = np.arange(-6000, 6001, 100.0)
    X, Y = np.meshgrid(x, x)
    z = 100.0 * np.exp(-(X ** 2 + Y ** 2) / (2 * 1000.0 ** 2))
    T = C.Terrain3D(x, x, z, smooth_m=0.0, far_m=8000.0)
    pan = C.build_panels(T, focus=[(0.0, 0.0)], ds_min=50.0, focus_r=1500.0)
    bg = C.bg_profile(C.U10, C.ALPHA, C.Z_SAT, T, wind_to=(1, 0))
    infl = C.assemble(pan, "auto")
    sig, _ = C.solve(pan, bg, None, infl)

    from types import SimpleNamespace
    R = SimpleNamespace(panels=pan, sigma=sig, bg=bg, z0=0.03, terrain=T, wt=(1.0, 0.0))
    d = C.separation_diag(R)
    return pan.N, d


def run_main(case, refs):
    t_all = time.time()
    run = C.Run(case, refs=refs)
    res = dict(rows=[], timing=[], rotor=[], diag=[])
    nkey, Ud = norm_info(case, refs)
    fields = {}
    for var in VARIANTS:
        f, tq = run.field(var)
        fields[var] = f
        res["rows"] += make_rows(run, var, f, refs)
        res["timing"].append(dict(case=case, variant=var, N=run.N, t_assemble_s=run.info["t_assemble_s"],
                                  t_solve_s=run.info["t_solve_s"], t_query_us=tq, t_run_s=time.time() - t_all,
                                  backend=run.info["backend"]))
    # ротор
    trs = [t for t in refs["transects"] if t["case"] == case]
    rr = [r for r in refs["rotor"] if r["case"] == case]
    for var in VARIANTS:
        sn = C.hspeed(fields[var], nkey)
        for tr in trs:
            present, L, depth = C.rotor_scan(run, var, tr, Ud / sn)
            men = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "menke2019"]
            pic = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "picard_nom"]
            ref = (men or pic or [None])[0]
            res["rotor"].append(dict(case=case, transect=tr["name"], variant=var, present=present, L_m=L, depth_m=depth,
                                     L_ref=ref["L_m"] if ref else None,
                                     ref_source=(ref["source"] + ": " + (ref["ref_source"] or "")[:120]) if ref else "нет эталона"))
    # диагностика отрыва по линиям тока (потенциальное решение)
    sd = C.separation_diag(run)
    for item, val, note in (
            ("sep_n_lines", sd["n_lines"], "линий тока с расчётом слоя"),
            ("sep_n_points_lee_only", sd["n_sep"], "точек отрыва по Хеду, lee_only=True"),
            ("sep_n_rejected_by_lee_only", sd["n_rej"], "точек отрыва, которые Хед даёт вне подветренной зоны (отброшены lee_only; координаты — windward_sep_point)"),
            ("H_sep_median", float(np.median(sd["H_sep"])) if sd["H_sep"] else None, "медиана H в точках отрыва (интерполяция на пороге 2,4)"),
            ("H_max_along_lines", sd["H_max"], "max H по всем линиям (насыщение формулы H(H1) ~11,7 — не физическое значение)"),
            ("cf_min_along_lines", sd["cf_min"], "min cf по всем линиям")):
        res["diag"].append(dict(case=case, item=item, value=fnum(val), note=note))
    ce = sd["central"]
    if ce is not None:
        for j in range(len(ce["s"])):
            res["diag"].append(dict(case=case, item=f"central_line_H_s{ce['s'][j]:.0f}", value=fnum(ce["H"][j]),
                                    note=f"H вдоль средней линии тока (затравка q = {ce['q']:.0f} м), s = {ce['s'][j]:.0f} м из {ce['s_total']:.0f}; "
                                         f"x = {ce['x'][j]:.0f}, y = {ce['y'][j]:.0f}, z = {ce['z'][j]:.0f} м; cf = {ce['cf'][j]:.5f}; "
                                         f"отрыв на этой линии: {'да (i_sep = %d)' % ce['i_sep'] if ce['i_sep'] >= 0 else 'нет'}"))
    rj = sd["rej"]
    for j in range(len(rj["x"])):
        res["diag"].append(dict(case=case, item="windward_sep_point", value=fnum(rj["s_sep"][j]),
                                note=f"отброшенная lee_only точка отрыва: x = {rj['x'][j]:.0f}, y = {rj['y'][j]:.0f}, z = {rj['z'][j]:.0f} м, "
                                     f"линия тока {int(rj['streamline'][j])}, s по линии (value) = {rj['s_sep'][j]:.0f} м"))
    run.free()
    return res


def run_bglog(case, refs):
    """Контроль: фон степенной α = 0,235 (как в 2D) вместо логарифмического основного набора."""
    run = C.Run(case, refs=refs, bg_kind="power")
    out = []
    for var in VARIANTS:
        f, _ = run.field(var)
        for k, v in metrics(make_rows(run, var, f, refs)).items():
            if k in ("rmse_s_mast", "frac_tol_picard_ge50", "rmse_s_picard_ge50", "dS_HT_10", "dS_HT_10_err", "err_crest_50_vs_picard_nom"):
                out.append(dict(case=case, item=f"bgpower_{var}_{k}", value=fnum(v),
                                note="фон степенной α = 0,235 (как в 2D) вместо логарифмического основного набора; остальное как в основном наборе"))
    run.free()
    return out


def run_scan(case, refs, main_rows):
    out = []

    def add(var, param, val, name, result):
        if result is not None:
            out.append(dict(case=case, variant=var, param=param, value=float(val), metric=name, result=float(result)))
    for sg in SCAN_SIGMA:
        run = C.Run(case, smooth_m=sg, refs=refs)
        for var in VARIANTS:
            f, _ = run.field(var)
            m = metrics(make_rows(run, var, f, refs))
            for k, v in m.items():
                add(var, "smooth_m", sg, k, v)
        run.free()
    for ds in SCAN_DS:
        run = C.Run(case, ds_min=ds, refs=refs)
        for var in VARIANTS:
            f, _ = run.field(var)
            m = metrics(make_rows(run, var, f, refs))
            for k, v in m.items():
                add(var, "ds_min", ds, k, v)
            add(var, "ds_min", ds, "N", run.N)
        run.free()
    runp = C.Run(case, refs=refs, bg_kind="power")      # степенной фон (α = 0,235) при основных σ, ds_min — в scan (решение координатора)
    for var in VARIANTS:
        f, _ = runp.field(var)
        for k, v in metrics(make_rows(runp, var, f, refs)).items():
            add(var, "smooth_m", C.SMOOTH_MAIN, "bgpower_" + k, v)
    runp.free()
    for var in VARIANTS:
        rows = [r for r in main_rows if r["variant"] == var]
        for name, zh, val in zH_metrics(rows, case):
            add(var, "z_over_H", zh, name, val)
    return out


# ---------------------------------------------------------------- проблемы 2D
def problems(main, scan, gauss):
    R = main["rows"]

    def sel(case=None, var=None, kind=None, pred=None):
        return [r for r in R if (case is None or r["case"] == case) and (var is None or r["variant"] == var)
                and (kind is None or r["ref_kind"] == kind) and (pred is None or pred(r))]

    def dg(case, item):
        return next(d["value"] for d in main["diag"] if d["case"] == case and d["item"] == item)
    P = []
    # 1
    gN, gd = gauss
    n_sep = {c: dg(c, "sep_n_points_lee_only") for c in C.CASES}
    P.append(dict(problem="1. порог отрыва / ложный ротор (критерий Хеда на любом торможении)", kind="схема",
                  status="ушла" if gd["n_sep"] == 0 else "осталась",
                  evidence=f"контроль-прокси (не C4): осесимметричный гаусс H/L = 0,1, N = {gN}: точек отрыва {gd['n_sep']} (H_max {gd['H_max']:.2f}, порог 2,4); "
                           f"реальные рельефы, lee_only: Askervein {n_sep['ASK_TU03B']}, Perdigão NE {n_sep['PERD_NE']}, SW {n_sep['PERD_SW']}; "
                           f"в данных обратного течения на Askervein нет. C4 и роторы Пикара ложными/реальными не разделены (ротор — SWD-5b)"))
    # 2
    rej = {c: dg(c, "sep_n_rejected_by_lee_only") for c in C.CASES}
    P.append(dict(problem="2. отрыв на наветренном склоне (Хед без lee_only)", kind="схема",
                  status="осталась" if any(v > 0 for v in rej.values()) else "ушла",
                  evidence=f"Хед даёт отрыв вне подветренной зоны (отброшено lee_only): Askervein {rej['ASK_TU03B']}, Perdigão NE {rej['PERD_NE']}, "
                           f"SW {rej['PERD_SW']} точек (по линиям тока); координаты — diag `windward_sep_point`; без lee_only эти точки остались бы"))
    # 3
    ht = {v: next((r for r in R if r["case"] == "ASK_TU03B" and r["variant"] == v and r["ref_kind"] == "mast" and r["name"] == "HT"
                   and abs(r["z_agl"] - 10) < 1e-6), None) for v in VARIANTS}
    cr = {(c, v): next((r for r in R if r["case"] == c and r["variant"] == v and r["name"] == "P_crest_0" and r["ref_kind"] == "picard_nom"
                        and abs(r["z_agl"] - 50) < 1e-6), None) for c in C.CASES for v in VARIANTS}
    over = abs(ht["potential_jh"]["dS_pan"] - ht["potential_jh"]["dS_ref"]) > 0.15 * ht["potential_jh"]["dS_ref"]
    bl = {(d["case"], d["item"]): d["value"] for d in main["diag"] if d["item"].startswith("bgpower_")}
    P.append(dict(problem="3. внутренний слой у земли: недобор ΔS трубы, затем перелёт", kind="схема",
                  status="осталась" if over else "ушла",
                  evidence=f"Askervein HT 10 м: dS данных {ht['potential']['dS_ref']:.3f} (FSR опубл.), potential {ht['potential']['dS_pan']:.3f}, "
                           f"potential_jh {ht['potential_jh']['dS_pan']:.3f}; гребень P_crest_0, 50 м, s_pan − s_nom: " +
                           "; ".join(f"{c} {v}: {cr[(c, v)]['err']:+.2f}" for c in C.CASES for v in VARIANTS) +
                           f". Порог: |dS_pan − dS_ref| ≤ 0,15·dS_ref у potential_jh на HT 10 м. Со степенным фоном α = 0,235 (контроль, diag bgpower_*) HT 10 м dS потенциал {bl[('ASK_TU03B','bgpower_potential_dS_HT_10')]:.3f}, "
                           f"jh {bl[('ASK_TU03B','bgpower_potential_jh_dS_HT_10')]:.3f}. " + ("Перелёта нет, есть недобор (ΔS берётся на высоте l > 10 м по контракту SWD2)." if ht["potential_jh"]["dS_pan"] < ht["potential_jh"]["dS_ref"] else "Перелёт ΔS.") + f" Труб Lubitz–White в 3D не считали"))
    # 4
    sp = {}
    for s in scan:
        if s["param"] == "smooth_m" and s["metric"] in ("rmse_s_mast", "dS_HT_10"):
            sp.setdefault((s["case"], s["variant"], s["metric"]), []).append(s["result"])
    rng = {k: max(v) - min(v) for k, v in sp.items()}
    sens = any(v > 0.05 for v in rng.values())
    P.append(dict(problem="4. зависимость от сглаживания фона и высоты сравнения (σ, z/H)", kind="схема",
                  status="осталась" if sens else "ушла",
                  evidence="скан σ 0…160 м: размах rmse_s_mast/dS_HT_10 по (случай, вариант): " +
                           "; ".join(f"{k[0]}/{k[1]}/{k[2]} {v:.3f}" for k, v in rng.items()) + "; скан z/H и ds_min — таблицы scan; порог «чувствительна» — размах > 0,05"))
    # 5, 6, 9, 10, 11
    rot = [(r["case"], r["transect"], r["variant"], r["present"]) for r in main["rotor"]]
    npres = sum(1 for r in rot if r[3])
    P.append(dict(problem="5. реальные роторы не воспроизведены; сила и незатухание ротора", kind="2D-артефакт", status="не проверено",
                  evidence=f"вихревых нитей в SWD-5 нет (SWD-5b). Контроль без вихрей: ротор u∥ < −0,5 м/с на 15 м в potential/potential_jh — "
                           f"{npres} из {len(rot)} разрезов (потенциальное течение с фоном без обратного потока; ротор без нитей не ожидается)"))
    P.append(dict(problem="6. завышение σ_w", kind="2D-артефакт", status="не проверено",
                  evidence="конвективный слой/вихри в SWD-5 не считаются; σ_w в 3D — вне постановки (панели без нитей)"))
    # 7
    nlow = len(sel(var="potential", kind="picard_nom", pred=lambda r: r["z_agl"] < 50)) + len(sel(var="potential", kind="picard_adv1", pred=lambda r: r["z_agl"] < 50))
    P.append(dict(problem="7. погрешность эталона Пикара у земли", kind="эталон", status="осталась",
                  evidence=f"строки Пикара ниже 50 м помечены ref_use = «справочно» ({nlow} строк на вариант), в frac_tol_picard_ge50 не входят; "
                           "поправка ±15 % + 1,5·|P100r − P50| из 2D не вводилась (нет второго уровня Пикара того же положения в SWD1)"))
    # 8
    def u_rmse(case, var):
        m = sel(case, var, "mast", pred=lambda r: r["u_par_ref"] is not None and r["u_par_pan"] is not None)
        Ud = norm_info(case, load_refs_cached())[1]
        return rmse([(r["u_par_pan"] - r["u_par_ref"]) / Ud for r in m]), len(m)
    ev8 = []
    for c in ("PERD_NE", "PERD_SW"):
        for v in VARIANTS:
            rm, n = u_rmse(c, v)
            ev8.append(f"{c}/{v}: RMSE u∥/U {rm:.3f} (n {n}), RMSE s {rmse([r['err'] for r in sel(c, v, 'mast')]):.3f}")
    def central_sep(c):
        d = next((d for d in main["diag"] if d["case"] == c and d["item"].startswith("central_line_H_s") and "отрыв на этой линии: да" in d["note"]), None)
        return d is not None
    Hs = {c: dg(c, "H_sep_median") for c in ("PERD_NE", "PERD_SW")}
    nsep = {c: dg(c, "sep_n_points_lee_only") for c in ("PERD_NE", "PERD_SW")}
    csep = {c: central_sep(c) for c in ("PERD_NE", "PERD_SW")}
    P.append(dict(problem="8. мачты Perdigão и исчезнувший отрыв", kind="не выяснено",
                  status="ушла" if all(nsep[c] > 0 and csep[c] for c in nsep) else "осталась",
                  evidence="; ".join(ev8) + f". Отрыв в лее по Хеду (lee_only): точек NE {nsep['PERD_NE']:.0f}, SW {nsep['PERD_SW']:.0f}; "
                           f"на средней линии тока отрыв NE {'есть' if csep['PERD_NE'] else 'нет'}, SW {'есть' if csep['PERD_SW'] else 'нет'}; "
                           f"медиана H в точках отрыва NE {Hs['PERD_NE']}, SW {Hs['PERD_SW']} (порог 2,4); H(s), cf(s) средней линии — diag `central_line_H_s*`. "
                           "Ротор (обратный u∥ на 15 м) при этом не возникает ни в одном разрезе — слой Хеда не даёт обратной скорости; число H_max вдоль линий (~11,7) — насыщение формулы, в статус не входит. "
                           "2D: RMSE u∥/S 0,27 (NE), 0,21 (SW) у игры, 0,495 и 0,273 у SWC-19 — сравнение лишь по порядку (другая нормировка, набор мачт)"))
    P.append(dict(problem="9. вихри не влияют на velocity_jh (вклад аддитивный)", kind="схема", status="не проверено",
                  evidence="нужны нити (SWD-5b, velocity_jh(couple=True)); в SWD-5 вихрей нет"))
    P.append(dict(problem="10. отрыв термика от склона", kind="схема", status="не проверено",
                  evidence="термики/нагрев склона в SWD-5 не заложены (прототипы A/C 3D — отдельная задача)"))
    P.append(dict(problem="11. нет присоединения за отрывом и повторного старта слоя", kind="схема", status="не проверено",
                  evidence="отрыв Хеда в SWD-5 считается v2 (без restart); restart=True требует нитей/ротора — SWD-5b"))
    # 12
    ok = {}
    for v in VARIANTS:
        for t in ("crest", "lee"):
            m = sel("ASK_TU03B", v, "mast", pred=lambda r, t=t: r["point"] == t and r["z_agl"] < 30)
            ok[(v, t)] = (float(np.mean([r["within_tol_ref"] for r in m])) if m else None, len(m))
    good = all(a is not None and a >= 0.8 for (a, _) in ok.values())
    P.append(dict(problem="12. у земли на гребнях и в лее (< 30 м)", kind="схема", status="ушла" if good else "осталась",
                  evidence="Askervein, мачты z_agl < 30 м, доля в допуске max(0,15; ref_err): " +
                           "; ".join(f"{v} {t}: {a:.2f} (n {n})" if a is not None else f"{v} {t}: нет" for (v, t), (a, n) in ok.items()) +
                           "; порог «ушла» — не менее 0,8 по обеим зонам"))
    return P


_REFS = None


def load_refs_cached():
    global _REFS
    if _REFS is None:
        _REFS = C.load_refs()
    return _REFS


def tables_md(main, scan, probs):
    R = main["rows"]
    L = ["# SWD-5: сравнение panels3d (potential, potential_jh) с мачтами и Пикаром", "",
         f"Основной набор: σ = {C.SMOOTH_MAIN:g} м, ds_min = {C.DS_MAIN:g} м (выбор a priori, не по данным). Допуск Пикара ±{C.TOL:.0%}. "
         "Пикар ниже 50 м — «справочно» (в долях не учтён).", "", "## Основной набор: ошибка s_norm", "",
         "| случай | вариант | N | RMSE s мачты | сдвиг s мачты | доля мачт в допуске (max 0,15; ref_err) | RMSE s Пикар nom ≥50 м | доля nom ≥50 м в ±15 % |",
         "|---|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        for v in VARIANTS:
            rows = [r for r in R if r["case"] == c and r["variant"] == v]
            m = metrics(rows)
            L.append(f"| {c} | {v} | {rows[0]['N']} | {m['rmse_s_mast']:.3f} | {m['bias_s_mast']:+.3f} | {m['frac_tol_ref_mast']:.2f} | "
                     f"{m['rmse_s_picard_ge50']:.3f} | {m['frac_tol_picard_ge50']:.2f} |")
    L += ["", "## По типам точек (мачты, вариант potential_jh и potential): RMSE s", "",
          "| случай | вариант | upstream | windward | crest | lee | valley |", "|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        for v in VARIANTS:
            cells = []
            for t in ("upstream", "windward", "crest", "lee", "valley"):
                e = [r["err"] for r in R if r["case"] == c and r["variant"] == v and r["ref_kind"] == "mast" and r["point"] == t]
                cells.append(f"{rmse(e):.3f} (n {len(e)})" if e else "—")
            L.append(f"| {c} | {v} | " + " | ".join(cells) + " |")
    L += ["", "## Askervein: HT и dS", "", "| z_agl, м | dS данных (FSR) | potential | potential_jh |", "|---|---|---|---|"]
    for z in (3, 5, 8, 10, 15, 24, 34):
        d = {v: next((r for r in R if r["case"] == "ASK_TU03B" and r["variant"] == v and r["ref_kind"] == "mast" and r["name"] == "HT"
                      and abs(r["z_agl"] - z) < 1e-6), None) for v in VARIANTS}
        if d["potential"]:
            L.append(f"| {z} | {d['potential']['dS_ref']:.3f} | {d['potential']['dS_pan']:.3f} | {d['potential_jh']['dS_pan']:.3f} |")
    L += ["", "## Доля в ±15 % от Пикара: случай × тип точки × z_agl (nom / adv1)", "",
          "Ячейка: nom / adv1 (n); строки Пикара на 10 м — справочно (ниже 50 м). «—» — нет точек.", "",
          "| случай | вариант | тип | 10 м | 50 м | 300 м |", "|---|---|---|---|---|---|"]
    for c in C.CASES:
        for v in VARIANTS:
            for t in ("upstream", "windward", "crest", "lee", "valley"):
                cells = []
                for z in (10.0, 50.0, 300.0):
                    parts = []
                    for rk in ("picard_nom", "picard_adv1"):
                        m = [r for r in R if r["case"] == c and r["variant"] == v and r["ref_kind"] == rk and r["point"] == t
                             and abs(r["z_agl"] - z) < 1e-6]
                        parts.append((f"{np.mean([r['within_tol'] for r in m]):.2f}", len(m)) if m else ("—", 0))
                    cells.append(f"{parts[0][0]} / {parts[1][0]} (n {parts[0][1]})" if parts[0][1] else "—")
                if any(x != "—" for x in cells):
                    L.append(f"| {c} | {v} | {t} | " + " | ".join(cells) + " |")
    L += ["", "Все высоты (nom / adv1), доля в ±15 %, только z_agl ≥ 50 м:", "", "| случай | вариант | nom | adv1 |", "|---|---|---|---|"]
    for c in C.CASES:
        for v in VARIANTS:
            vals = []
            for rk in ("picard_nom", "picard_adv1"):
                m = [r for r in R if r["case"] == c and r["variant"] == v and r["ref_kind"] == rk and r["z_agl"] >= 50]
                vals.append(f"{np.mean([r['within_tol'] for r in m]):.2f} (n {len(m)})")
            L.append(f"| {c} | {v} | {vals[0]} | {vals[1]} |")
    L += ["", "## Askervein: линии A, AA, B (мачты на 10 м) — dS данных (FSR) и панелей", "",
          "| мачта | линия | dS данных | potential | potential_jh | ref_err |", "|---|---|---|---|---|---|"]
    for r in R:
        if r["case"] == "ASK_TU03B" and r["variant"] == "potential" and r["ref_kind"] == "mast" and abs(r["z_agl"] - 10) < 1e-6 \
                and r["name"][:2] in ("AA", "AN", "AS", "BN", "BS") and r["dS_ref"] is not None:
            j = next(q for q in R if q["variant"] == "potential_jh" and q["case"] == r["case"] and q["name"] == r["name"]
                     and q["ref_kind"] == "mast" and abs(q["z_agl"] - 10) < 1e-6)
            ln = "AA" if r["name"].startswith("AA") else ("A" if r["name"][0] == "A" else "B")
            L.append(f"| {r['name']} | {ln} | {r['dS_ref']:.3f} | {r['dS_pan']:.3f} | {j['dS_pan']:.3f} | "
                     f"{'' if r['ref_err'] is None else format(r['ref_err'], '.3f')} |")
    L += ["", "## Perdigão: H(s), cf(s) вдоль средней линии тока", "", "| случай | s, м | H | примечание |", "|---|---|---|---|"]
    for d in main["diag"]:
        if d["item"].startswith("central_line_H_s"):
            L.append(f"| {d['case']} | {d['item'][len('central_line_H_s'):]} | {d['value']} | {d['note']} |")
    L += ["", "## Время", "", "| случай | вариант | N | сборка, с | решение (LU), с | запрос, мкс/точку | backend |", "|---|---|---|---|---|---|---|"]
    for t in main["timing"]:
        L.append(f"| {t['case']} | {t['variant']} | {t['N']} | {t['t_assemble_s']:.1f} | {t['t_solve_s']:.1f} | {t['t_query_us']:.0f} | {t['backend']} |")
    L += ["", "## Скан (метрика по параметру)", ""]
    for param in ("smooth_m", "ds_min", "z_over_H"):
        sc = [s for s in scan if s["param"] == param]
        mets = sorted({s["metric"] for s in sc})
        L += [f"### {param}", ""]
        for met in mets:
            vals = sorted({s["value"] for s in sc if s["metric"] == met})
            L += [f"**{met}**", "", "| случай | вариант | " + " | ".join(f"{v:.3g}" for v in vals) + " |", "|---|---|" + "---|" * len(vals)]
            for c in C.CASES:
                for v in VARIANTS:
                    cells = []
                    for x in vals:
                        z = [s["result"] for s in sc if s["case"] == c and s["variant"] == v and s["metric"] == met and s["value"] == x]
                        cells.append(f"{z[0]:.3f}" if z else "—")
                    if any(cc != "—" for cc in cells):
                        L.append(f"| {c} | {v} | " + " | ".join(cells) + " |")
            L.append("")
    L += ["## Ротор (u∥ < −0,5 м/с, 15 м, > 50 м)", "", "| случай | разрез | вариант | есть | L, м | L эталона, м |", "|---|---|---|---|---|---|"]
    for r in main["rotor"]:
        L.append(f"| {r['case']} | {r['transect']} | {r['variant']} | {r['present']} | {r['L_m']:.0f} | {r['L_ref']} |")
    L += ["", "## Диагностика отрыва", "", "| случай | пункт | значение | примечание |", "|---|---|---|---|"]
    for d in main["diag"]:
        if d["item"] != "windward_sep_point" and not d["item"].startswith("central_line_H_s"):
            L.append(f"| {d['case']} | {d['item']} | {d['value']} | {d['note']} |")
    L += ["", "## 12 проблем 2D", "", "| проблема | вид | статус | основание |", "|---|---|---|---|"]
    for p in probs:
        L.append(f"| {p['problem']} | {p['kind']} | {p['status']} | {p['evidence']} |")
    return "\n".join(L) + "\n"


def main_all():
    refs = C.load_refs()
    C.OUT.mkdir(parents=True, exist_ok=True)
    main = dict(rows=[], timing=[], rotor=[], diag=[])
    scan = []
    for case in C.CASES:
        cf = C.CACHE / f"{case}.json"
        if cf.exists():
            m, sc = json.load(open(cf))
        else:
            print("main", case, flush=True)
            m = run_main(case, refs)
            print("scan", case, flush=True)
            sc = run_scan(case, refs, m["rows"])
            C.CACHE.mkdir(parents=True, exist_ok=True)
            json.dump([m, sc], open(cf, "w"), allow_nan=False)
        bf = C.CACHE / f"{case}_bglog.json"
        if bf.exists():
            bl = json.load(open(bf))
        else:
            bl = run_bglog(case, refs)
            json.dump(bl, open(bf, "w"), allow_nan=False)
        m["diag"] = m["diag"] + bl
        for k in main:
            main[k] += m[k]
        scan += sc
    print("gauss", flush=True)
    gN, gd = gauss_diag()
    main["diag"].append(dict(case="GAUSS_H0.1", item="sep_n_points_lee_only", value=float(gd["n_sep"]),
                             note=f"осесимметричный гаусс H/L = 0,1 (H 100 м, L 1000 м), N = {gN}: отрыва быть не должно"))
    main["diag"].append(dict(case="GAUSS_H0.1", item="H_max_along_lines", value=fnum(gd["H_max"]), note="порог 2,4"))
    probs = problems(main, scan, (gN, gd))
    doc = dict(format="sw3d-compare", version=2, git=git_rev(), created=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               tol_picard=C.TOL, rows=main["rows"], scan=scan, rotor=main["rotor"], timing=main["timing"],
               diag=main["diag"], problems2d=probs)
    json.dump(doc, open(C.OUT / "points.json", "w"), ensure_ascii=False, indent=1, allow_nan=False)
    keys = [k for k in main["rows"][0]]
    with open(C.OUT / "points.csv", "w", newline="") as f:
        w = csv.DictWriter(f, keys)
        w.writeheader()
        w.writerows(main["rows"])
    (C.OUT / "tables.md").write_text(tables_md(main, scan, probs))
    print("done rows", len(main["rows"]), "scan", len(scan))


# ---------------------------------------------------------------- SWD-5b: vortex_jh
def _vload(case, tau):
    import vortex as V
    f = V.cache_file(case, tau)
    return json.load(open(f)) if f.exists() else None


def _med(a):
    a = [x for x in a if x is not None]
    return float(np.median(a)) if a else None


def sep_stats(s):
    """Отрывы только на шагах схода (it % sep_every == 0): среднее число точек отрыва за шаг схода в начале (t ≤ 12 с) и в окне (t > t_end/2),
    доля шагов схода с отрывом в окне."""
    ns, se, dt = s["n_sep_by_step"], s["sep_every"], s["dt"]
    idx = [i for i in range(len(ns)) if i % se == 0]
    early = [ns[i] for i in idx if (i + 1) * dt <= 12.0 + 1e-9]
    win = [ns[i] for i in idx if (i + 1) * dt > 0.5 * s["t_end"] + 1e-9]
    return dict(early=float(np.mean(early)) if early else None, win=float(np.mean(win)) if win else None,
                frac_win=float(np.mean([v > 0 for v in win])) if win else None, n_win_steps=len(win))


def vortex_metrics(res):
    """Метрики одного расчёта (случай, tau_s) для скана tau_s и проблем 2D."""
    S, M = res["summary"], res["metrics"]
    rot = res["rotor"]
    men = [r for r in rot if r["transect"].startswith("menke_T")]
    pres = [r for r in men if r["present"]]
    lee = [abs(d["rel"]) for d in S["dv"] if d["point"] in ("lee", "valley") and d["z_agl"] < 30]
    low = [abs(d["rel"]) for d in S["dv"] if d["z_agl"] < 30]
    out = dict(rmse_s_mast=M.get("rmse_s_mast"), frac_tol_ref_mast=M.get("frac_tol_ref_mast"),
               frac_tol_picard_ge50=M.get("frac_tol_picard_ge50"), dS_HT_10=M.get("dS_HT_10"),
               rotor_present_all=float(sum(r["present"] for r in rot)), rotor_n_all=float(len(rot)),
               rotor_menke_present=float(len(pres)), rotor_menke_n=float(len(men)),
               rotor_L_mean_present=float(np.mean([r["L_m"] for r in pres])) if pres else 0.0,
               n_nodes_end=float(S["n_nodes_end"]), n_nodes_max=float(S["n_nodes_max"]), t_step_median=S["t_step_median"],
               dv_median_lee_valley_lt30=_med(lee), dv_median_lt30=_med(low), dv_max_lt30=max(low) if low else None)
    return out


def vortex_merge():
    import vortex as V
    refs = C.load_refs()
    doc = json.load(open(C.OUT / "points.json"))
    base = C.CACHE / "problems2d_swd5.json"      # статусы SWD-5 до vortex_jh (копия problems2d из points.json основного набора)
    if base.exists():
        doc["problems2d"] = json.load(open(base))
    else:
        json.dump(doc["problems2d"], open(base, "w"), ensure_ascii=False, indent=1)
    doc["rows"] = [r for r in doc["rows"] if r["variant"] != "vortex_jh"]
    doc["rotor"] = [r for r in doc["rotor"] if r["variant"] != "vortex_jh"]
    doc["timing"] = [r for r in doc["timing"] if r["variant"] != "vortex_jh"]
    doc["diag"] = [d for d in doc["diag"] if not d["item"].startswith("vortex_")]
    main_res, scan_res = {}, {}
    for c in C.CASES:
        main_res[c] = _vload(c, V.TAU_MAIN)
        if main_res[c] is None:
            raise SystemExit(f"нет кеша {V.cache_file(c, V.TAU_MAIN)}")
        for tau in V.TAU_SCAN:
            r = _vload(c, tau)
            if r is not None:
                scan_res[(c, tau)] = r
    for c in C.CASES:
        m = main_res[c]
        doc["rows"] += m["rows"]
        for r in m["rotor"]:
            rr = {k: v for k, v in r.items() if k not in ("u_par_min_15m", "u_par_min_over_U")}
            doc["rotor"].append(rr)
            doc["diag"].append(dict(case=c, item=f"vortex_rotor_upar_min_{r['transect']}", value=fnum(r["u_par_min_over_U"]),
                                    note=f"vortex_jh, tau_s {V.TAU_MAIN:g} с: min u∥ на 15 м вдоль разреза, доля U данных опорной точки ({r['u_par_min_15m']:.2f} м/с); "
                                         f"ротор {'есть' if r['present'] else 'нет'}, L = {r['L_m']:.0f} м, глубина {r['depth_m']:.0f} м"))
        doc["timing"].append(m["timing"])
        s = m["summary"]
        for k, note in (("tau_s", "затухание нитей Γ·exp(−t/tau_s), с (выбрано заранее)"), ("t_end", "длина счёта, с"), ("dt", "шаг связки, с"),
                        ("sep_every", "сход раз в столько шагов (правило sim3d)"), ("U_ref", "м/с, фон на 100 м у наветренного края"), ("core", "ядро новых нитей, м"),
                        ("n_nodes_end", "узлов нитей в конце"), ("n_seg_end", "отрезков в конце"), ("n_nodes_max", "узлов нитей, максимум"),
                        ("gamma_abs_end", "Σ|Γ| в конце, м²/с"), ("imbalance_max", "max дивергенции Γ в узлах (инвариант ∇·ω = 0)"),
                        ("t_step_median", "медиана времени шага связки, с"), ("t_step_last", "время последнего шага, с"), ("substeps_max", "подшагов нитей, максимум"),
                                                ("n_reattach_sum", "присоединений (точек) за всё время"), ("n_lines_sum", "линий отрыва, давших нити, за всё время"),
                        ("n_skipped_sum", "точек линии отрыва вне сетки панелей (отброшено)"),
                        ("f_reconnect", "перезамыканий (r_rec = 0 — выключено)"), ("f_split", "делений отрезков"), ("f_merge", "слияний отрезков"),
                        ("f_lifted", "узлов поднято с земли"), ("f_removed", "узлов удалено (gamma_min, границы)"), ("n_snapshots", "снимков нитей в окне для ротора")):
            doc["diag"].append(dict(case=c, item=f"vortex_{k}", value=fnum(s[k]), note=f"vortex_jh, tau_s {V.TAU_MAIN:g} с: {note}"))
        q = sep_stats(s)
        doc["diag"].append(dict(case=c, item="vortex_n_sep_early", value=fnum(q["early"]), note=f"vortex_jh, tau_s {V.TAU_MAIN:g} с: точек отрыва на шаге схода, среднее за t ≤ 12 с"))
        doc["diag"].append(dict(case=c, item="vortex_n_sep_win", value=fnum(q["win"]), note=f"vortex_jh, tau_s {V.TAU_MAIN:g} с: точек отрыва на шаге схода, среднее за окно t > t_end/2"))
        doc["diag"].append(dict(case=c, item="vortex_frac_sep_win", value=fnum(q["frac_win"]), note=f"vortex_jh, tau_s {V.TAU_MAIN:g} с: доля шагов схода в окне, где отрыв есть"))
        vm = vortex_metrics(m)
        for k in ("dv_median_lee_valley_lt30", "dv_median_lt30", "dv_max_lt30"):
            doc["diag"].append(dict(case=c, item=f"vortex_{k}", value=fnum(vm[k]),
                                    note="|s_vortex_jh − s_potential_jh|/s_potential_jh в точках rows (s — доля опорной точки), "
                                         + {"dv_median_lee_valley_lt30": "медиана, lee и valley, z_agl < 30 м", "dv_median_lt30": "медиана, все точки z_agl < 30 м",
                                            "dv_max_lt30": "максимум, все точки z_agl < 30 м"}[k]))
    # скан tau_s
    for (c, tau), res in sorted(scan_res.items()):
        for k, v in vortex_metrics(res).items():
            doc["diag"].append(dict(case=c, item=f"vortex_tau{V.tau_name(tau)}_{k}", value=fnum(v),
                                    note=f"скан tau_s = {tau:g} с ({'без затухания' if tau >= 1e8 else 'экспоненциальное'}); остальное как в основном наборе; "
                                         f"метрика {k}; N = {res['summary']['N']}, t_end {res['summary']['t_end']:g} с"))
    probs = {p["problem"].split(".")[0]: p for p in doc["problems2d"]}
    for p in vortex_problems(doc, main_res, scan_res):
        probs[p["problem"].split(".")[0]] = p
    doc["problems2d"] = [probs[k] for k in sorted(probs, key=int)]
    doc["git"], doc["created"] = git_rev(), time.strftime("%Y-%m-%dT%H:%M:%S%z")
    json.dump(doc, open(C.OUT / "points.json", "w"), ensure_ascii=False, indent=1, allow_nan=False)
    with open(C.OUT / "points.csv", "w", newline="") as f:
        w = csv.DictWriter(f, list(doc["rows"][0]))
        w.writeheader()
        w.writerows(doc["rows"])
    global VARIANTS
    VARIANTS = ("potential", "potential_jh", "vortex_jh")
    main = dict(rows=doc["rows"], timing=doc["timing"], rotor=doc["rotor"], diag=doc["diag"])
    md = tables_md(main, doc["scan"], doc["problems2d"]) + vortex_tables(doc, main_res, scan_res)
    (C.OUT / "tables.md").write_text(md)
    print("merged: rows", len(doc["rows"]), "rotor", len(doc["rotor"]), "diag", len(doc["diag"]))


def vortex_problems(doc, main_res, scan_res):
    import vortex as V
    R = doc["rows"]
    P_ = []
    men = {c: [r for r in main_res[c]["rotor"] if r["transect"].startswith("menke_T")] for c in ("PERD_NE", "PERD_SW")}
    ok5 = {}
    ev = []
    for c in ("PERD_NE", "PERD_SW"):
        n_ok = 0
        for r in men[c]:
            good = r["present"] and r["L_ref"] and 0.5 * r["L_ref"] <= r["L_m"] <= 2.0 * r["L_ref"]
            n_ok += bool(good)
            ev.append(f"{c} {r['transect']}: {'ротор' if r['present'] else 'нет'} L {r['L_m']:.0f} м (Menke {r['L_ref']}), глубина {r['depth_m']:.0f} м, min u∥/U {r['u_par_min_over_U']:+.2f}")
        ok5[c] = n_ok
    allp = [r for c in C.CASES for r in main_res[c]["rotor"]]
    ask = [r for r in main_res["ASK_TU03B"]["rotor"]]
    tau_ev = []
    for (c, tau), res in sorted(scan_res.items()):
        if c in ("PERD_NE", "PERD_SW"):
            m = [r for r in res["rotor"] if r["transect"].startswith("menke_T")]
            tau_ev.append(f"{c} tau {tau:g}: роторов {sum(r['present'] for r in m)}/3")
    st5 = "ушла" if all(v >= 2 for v in ok5.values()) else "осталась"
    P_.append(dict(problem="5. реальные роторы не воспроизведены; сила и незатухание ротора", kind="2D-артефакт", status=st5,
                   evidence="vortex_jh (sim3d: нити с гребня, couple, restart), tau_s " + f"{V.TAU_MAIN:g} с (заранее), t_end {V.T_END:g} с, окно t ≥ {V.T_END/2:g} с; разрезы Menke: " + "; ".join(ev) +
                            f". Правило статуса: «ушла» — ротор на ≥ 2 из 3 разрезов Menke в каждом случае и L в пределах ×2 от Menke ({ok5['PERD_NE']} / {ok5['PERD_SW']} из 3). "
                            f"Роторы по всем {len(allp)} разрезам: {sum(r['present'] for r in allp)} (Askervein: {sum(r['present'] for r in ask)} из {len(ask)}; данных об обратном течении нет). "
                            "Скан tau_s (разрезы Menke): " + "; ".join(tau_ev) + ". Число узлов, время шага — diag `vortex_*`. Сила: min u∥/U — diag `vortex_rotor_upar_min_*` (2D: |u| 0,89–0,96·U100 против 0,22 ± 0,08 Menke)"))
    # 8
    def u_rmse(c, v):
        m = [r for r in R if r["case"] == c and r["variant"] == v and r["ref_kind"] == "mast" and r["u_par_ref"] is not None and r["u_par_pan"] is not None]
        Ud = norm_info(c, load_refs_cached())[1]
        neg_ref = sum(r["u_par_ref"] < 0 for r in m)
        neg_pan = sum(r["u_par_pan"] < 0 for r in m)
        return rmse([(r["u_par_pan"] - r["u_par_ref"]) / Ud for r in m]), len(m), neg_ref, neg_pan
    ev8, worse, rev_ok = [], False, True
    for c in ("PERD_NE", "PERD_SW"):
        a = u_rmse(c, "potential_jh")
        b = u_rmse(c, "vortex_jh")
        worse |= b[0] > 1.1 * a[0]
        rev_ok &= (b[2] == 0) or (b[3] >= 0.5 * b[2])
        ev8.append(f"{c}: RMSE u∥/U potential_jh {a[0]:.3f} → vortex_jh {b[0]:.3f} (n {b[1]}); мачт с u∥ < 0: данные {b[2]}, potential_jh {a[3]}, vortex_jh {b[3]}")
    old8 = next(p for p in doc["problems2d"] if p["problem"].startswith("8."))
    P_.append(dict(problem="8. мачты Perdigão и исчезнувший отрыв", kind="не выяснено", status="осталась" if (old8["status"] != "ушла" or worse or not rev_ok) else "ушла",
                   evidence="Отрыв в лее по Хеду есть (SWD-5, до вихрей); с вихрями: " + "; ".join(ev8) +
                            ". Правило (по определению проблемы 8 в 2D: «обратный u∥ в данных у 8 точек NE, в модели ни у одной»): «ушла» — отрыв в лее есть, RMSE u∥/U vortex_jh не хуже potential_jh более чем на 10 % и модель даёт u∥ < 0 хотя бы на половине тех мачт, где он отрицателен в данных. Первое условие выполнено со SWD-5 (отрыв по Хеду есть), последнее — нет. Ранее: " + old8["evidence"]))
    # 9
    dv = {c: next(d["value"] for d in doc["diag"] if d["case"] == c and d["item"] == "vortex_dv_median_lee_valley_lt30") for c in C.CASES}
    dmx = {c: next(d["value"] for d in doc["diag"] if d["case"] == c and d["item"] == "vortex_dv_max_lt30") for c in C.CASES}
    st9 = "ушла" if max(v for v in dv.values() if v is not None) > 0.05 else "осталась"
    P_.append(dict(problem="9. вихри не влияют на velocity_jh (вклад аддитивный)", kind="схема", status=st9,
                   evidence="velocity_jh(couple=True) с нитями против couple=False без нитей, точки rows z_agl < 30 м: медиана |Δs|/s в лее и долине " +
                            "; ".join(f"{c} {v:.3f}" for c, v in dv.items()) + "; максимум по точкам < 30 м " + "; ".join(f"{c} {v:.3f}" for c, v in dmx.items()) +
                            ". Правило: «ушла» — медиана > 0,05 хотя бы в одном случае. SWD-4: ΔS у стены гасится изображением нити в панелях (на 10 м за гребнем ~4,5 %); "
                            "сравнение в SWD-5b — не только couple, но и вклад нитей в σ и extra"))
    # 11
    ev11 = []
    ok11 = True
    for c in C.CASES:
        s = main_res[c]["summary"]
        q = sep_stats(s)
        ev11.append(f"{c}: точек отрыва на шаге схода в начале {q['early']:.1f}, в окне {q['win']:.1f} (шагов схода с отрывом {q['frac_win']:.0%} из {q['n_win_steps']}), "
                    f"точек с присоединением (restart) за всё время {s['n_reattach_sum']}")
        ok11 &= bool(q["win"] and q["early"] and q["win"] >= 0.5 * q["early"] and s["n_reattach_sum"] > 0)
    P_.append(dict(problem="11. нет присоединения за отрывом и повторного старта слоя", kind="схема", status="ушла" if ok11 else "осталась",
                   evidence="sim3d (restart=True, separation3d streamlines_from=\"bg\"): " + "; ".join(ev11) +
                            ". Правило: «ушла» — в окне усреднения отрывов не меньше половины ранних, присоединения есть (в 2D число отрывов в окне вихрей падало до 0). "
                            "Правило присоединения в panels3d дополнено исполнителем SWD-2 (README sim3d)"))
    return P_


def vortex_tables(doc, main_res, scan_res):
    import vortex as V
    L = ["", "# SWD-5b: vortex_jh (sim3d: вихревые нити, couple, restart)", "",
         f"tau_s основной = {V.TAU_MAIN:g} с (выбор заранее), gamma_min = {V.GAMMA_MIN:g} м²/с, dt = {V.DT:g} с, t_end = {V.T_END:g} с, окно усреднения t ≥ {V.T_END/2:g} с, "
         f"r_rec = 0; те же σ = {C.SMOOTH_MAIN:g} м, ds_min = {C.DS_MAIN:g} м, лог. фон, z0 — медиана растра.", "",
         "## Скан tau_s (разрезы Menke — 3 на случай Perdigão)", "",
         "| случай | tau_s, с | RMSE s мачты | доля мачт в допуске | доля nom ≥50 м в ±15 % | dS HT 10 м | роторов Menke | L ротора (среднее), м | узлов в конце | шаг (медиана), с | мед. Δs/s лее+долина <30 м |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    def f(x, n=3):
        return "—" if x is None else f"{x:.{n}f}"
    for (c, tau), res in sorted(scan_res.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        m = vortex_metrics(res)
        L.append(f"| {c} | {'∞' if tau >= 1e8 else format(tau, 'g')} | {f(m['rmse_s_mast'])} | {f(m['frac_tol_ref_mast'], 2)} | {f(m['frac_tol_picard_ge50'], 2)} | {f(m['dS_HT_10'])} | "
                 f"{m['rotor_menke_present']:.0f}/{m['rotor_menke_n']:.0f} | {m['rotor_L_mean_present']:.0f} | {m['n_nodes_end']:.0f} | {m['t_step_median']:.1f} | {f(m['dv_median_lee_valley_lt30'])} |")
    L += ["", "## Ротор vortex_jh по разрезам (основной набор)", "", "| случай | разрез | есть | L, м | глубина, м | эталон L, м | min u∥/U |", "|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        for r in main_res[c]["rotor"]:
            L.append(f"| {c} | {r['transect']} | {r['present']} | {r['L_m']:.0f} | {r['depth_m']:.0f} | {r['L_ref']} | {r['u_par_min_over_U']:+.2f} |")
    L += ["", "## Нити и отрыв по времени (основной набор)", "", "| случай | t, с | узлов | отрывов | присоединений |", "|---|---|---|---|---|"]
    for c in C.CASES:
        s = main_res[c]["summary"]
        for i in range(0, len(s["n_nodes_by_step"]), max(1, len(s["n_nodes_by_step"]) // 10)):
            L.append(f"| {c} | {(i + 1) * s['dt']:g} | {s['n_nodes_by_step'][i]} | {s['n_sep_by_step'][i]} | {s['n_reattach_by_step'][i]} |")
    return "\n".join(L) + "\n"


def vortex_run(case, taus):
    import vortex as V
    refs = C.load_refs()
    ctx = None
    for tau in taus:
        t0 = time.time()
        if ctx is None and not V.cache_file(case, tau).exists():
            ctx = V.build(case, refs)
        V.simulate(case, refs, tau, make_rows=make_rows, norm_info=norm_info, fnum=fnum, metrics=metrics, ctx=ctx)
        print("vortex", case, "tau", tau, "%.0f c" % (time.time() - t0), flush=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["vortex-run"]:
        vortex_run(sys.argv[2], [float(a) for a in sys.argv[3:]])
    elif sys.argv[1:] == ["vortex-merge"]:
        vortex_merge()
    elif sys.argv[1:] == ["all"]:
        main_all()
    else:
        print(__doc__)
