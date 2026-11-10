#!/usr/bin/env python3
"""LT-8: сверка поля игры с мачтами. analyze.py -> out/mast_compare.csv, out/fieldcheck.json (python3 -I; numpy).
Вход: ~/data/lee_turb/lts_fieldcheck/{a,b}_<случай>[_Lxx].lts.csv (run.py), out/lines.json, ../obs/lee_obs.csv.
Модель «новая» = прототип LT-7 (proto.run_section, вариант B_new: центр слоя по z½ поля, B только под линией) на разрезе линии станции; «прежняя» = σ из LTS (0,5(σu²+σv²+σw²))."""
import csv, glob, json, math, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import proto as P
import model_obs as MO
DATA = os.path.expanduser("~/data/lee_turb/lts_fieldcheck")
L = json.load(open(os.path.join(HERE, "out", "lines.json")))
OBS = list(csv.DictReader(open(MO.OBS, encoding="utf-8")))
PROFS = MO.load_profiles()
SITECASE = {"perdigao_sw": ("perdigao", "SW"), "perdigao_ne": ("perdigao", "NE"), "askervein_tu03b": ("askervein", "TU03B")}
FIELDS = [f for f in ("a", "b") if glob.glob(os.path.join(DATA, f + "_*.lts.csv"))]


def zone_dx(name):
    """dx окна поля, содержащего разрез: самый мелкий уровень из stderr стенда (строка 'dx')."""
    p = os.path.join(DATA, name + ".stderr")
    best = None
    if os.path.exists(p):
        for ln in open(p, encoding="utf-8"):
            if "dx" in ln:
                import re
                m = re.findall(r"dx[= ]+([0-9.]+)", ln)
                for v in m:
                    best = float(v) if best is None else min(best, float(v))
    return best


def interp_at(sec, arr, s, agl):
    """arr[s_i, y_j] в точке (s, agl): по колонкам, интерполяция по agl в колонке, линейно по s между соседними колонками."""
    S, g = sec["s"], sec["g"]
    i1 = int(np.clip(np.searchsorted(S, s), 1, len(S) - 1)); i0 = i1 - 1
    vals = []
    for i in (i0, i1):
        a, v = g["agl"][i], arr[i]
        ok = np.isfinite(a) & np.isfinite(v)
        if ok.sum() < 2 or agl < a[ok].min() - 1e-6 or agl > a[ok].max():
            vals.append(np.nan); continue
        o = np.argsort(a[ok]); vals.append(float(np.interp(agl, a[ok][o], v[ok][o])))
    t = (s - S[i0]) / (S[i1] - S[i0])
    if np.isnan(vals[0]) or np.isnan(vals[1]):
        return vals[0] if t < 0.5 and not np.isnan(vals[0]) else (vals[1] if not np.isnan(vals[1]) else vals[0])
    return vals[0] * (1 - t) + vals[1] * t


def col_val(S, v, s):
    ok = np.isfinite(v)
    return float(np.interp(s, S[ok], v[ok])) if ok.sum() > 1 else float("nan")


def run_sections():
    """{(fld,case): {linename: sec}}, sec - результат run_section + dx."""
    out, meta = {}, {}
    for f in FIELDS:
        for cj, v in L.items():
            for ln in v["lines"]:
                main = v["crest"] in ln["members"]
                name = "%s_%s%s" % (f, cj, "" if main else "_" + ln["name"].split("_")[-1])
                path = os.path.join(DATA, name + ".lts.csv")
                if not os.path.exists(path):
                    continue
                dx = zone_dx(name) or 50.0
                sec = P.run_section(path, dict(name=name, H=v["H"], zone=dx), dy_field=dx / 2.0)
                sec["dx"] = dx; sec["name"] = name; sec["line"] = ln; sec["main"] = main
                out.setdefault((f, cj), {})[ln["name"]] = sec
    return out


def station_rows(secs):
    rows = []
    for (f, cj), lns in secs.items():
        v = L[cj]; site, oc = SITECASE[cj]
        profs = PROFS[(site, oc)]
        sub = [r for r in OBS if r["site"] == site and r["case"] == oc]
        bgf, _ = MO.upwind_bg(site, oc, sub, profs)
        mem = {m: ln for ln in lns.values() for m in ln["line"]["members"]}
        for r in sub:
            if not r["tke_m2s2"] or r["reliability"] not in ("A", "B"):
                continue
            base, z = MO.station_key(r["station"])
            if base in ("RS|gill",) or base not in v["stations"] or base not in mem:
                continue
            sec = mem[base]; ln = sec["line"]; st = v["stations"][base]
            s = st["a"] - ln["a0"]
            if not (sec["s"][0] <= s <= sec["s"][-1]):
                continue
            uref = float(r["u_ref_ms"]); H = float(r["H_m"])
            old = 0.5 * sum(interp_at(sec, sec["g"][c], s, z) ** 2 for c in ("sigma_u", "sigma_v", "sigma_w"))
            new = 0.5 * sum(interp_at(sec, sec["sig3"][c]["B_new"], s, z) ** 2 for c in ("sigma_u", "sigma_v", "sigma_w"))
            fb = 0.5 * sum(interp_at(sec, sec["sig3"][c]["B_fb"], s, z) ** 2 for c in ("sigma_u", "sigma_v", "sigma_w"))
            nolayer = ""
            if not np.isfinite(new) and np.isfinite(old):          # слоя нет (станция до гребня или за ближайшим подножием, где гребня против ветра нет): новая = прежняя
                new, fb = old, old
                nolayer = "; слоя нет (новая = прежняя)"
            gl = col_val(sec["s"], sec["gnd"], s)
            upar, uperp = interp_at(sec, sec["g"]["u_par"], s, z), interp_at(sec, sec["g"]["u_perp"], s, z)
            um = MO.speed_at(profs, base, z)
            q = col_val(sec["s"], sec["q"], s)
            kb, tb = bgf(z)
            note = "линия %s, поперёк %+.0f м от линии, земля линии - станции %+.0f м, dx окна %g м%s" % (ln["name"].split("_")[-1], st["c"] - ln["cross"], gl - st["g"], sec["dx"], nolayer)
            rows.append(dict(field=f, case=oc, site=site, station=r["station"], x_over_h=float(r["x_m"]) / H, z_over_h=float(r["z_m"]) / H,
                             tke_obs_over_uref2=float(r["tke_m2s2"]) / uref**2, tke_old_over_uref2=old / uref**2, tke_new_over_uref2=new / uref**2,
                             q_field_center=q, u_mean_obs_over_uref=(um / uref) if um else float("nan"),
                             u_mean_field_over_uref=math.hypot(upar, uperp) / uref,
                             note=note, tke_newfb_over_uref2=fb / uref**2, tke_bg_over_uref2=tb / uref**2,
                             reliability=r["reliability"], cross_off=st["c"] - ln["cross"], dground=gl - st["g"], line_minus_station_m=col_val(sec["s"], sec["yc"], s) - (st["g"] + float(r["z_m"])), nolayer=int(bool(nolayer))))
    return rows


def fmt(x):
    return "" if (isinstance(x, float) and not np.isfinite(x)) else (("%.5g" % x) if isinstance(x, float) else x)


def write_csv(rows, path):
    cols = ["field", "case", "station", "x_over_h", "z_over_h", "tke_obs_over_uref2", "tke_old_over_uref2", "tke_new_over_uref2", "q_field_center",
            "u_mean_obs_over_uref", "u_mean_field_over_uref", "note", "tke_newfb_over_uref2", "tke_bg_over_uref2", "reliability", "site", "line_minus_station_m"]
    with open(path + ".tmp", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh); w.writerow(cols)
        for r in rows:
            w.writerow([fmt(r[c]) for c in cols])
    os.replace(path + ".tmp", path)


def bubble(sec, v):
    """Пузырь поля на линии опорной станции (u_par<0): длина по нижнему уровню, наибольшая длина, глубина над подножием, обратная скорость."""
    S, y, g, gnd = sec["s"], sec["y"], sec["g"], sec["gnd"]
    geo = sec["geo"]; dc = geo["d_c"]; foot = geo["foot"]
    up = g["u_par"]; agl = g["agl"]
    neg = np.isfinite(up) & (up < 0) & (S[:, None] > dc)
    out = dict(H_model=float(geo["H"]), crest_s=float(dc), foot_msl=float(foot), n_neg_cells=int(neg.sum()), dx=sec["dx"])
    if neg.sum() == 0:
        out.update(x_r_low=None, x_extent=0.0, depth_max=0.0, depth_mean=0.0, u_back_min=None, u_back_median=None); return out
    cols = np.where(neg.any(axis=1))[0]
    out["x_extent"] = float(S[cols[-1]] - dc)
    out["x_start"] = float(S[cols[0]] - dc)
    low = np.array([P._u_at_agl(g, j, 25.0) for j in range(len(S))])
    b = P.bubble_from_field(S, low, dc, sec["dx"])
    out["x_r_low"] = None if b is None else dict(L=b[0], x_sep=b[1], x_att=b[2])
    tops = []
    for i in cols:
        yy = y[neg[i]]
        tops.append(yy.max() - foot)                        # верх области u<0 в колонке над подножием (дно долины)
    out["depth_max"] = float(max(tops)); out["depth_mean"] = float(np.mean(tops)); out["depth_mean_over_H"] = out["depth_mean"] / geo["H"]
    out["depth_max_over_H"] = out["depth_max"] / geo["H"]
    out["u_back_min"] = float(up[neg].min()); out["u_back_median"] = float(np.median(up[neg]))
    mk = np.isfinite(up) & (up < -0.5) & (S[:, None] > dc)                      # порог Menke 2019: обратная скорость > 0,5 м/с
    mc = np.where(mk.any(axis=1))[0]
    out["menke_thr"] = dict(n_cells=int(mk.sum()), x_extent=None if len(mc) == 0 else float(S[mc[-1]] - S[mc[0]]),
                            depth_max=None if len(mc) == 0 else float(max(y[mk[i]].max() - foot for i in mc)))
    return out


def centre(sec, v):
    """Центр слоя поля z½ против запасной линии, x/H 0,5..6: доля колонок q>0,5, средняя разность (z½ - запасная), высоты над землёй."""
    H = sec["geo"]["H"]; dc = sec["geo"]["d_c"]
    xh = (sec["s"] - dc) / H
    m = (xh >= 0.5) & (xh <= 6) & np.isfinite(sec["q"])
    if m.sum() == 0:
        return None
    qq = sec["q"][m]; zh = sec["z_half"][m]; fbk = sec["yc_fb"][m]; gg = sec["gnd"][m]
    use = qq > 0.5
    return dict(n_cols=int(m.sum()), frac_q_gt_half=float(use.mean()),
                dz_field_minus_fallback_m=None if not use.any() else float(np.mean(zh[use] - fbk[use])),
                zhalf_agl_over_H_mean=None if not use.any() else float(np.mean((zh[use] - gg[use]) / H)),
                fallback_agl_over_H_mean=float(np.mean((fbk - gg) / H)), xr_used_over_H=float(sec["geo"].get("xr", np.nan) / H))


def stats_block(rows):
    """RMSE/смещение ТКЭ/u_ref² за гребнем (x>0) на ОБЩЕМ наборе строк (где конечны измерение, прежняя, новая, фон), два набора: x/H в (0, 6] и x>0 (до 14H);
    максимумы - по тем же наборам; скорость - на строках с конечными скоростями поля и измерения."""
    out = {}
    keys = {"old": "tke_old_over_uref2", "new": "tke_new_over_uref2", "newfb": "tke_newfb_over_uref2", "bg": "tke_bg_over_uref2"}
    for f in FIELDS:
        for site_case in sorted({(r["site"], r["case"]) for r in rows}):
            allr = [r for r in rows if r["field"] == f and (r["site"], r["case"]) == site_case]
            for lab, lo, hi in (("x0_6", 0.0, 6.0), ("x0_all", 0.0, 1e9), ("x1.5_7", 1.5, 7.0)):
                sel = [r for r in allr if lo < r["x_over_h"] <= hi and all(np.isfinite(r[c]) for c in list(keys.values()) + ["tke_obs_over_uref2"])]
                o = np.array([r["tke_obs_over_uref2"] for r in sel])
                d = dict(n=len(sel), obs_mean=float(o.mean()) if len(o) else None)
                if len(o):
                    lm = [r["line_minus_station_m"] for r in sel if np.isfinite(r["line_minus_station_m"])]
                    d["line_minus_station_m_median"] = float(np.median(lm)) if lm else None
                    d["ratio_mean_to_obs"] = {k: float(np.mean([r[c] / r["tke_obs_over_uref2"] for r in sel])) for k, c in keys.items()}
                for k, c in keys.items():
                    a = np.array([r[c] for r in sel])
                    if len(a):
                        d[k] = dict(rmse=float(np.sqrt(np.mean((a - o) ** 2))), bias=float(np.mean(a - o)))
                for k, c in (("obs", "tke_obs_over_uref2"), ("old", "tke_old_over_uref2"), ("new", "tke_new_over_uref2")):
                    c2 = [r for r in sel if np.isfinite(r[c])]
                    if c2:
                        rr = max(c2, key=lambda r: r[c])
                        d["max_" + k] = dict(station=rr["station"], x_over_h=rr["x_over_h"], z_over_h=rr["z_over_h"], value=rr[c])
                um = [(r["u_mean_field_over_uref"], r["u_mean_obs_over_uref"]) for r in allr
                      if lo < r["x_over_h"] <= hi and np.isfinite(r["u_mean_obs_over_uref"]) and np.isfinite(r["u_mean_field_over_uref"])]
                if um:
                    a = np.array(um); d["u_mean"] = dict(n=len(a), rmse=float(np.sqrt(np.mean((a[:, 0] - a[:, 1]) ** 2))), bias=float(np.mean(a[:, 0] - a[:, 1])),
                                                          ratio_median=float(np.median(a[:, 0] / np.maximum(a[:, 1], 1e-3))))
                out["%s/%s/%s/%s" % (f, site_case[0], site_case[1], lab)] = d
    return out


def main():
    secs = run_sections()
    rows = station_rows(secs)
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    write_csv(rows, os.path.join(HERE, "out", "mast_compare.csv"))
    info = dict(n_rows=len(rows), bubble={}, centre={}, stats=stats_block(rows), times={})
    for (f, cj), lns in secs.items():
        for lname, sec in lns.items():
            if sec["main"]:
                info["bubble"]["%s/%s" % (f, cj)] = bubble(sec, L[cj])
                info["centre"]["%s/%s" % (f, cj)] = centre(sec, L[cj])
    tp = os.path.join(DATA, "times_%s.csv")
    for f in FIELDS:
        if os.path.exists(tp % f):
            info["times"][f] = [ln.strip().split(",") for ln in open(tp % f) if ln.strip()]
    json.dump(info, open(os.path.join(HERE, "out", "fieldcheck.json"), "w"), ensure_ascii=False, indent=1, default=float)
    print("rows", len(rows), "fields", FIELDS)


if __name__ == "__main__":
    main()
