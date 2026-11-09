#!/usr/bin/env python3
"""Скачать суточные 5-мин ISFS-файлы NetCDF двух дней случаев (~3 МБ файл) в каталог вне git.
python3 dl_isfs.py [каталог=~/data/lee_turb/isfs5]
Сервер: THREDDS U.Porto (без регистрации). На 2026-11-09 не отвечал (таймаут/502) — не проверено, что имя файла сервера верно:
имя взято из tools/research/data/perdigao/scripts/extract_profiles.py (isfs_qc_tiltcor_YYYYMMDD.nc)."""
import os, sys, urllib.parse, urllib.request
OUT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/lee_turb/isfs5")
BASE = "https://windsptds.fe.up.pt/thredds/fileServer/flux/"
DIR = "NCAR-EOL Quality Controlled 5-minute ISFS surface flux data, geographic coordinate, tilt corrected/"
os.makedirs(OUT, exist_ok=True)
for day in ("20170427", "20170511"):
    name = f"isfs_qc_tiltcor_{day}.nc"
    url = BASE + urllib.parse.quote(DIR + name)
    dst = os.path.join(OUT, name)
    if os.path.exists(dst):
        continue
    print("GET", url)
    urllib.request.urlretrieve(url, dst)
    print(dst, os.path.getsize(dst))
