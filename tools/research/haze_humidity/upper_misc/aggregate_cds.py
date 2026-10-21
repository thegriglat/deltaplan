"""RAW/upper_misc_cds/{pl,sl}_<год>.nc (сутки 00+12 UTC, 1°) и tz_2011.nc (месячные T,Z на 500…50 гПа) -> RAW/upper_misc_cds_clim.npz.
WR = <|V700|>/<|V10|> за месяц (средние модулей, 00+12 UTC всех суток 2011–2020); HCC — среднее/медиана/доля суток <0,1 (среднее 00+12);
TROP — тропопауза ВМО по среднему профилю месяца. Узлы CDS 1° -> ячейки HH (центры ±0.5°): среднее 4 соседних узлов. Запуск: python aggregate_cds.py"""
import os, glob, numpy as np, xarray as xr
from common import RAW
R = os.path.expanduser(RAW); C = R + "/upper_misc_cds"
G = 9.80665


def cells(a):
    """(..., 181 lat 90->-90, 360 lon 0..359) -> (..., 180 lat юг->север, 360 lon с -179.5)."""
    a = a[..., ::-1, :]  # lat -90..90
    a = np.roll(a, 180, axis=-1)  # lon -180..179
    a = 0.5 * (a[..., :-1, :] + a[..., 1:, :])
    return 0.5 * (a + np.roll(a, -1, axis=-1))


def var(ds, *names):
    for n in names:
        if n in ds: return ds[n]
    raise KeyError(names)


def tvar(ds):
    return [d for d in ("valid_time", "time") if d in ds.dims][0]


def tropopause(T, z):
    """T[L,N] К, z[L,N] м (снизу вверх). Тропопауза ВМО: нижний уровень, где градиент <= 2 К/км, и средний градиент до любого уровня в слое 2 км выше <= 2 К/км.
    Возвращает (м, найдена?). T(z) — линейно между уровнями."""
    L, N = T.shape
    gam = -(T[1:] - T[:-1]) / (z[1:] - z[:-1]) * 1000  # K/km по слоям (L-1)
    out = np.full(N, np.nan)
    for k in range(L - 1):
        cand = np.isnan(out) & (gam[k] <= 2.0)
        if not cand.any(): continue
        # нижняя точка: пересечение 2 К/км между серединами слоёв k-1 и k; для k=0 — нижний уровень
        zt = z[k].copy()
        if k > 0:
            m0 = 0.5 * (z[k - 1] + z[k]); m1 = 0.5 * (z[k] + z[k + 1])
            w = np.clip((gam[k - 1] - 2.0) / np.maximum(gam[k - 1] - gam[k], 1e-9), 0, 1)
            zt = np.where(gam[k - 1] > 2.0, m0 + w * (m1 - m0), z[k])
            zt = np.clip(zt, z[k - 1], z[k + 1])
        Tt = np.where(zt <= z[k], T[k] + (T[k - 1] - T[k]) * (z[k] - zt) / np.maximum(z[k] - z[k - 1], 1e-9) if k > 0 else T[k], T[k] + (T[k + 1] - T[k]) * (zt - z[k]) / (z[k + 1] - z[k]))
        ok = cand.copy()
        for j in range(k + 1, L):
            zj = np.minimum(z[j], zt + 2000.0)
            Tj = np.interp_ = None
            # T на zj: линейно в слое [j-1, j]
            lo = z[j - 1]; frac = np.clip((zj - lo) / (z[j] - lo), 0, 1)
            Tj = T[j - 1] + (T[j] - T[j - 1]) * frac
            gj = -(Tj - Tt) / np.maximum(zj - zt, 1.0) * 1000
            ok &= ~((z[j - 1] < zt + 2000.0) & (gj > 2.0))
            if not (z[j - 1] < zt + 2000.0).any(): break
        out = np.where(ok & np.isnan(out), zt, out)
    found = ~np.isnan(out)
    return out, found


if __name__ == "__main__":
    S = {m: [0.0, 0.0, 0] for m in range(12)}  # сумма |V700|, |V10|, число
    H = [[] for _ in range(12)]
    years = []
    for f in sorted(glob.glob(C + "/pl_*.nc")):
        y = int(f[-7:-3]); fs = C + f"/sl_{y}.nc"
        if not os.path.exists(fs): continue
        pl, sl = xr.open_dataset(f), xr.open_dataset(fs)
        tp, ts = tvar(pl), tvar(sl)
        assert (pl[tp].values == sl[ts].values).all(), "оси времени pl/sl разные"
        t = pl[tp].values.astype("datetime64[M]").astype(int) % 12  # месяц 0..11
        u7, v7 = var(pl, "u").squeeze().values, var(pl, "v").squeeze().values
        s7 = cells(np.hypot(u7, v7)); s10 = cells(np.hypot(var(sl, "u10").values, var(sl, "v10").values)); hc = cells(var(sl, "hcc").values)
        for m in range(12):
            i = np.where(t == m)[0]
            S[m][0] = S[m][0] + s7[i].sum(0); S[m][1] = S[m][1] + s10[i].sum(0); S[m][2] += len(i)
            # среднее 00+12 UTC по суткам: подряд идущие пары
            h = hc[i]; H[m].append(0.5 * (h[0::2] + h[1::2]))
        years.append(y); print(y, flush=True)
    n = np.array([S[m][2] for m in range(12)])
    wr = np.array([S[m][0] / S[m][1] for m in range(12)])
    v7m = np.array([S[m][0] / S[m][2] for m in range(12)]); v10m = np.array([S[m][1] / S[m][2] for m in range(12)])
    Hm = [np.concatenate(h) for h in H]
    hcc = np.array([h.mean(0) for h in Hm]); hmed = np.array([np.median(h, 0) for h in Hm])
    hlt = np.array([(h < 0.1).mean(0) for h in Hm]); hsem = np.array([h.std(0, ddof=1) / np.sqrt(len(h)) for h in Hm])
    # тропопауза
    tz = xr.open_dataset(C + "/tz_2011.nc"); tt = tvar(tz); lev = [d for d in ("pressure_level", "level") if d in tz.dims][0]
    order = np.argsort(-tz[lev].values)  # 500 -> 50 гПа
    T = var(tz, "t").transpose(tt, lev, "latitude", "longitude").values[:, order]; Z = var(tz, "z").transpose(tt, lev, "latitude", "longitude").values[:, order] / G
    mon = tz[tt].values.astype("datetime64[M]").astype(int) % 12
    trop = np.zeros((12, 180, 360)); found = np.zeros((12, 180, 360), bool)
    for m in range(12):
        Tm, Zm = cells(T[mon == m].mean(0)), cells(Z[mon == m].mean(0))
        L = Tm.shape[0]
        tr, fd = tropopause(Tm.reshape(L, -1), Zm.reshape(L, -1))
        trop[m] = tr.reshape(180, 360); found[m] = fd.reshape(180, 360)
    print("тропопауза найдена", found.mean(), "мин/макс", np.nanmin(trop), np.nanmax(trop), flush=True)
    np.savez(R + "/upper_misc_cds_clim.npz", wr=wr, v7=v7m, v10=v10m, hcc=hcc, hcc_med=hmed, hcc_lt01=hlt, hcc_sem=hsem, trop=trop, trop_found=found,
             n=n, years=np.array([min(years), max(years)]), n_years=len(years))
    print("годы", min(years), max(years), "n/мес", n.tolist(), "wr", wr.min(), wr.max(), "hcc", hcc.min(), hcc.max())
