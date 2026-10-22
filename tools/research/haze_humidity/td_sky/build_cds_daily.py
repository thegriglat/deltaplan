"""CDS daily-statistics (fetch_cds_daily.py) -> ~/data/haze_humidity/td_sky/<год>.npz: tccday (daily_mean, UTC-сутки), tmax (daily_maximum, °C), tcc = tccday.
Ячейка 1° HH-1 = среднее 4 узлов сетки 360x181 вокруг центра. Запуск: python build_cds_daily.py <год> [<год1>] | compare (2013-06 против ARCO 2013.npz)"""
import os, sys, json, calendar
import numpy as np, xarray as xr
D = os.path.expanduser("~/data/haze_humidity/td_sky"); C = D + "/cds"
I0 = (np.arange(360) - 180) % 360; I1 = (np.arange(360) - 179) % 360


def cells(x):  # [t, lat 181, lon 360] (lat -90..90, lon 0..359) -> [t,180,360]
    y = (x[:, :, I0] + x[:, :, I1]) / 2
    return (y[:, :-1] + y[:, 1:]) / 2


def load(fn):
    ds = xr.open_dataset(fn)
    v = [k for k in ds.data_vars][0]; a = ds[v]
    tn = [d for d in a.dims if d not in ("latitude", "longitude")][0]
    a = a.sortby(tn).sortby("latitude").sortby("longitude")
    assert a.shape[1:] == (181, 360) and abs(float(a.latitude[0]) + 90) < 1e-3 and abs(float(a.longitude[0])) < 1e-3, a.shape
    return cells(a.values.astype(np.float32))


def month(key, y, m): return load(f"{C}/{key}_{y}-{m:02d}.nc")


def do_year(y):
    fn = f"{D}/{y}.npz"
    if os.path.exists(fn): return
    c = np.concatenate([month("tcc", y, m) for m in range(1, 13)]); t = np.concatenate([month("tmax", y, m) for m in range(1, 13)]) - 273.15
    assert len(c) == (366 if calendar.isleap(y) else 365)
    np.savez(fn + ".tmp.npz", tcc=c, tccday=c, tmax=t); os.replace(fn + ".tmp.npz", fn); print(y, "ok", flush=True)


def compare():
    land = np.load(os.path.expanduser("~/data/haze_humidity/climatology.npz"))["lsm"] > 0.5
    w = np.cos(np.radians(-89.5 + np.arange(180)))[:, None] * np.ones((1, 360))
    c = month("tcc", 2013, 6); t = month("tmax", 2013, 6) - 273.15
    z = np.load(f"{D}/2013.npz"); k0 = 151
    A = {"tccday": z["tccday"][k0:k0 + 30], "tmax": z["tmax"][k0:k0 + 30], "tcc": z["tcc"][k0:k0 + 30]}
    out = {}
    cat = lambda x: np.where(x < .2, 0, np.where(x <= .6, 1, 2))
    for n, x, ref in (("tccday", c, A["tccday"]), ("tmax", t, A["tmax"])):
        d = x - ref
        for nm, msk in (("all", np.ones_like(land)), ("land", land)):
            m = np.isfinite(d) & msk[None]; ww = np.broadcast_to(w, d.shape)[m]
            out[f"{n}_{nm}_bias"] = float((d[m] * ww).sum() / ww.sum()); out[f"{n}_{nm}_rmsd"] = float(np.sqrt((d[m] ** 2 * ww).sum() / ww.sum()))
            out[f"{n}_{nm}_corr"] = float(np.corrcoef(x[m], ref[m])[0, 1])
    m = land[None] & np.isfinite(A["tccday"]) & np.isfinite(c)
    out["class_agree_land_cds_vs_arco_tccday"] = float((cat(c) == cat(A["tccday"]))[m].mean())
    json.dump(out, open(os.path.dirname(os.path.abspath(__file__)) + "/cds_vs_arco.json", "w"), indent=1); print(json.dumps(out, indent=1))


def category_shift():
    """ARCO 2011-13: доля дней суши, сменивших класс при замене окна 10-16 ч (tcc) на сутки (tccday)"""
    land = np.load(os.path.expanduser("~/data/haze_humidity/climatology.npz"))["lsm"] > 0.5
    cat = lambda x: np.where(x < .2, 0, np.where(x <= .6, 1, 2))
    ch = n = 0; tr = np.zeros((3, 3)); W = np.cos(np.radians(-89.5 + np.arange(180)))[:, None] * np.ones((1, 360)) * land
    for y in (2011, 2012, 2013):
        z = np.load(f"{D}/{y}.npz"); a, b = z["tcc"], z["tccday"]; ok = np.isfinite(a) & np.isfinite(b)
        ca, cb = cat(a), cat(b)
        for i in range(3):
            for j in range(3): tr[i, j] += (((ca == i) & (cb == j) & ok) * W[None]).sum()
    tr /= tr.sum()
    out = {"share_changed_class": float(1 - np.trace(tr)), "transition_window_to_day": tr.round(4).tolist(), "classes": ["clear", "partly", "overcast"]}
    json.dump(out, open(os.path.dirname(os.path.abspath(__file__)) + "/class_shift_window_vs_day.json", "w"), indent=1); print(out)


if __name__ == "__main__":
    if sys.argv[1] == "compare": compare()
    elif sys.argv[1] == "shift": category_shift()
    else:
        for y in range(int(sys.argv[1]), int(sys.argv[-1]) + 1): do_year(y)
