"""Сборка out/swg-1/ground.json (SWG2 v1) и tables.md из кешей out/swg-1/raw/."""
from __future__ import annotations

import json
import math
from collections import defaultdict
from pathlib import Path

import h5py
import numpy as np

from . import common as K
from . import evaluate as E
from . import tables as T

RAW = K.OUT_TASK / "raw"
Z_DEC = (10.0, 50.0)
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра (Askervein 0,03 м; Perdigão 1,80 м), "
                 "σ земли для z_agl фона 250 м; без JH и отрыва; сетка панелей — группы по ≤ 40 различных (x, y) с фокусом ds_min 25 м",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (velocity_jh, копия jh_parts), остальное как potential; без отрыва Хеда и нитей",
    "bg_only": "только лог-фон U10·ln(z_agl/z0)/ln(10/z0), z_agl над землёй, сглаженной σ 250 м (панелей нет); контроль для разложения",
}
SCAN_CODE = {"z0_rule": {0: "median", 1: "lnmean", 2: "local_jh"}, "bg_kind": {0: "log", 1: "power"}}


def load(path):
    return json.load(open(path))


def picard_ratio(case, x, y, z, z0):
    """Профиль Пикара в колонне клетки (x, y) против лог-фона: r = [ln(z/z0)/ln(300/z0)] / [u_P(z)/u_P(300)] − 1."""
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        g = h["picard_nom"]
        xs, ys = g["x"][:], g["y"][:]
        zl = g["z_agl"][:].astype(float)
        sc = float(g["u"].attrs["scale"])
        U, V = g["u"][:], g["v"][:]
        out = np.full(len(x), np.nan)
        i300 = int(np.argmin(np.abs(zl - 300.0)))
        for k, (xx, yy, zz) in enumerate(zip(x, y, z)):
            i = int(np.argmin(np.abs(xs - xx)))
            j = int(np.argmin(np.abs(ys - yy)))
            lev = int(np.argmin(np.abs(zl - zz)))
            sp = np.hypot(U[:, j, i], V[:, j, i]).astype(float)
            shape_p = sp[lev] / sp[i300]
            shape_log = math.log(zz / z0) / math.log(300.0 / z0)
            out[k] = shape_log / shape_p - 1.0 if shape_p > 0 else np.nan
    return out


def old_head_effect():
    """Вклад отрыва Хеда + нити (SWD5b): (s_vortex_jh − s_potential_jh)/s_ref по старым точкам Пикара nom (out/compare/points.json)."""
    import core as C
    old = json.load(open(C.OUT / "points.json"))
    v = defaultdict(dict)
    for r in old["rows"]:
        if r["ref_kind"] == "picard_nom" and r["variant"] in ("potential_jh", "vortex_jh"):
            v[(r["case"], r["point"], r["z_agl"], r["name"])][r["variant"]] = (r["s_pan"], r["s_ref"])
    g = defaultdict(list)
    for (c, t, z, _), d in v.items():
        if "potential_jh" in d and "vortex_jh" in d:
            g[(c, t, z)].append((d["vortex_jh"][0] - d["potential_jh"][0]) / d["potential_jh"][1])
    return {k: (float(np.mean(a)), len(a)) for k, a in g.items()}


def main():
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    rows, extra = [], {}
    base = {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        b = load(RAW / f"base_{case}.json")
        assert b["ids"] == [p["id"] for p in pl]
        base[case] = (pl, b)
        for var, key in (("potential", "s_pot"), ("potential_jh", "s_jh"), ("bg_only", "s_bg")):
            for p, s in zip(pl, b[key]):
                if s is None or not math.isfinite(s) or p["s_ref"] <= 0:
                    continue
                rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
    summary = T.summarize(rows)
    masts = T.mast_stats(rows)

    # ---- разложение
    decomp = []

    def add(case, typ, z, term, val, unit, note):
        if val is not None and math.isfinite(val):
            decomp.append(dict(case=case, type=typ, z_agl=float(z), term=term, value=float(val), unit=unit, note=note))
    head_old = old_head_effect()
    for case in K.CASES:
        pl, b = base[case]
        h = load(RAW / f"head_{case}.json") if (RAW / f"head_{case}.json").exists() else None
        cov = dict(zip(h["ids"], h["covered"])) if h else {}
        z0m = None
        for typ in K.TYPES:
            for z in Z_DEC:
                idx = [i for i, p in enumerate(pl) if p["kind"] == "picard_nom" and p["type"] == typ and p["z_agl"] == z
                       and all(b[k][i] is not None for k in ("s_bg", "s_pot", "s_jh"))]
                if not idx:
                    continue
                sref = np.array([pl[i]["s_ref"] for i in idx])
                sbg, spot, sjh = (np.array([b[k][i] for i in idx]) for k in ("s_bg", "s_pot", "s_jh"))
                n = len(idx)
                nn = f"n={n}; Пикар nom, ref_use {'справочно' if z < 50 else 'эталон'}"
                add(case, typ, z, "total", np.mean((sjh - sref) / sref), "rel", f"среднее rel_err potential_jh = bg + panels + jh; {nn}")
                add(case, typ, z, "bg", np.mean(sbg / sref - 1), "rel", f"лог-фон без панелей против Пикара: mean(s_bg/s_ref − 1), s_bg нормирован на фон в опорной точке; {nn}")
                add(case, typ, z, "panels", np.mean((spot - sbg) / sref), "rel", f"возмущение панелей: mean((s_pot − s_bg)/s_ref); {nn}")
                add(case, typ, z, "jh", np.mean((sjh - spot) / sref), "rel", f"добавка внутреннего слоя JH: mean((s_jh − s_pot)/s_ref); {nn}")
                up = [i for i, p in enumerate(pl) if p["kind"] == "picard_nom" and p["type"] == "upstream" and p["z_agl"] == z
                      and all(b[k][i] is not None for k in ("s_jh",))]
                if up and typ != "upstream":
                    add(case, typ, z, "wake_ref", np.mean(sref) / np.mean([pl[i]["s_ref"] for i in up]), "rel",
                        f"отношение среднего s Пикара типа к среднему s Пикара upstream на той же высоте (безразмерное, не rel; <1 — торможение относительно набегающего); {nn}")
                    add(case, typ, z, "wake_pan", np.mean(sjh) / np.mean([b["s_jh"][i] for i in up]), "rel",
                        f"то же для potential_jh (безразмерное); {nn}")
                need = np.mean(sref) - np.mean(sbg)
                if abs(need) > 0.02:
                    add(case, typ, z, "capture_jh", (np.mean(sjh) - np.mean(sbg)) / need, "rel",
                        f"доля нужного отклонения от фона, воспроизведённая potential_jh: (mean s_jh − mean s_bg)/(mean s_ref − mean s_bg) (безразмерная, 1 — идеально, <0 — не в ту сторону); {nn}")
                    add(case, typ, z, "capture_pot", (np.mean(spot) - np.mean(sbg)) / need, "rel",
                        f"то же для potential (безразмерная); {nn}")
                add(case, typ, z, "s_ref", np.mean(sref), "s", f"средний s Пикара nom; {nn}")
                add(case, typ, z, "s_bg", np.mean(sbg), "s", f"средний s фона; {nn}")
                add(case, typ, z, "s_pot", np.mean(spot), "s", f"средний s потенциала; {nn}")
                add(case, typ, z, "s_jh", np.mean(sjh), "s", f"средний s потенциала + JH; {nn}")
                nrm = b["meta"].get("norm")
                if nrm and all(b.get(k) for k in ("u0_over_Uref", "A", "dS")):
                    lf = np.array([b["u0_over_Uref"][i] for i in idx], float)
                    su = np.array([1.0 + b["A"][i] * b["dS"][i] for i in idx], float)
                    nlf = float(np.mean([q["u0_over_Uref"] for q in nrm]))
                    nsu = float(np.mean([1.0 + q["A"] * q["dS"] for q in nrm]))
                    inner = float(np.mean([b["t"][i] < 0.05 for i in idx]))
                    add(case, typ, z, "jh_logfac", np.nanmean(lf), "s", f"внутренний слой JH: лог-множитель u0/U_ref = ln(z/z0)/ln(100/z0), среднее; {nn}")
                    add(case, typ, z, "jh_speedup", np.nanmean(su), "s", f"внутренний слой JH: множитель (1 + A·dS), среднее (безразмерное); {nn}")
                    add(case, typ, z, "norm_logfac", nlf, "s", f"то же в опорной точке: u0/U_ref (среднее по группам сетки); {nn}")
                    add(case, typ, z, "norm_speedup", nsu, "s", f"то же в опорной точке: 1 + A·dS; s_jh в слое ≈ jh_logfac·jh_speedup/(norm_logfac·norm_speedup); {nn}")
                    sref_i = np.array([pl[i]["s_ref"] for i in idx], float)
                    add(case, typ, z, "su_required", np.nanmean(sref_i * nlf * nsu / lf), "s",
                        f"множитель (1 + A·dS), который при логе внутреннего слоя дал бы Пикар: mean(s_ref·norm_logfac·norm_speedup/jh_logfac); сравнить с jh_speedup (безразмерное); {nn}")
                    add(case, typ, z, "jh_inner_frac", inner, "rel", f"доля точек полностью во внутреннем слое JH (t < 0,05; безразмерная, не rel); {nn}")
                for k, unit, nm in (("dS", "rel", "относительное ускорение однородного потенциального потока на высоте max(z, l) — вход JH (dS)"),
                                    ("t", "rel", "вес внешнего решения в смеси JH (0 — полностью внутренний слой, 1 — потенциал)")):
                    v = np.array([b[k][i] for i in idx], float)
                    add(case, typ, z, f"jh_{k}", np.nanmean(v), unit, f"{nm}; среднее; {nn}")
                # профиль Пикара против лога в той же колонне
                z0r = {"median": M_z0(case, "median"), "lnmean": M_z0(case, "lnmean")}
                xs = [pl[i]["x"] for i in idx]
                ys = [pl[i]["y"] for i in idx]
                for rule, z0 in z0r.items():
                    r = picard_ratio(case, xs, ys, [z] * n, z0)
                    add(case, typ, z, f"profile_log_vs_picard_{rule}", np.nanmean(r), "rel",
                        f"форма профиля в колонне: mean{{[ln(z/z0)/ln(300/z0)] / [u_P(z)/u_P(300)] − 1}}, z0 = {z0:.3f} м ({rule}); >0 — лог-профиль быстрее Пикара у земли; {nn}")
                # отрыв Хеда
                if h:
                    c = np.array([cov[pl[i]["id"]] for i in idx])
                    rel = (sjh - sref) / sref
                    add(case, typ, z, "head_cover", c.mean(), "rel", f"доля точек в зоне отрыва Хеда (≤100 м от отрезка отрыв–присоединение, ds_min 50 м; доля, не rel); {nn}")
                    if c.any():
                        add(case, typ, z, "rel_in_head_zone", rel[c].mean(), "rel", f"mean rel_err potential_jh в зоне отрыва Хеда; n={int(c.sum())}")
                    if (~c).any():
                        add(case, typ, z, "rel_outside_head_zone", rel[~c].mean(), "rel", f"mean rel_err potential_jh вне зоны отрыва Хеда; n={int((~c).sum())}")
                hv = head_old.get((case, typ, z))
                add(case, typ, z, "head", hv[0] if hv else None, "rel",
                    "вклад отрыва Хеда + замкнутых нитей (vortex_jh − potential_jh)/s_ref, SWD5b, старые точки (мачты, P_*_0)" + (f"; n={hv[1]}" if hv else "")
                    + "; в potential_jh отрыва нет, в плотных точках не считался")
    # ---- сканы
    scan = []
    from .run_before import SCANS

    def metrics(case, pl, arrs, tag_base=False):
        out = {}
        for var, key in (("potential_jh", "s_jh"), ("potential", "s_pot")):
            rr = []
            for p, s in zip(pl, arrs[key]):
                if s is None or not math.isfinite(s) or p["s_ref"] <= 0:
                    continue
                rr.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], s))
            for typ in ("lee", "valley"):
                for z in Z_DEC:
                    sel = [r for r in rr if r["ref_kind"] != "mast" and r["type"] == typ and r["z_agl"] == z]
                    if sel:
                        out[(var, f"frac_tol_{typ}_{z:g}")] = float(np.mean([r["within_tol"] for r in sel]))
                        out[(var, f"mean_rel_{typ}_{z:g}")] = float(np.mean([r["rel_err"] for r in sel]))
            ms = [r for r in rr if r["ref_kind"] == "mast"]
            if ms:
                out[(var, "rmse_s_mast")] = float(np.sqrt(np.mean([(r["s_pan"] - r["s_ref"]) ** 2 for r in ms])))
        return out
    scan_vals = {}
    for case in K.CASES:
        pl, b = base[case]
        from .run_before import scan_subset
        keep = {p["id"] for p in scan_subset(pl)}
        pos = [i for i, p in enumerate(pl) if p["id"] in keep]
        bm = metrics(case, [pl[i] for i in pos], {k: [b[k][i] for i in pos] for k in ("s_jh", "s_pot")})
        bparams = [("smooth_m", 40.0), ("z0_rule", 0.0), ("bg_kind", 0.0), ("bg_smooth_m", 250.0)]
        for prm, val in bparams:
            for (var, met), res in bm.items():
                scan.append(dict(case=case, variant=var, param=prm, value=val, metric=met, result=res))
        scan_vals[(case, "base")] = bm
        for name, (kw, prm, val) in SCANS.items():
            f = RAW / f"scan_{name}_{case}.json"
            if not f.exists():
                continue
            s = load(f)
            plS = [p for p in E.case_points(case, refs, pts) if p["id"] in set(s["ids"])]
            order = {i: k for k, i in enumerate(s["ids"])}
            plS = sorted(plS, key=lambda p: order[p["id"]])
            sm = metrics(case, plS, s)
            scan_vals[(case, name)] = sm
            pname, pval = {"z0_lnmean": ("z0_rule", 1.0), "z0_local_jh": ("z0_rule", 2.0), "bg_power": ("bg_kind", 1.0)}.get(name, (prm, val))
            for (var, met), res in sm.items():
                scan.append(dict(case=case, variant=var, param=pname, value=pval, metric=met, result=res))
    # z0 и σ как слагаемые разложения: изменение mean_rel_<type>_<z> (potential_jh) относительно основного набора
    for case in K.CASES:
        bm = scan_vals[(case, "base")]
        for name, term, note in (("z0_lnmean", "z0", "z0 = exp(mean ln z0) вместо медианы растра (скаляр прогона Пикара на Perdigão 0,645 м; Askervein совпадает)"),
                                 ("sigma160", "sigma", "σ земли 160 м вместо 40 м"),
                                 ("sigma0", "sigma0", "σ земли 0 вместо 40 м"),
                                 ("z0_local_jh", "z0_local_jh", "z0 клетки растра в точке для JH (фон — медиана)"),
                                 ("bg_power", "bg_power", "степенной фон α = 0,235 вместо логарифмического"),
                                 ("bgsm500", "bg_sigma", "σ земли для z_agl фона 500 м вместо 250 м")):
            sm = scan_vals.get((case, name))
            if not sm:
                continue
            for typ in ("lee", "valley"):
                for z in Z_DEC:
                    k = ("potential_jh", f"mean_rel_{typ}_{z:g}")
                    if k in sm and k in bm:
                        add(case, typ, z, term, sm[k] - bm[k], "rel", f"изменение mean_rel potential_jh: {note}")
    # ---- файл
    ids_pts = {r["id"] for r in pts["rows"]}
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-1", variants=VARIANTS,
               rows=rows, summary=summary, masts=masts, decomp=decomp, scan=scan,
               scan_codes={"z0_rule": "0 медиана растра, 1 exp(mean ln z0), 2 локальный z0 клетки (только JH)", "bg_kind": "0 лог, 1 степенной α 0,235",
                           "smooth_m": "σ поверхности панелей, м", "bg_smooth_m": "σ земли для z_agl лог-фона, м"})
    K.dump_json(K.OUT_TASK / "ground.json", doc)
    print(len(rows), "строк", len(summary), "summary", len(masts), "masts", len(decomp), "decomp", len(scan), "scan")


def M_z0(case, rule):
    from . import model as M
    return M.z0_rules(case)[rule]


if __name__ == "__main__":
    main()
