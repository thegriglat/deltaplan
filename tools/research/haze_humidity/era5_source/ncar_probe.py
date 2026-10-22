"""Структура файлов NCAR ERA5 (s3://nsf-ncar-era5, анонимно): чанки HDF5, сжатие, масштаб. Только метаданные + один срез."""
import sys, time, s3fs, h5py
B = "nsf-ncar-era5/"
FILES = {
    "pl_t": "e5.oper.an.pl/201807/e5.oper.an.pl.128_130_t.ll025sc.2018070100_2018070123.nc",
    "sfc_2t": "e5.oper.an.sfc/201807/e5.oper.an.sfc.128_167_2t.ll025sc.2018070100_2018073123.nc",
}
fs = s3fs.S3FileSystem(anon=True)
key = sys.argv[1]
t = time.time()
f = h5py.File(fs.open(B + FILES[key], "rb", block_size=256 * 1024, cache_type="none"), "r")
print(key, "open", round(time.time() - t, 1), "s", flush=True)
for k, v in f.items():
    print("  ", k, v.shape, v.dtype, "chunks", v.chunks, "comp", v.compression, v.compression_opts, "shuffle", v.shuffle,
          {a: v.attrs[a] for a in ("scale_factor", "add_offset", "units", "long_name") if a in v.attrs}, flush=True)
d = [v for k, v in f.items() if v.ndim >= 3][0]
t = time.time()
x = d[0, 25] if d.ndim == 4 else d[0]
print("one slice", x.shape, x.dtype, "t", round(time.time() - t, 1), "s", flush=True)
if d.ndim == 4:
    print("level[25]", f["level"][25], flush=True)
print("time0", f["time"][:2], f["time"].attrs.get("units"), flush=True)
