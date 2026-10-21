"""Td дня против облачности и жары дня. Вход: ~/data/haze_humidity/daily/<г>.npz (td1, 00+12 UTC), ~/data/haze_humidity/td_sky/<г>.npz
(tcc, tmax, окно местных 10-16 ч), climatology.npz (sd, lsm). Выход: td_sky.json, td_sky.csv.
Запуск: python analyze.py"""
import os, sys, json, csv, glob, datetime as dt
import numpy as np

R = os.path.expanduser("~/data/haze_humidity")
HERE = os.path.dirname(os.path.abspath(__file__))
TH = (0.2, 0.6)  # clear < 0.2 <= partly <= 0.6 < overcast
BANDS = [(0, 20), (20, 40), (40, 60), (60, 75)]
SEAS = ["DJF", "MAM", "JJA", "SON"]
CATS = ["clear", "partly", "overcast"]
SITES = {"altai": (51.87, 85.87), "askarovo": (53.26, 58.54), "crimea": (44.95, 35.12), "darab": (28.75, 54.55), "cairns": (-16.92, 145.77)}
LAT = -89.5 + np.arange(180); LON = -179.5 + np.arange(360)

clim = np.load(f"{R}/climatology.npz")
SD = clim["sd"]  # [12,180,360] К
LAND = clim["lsm"] > 0.5
years = sorted(int(os.path.basename(f)[:4]) for f in glob.glob(f"{R}/td_sky/[12]*.npz") if "tmp" not in f)
if len(sys.argv) > 1: years = [y for y in years if y in map(int, sys.argv[1:])]
print("годы", years)
# ---- проход 1: среднее по месяцам выборки (ячейка, месяц) для Td и Tmax; по годам, чтобы не держать всё в памяти
def month_idx(y, n): return np.array([(dt.date(y, 1, 1) + dt.timedelta(k)).month - 1 for k in range(n)])
def load(y):
    a = np.load(f"{R}/daily/{y}.npz")["td1"]; b = np.load(f"{R}/td_sky/{y}.npz")
    bad = np.isnan(a).all((1, 2)) | np.isnan(b["tcc"]).all((1, 2)) | np.isnan(b["tmax"]).all((1, 2))
    return a, b["tcc"], b["tmax"], month_idx(y, len(a)), bad
s_td = np.zeros((12, 180, 360)); s_tx = np.zeros((12, 180, 360)); cnt = np.zeros((12, 180, 360))
for y in years:
    a, c, x, mo, bad = load(y)
    ok = np.isfinite(c) & np.isfinite(x) & np.isfinite(a)  # ARCO дал NaN в части (день, долгота): учитываем только полные ячейки-дни
    for m in range(12):
        sel = (mo == m) & ~bad
        o = ok[sel]
        s_td[m] += np.where(o, a[sel], 0).sum(0); s_tx[m] += np.where(o, x[sel], 0).sum(0); cnt[m] += o.sum(0)
with np.errstate(invalid="ignore"):
    M_TD = s_td / cnt; M_TX = s_tx / cnt
with np.errstate(invalid="ignore"): pass
bias = M_TD - clim["td"]  # сдвиг средней выборки против 30-летней, К
print("сдвиг средней Td выборки против 1991-2020 (суша), К:", float(np.nanmean(bias[:, LAND])))
sig = np.maximum(SD, 0.3)  # σ ячейки-месяца (на суше σ ≥ 0.26 К; страховка от деления на ~0)
W = np.cos(np.radians(LAT))[:, None] * np.ones((1, 360))
band_of = np.full(180, -1)
for b, (lo, hi) in enumerate(BANDS): band_of[(np.abs(LAT) >= lo) & (np.abs(LAT) < hi)] = b
hem_of = (LAT < 0).astype(int)
season_of_m = np.array([0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0])


def sums(w, x, y, u):
    """суммы по набору точек: w; 1,x,y произведения с w (К) и с w*u (u=1/σ²); y/σ"""
    wu = w * u
    return np.array([w.sum(), (w * x).sum(), (w * y).sum(), (w * x * x).sum(), (w * x * y).sum(), (w * y * y).sum(),
                     wu.sum(), (wu * x).sum(), (wu * y).sum(), (wu * x * x).sum(), (wu * x * y).sum(), (wu * y * y).sum(),
                     (w * y * np.sqrt(u)).sum(), (w * y * y * u).sum()])


ACC = np.zeros((len(years), 2, 4, 4, 3, 14))
SITE = {n: np.zeros((4, 3, 14)) for n in SITES}
SIJ = {n: (int(np.floor(la + 90)), int(np.floor(lo + 180))) for n, (la, lo) in SITES.items()}
for iy, y in enumerate(years):
    a, tc, tx, mo, bad = load(y)
    for m in range(12):
        s = np.where((mo == m) & ~bad)[0]
        if len(s) == 0: continue
        ay = a[s] - M_TD[m]; ax = tx[s] - M_TX[m]
        okm = np.isfinite(ay) & np.isfinite(ax) & np.isfinite(tc[s])
        cat = np.where(~okm, -1, np.where(tc[s] < TH[0], 0, np.where(tc[s] <= TH[1], 1, 2)))
        u = 1 / sig[m] ** 2
        for n, (j, i) in SIJ.items():
            for c in range(3):
                sel = cat[:, j, i] == c
                if sel.any(): SITE[n][season_of_m[m], c] += sums(np.ones(sel.sum()), ax[sel, j, i], ay[sel, j, i], np.full(sel.sum(), u[j, i]))
        for h in range(2):
            for b in range(4):
                rows = (hem_of == h) & (band_of == b)
                if not rows.any(): continue
                lm = LAND[rows]
                for c in range(3):
                    sel = (cat[:, rows] == c) & lm[None]
                    if not sel.any(): continue
                    wv = np.broadcast_to(W[rows], sel.shape)[sel]
                    uv = np.broadcast_to(u[rows], sel.shape)[sel]
                    ACC[iy, h, b, season_of_m[m], c] += sums(wv, ax[:, rows][sel], ay[:, rows][sel], uv)
    print("год", y, flush=True)
np.save(f"{HERE}/acc_cache.npy", ACC)
# ---- свёртка
def stats(S):
    """S[..., cat, 14] (суммы по гем/годам) -> dict по категориям + β"""
    S = np.asarray(S)
    w = S[:, 0]
    frac = w / w.sum()
    xm = S[:, 1] / w; ym = S[:, 2] / w
    sxx = S[:, 3] - w * xm ** 2; sxy = S[:, 4] - w * xm * ym; syy = S[:, 5] - w * ym ** 2
    beta = sxy.sum() / sxx.sum()
    beta_c = sxy / sxx
    mu_k = ym
    mu_s = S[:, 12] / w
    sig_k = np.sqrt(syy / w)  # внутриклассовое σ, К
    # остаток в σ: r = y - c - beta*x, c = ym - beta*xm
    c = ym - beta * xm
    ws = S[:, 6]
    r2 = S[:, 11] - 2 * beta * S[:, 10] + beta ** 2 * S[:, 9] - 2 * c * S[:, 8] + 2 * c * beta * S[:, 7] + c ** 2 * ws
    res = np.sqrt(r2 / w)
    dsd = np.sqrt((S[:, 13] / w) - mu_s ** 2)  # σ_Td/σ внутри категории без β
    # μ при климатической Tmax (без центрирования x): (ym - beta*xm)/σ_cat, σ_cat=средний σ = sqrt(w/ws)
    sigb = np.sqrt(w / ws)
    mu_unc = c / sigb
    return dict(frac=frac, mu_sigma=mu_s, mu_k=mu_k, beta=beta, beta_cat=beta_c, res_ratio=res, noβ_ratio=dsd, dtmax_k=xm,
                mu_sigma_uncentered=mu_unc, n_w=w, sigma_mean_k=sigb)


def combine(ACCy, hems=(0, 1), phys=True):
    out = {}
    for b in range(4):
        for s in range(4):
            tot = 0
            for h in hems:
                sp = (s + 2) % 4 if (phys and h == 1) else s  # физический сезон: юг сдвинут на полгода
                # физ. сезон s на юге = календарный (s+2)%4
                tot = tot + ACCy[h, b, sp]
            out[(b, s)] = tot
    return out


full = ACC.sum(0)
comb = combine(full)
# джекнайф по годам
NY = len(years)
jk = [combine(full - ACC[i]) for i in range(NY)]
res = {}
for (b, s), S in comb.items():
    st = stats(S)
    se = {}
    vals = [stats(j[(b, s)]) for j in jk]
    for k in ("frac", "mu_sigma", "mu_k", "res_ratio", "dtmax_k", "mu_sigma_uncentered"):
        arr = np.array([v[k] for v in vals])
        se[k] = np.sqrt((NY - 1) / NY * ((arr - arr.mean(0)) ** 2).sum(0))
    arr = np.array([v["beta"] for v in vals]); se["beta"] = float(np.sqrt((NY - 1) / NY * ((arr - arr.mean()) ** 2).sum()))
    res[(b, s)] = (st, se)

# ---- места
sites_out = {}
for name in SITES:
    j, i = SIJ[name]
    sd_site = {sn: stats(SITE[name][sn]) for sn in range(4) if (SITE[name][sn][:, 0] > 0).all()}
    sites_out[name] = (j, i, bool(LAND[j, i]), float(clim["lsm"][j, i]), sd_site)

# ---- вывод
def f(a, nd=3): return [round(float(v), nd) for v in a]
J = dict(bands=[list(b) for b in BANDS], seasons=SEAS, season_note="|lat| сливает полушария по физическому сезону: на юге DJF = календарные JJA (зима/лето совпадают с севером)",
         cat_thresholds_tcc=list(TH), years=[years[0], years[-1]], sky={}, beta_k_per_k=[[0] * 4 for _ in range(4)])
for ci, c in enumerate(CATS):
    J["sky"][c] = dict(mu_sigma=[[0] * 4 for _ in range(4)], mu_k=[[0] * 4 for _ in range(4)], frac=[[0] * 4 for _ in range(4)],
                        res_ratio=[[0] * 4 for _ in range(4)], dtmax_k=[[0] * 4 for _ in range(4)],
                        mu_sigma_uncentered=[[0] * 4 for _ in range(4)], se_mu_sigma=[[0] * 4 for _ in range(4)], beta_cat=[[0] * 4 for _ in range(4)])
    for (b, s), (st, se) in res.items():
        d = J["sky"][c]
        d["mu_sigma"][b][s] = round(float(st["mu_sigma"][ci]), 3); d["mu_k"][b][s] = round(float(st["mu_k"][ci]), 3)
        d["frac"][b][s] = round(float(st["frac"][ci]), 3); d["res_ratio"][b][s] = round(float(st["res_ratio"][ci]), 3)
        d["dtmax_k"][b][s] = round(float(st["dtmax_k"][ci]), 3); d["mu_sigma_uncentered"][b][s] = round(float(st["mu_sigma_uncentered"][ci]), 3)
        d["se_mu_sigma"][b][s] = round(float(se["mu_sigma"][ci]), 3); d["beta_cat"][b][s] = round(float(st["beta_cat"][ci]), 3)
for (b, s), (st, se) in res.items():
    J["beta_k_per_k"][b][s] = round(float(st["beta"]), 3)
# сводка по всему миру (суша 0-75) для рекомендации
allS = sum(comb.values())
sa = stats(allS)
J["pooled_all"] = dict(frac=f(sa["frac"]), mu_sigma=f(sa["mu_sigma"]), mu_k=f(sa["mu_k"]), beta=round(float(sa["beta"]), 3), beta_cat=f(sa["beta_cat"]),
                       res_ratio=f(sa["res_ratio"]), dtmax_k=f(sa["dtmax_k"]), mu_sigma_uncentered=f(sa["mu_sigma_uncentered"]))
J["sites"] = {n: dict(cell_j=v[0], cell_i=v[1], land=v[2], lsm=round(v[3], 2),
                      seasons={SEAS[s]: dict(frac=f(st["frac"]), mu_sigma=f(st["mu_sigma"]), mu_k=f(st["mu_k"]), beta=round(float(st["beta"]), 3),
                                             res_ratio=f(st["res_ratio"]), dtmax_k=f(st["dtmax_k"]), mu_sigma_uncentered=f(st["mu_sigma_uncentered"]))
                               for s, st in v[4].items()}) for n, v in sites_out.items()}
J["td_bias_sample_vs_30y_k"] = round(float(np.nanmean(bias[:, LAND])), 3)
json.dump(J, open(f"{HERE}/td_sky.json", "w"), indent=1, ensure_ascii=False)
with open(f"{HERE}/td_sky.csv", "w", newline="") as fh:
    wr = csv.writer(fh)
    wr.writerow(["scope", "band_or_site", "season", "sky", "frac", "mu_sigma", "se_mu_sigma", "mu_k", "mu_sigma_uncentered", "res_ratio", "dtmax_k", "beta_pooled", "beta_cat"])
    for (b, s), (st, se) in res.items():
        for ci, c in enumerate(CATS):
            wr.writerow(["band", f"{BANDS[b][0]}-{BANDS[b][1]}", SEAS[s], c, *[round(float(v), 3) for v in (st["frac"][ci], st["mu_sigma"][ci], se["mu_sigma"][ci], st["mu_k"][ci],
                         st["mu_sigma_uncentered"][ci], st["res_ratio"][ci], st["dtmax_k"][ci], st["beta"], st["beta_cat"][ci])]])
    for n, v in sites_out.items():
        for s, st in v[4].items():
            for ci, c in enumerate(CATS):
                wr.writerow(["site", n, SEAS[s], c, *[round(float(x), 3) for x in (st["frac"][ci], st["mu_sigma"][ci], np.nan, st["mu_k"][ci],
                             st["mu_sigma_uncentered"][ci], st["res_ratio"][ci], st["dtmax_k"][ci], st["beta"], st["beta_cat"][ci])]])
print(json.dumps(J["pooled_all"], ensure_ascii=False))
