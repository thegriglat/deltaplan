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
    S = np.zeros((12, 180, 360)); Nn = np.zeros(12); years = []
    for f in sorted(glob.glob(C + "/u700_*.nc")):
        d = xr.open_dataset(f); tt = d[tvar(d)].values.astype("datetime64[M]").astype(int) % 12
        sp = cells(np.hypot(d["u"].squeeze().values, d["v"].squeeze().values).astype(np.float64))
        for m in range(12):
            i = tt == m; S[m] += sp[i].sum(0); Nn[m] += i.sum()
        years.append(int(f[-7:-3])); print(f, flush=True)
    v7 = S / Nn[:, None, None]; wr = v7 / v10m
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
             n_days=Nn, years=np.array([int(yr.min()), int(yr.max())]), v7_years=np.array(years))
    print("годы", yr.min(), yr.max(), "u700 лет", len(years), "wr", wr.min(), wr.max(), "hcc", hcc.min(), hcc.max())
