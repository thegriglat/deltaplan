#!/usr/bin/env python3
"""LT-12: сверка прежней (7665fb7) и новой (LTM v1) модели на разрезах LTS: мачты Perdigão/Askervein и разрезы Онгудая.
python3 -I analyze.py -> out/mast_compare.csv, out/ongudai.csv, out/verify.json. Вход: ~/data/lee_turb/lts_verify/{old,new}_*.lts.csv (run.py), out/lines.json, ../obs/lee_obs.csv.
Обе модели берутся прямо из LTS: ТКЭ = 0,5(σu²+σv²+σw²) в точке станции (интерполяция вдоль линии по x, в колонке по высоте над землёй)."""
import csv, glob, json, math, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import model_obs as MO
DATA = os.path.expanduser("~/data/lee_turb/lts_verify")
L = json.load(open(os.path.join(HERE, "out", "lines.json")))
RIDGES = {r["name"]: r for r in json.load(open(os.path.join(HERE, "..", "stand", "ridges.json")))}
OBS = list(csv.DictReader(open(MO.OBS, encoding="utf-8")))
PROFS = MO.load_profiles()
SITECASE = {"perdigao_sw": ("perdigao", "SW"), "perdigao_ne": ("perdigao", "NE"), "askervein_tu03b": ("askervein", "TU03B")}
CODES = ("old", "new")


def load(path):
    with open(path) as f:
        f.readline(); rd = csv.DictReader(f); rows = list(rd)
    cols = {k: (np.array([r[k] for r in rows]) if k == "src" else np.array([float(r[k]) if r[k] != "" else np.nan for r in rows])) for k in rd.fieldnames}
    s_u, y_u = np.unique(cols["s"]), np.unique(cols["y"])
    si = {v: i for i, v in enumerate(s_u)}; yi = {v: i for i, v in enumerate(y_u)}
    ii = np.array([si[v] for v in cols["s"]]); jj = np.array([yi[v] for v in cols["y"]])
    g = {}
    for k, v in cols.items():
        if k in ("s", "y"):
            continue
        a = np.full((len(s_u), len(y_u)), "" if k == "src" else np.nan, dtype=object if k == "src" else float)
        a[ii, jj] = v; g[k] = a
    return s_u, y_u, g


def at_agl(s_u, g, arr, s, agl):
    """arr в точке (s, agl над землёй): интерполяция по agl в двух соседних колонках, линейно по s."""
    i1 = int(np.clip(np.searchsorted(s_u, s), 1, len(s_u) - 1)); i0 = i1 - 1
    vals = []
    for i in (i0, i1):
        a, v = g["agl"][i], arr[i]
        ok = np.isfinite(a) & np.isfinite(v)
        if ok.sum() < 2 or agl < a[ok].min() - 1e-6 or agl > a[ok].max():
            vals.append(np.nan); continue
        o = np.argsort(a[ok]); vals.append(float(np.interp(agl, a[ok][o], v[ok][o])))
    t = (s - s_u[i0]) / (s_u[i1] - s_u[i0])
    if np.isnan(vals[0]) or np.isnan(vals[1]):
        return vals[0] if t < 0.5 and not np.isnan(vals[0]) else (vals[1] if not np.isnan(vals[1]) else vals[0])
    return vals[0] * (1 - t) + vals[1] * t


def nearest_meta(s_u, y_u, g, s, agl, key):
    i = int(np.argmin(abs(s_u - s))); a = g["agl"][i]
    ok = np.isfinite(a)
    j = int(np.where(ok)[0][np.argmin(abs(a[ok] - agl))]) if ok.any() else 0
    return g[key][i, j]


def fnum(x):
    return "" if (isinstance(x, float) and not np.isfinite(x)) else (("%.5g" % x) if isinstance(x, float) else x)


def stations():
    rows = []
    for code in CODES:
        for cj, v in L.items():
            site, oc = SITECASE[cj]; profs = PROFS[(site, oc)]
            sub = [r for r in OBS if r["site"] == site and r["case"] == oc]
            bgf, _ = MO.upwind_bg(site, oc, sub, profs)
            secs = {}
            for ln in v["lines"]:
                main = v["crest"] in ln["members"]
                p = os.path.join(DATA, "%s_%s%s.lts.csv" % (code, cj, "" if main else "_" + ln["name"].split("_")[-1]))
                if os.path.exists(p):
                    secs[ln["name"]] = (ln, load(p))
            mem = {m: nm for nm, (ln, _) in secs.items() for m in ln["members"]}
            for r in sub:
                if not r["tke_m2s2"] or r["reliability"] not in ("A", "B"):
                    continue
                base, z = MO.station_key(r["station"])
                if base == "RS|gill" or base not in v["stations"] or base not in mem:
                    continue
                ln, (s_u, y_u, g) = secs[mem[base]]; st = v["stations"][base]
                s = st["a"] - ln["a0"]
                if not (s_u[0] <= s <= s_u[-1]):
                    continue
                uref = float(r["u_ref_ms"]); H = float(r["H_m"])
                tke = 0.5 * sum(at_agl(s_u, g, g[c], s, z) ** 2 for c in ("sigma_u", "sigma_v", "sigma_w"))
                if not np.isfinite(tke):
                    continue
                upar, uperp = at_agl(s_u, g, g["u_par"], s, z), at_agl(s_u, g, g["u_perp"], s, z)
                um = MO.speed_at(profs, base, z)
                _, tb = bgf(z)
                rows.append(dict(code=code, case=oc, site=site, station=r["station"], x_over_h=float(r["x_m"]) / H, z_over_h=float(r["z_m"]) / H,
                                 tke_obs_over_uref2=float(r["tke_m2s2"]) / uref**2, tke_model_over_uref2=tke / uref**2, tke_bg_over_uref2=tb / uref**2,
                                 u_field_over_uref=math.hypot(upar, uperp) / uref, u_obs_over_uref=(um / uref) if um else float("nan"),
                                 lee_f=float(at_agl(s_u, g, g["lee_f"], s, z)), w_sep="",
                                 du=float(at_agl(s_u, g, g["du"], s, z)), src=str(nearest_meta(s_u, y_u, g, s, z, "src")),
                                 sigma_w=float(at_agl(s_u, g, g["sigma_w"], s, z)), reliability=r["reliability"], cross_off_m=st["c"] - ln["cross"]))
    return rows


def stats(rows):
    out = {}
    for site_case in sorted({(r["site"], r["case"]) for r in rows}):
        for lab, lo, hi in (("x0_6", 0.0, 6.0), ("x0_1", 0.0, 1.0), ("x1.5_7", 1.5, 7.0)):
            # общий набор строк: станции, где есть обе модели
            by = {}
            for r in rows:
                if (r["site"], r["case"]) == site_case and lo < r["x_over_h"] <= hi and np.isfinite(r["tke_obs_over_uref2"]):
                    by.setdefault((r["station"], round(r["z_over_h"], 5)), {})[r["code"]] = r
            sel = [d for d in by.values() if "old" in d and "new" in d]
            if not sel:
                continue
            o = np.array([d["old"]["tke_obs_over_uref2"] for d in sel])
            d = dict(n=len(sel), obs_mean=float(o.mean()))
            for k, f in (("old", lambda d: d["old"]["tke_model_over_uref2"]), ("new", lambda d: d["new"]["tke_model_over_uref2"]), ("bg", lambda d: d["old"]["tke_bg_over_uref2"])):
                a = np.array([f(x) for x in sel]); ok = np.isfinite(a)
                d[k] = dict(rmse=float(np.sqrt(np.mean((a[ok] - o[ok]) ** 2))), bias=float(np.mean(a[ok] - o[ok])), mean=float(a[ok].mean()), n=int(ok.sum()))
            for k, f in (("obs", lambda d: d["old"]["tke_obs_over_uref2"]), ("old", lambda d: d["old"]["tke_model_over_uref2"]), ("new", lambda d: d["new"]["tke_model_over_uref2"])):
                best = max(sel, key=f); rr = best["old"]
                d["max_" + k] = dict(station=rr["station"], x_over_h=rr["x_over_h"], z_over_h=rr["z_over_h"], value=float(f(best)))
            um = [(x["old"]["u_field_over_uref"], x["new"]["u_field_over_uref"], x["old"]["u_obs_over_uref"]) for x in sel if np.isfinite(x["old"]["u_obs_over_uref"])]
            if um:
                a = np.array(um)
                d["u_mean"] = dict(n=len(a), obs=float(a[:, 2].mean()), old=float(a[:, 0].mean()), new=float(a[:, 1].mean()))
            out["%s/%s/%s" % (site_case[0], site_case[1], lab)] = d
    return out


def ongudai():
    rows = []
    for code in CODES:
        for name, R in RIDGES.items():
            p = os.path.join(DATA, "%s_ongudai_strong_%s.lts.csv" % (code, name))
            if not os.path.exists(p):
                continue
            s_u, y_u, g = load(p)
            H, crest = R["H"], R["crest_msl"]; xh = (s_u - 2 * H) / H
            agl, src = g["agl"], g["src"]
            inf = (src != "none") & (src != "")
            row = dict(code=code, ridge=name, zone_dx=R["zone"], H_m=H)
            for lab, lo, hi in (("all", 5.0, 1e9), ("agl150", 5.0, 150.0)):
                sw = np.where((agl >= lo) & (agl <= hi) & inf, g["sigma_w"], np.nan)
                # только за гребнем (x/H > 0)
                sw[xh <= 0] = np.nan
                if not np.isfinite(sw).any():
                    row.update({"xh_max_" + lab: "", "zc_max_" + lab: "", "agl_max_" + lab: "", "sw_max_" + lab: "", "src_max_" + lab: ""}); continue
                i, j = np.unravel_index(np.nanargmax(sw), sw.shape)
                row.update({"xh_max_" + lab: float(xh[i]), "zc_max_" + lab: float(y_u[j] - crest), "agl_max_" + lab: float(agl[i, j]),
                            "sw_max_" + lab: float(sw[i, j]), "src_max_" + lab: str(src[i, j])})
            for t in (0.5, 1, 2, 4):
                i = int(np.argmin(abs(xh - t)))
                a = g["agl"][i]; ok = np.isfinite(a) & np.isfinite(g["sigma_w"][i])
                if ok.sum() >= 2 and a[ok].min() <= 30 <= a[ok].max():
                    row["sw30_xh%g" % t] = float(np.interp(30.0, a[ok], g["sigma_w"][i][ok]))
                    j = int(np.where(ok)[0][np.argmin(abs(a[ok] - 30.0))]); row["src30_xh%g" % t] = str(src[i, j])
                else:
                    row["sw30_xh%g" % t] = ""; row["src30_xh%g" % t] = ""
            m = (xh > 0) & (xh <= 6)
            sub = np.where(m[:, None] & (agl >= 5) & (agl <= 150) & inf, 1, 0).astype(bool)
            row["frac_mix_agl150_x0_6"] = float((src[sub] == "mix").mean()) if sub.any() else ""
            row["frac_mech_agl150_x0_6"] = float((src[sub] == "mech").mean()) if sub.any() else ""
            row["frac_conv_agl150_x0_6"] = float((src[sub] == "conv").mean()) if sub.any() else ""
            row["sw_mean_agl30_x0_6"] = ""
            vals = []
            for i in np.where(m)[0]:
                a = g["agl"][i]; ok = np.isfinite(a) & np.isfinite(g["sigma_w"][i])
                if ok.sum() >= 2 and a[ok].min() <= 30 <= a[ok].max():
                    vals.append(np.interp(30.0, a[ok], g["sigma_w"][i][ok]))
            if vals:
                row["sw_mean_agl30_x0_6"] = float(np.mean(vals))
            rows.append(row)
    # разность new - old на тех же точках (x > 0, 5 <= agl <= 150): σ_w, σ_u
    old = {r["ridge"]: r for r in rows if r["code"] == "old"}
    for r in rows:
        if r["code"] != "new":
            continue
        so, sn = [load(os.path.join(DATA, "%s_ongudai_strong_%s.lts.csv" % (c, r["ridge"]))) for c in ("old", "new")]
        s_u, y_u, go = so; gn = sn[2]
        H = r["H_m"]; xh = (s_u - 2 * H) / H
        mk = (xh[:, None] > 0) & (go["agl"] >= 5) & (go["agl"] <= 150)
        for c in ("sigma_w", "sigma_u"):
            d = (gn[c] - go[c])[mk]
            r["dfrac_" + c] = float((abs(d) > 0.05).mean()); r["dmin_" + c] = float(d.min()); r["dmax_" + c] = float(d.max())
        d = np.where(mk, gn["sigma_u"] - go["sigma_u"], np.nan)
        i, j = np.unravel_index(np.nanargmin(d), d.shape)
        r["xh_dmin_sigma_u"] = float(xh[i]); r["agl_dmin_sigma_u"] = float(go["agl"][i, j])
        r["n_src_changed"] = int((go["src"][mk] != gn["src"][mk]).sum()); r["n_points"] = int(mk.sum())
    return rows


def main():
    rows = stations()
    cols = ["code", "case", "station", "x_over_h", "z_over_h", "tke_obs_over_uref2", "tke_model_over_uref2", "u_field_over_uref", "u_obs_over_uref",
            "lee_f", "w_sep", "du", "src", "tke_bg_over_uref2", "sigma_w", "reliability", "site", "cross_off_m"]
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    with open(os.path.join(HERE, "out", "mast_compare.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh); w.writerow(cols)
        for r in rows:
            w.writerow([fnum(r[c]) for c in cols])
    og = ongudai()
    if og:
        keys = list(og[-1].keys())
        with open(os.path.join(HERE, "out", "ongudai.csv"), "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh); w.writerow(keys)
            for r in og:
                w.writerow([fnum(r.get(k, "")) for k in keys])
    info = dict(n_rows=len(rows), stats=stats(rows), ongudai=og)
    json.dump(info, open(os.path.join(HERE, "out", "verify.json"), "w"), ensure_ascii=False, indent=1, default=float)
    print("rows", len(rows), "ongudai", len(og))


if __name__ == "__main__":
    main()
