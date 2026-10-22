"""Сверка климата модели (Td, T700) с прогнозом Open-Meteo: places.csv, places_summer.csv, summary.json (часть stations — stations.py).
Запуск: python analyze.py   (после fetch.py)"""
import csv, datetime as dt, glob, json, os
import numpy as np
from common import *

TD = load_td(); UA = load_ua()
HAVE_SD700 = bool(np.isfinite(UA["sd"]).any())
RNG = np.random.default_rng(9)
HIGH_Z = 2500.0  # м: выше T700 (≈3 км) около поверхности/под рельефом — экстраполяция, исключаем из статистики T700


def load_place(run, name):
    j = json.load(open(f"{RAW}/raw/{run}/{name}.json"))
    h = j["hourly"]; t = np.array([dt.datetime.fromisoformat(s) for s in h["time"]])
    td = np.array([np.nan if v is None else v for v in h["dew_point_2m"]], float)
    t7 = np.array([np.nan if v is None else v for v in h["temperature_700hPa"]], float)
    days = {}
    for k, ti in enumerate(t):
        if ti.hour in (0, 12):
            days.setdefault(ti.date(), {})[ti.hour] = (td[k], t7[k])
    out = []
    t0 = min(days)
    for d in sorted(days):
        v = days[d]
        if 0 in v and 12 in v:  # Td дня = среднее 00 и 12 UTC, как в сетке
            out.append((d, (d - t0).days, (v[0][0] + v[12][0]) / 2, (v[0][1] + v[12][1]) / 2))
    return j["elevation"], out


def place_rows(run, with_lead=True):
    rows = []
    for name, lat, lon, src in PLACES:
        z, days = load_place(run, name)
        zc = float(bil(TD["z"], lat, lon))
        for d, lead, fd, f7 in days:
            tdc = float(at_day(TD["td"], lat, lon, d)) + g_td(lat, d) * (z - zc) / 1000.0
            sdc = float(at_day(TD["sd"], lat, lon, d))
            t7c = float(at_day(UA["t"], lat, lon, d)); s7 = float(at_day(UA["sd"], lat, lon, d))
            rows.append(dict(name=name, lat=lat, lon=lon, src=src, z=z, zc=zc, date=d, lead=lead, f_td=fd, c_td=tdc, sd_td=sdc, f_t7=f7, c_t7=t7c, sd_t7=s7))
    return rows


def boot(vals, n=10000):
    """Бутстрэп по местам (кластеры = места; дни внутри места коррелированы): 95 % ДИ среднего по местам."""
    v = np.asarray(vals, float); v = v[np.isfinite(v)]
    m = RNG.integers(0, len(v), (n, len(v)))
    b = v[m].mean(1)
    return [float(np.percentile(b, 2.5)), float(np.percentile(b, 97.5))]


def per_place(rows, var):
    """var: 'td' или 't7'. -> список по местам: n, bias, bias/σ, доля |Δ|<σ, std(Δ), lag-1 автокорреляция Δ, n_eff."""
    res = []
    for name in dict.fromkeys(r["name"] for r in rows):
        rs = [r for r in rows if r["name"] == name]
        f = np.array([r["f_" + var] for r in rs]); c = np.array([r["c_" + var] for r in rs]); s = np.array([r["sd_" + var] for r in rs])
        ok = np.isfinite(f) & np.isfinite(c)
        f, c, s = f[ok], c[ok], s[ok]
        dlt = f - c; n = len(dlt)
        if n < 3:
            continue
        r1 = float(np.corrcoef(dlt[:-1], dlt[1:])[0, 1]) if n > 3 else 0.0
        neff = n * (1 - r1) / (1 + r1) if r1 > 0 else n
        e = dict(name=name, lat=rs[0]["lat"], lon=rs[0]["lon"], z=rs[0]["z"], src=rs[0]["src"], n=n, bias=float(dlt.mean()), std=float(dlt.std(ddof=1)),
                 r1=r1, neff=float(max(1.0, min(n, neff))))
        if np.isfinite(s).all():
            e["bias_sig"] = float((dlt / s).mean()); e["frac"] = float((np.abs(dlt) < s).mean()); e["sd_mean"] = float(s.mean())
        else:
            e["bias_sig"] = e["frac"] = e["sd_mean"] = float("nan")
        res.append(e)
    return res


def agg(pp, var, lab=""):
    g = lambda k: [e[k] for e in pp]
    o = dict(places=len(pp), bias_k=float(np.mean(g("bias"))), bias_ci95=boot(g("bias")), median_bias_k=float(np.median(g("bias"))),
             std_delta_k=float(np.mean(g("std"))), n_days_mean=float(np.mean(g("n"))), neff_mean=float(np.mean(g("neff"))), lag1_mean=float(np.mean(g("r1"))))
    fr = np.array(g("frac"))
    if np.isfinite(fr).all():
        o.update(frac_within_sigma=float(fr.mean()), ci95=boot(fr), bias_sigma=float(np.mean(g("bias_sig"))), bias_sigma_ci95=boot(g("bias_sig")),
                 places_bias_over_half_sigma=int(sum(abs(e["bias_sig"]) > 0.5 for e in pp)))
    else:
        o.update(frac_within_sigma="ждёт σ T700", ci95=None, note="t700_sd.npz (HH-1g) пока NaN; std_delta_k — ориентир для будущей σ: вариация суточной T700 вокруг климата")
    return o


def lead_bins(rows, var, bins=((0, 3), (4, 9), (10, 15))):
    out = {}
    for lo, hi in bins:
        rs = [r for r in rows if lo <= r["lead"] <= hi]
        pp = per_place(rs, var)
        if pp:
            a = agg(pp, var)
            out[f"{lo}-{hi}"] = {k: a[k] for k in ("bias_k", "frac_within_sigma", "std_delta_k") if k in a}
    return out


def write_csv(path, ptd, pt7):
    t7 = {e["name"]: e for e in pt7}
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["место", "lat", "lon", "z_м", "источник", "n_дней", "td_сдвиг_К", "td_сдвиг_σ", "td_доля_в_σ", "td_σ_К", "td_std_Δ_К", "td_n_eff",
                    "t700_сдвиг_К", "t700_доля_в_σ", "t700_std_Δ_К", "t700_учтено"])
        for e in ptd:
            q = t7.get(e["name"])
            w.writerow([e["name"], e["lat"], e["lon"], round(e["z"]), e["src"], e["n"], round(e["bias"], 2), round(e["bias_sig"], 2), round(e["frac"], 3),
                        round(e["sd_mean"], 2), round(e["std"], 2), round(e["neff"], 1),
                        round(q["bias"], 2) if q else "", ("" if not q or not np.isfinite(q["frac"]) else round(q["frac"], 3)) if q else "",
                        round(q["std"], 2) if q else "", "да" if q else f"нет (z>{HIGH_Z:.0f} м)"])


def run_set(run):
    rows = place_rows(run)
    rows_t7 = [r for r in rows if r["z"] <= HIGH_Z]
    ptd, pt7 = per_place(rows, "td"), per_place(rows_t7, "t7")
    return rows, ptd, pt7


if __name__ == "__main__":
    out = {}
    summ = {}
    for key, run, csvname in (("forecast", "forecast_best_match", "places.csv"), ("summer", "summer_best_match", "places_summer.csv")):
        rows, ptd, pt7 = run_set(run)
        write_csv(f"{H}/{csvname}", ptd, pt7)
        rows_t7 = [r for r in rows if r["z"] <= HIGH_Z]
        dates = sorted({r["date"] for r in rows})
        summ[key] = dict(run=run, dates=[dates[0].isoformat(), dates[-1].isoformat()], horizon_days=max(r["lead"] for r in rows) + 1,
                         td=agg(ptd, "td"), t700=agg(pt7, "t7"), td_by_lead=lead_bins(rows, "td") if key == "forecast" else None,
                         t700_by_lead=lead_bins(rows_t7, "t7") if key == "forecast" else None)
        summ[key]["t700"]["places_excluded_high"] = sorted({r["name"] for r in rows if r["z"] > HIGH_Z})
        # пул по дням (для справки, без учёта корреляции — ДИ слишком узкий)
        d_ = np.array([(abs(r["f_td"] - r["c_td"]) < r["sd_td"]) for r in rows if np.isfinite(r["f_td"])])
        summ[key]["td"]["pooled_day_frac_no_cluster"] = float(d_.mean())
        # по группам: игра / доп
        for grp, sel in (("game", lambda e: e["src"] == "игра"), ("extra", lambda e: e["src"] != "игра")):
            summ[key]["td"][grp] = dict(places=sum(map(sel, ptd)), bias_k=float(np.mean([e["bias"] for e in ptd if sel(e)])), frac=float(np.mean([e["frac"] for e in ptd if sel(e)])))
    # чувствительность к модели прогноза
    sens = {}
    for run in ("forecast_gfs_seamless", "forecast_icon_seamless", "summer_gfs_seamless"):
        rows, ptd, pt7 = run_set(run)
        sens[run] = dict(td={k: v for k, v in agg(ptd, "td").items() if k in ("bias_k", "bias_ci95", "frac_within_sigma", "ci95", "places")},
                         t700={k: v for k, v in agg(pt7, "t7").items() if k in ("bias_k", "bias_ci95", "std_delta_k", "places")})
    f = summ["forecast"]
    out = dict(places=f["td"]["places"], horizon_days=f["horizon_days"], dates=f["dates"], td=f["td"], t700=f["t700"], summer=summ["summer"],
               td_by_lead=f["td_by_lead"], t700_by_lead=f["t700_by_lead"], model_sensitivity=sens, sigma_t700_available=HAVE_SD700,
               grid_years=dict(td=TD["years"], t700=UA["years"]), stations=[])
    if os.path.exists(H + "/stations.json"):
        out["stations"] = json.load(open(H + "/stations.json"))
    json.dump(out, open(H + "/summary.json", "w"), ensure_ascii=False, indent=1, default=str)
    print(json.dumps({k: out[k] for k in ("places", "horizon_days", "dates")}, ensure_ascii=False))
    for k in ("td", "t700"):
        print(k, json.dumps({a: b for a, b in out[k].items()}, ensure_ascii=False, default=str))
    print("by lead td", out["td_by_lead"]); print("by lead t700", out["t700_by_lead"])
    print("summer", json.dumps({k: summ["summer"][k] for k in ("td", "t700", "dates")}, ensure_ascii=False, default=str))
    print("sens", json.dumps(sens, ensure_ascii=False, default=str))
