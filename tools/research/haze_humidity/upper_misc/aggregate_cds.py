"""RAW/upper_misc_cds/*.nc -> RAW/upper_misc_cds_clim.npz (ячейки 1° HH, 2011–2020).
 HCC, V10 — sl_monthly.nc (monthly_averaged_reanalysis; 10m_wind_speed = среднее модулей), климатология = среднее по годам; hcc_sem = σ межгодовых средних/√n.
 WR = <|V700|>/<V10>: |V700| = модуль суточного среднего вектора (u700_<г>.nc, daily_mean), усреднён по суткам месяца (занижает среднее модуля — см. README).
 TROP — тропопауза ВМО по среднему за месяц профилю T, Z (tz.nc, 500…50 гПа; среднее по годам), не среднее суточных.
Узлы CDS 1° -> ячейки HH (центры ±0.5°): среднее 4 соседних узлов. Запуск: python aggregate_cds.py"""
import os, glob, numpy as np, xarray as xr
from common import RAW
R = os.path.expanduser(RAW); C = R + "/upper_misc_cds"
G = 9.80665


def cells(a):
    """(..., 181 lat 90->-90, 360 lon 0..359) -> (..., 180 lat юг->север, 360 lon с -179.5)."""
    a = a[..., ::-1, :]
    a = np.roll(a, 180, axis=-1)
    a = 0.5 * (a[..., :-1, :] + a[..., 1:, :])
    return 0.5 * (a + np.roll(a, -1, axis=-1))


def tvar(ds): return [d for d in ("valid_time", "time") if d in ds.dims][0]


def tropopause(T, z):
    """T[L,N] К, z[L,N] м, снизу вверх (L=14). ВМО: нижний уровень k, где градиент слоя (k,k+1) <= 2 К/км и средний градиент от k до каждого уровня
    не выше z_k+2 км <= 2 К/км. Уточнение: пересечение 2 К/км линейно между серединами слоёв. Возвращает (м, найдена)."""
    L, N = T.shape
    gam = -(T[1:] - T[:-1]) / (z[1:] - z[:-1]) * 1000
    out = np.full(N, np.nan)
    for k in range(1, L - 1):
        ok = np.isnan(out) & (gam[k] <= 2.0)
        for j in range(k + 1, L):
            inl = (z[j] - z[k]) <= 2000.0
            g = -(T[j] - T[k]) / (z[j] - z[k]) * 1000
            ok &= ~(inl & (g > 2.0))
        if not ok.any(): continue
        m0 = 0.5 * (z[k - 1] + z[k]); m1 = 0.5 * (z[k] + z[k + 1])
        w = np.clip((gam[k - 1] - 2.0) / np.maximum(gam[k - 1] - gam[k], 1e-9), 0, 1)
        zt = np.clip(m0 + w * (m1 - m0), z[k - 1], z[k + 1])
        out = np.where(ok, zt, out)
    return out, ~np.isnan(out)


if __name__ == "__main__":
    sl = xr.open_dataset(C + "/sl_monthly.nc"); t = sl[tvar(sl)].values.astype("datetime64[M]")
    mo = t.astype(int) % 12; yr = t.astype("datetime64[Y]").astype(int) + 1970
    hc = cells(sl["hcc"].values.astype(np.float64)); v10 = cells(sl["si10"].values.astype(np.float64))
    hcc = np.array([hc[mo == m].mean(0) for m in range(12)]); v10m = np.array([v10[mo == m].mean(0) for m in range(12)])
    hsem = np.array([hc[mo == m].std(0, ddof=1) / np.sqrt((mo == m).sum()) for m in range(12)])
    # |V700|
    S = np.zeros((12, 180, 360)); S2 = np.zeros((12, 180, 360)); Nn = np.zeros(12); years = []
    ys = {}  # (год, месяц) -> [сумма |V700|, число суток] для межгодового разброса двух лет
    for y in (2018, 2019):
        for h in (1, 2):
            fu, fv = (C + f"/uv700_{y}_h{h}_{c}.nc" for c in "uv")
            if not (os.path.exists(fu) and os.path.exists(fv)): continue
            du, dv = xr.open_dataset(fu), xr.open_dataset(fv)
            tt = du[tvar(du)].values.astype("datetime64[M]").astype(int) % 12
            sp = cells(np.hypot(du["u"].squeeze().values, dv["v"].squeeze().values).astype(np.float64))
            for m in range(12):
                i = tt == m
                if i.any():
                    S[m] += sp[i].sum(0); Nn[m] += i.sum(); ys.setdefault((y, m), [0, 0]); ys[(y, m)][1] += i.sum()
                    ys[(y, m)][0] = ys[(y, m)][0] + sp[i].sum(0)
            if y not in years: years.append(y)
            print(fu, flush=True)
    # разность двух лет месячных средних |V700| (оценка погрешности короткого ряда)
    dy = np.full((12, 180, 360), np.nan)
    if len(years) == 2 and all((y, m) in ys for y in years for m in range(12)):
        for m in range(12):
            dy[m] = ys[(2018, m)][0] / ys[(2018, m)][1] - ys[(2019, m)][0] / ys[(2019, m)][1]
    if years:
        v10s = np.array([v10[(mo == m) & np.isin(yr, years)].mean(0) for m in range(12)])  # V10 за те же годы, что |V700|
        v7 = S / Nn[:, None, None]; wr = v7 / v10s
    else:  # суточные |V700| не загружены (шлюз Q4) — WR в сетку не идёт, bake.py ставит заглушку и stub_mask=1
        v7 = wr = np.full((12, 180, 360), np.nan)
    # тропопауза
    tz = xr.open_dataset(C + "/tz.nc"); tt = tvar(tz); lev = [d for d in ("pressure_level", "level") if d in tz.dims][0]
    order = np.argsort(-tz[lev].values)
    T = tz["t"].transpose(tt, lev, "latitude", "longitude").values[:, order].astype(np.float64)
    Z = tz["z"].transpose(tt, lev, "latitude", "longitude").values[:, order].astype(np.float64) / G
    mon = tz[tt].values.astype("datetime64[M]").astype(int) % 12
    trop = np.zeros((12, 180, 360)); found = np.zeros((12, 180, 360), bool)
    for m in range(12):
        Tm, Zm = cells(T[mon == m].mean(0)), cells(Z[mon == m].mean(0)); L = Tm.shape[0]
        tr, fd = tropopause(Tm.reshape(L, -1), Zm.reshape(L, -1))
        trop[m] = np.where(fd, tr, 19000.0).reshape(180, 360); found[m] = fd.reshape(180, 360)
    print("тропопауза найдена", found.mean(), "мин/макс", trop.min(), trop.max(), flush=True)
    np.savez(R + "/upper_misc_cds_clim.npz", wr=wr, v7=v7, v10=v10m, hcc=hcc, hcc_sem=hsem, trop=trop, trop_found=found,
             n_days=Nn, v7_diff_2018_2019=dy, years=np.array([int(yr.min()), int(yr.max())]), v7_years=np.array(years))
    print("годы", yr.min(), yr.max(), "u700 лет", len(years), "wr", wr.min(), wr.max(), "hcc", hcc.min(), hcc.max())
