"""RAW/upper_misc_cds/*.nc -> RAW/upper_misc_cds_clim.npz (ячейки 1° HH, 2011–2020).
 HCC, V10 — sl_monthly.nc (monthly_averaged_reanalysis; 10m_wind_speed = среднее модулей), климатология = среднее по годам; hcc_sem = σ межгодовых средних/√n.
 WR = <|V700|>/<V10>: |V700| = модуль суточного среднего вектора (ARCO-ERA5 1°, era5_arco/{u,v}_component_of_wind_700/*.npz, 2018–2019), усреднён по суткам месяца (занижает среднее модуля — см. README); V10 — за те же годы.
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
    # |V700|: суточные среднее u, v из ARCO-ERA5 1° (HH-18), 2018–2019; сутки с NaN (7 суток v) пропускаются целиком
    import datetime as dt
    A = os.path.expanduser(RAW) + "/era5_arco"
    S = np.zeros((12, 180, 360)); Nn = np.zeros(12); years = []; ys = {}; skipped = []
    for y in (2018, 2019):
        for k in range((dt.date(y + 1, 1, 1) - dt.date(y, 1, 1)).days):
            d = dt.date(y, 1, 1) + dt.timedelta(k)
            fu, fv = (f"{A}/{n}_component_of_wind_700/{d}.npz" for n in "uv")
            if not (os.path.exists(fu) and os.path.exists(fv)): skipped.append((str(d), "нет файла")); continue
            u, v = (np.load(f)["mean"].astype(np.float64).T[::-1] for f in (fu, fv))  # [lon,lat -90..90] -> [lat 90..-90, lon 0..359]
            if np.isnan(u).any() or np.isnan(v).any(): skipped.append((str(d), "NaN")); continue
            sp = cells(np.hypot(u, v)); m = d.month - 1
            S[m] += sp; Nn[m] += 1
            e = ys.setdefault((y, m), [0, 0]); e[0] = e[0] + sp; e[1] += 1
        years.append(y)
    print("пропущено суток:", skipped, flush=True)
    # разность двух лет месячных средних |V700| (оценка погрешности короткого ряда)
    dy = np.full((12, 180, 360), np.nan)
    for m in range(12):
        dy[m] = ys[(2018, m)][0] / ys[(2018, m)][1] - ys[(2019, m)][0] / ys[(2019, m)][1]
    v10s = np.array([v10[(mo == m) & np.isin(yr, years)].mean(0) for m in range(12)])  # V10 за те же годы, что |V700|
    v7 = S / Nn[:, None, None]; wr = v7 / v10s
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
             n_days=Nn, v7_diff_2018_2019=dy, v10_2018_2019=v10s, years=np.array([int(yr.min()), int(yr.max())]), v7_years=np.array(years))
    print("годы", yr.min(), yr.max(), "u700 лет", len(years), "wr", wr.min(), wr.max(), "hcc", hcc.min(), hcc.max())
