#!/usr/bin/env python3
"""LT-6: сверка модели слоя (proto.py / spec.json) с измерениями LTO (lee_obs.csv) без поля игры.

Вход: рельеф вдоль линии мачт (Perdigão: cases/perdigao/out/terrain10_9km.npz; Askervein: контуры WAsP),
lee_obs.csv, осреднённые окна ISFS (скорость на мачтах) и таблица Askervein (скорость станций).
Выход: out/obs_compare.csv, out/obs_compare.json (метрики, положение максимума, H и x_r/H).

  python3 -I model_obs.py --selftest
  python3 -I model_obs.py            # пишет out/obs_compare.csv и out/obs_compare.json

Только numpy + stdlib. Поля игры нет: «поле» заменено измеренной скоростью (см. docs/research/lee_turb/model_obs.md).
"""
import csv, json, math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto as P

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.abspath(os.path.join(HERE, "..", ".."))            # tools/research
K = P.K
OBS = os.path.join(RES, "lee_turb", "obs", "lee_obs.csv")
TERR9 = os.path.join(RES, "cases", "perdigao", "out", "terrain10_9km.npz")
MASTS = os.path.join(RES, "cases", "perdigao", "out", "masts.csv")
PD_WM = {"NE": os.path.join(RES, "data", "perdigao", "cases", "ne_20170427_windowmean.csv"),
         "SW": os.path.join(RES, "data", "perdigao", "cases", "sw_20170511_windowmean.csv")}
ASK_VAL = os.path.join(RES, "data", "askervein", "askervein_validation1.txt")
ASK_MAP = os.path.join(RES, "data", "askervein", "askervein_elevation-roughness.map")

# ветер и опорная (гребневая) мачта: как build_lee_obs.py
CASES = {
    ("perdigao", "NE"): dict(crest="tse13", wdir_to=(60.7 + 180) % 360),
    ("perdigao", "SW"): dict(crest="tse04", wdir_to=(216.5 + 180) % 360),
    ("askervein", "TU03B"): dict(crest="HT", wdir_to=30.0),
}
# отношения σ_u : σ_v : σ_w в нейтральном приземном слое (Panofsky–Dutton: 2,5 : 1,9 : 1,25 u*) - допущение
RATIO = np.array([2.5, 1.9, 1.25])
FRAC = RATIO ** 2 / np.sum(RATIO ** 2)                            # доли ТКЭ по u, v, w
SEP_BG_NOTE = "фон пузыря = ТКЭ наветренной мачты на той же высоте над землёй (в LTL σ у стенки в рециркуляции нет - допущение)"


# ---------------------------------------------------------------- рельеф
def bilinear(Z, xs, ys, x, y):
    fx = (np.asarray(x) - xs[0]) / (xs[1] - xs[0])
    fy = (np.asarray(y) - ys[0]) / (ys[1] - ys[0])
    ix = np.clip(np.floor(fx).astype(int), 0, len(xs) - 2)
    iy = np.clip(np.floor(fy).astype(int), 0, len(ys) - 2)
    tx, ty = fx - ix, fy - iy
    return (Z[iy, ix] * (1 - tx) * (1 - ty) + Z[iy, ix + 1] * tx * (1 - ty) + Z[iy + 1, ix] * (1 - tx) * ty + Z[iy + 1, ix + 1] * tx * ty)


def masts():
    return {r["name"]: r for r in csv.DictReader(open(MASTS, encoding="utf-8"))}


def line_perdigao(crest, wdir_to, d):
    m = masts()[crest]
    ex, ey = math.sin(math.radians(wdir_to)), math.cos(math.radians(wdir_to))
    z = np.load(TERR9)
    return bilinear(z["dsm"], z["x"], z["y"], float(m["x"]) + d * ex, float(m["y"]) + d * ey)


def read_wasp_points(path=ASK_MAP):
    """Изолинии WAsP -> (x, y, z); как tools/research/air3d/askervein.py:read_map_lines (без matplotlib)."""
    lines = open(path).read().splitlines()[4:]
    pts, k = [], 0
    while k < len(lines):
        head = lines[k].split()
        k += 1
        if not head:
            continue
        n = int(float(head[-1]))
        buf = []
        while len(buf) < 2 * n:
            buf += [float(t) for t in lines[k].split()]
            k += 1
        xy = np.array(buf[:2 * n]).reshape(n, 2)
        if len(head) == 2:
            pts.append(np.column_stack([xy, np.full(n, float(head[0]))]))
        elif len(head) == 4:
            pts.append(np.column_stack([xy, np.full(n, float(head[2]))]))
    return np.concatenate(pts)


def plane_fit_height(pts, x, y, kn=24):
    """Высота в точке: взвешенная плоскость по kn ближайшим точкам изолиний (без scipy)."""
    d2 = (pts[:, 0] - x) ** 2 + (pts[:, 1] - y) ** 2
    idx = np.argpartition(d2, kn)[:kn]
    w = 1.0 / (d2[idx] + 25.0)
    A = np.column_stack([np.ones(kn), pts[idx, 0] - x, pts[idx, 1] - y]) * np.sqrt(w)[:, None]
    b = pts[idx, 2] * np.sqrt(w)
    c, *_ = np.linalg.lstsq(A, b, rcond=None)
    return float(c[0])


def line_askervein(wdir_to, d, ht=(75387.0, 23735.0)):
    pts = read_wasp_points()
    ex, ey = math.sin(math.radians(wdir_to)), math.cos(math.radians(wdir_to))
    return np.array([plane_fit_height(pts, ht[0] + t * ex, ht[1] + t * ey) for t in d])


# ---------------------------------------------------------------- измерения (скорость, ТКЭ) по мачтам
def logz_interp(z, zs, vs):
    """Интерполяция по ln z с постоянным продолжением за краями."""
    zs, vs = np.asarray(zs, float), np.asarray(vs, float)
    o = np.argsort(zs)
    return float(np.interp(math.log(max(z, 0.5)), np.log(np.maximum(zs[o], 0.5)), vs[o]))


def load_profiles():
    """prof[(site, case)][mast] = list of (z, spd, tke); Perdigão - windowmean, Askervein - таблица валидации."""
    prof = {}
    for case, p in PD_WM.items():
        d = {}
        for r in csv.DictReader(open(p, encoding="utf-8")):
            if r["tke"] and r["spd"]:
                d.setdefault(r["site"], []).append((float(r["z_agl_m"]), float(r["spd"]), float(r["tke"])))
        prof[("perdigao", case)] = d
    a = {}
    for r in csv.DictReader(open(ASK_VAL)):
        nm, z, s, t = r["Name"], float(r["H(m)"]), float(r["S(m/s)"]), float(r["tke(m^2/s^2)"])
        if s < 0 or t < 0:
            continue
        key = nm + ("|gill" if "gill" in r["Sensor"] else "|cup" if "cup" in r["Sensor"] else "")
        a.setdefault(key, []).append((z, s, t))
        a.setdefault(nm, []).append((z, s, t))
    prof[("askervein", "TU03B")] = a
    return prof


def station_key(station):
    """'tse04_78m' -> ('tse04', 78); 'ANE20_10m' -> ('ANE20', 10); RS_AES_tilted_gill_uvw_10m -> ('RS|gill', 10)"""
    base, zz = station.rsplit("_", 1)
    z = float(zz[:-1])
    if base.startswith("RS_AES_tilted_gill"):
        base = "RS|gill"
    elif base.startswith("HT_"):
        base = "HT"
    return base, z


def speed_at(profs, mast, z):
    p = profs.get(mast)
    if not p:
        return None
    sel = [q for q in p if abs(q[0] - z) < 1e-6]
    if sel:
        return sel[0][1]
    return None


def upwind_bg(site, case, obs_rows, profs):
    """Фон: k_bg(z) = ТКЭ/U² наветренных мачт (x<0), интерполяция по ln z, среднее по мачтам; и ТКЭ фона tke_bg(z)."""
    masts_up = {}
    for r in obs_rows:
        if r["site"] == site and r["case"] == case and float(r["x_m"]) < 0 and r["reliability"] in ("A", "B") and r["tke_m2s2"]:
            mm = station_key(r["station"])[0]
            if site == "askervein" and mm != "RS|gill":
                continue                                   # Askervein: фон - только эталонная мачта RS (3 км против ветра); ASW/AASW стоят на склоне
            masts_up.setdefault(mm, set())
    ks, ts = [], []
    for m in masts_up:
        p = profs.get(m)
        if p and len(p) >= 1:
            ks.append(p)
    if not ks:
        raise RuntimeError("нет наветренного фона " + site + case)

    def fn(z):
        kv, tv = [], []
        for p in ks:
            zs = [q[0] for q in p]
            kv.append(logz_interp(z, zs, [q[2] / q[1] ** 2 for q in p]))
            tv.append(logz_interp(z, zs, [q[2] for q in p]))
        return float(np.mean(kv)), float(np.mean(tv))
    return fn, sorted(masts_up)


# ---------------------------------------------------------------- модель на станции
def tke_parts(sig):
    return 0.5 * float(np.sum(np.asarray(sig) ** 2))


def model_station(g_at, x, z, g_st, u1, bg_tke, tke_crest, k_crest, u_meas, k=K):
    """Все варианты ТКЭ в точке (x от опорной мачты, z над землёй, g_st - высота земли станции MSL).
    Возвращает dict: слой (ТКЭ), механика A (атмосферная скорость на гребне) и A_meas, варианты A/B/...; геометрию."""
    cp = P.crest_params(g_at, x, k)
    out = dict(geo=cp)
    bg_sig = np.sqrt(2.0 * bg_tke * FRAC)                           # σ фона по u, v, w
    mech_att = np.sqrt(2.0 * tke_crest * FRAC)                      # поле не видит отрыва: у стенки в следе то же, что на гребне (ТКЭ гребневой мачты на этой высоте)
    mech_meas = None if u_meas is None else np.sqrt(2.0 * k_crest * u_meas ** 2 * FRAC)   # «идеальное поле»: ТКЭ гребня, пересчитанная по измеренной скорости (∝ U²)
    if cp is None:
        lay = np.zeros(3)
        in_sep, f_sep, xr, xh = False, 0.0, float("nan"), float("nan")
    else:
        H = cp["H"]
        xr = k["ridge_xr_over_h"] * H
        cp = dict(cp)
        cp["h_at_xr"] = g_at(cp["d_c"] + xr)
        xx = x - cp["d_c"]
        u2 = k["u2_unresolved_over_u1"] * u1
        st = P.layer_state(np.array([xx]), np.array([g_st + z]), np.array([g_st]), cp, xr, u1, u2, k, res=0.0)
        lay = np.array([st["sig_u"][0], st["sig_v"][0], st["sig_w"][0]])
        f_sep = float(st["f_sep"])
        in_sep = (0.0 < xx < xr) and f_sep > 0.0
        xh = xx / H
        out.update(x_model=xx, xr=xr, f_sep=f_sep, H=H, s_lee=cp["s_lee"])
    out.update(f_sep=f_sep, xh_model=xh, in_sep=in_sep)
    out["layer"] = tke_parts(lay)
    out["A"] = tke_parts(np.maximum(mech_att, lay))
    out["A_meas"] = np.nan if mech_meas is None else tke_parts(np.maximum(mech_meas, lay))
    # B: в области отрыва (под линией слоя; вес f_sep) механика стенки не берётся из поля, болтанка = слой + фон
    sepB = tke_parts(np.maximum(bg_sig, lay))
    sepB2 = tke_parts(np.sqrt(bg_sig ** 2 + lay ** 2))
    w = f_sep if in_sep else 0.0
    out["B"] = (1 - w) * out["A"] + w * sepB
    out["B_sum"] = (1 - w) * out["A"] + w * sepB2
    out["bg"] = bg_tke
    out["mech_att"] = tke_parts(mech_att)
    return out


# ---------------------------------------------------------------- прогон
VARIANTS = ["A", "B", "A_meas", "B_sum", "layer", "bg"]


def run(out_dir):
    rows = list(csv.DictReader(open(OBS, encoding="utf-8")))
    profs_all = load_profiles()
    mst = masts()
    d_axis = np.arange(-3300.0, 3600.0 + 1e-9, 10.0)                 # линия: от опорной точки, ветер в +d
    result, summary = [], {}
    geom = {}
    for (site, case), cc in CASES.items():
        profs = profs_all[(site, case)]
        if site == "perdigao":
            gl = line_perdigao(cc["crest"], cc["wdir_to"], d_axis)
        else:
            gl = line_askervein(cc["wdir_to"], d_axis)
        g_at = lambda d, gl=gl: float(np.interp(d, d_axis, gl))
        sub = [r for r in rows if r["site"] == site and r["case"] == case]
        bgf, bg_masts = upwind_bg(site, case, sub, profs)
        crest_prof = profs[cc["crest"]]
        zc = [q[0] for q in crest_prof if q[0] >= 3]
        uc = [q[1] for q in crest_prof if q[0] >= 3]
        if site == "perdigao":
            u1 = float(sub[0]["u_ref_ms"])                           # U100 гребневой мачты
        else:
            u1 = [q[1] for q in crest_prof if abs(q[0] - 10) < 1e-6][0]   # HT на 10 м (вершина, ~уровень гребня)
        # геометрия: H, x_foot, s_lee для зонда в 0,5 км за гребнем
        cp = P.crest_params(g_at, 300.0, K)
        geom[f"{site}/{case}"] = dict(H_model_m=cp["H"], d_c_m=cp["d_c"], h_c_msl=cp["h_c"], foot_msl=cp["foot"], x_foot_m=cp["x_foot"],
                                      s_lee=cp["s_lee"], H_obs_csv_m=float(sub[0]["H_m"]), u1_ms=u1, bg_masts=bg_masts, n_queries=cp["n_queries"])
        for r in sub:
            x = float(r["x_m"])
            if x <= 0 or not r["tke_m2s2"] or r["reliability"] not in ("A", "B"):
                continue
            base, zz = station_key(r["station"])
            z = float(r["z_m"])
            if site == "perdigao":
                g_st = float(mst[base]["ground_asl"])
            else:
                g_st = float([q for q in csv.DictReader(open(ASK_VAL)) if q["Name"] == base and float(q["H(m)"]) == z][0]["Z(m)"])
            k_bg, tke_bg = bgf(z)
            tke_c = logz_interp(z, zc, [q[2] for q in crest_prof if q[0] >= 3])
            k_c = logz_interp(z, zc, [q[2] / q[1] ** 2 for q in crest_prof if q[0] >= 3])
            u_meas = speed_at(profs, base, zz) if site == "perdigao" else speed_at(profs, base, zz)
            m = model_station(g_at, x, z, g_st, u1, tke_bg, tke_c, k_c, u_meas)
            uref2 = float(r["u_ref_ms"]) ** 2
            H = m.get("H", float(sub[0]["H_m"]))
            row = dict(site=site, case=case, station=r["station"], x_over_h=x / float(r["H_m"]), z_over_h=z / float(r["H_m"]),
                       tke_obs_over_uref2=float(r["tke_m2s2"]) / uref2, n=r["n"], reliability=r["reliability"],
                       f_sep=m["f_sep"], in_sep=int(m["in_sep"]), xh_model=m["xh_model"])
            for v in VARIANTS:
                row["tke_%s_over_uref2" % v] = m[v] / uref2
            result.append(row)
    return result, geom


def stats(result, sel, keys=VARIANTS):
    out = {}
    for v in keys:
        e, le = [], []
        for r in sel:
            a, o = r["tke_%s_over_uref2" % v], r["tke_obs_over_uref2"]
            if not (np.isfinite(a) and np.isfinite(o)):
                continue
            e.append(a - o)
            le.append(math.log(max(a, 1e-4) / o))
        if e:
            out[v] = dict(n=len(e), rmse=float(np.sqrt(np.mean(np.square(e)))), bias=float(np.mean(e)),
                          rmse_log=float(np.sqrt(np.mean(np.square(le)))), bias_log=float(np.mean(le)))
    return out


def maxima(result, sel, keys=VARIANTS + ["obs"]):
    out = {}
    for v in keys:
        kk = "tke_%s_over_uref2" % v
        c = [r for r in sel if np.isfinite(r[kk])]
        if not c:
            continue
        r = max(c, key=lambda q: q[kk])
        out[v] = dict(station=r["station"], x_over_h=r["x_over_h"], z_over_h=r["z_over_h"], value=r[kk])
    return out


def write(result, geom, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cols = ["site", "case", "station", "x_over_h", "z_over_h", "tke_obs_over_uref2", "tke_A_over_uref2", "tke_B_over_uref2",
            "tke_A_meas_over_uref2", "tke_B_sum_over_uref2", "tke_layer_over_uref2", "tke_bg_over_uref2", "f_sep", "in_sep", "xh_model", "note"]
    with open(os.path.join(out_dir, "obs_compare.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in result:
            rr = dict(r)
            rr["note"] = "n=%s, надёжность %s; %s" % (r["n"], r["reliability"], "в области отрыва модели" if r["in_sep"] else "вне области отрыва")
            for k in rr:
                if isinstance(rr[k], float):
                    rr[k] = "%.5g" % rr[k]
            w.writerow({c: rr.get(c, "") for c in cols})
    S = {}
    for key in sorted({(r["site"], r["case"]) for r in result}):
        sel = [r for r in result if (r["site"], r["case"]) == key]
        nm = "/".join(key)
        H = geom[nm]["H_model_m"]
        xr_h = K["ridge_xr_over_h"]
        near = [r for r in sel if 0 < r["x_over_h"] * float(geom[nm]["H_obs_csv_m"]) / H <= xr_h]
        mid = [r for r in sel if xr_h < r["x_over_h"] * float(geom[nm]["H_obs_csv_m"]) / H <= 6 * float(geom[nm]["H_obs_csv_m"]) / H]
        within = [r for r in sel if r["x_over_h"] <= 6.0]
        Hobs = float(geom[nm]["H_obs_csv_m"])
        above = [r for r in within if r["z_over_h"] * Hobs >= 30.0 - 1e-6]          # выше 30 м: вне кроны (на 10-20 м мачты в лесу)
        # избыток над фоном (форма: множитель Rapp-Manhart против уступа): (ТКЭ_obs - ТКЭ_фона)/u_ref², пик при ΔU = 1,1 u_ref
        step_peak = 0.034 * (1.0 - K["u2_unresolved_over_u1"]) ** 2          # del_tke_peak * (ΔU/u_ref)^2
        exc = [(r["tke_obs_over_uref2"] - r["tke_bg_over_uref2"], r["station"], r["x_over_h"], r["z_over_h"]) for r in above]
        ex = max(exc) if exc else (float("nan"),) * 4
        S[nm] = dict(n_all=len(sel), n_within6=len(within), n_near=len(near), n_mid=len(mid),
                     stats_within6=stats(result, within), stats_near=stats(result, near), stats_all=stats(result, sel),
                     n_above30=len(above), stats_above30=stats(result, above), max_above30=maxima(result, above),
                     excess_over_bg=dict(value=ex[0], station=ex[1], x_over_h=ex[2], z_over_h=ex[3], step_layer_peak_tke_over_uref2=step_peak,
                                         implied_amp_over_step=math.sqrt(max(ex[0], 0.0) / step_peak) if exc else None),
                     max_within6=maxima(result, within), max_near=maxima(result, near))
    json.dump(dict(geometry=geom, summary=S, constants=dict(ridge_xr_over_h=K["ridge_xr_over_h"], FRAC=FRAC.tolist())),
              open(os.path.join(out_dir, "obs_compare.json"), "w"), indent=1, ensure_ascii=False)
    return S


def selftest():
    # ТКЭ-доли суммируются в 1; max по компонентам не ниже слоя и фона
    assert abs(FRAC.sum() - 1.0) < 1e-12
    d = np.arange(-3300.0, 3600.0, 10.0)
    g = np.where(d < 0, 200.0 + 0.1 * d, np.maximum(200.0 - 0.3 * d, 0.0))
    g_at = lambda t: float(np.interp(t, d, g))
    m = model_station(g_at, 300.0, 20.0, g_at(300.0), 8.0, 1.0, 1.28, 0.02, 2.0)
    assert m["geo"] is not None and abs(m["H"] - 200.0) < 1e-9 and m["in_sep"]
    assert m["A"] >= m["layer"] - 1e-12 and m["A"] >= m["mech_att"] - 1e-12
    assert m["B_sum"] >= m["B"] - 1e-12              # сумма не меньше максимума
    # без слоя (наветренная сторона гребня): варианты совпадают
    m0 = model_station(g_at, -200.0, 20.0, g_at(-200.0), 8.0, 1.0, 1.28, 0.02, 2.0)
    assert m0["layer"] == 0.0 and m0["B"] == m0["A"]
    # плоский склон (уклон < 0,128): слоя нет
    gf = lambda t: 200.0 - 0.05 * max(t, 0.0) if t > 0 else 200.0 + 0.1 * t
    mf = model_station(lambda t: float(gf(t)), 300.0, 20.0, float(gf(300.0)), 8.0, 1.0, 1.28, 0.02, 2.0)
    assert mf["f_sep"] == 0.0 and mf["layer"] == 0.0 and mf["B"] == mf["A"]
    print("selftest ok")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    res, geom = run(None)
    S = write(res, geom, os.path.join(HERE, "out"))
    print(json.dumps(geom, indent=1, ensure_ascii=False))
    for k, v in S.items():
        print(k, v["n_all"], v["n_within6"], v["n_near"])
        print(" stats_within6", json.dumps(v["stats_within6"], ensure_ascii=False))
        print(" max_within6", json.dumps(v["max_within6"], ensure_ascii=False))
