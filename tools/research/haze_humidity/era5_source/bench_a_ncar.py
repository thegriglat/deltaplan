"""Замер скорости/объёма для A = ARCO 0.25° (full_37-1h-0p25deg-chunk-1.zarr-v3) и NCAR ERA5 (s3://nsf-ncar-era5, NetCDF4/HDF5) и сверка
почасового 0.25° T2m 2018-07-01 с CDS-почасовым (surface_t_cds/t2m_2018.nc, 0.25°). Вывод — json в stdout.
Запуск: python bench_a_ncar.py <a|ncar>"""
import sys, time, json, os, threading
import numpy as np
import xarray as xr

R = os.path.expanduser("~/data/haze_humidity")
mode = sys.argv[1]
# CDS 0.25°: первые сутки каждого месяца, по 24 ч: 2018-07-01 = индекс 6*24..6*24+23
ref = xr.open_dataset(f"{R}/surface_t_cds/t2m_2018.nc")
sl = slice(6 * 24, 7 * 24)
assert str(ref.valid_time.values[sl.start])[:13] == "2018-07-01T00"
refv = ref.t2m.isel(valid_time=sl).values  # (24,721,1440), lat 90..-90, lon 0..359.75
res = {"mode": mode}
NB = [0]; lock = threading.Lock()

if mode == "a":
    import zarr, gcsfs
    from concurrent.futures import ThreadPoolExecutor

    class CFS(gcsfs.GCSFileSystem):
        async def _cat_file(self, path, start=None, end=None, **kw):
            r = await super()._cat_file(path, start=start, end=end, **kw)
            with lock:
                NB[0] += len(r)
            return r
    g = zarr.open_consolidated(CFS(token="anon", requests_timeout=120).get_mapper("gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"), mode="r")
    h0 = int((np.datetime64("2018-07-01") - np.datetime64("1900-01-01")) / np.timedelta64(1, "h"))
    ttag = g["time"]; res["time_units"] = ttag.attrs.get("units"); res["time0"] = int(ttag[0])
    base = np.datetime64("1900-01-01") if "1900" in res["time_units"] else np.datetime64(res["time_units"].split("since ")[1].strip())
    h0 = int((np.datetime64("2018-07-01") - base) / np.timedelta64(1, "h")) - res["time0"]
    a = g["2m_temperature"]
    t = time.time()
    with ThreadPoolExecutor(4) as ex:
        x = np.stack(list(ex.map(lambda i: np.asarray(a[h0 + i]), range(24))))
    dt_ = time.time() - t
    res["t2m_day_24h_4thr"] = {"s": round(dt_, 1), "MB": round(NB[0] / 1e6, 1), "MB_per_s": round(NB[0] / 1e6 / dt_, 2)}
    d = x.astype(np.float64) - refv
    res["t2m_vs_cds_hourly_0p25"] = {"max_abs_K": float(np.abs(d).max()), "rmse_K": float(np.sqrt((d ** 2).mean())), "bias_K": float(d.mean())}
    # одна часть 3D: T на 700 гПа за 1 час (чанк = 37 уровней)
    NB[0] = 0
    lv = list(g["level"][:]).index(700)
    t = time.time(); y = np.asarray(g["temperature"][h0 + 12, lv]); dt_ = time.time() - t
    res["T700_one_hour_chunk"] = {"s": round(dt_, 1), "MB": round(NB[0] / 1e6, 1), "MB_per_s": round(NB[0] / 1e6 / dt_, 2), "mean_K": float(y.mean())}
else:
    import s3fs, h5py
    from s3fs.core import S3File
    orig = S3File._fetch_range

    def counted(self, start, end, *a, **k):
        r = orig(self, start, end, *a, **k)
        with lock:
            NB[0] += len(r)
        return r
    S3File._fetch_range = counted
    fs = s3fs.S3FileSystem(anon=True)
    P = "nsf-ncar-era5/"
    # T2m: один файл на месяц (744 ч), чанки (1,721,1440) — читаем сутки 2018-07-01
    t = time.time()
    f = h5py.File(fs.open(P + "e5.oper.an.sfc/201807/e5.oper.an.sfc.128_167_2t.ll025sc.2018070100_2018073123.nc", "rb", block_size=256 * 1024, cache_type="none"), "r")
    d_ = f["VAR_2T"] if "VAR_2T" in f else [v for k, v in f.items() if v.ndim == 3][0]
    res["t2m_file"] = {"var": d_.name, "shape": list(d_.shape), "chunks": list(d_.chunks), "dtype": str(d_.dtype), "open_s": round(time.time() - t, 1), "open_MB": round(NB[0] / 1e6, 2)}
    NB[0] = 0; t = time.time()
    x = np.stack([d_[i] for i in range(24)]).astype(np.float64)
    dt_ = time.time() - t
    res["t2m_day_24h_1thr"] = {"s": round(dt_, 1), "MB": round(NB[0] / 1e6, 1), "MB_per_s": round(NB[0] / 1e6 / dt_, 2)}
    d = x - refv
    res["t2m_vs_cds_hourly_0p25"] = {"max_abs_K": float(np.abs(d).max()), "rmse_K": float(np.sqrt((d ** 2).mean())), "bias_K": float(d.mean())}
    # 3D: T на 700 гПа за 1 час: чанк (1,37,721,1440)
    NB[0] = 0; t = time.time()
    f2 = h5py.File(fs.open(P + "e5.oper.an.pl/201807/e5.oper.an.pl.128_130_t.ll025sc.2018070100_2018070123.nc", "rb", block_size=256 * 1024, cache_type="none"), "r")
    lv = list(f2["level"][:]).index(700)
    open_mb = NB[0] / 1e6; NB[0] = 0
    y = f2["T"][12, lv]
    dt_ = time.time() - t
    res["T700_one_hour_chunk"] = {"s": round(dt_, 1), "MB": round(NB[0] / 1e6, 1), "open_MB": round(open_mb, 2), "MB_per_s": round(NB[0] / 1e6 / dt_, 2), "mean_K": float(y.mean()), "chunks": list(f2["T"].chunks)}
print(json.dumps(res, ensure_ascii=False, indent=1))
