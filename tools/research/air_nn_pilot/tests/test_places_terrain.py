#!/usr/bin/env python3
"""Загрузчик мест t_* (places.py, П6 v1): форма h, info, context, hc400 = блочное среднее решателя побитно.

На подставном каталоге (tests/make_fake_p6.py, 3 места во временном каталоге) и, если готовы настоящие вырезки
($AIR_NN_DATA/pilot/tiles/v1, manifest → complete = true), — на 6 местах из них (равномерно по индексу).
Проверки: h (1601, 1601) float64 = float32 файла; info spacing 25, x0 = y0 = −20 000; water None; sites пусто;
meta center_lat/lon = индекс; height_at в узле = h; context: дата reference_context, lat/lon индекса,
utc_offset_h = round(lon/15), valley/mean по рельефу (W.ground_context); R.grid_domain(loc, 400) → hc побитно =
hc400 файла = terrain.block_mean (решатель берёт ровно эту высоту клеток); кэш мест ограничен (lru maxsize);
place_info — system/part индекса; window_centers даёт 3 точки в |x|, |y| ≤ 12 км.

  .venv/bin/python tests/test_places_terrain.py
"""
from __future__ import annotations

import importlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "tests"))


def check_dir(d, n_max=0):
    os.environ["AIRNN_P6_DIR"] = str(d)
    import places as P
    import real as R
    import terrain as T
    import weather as W
    P.location.cache_clear()
    P.context.cache_clear()
    P.p6_index.cache_clear()
    idx = P.p6_index(str(d))
    ids = list(idx)
    if n_max:
        ids = ids[:: max(1, len(ids) // n_max)][:n_max]
    rc = W.CFG["reference_context"]
    for loc in ids:
        L = P.location(loc)
        row = idx[loc]
        with np.load(Path(d) / "cut" / f"{loc}.npz") as z:
            h32, hc400 = z["h"], z["hc400"]
        assert L.h.shape == (1601, 1601) and L.h.dtype == np.float64, (loc, L.h.shape, L.h.dtype)
        assert np.array_equal(L.h, h32.astype(np.float64)), loc
        assert L.info == dict(spacing=25.0, x0=-20000.0, y0=-20000.0), L.info
        assert L.water is None and L.sites == {}, loc
        assert L.meta == dict(center_lat=row["lat"], center_lon=row["lon"]), L.meta
        assert L.height_at(0.0, 0.0) == float(L.h[800, 800]), loc
        assert abs(L.height_at(1000.0, -2000.0) - float(L.h[880, 840])) < 1e-9, loc   # z — юг: y = 2000 м → j = 880
        g, hc = R.grid_domain(loc, 400)
        assert (g.nx, g.ny, g.dx, g.x0, g.y0) == (96, 96, 400, -19200.0, -19200.0), (g.nx, g.dx, g.x0)
        assert hc.dtype == np.float64 and np.array_equal(hc, hc400), f"{loc}: hc решателя ≠ hc400 файла"
        assert np.array_equal(hc, T.block_mean(L.h, L.info, -19200.0, -19200.0, 400.0, 96, 96)), loc
        ctx = P.context(loc)
        assert (ctx["month"], ctx["day"]) == (rc["month"], rc["day"]), ctx
        assert ctx["lat"] == row["lat"] and ctx["lon"] == row["lon"], ctx
        assert ctx["utc_offset_h"] == round(row["lon"] / 15.0), ctx
        gc = W.ground_context(L.height_at)
        assert ctx["valley_msl_m"] == gc["valley_msl_m"] and ctx["mean_msl_m"] == gc["mean_msl_m"], ctx
        assert R.context(loc) is ctx and R.location(loc) is L, "эталон берёт место/контекст не через places"
        assert P.place_info(loc) == dict(system=row["system"], part=row["part"])
        cs = P.window_centers(loc, n_total=3)
        assert len(cs) == 3 and all(abs(x) <= 12000 and abs(y) <= 12000 for x, y in cs), cs
    assert P.location.cache_info().maxsize is not None and P.location.cache_info().maxsize <= 16, "кэш мест не ограничен"
    return len(ids)


def main():
    import make_fake_p6 as FP
    tmp = Path(tempfile.mkdtemp(prefix="nnp6_p6_"))
    try:
        FP.make(tmp, ["altai", "askarovo", "p_000"])
        n = check_dir(tmp)
        print(f"ok: подставной П6 — {n} места")
        # повтор каталога побитно
        tmp2 = tmp.parent / (tmp.name + "_2")
        FP.make(tmp2, ["altai", "askarovo", "p_000"])
        same = all((tmp / f).read_bytes() == (tmp2 / f).read_bytes()
                   for f in ["index.csv"] + [f"cut/t_{k:04d}.npz" for k in range(3)])
        shutil.rmtree(tmp2)
        assert same, "make_fake_p6 не повторяется побитно"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    real = Path(os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data") / "pilot/tiles/v1"
    mf = real / "manifest.json"
    if mf.exists() and json.loads(mf.read_text()).get("complete"):
        n = check_dir(real, n_max=6)
        print(f"ok: настоящие вырезки П6 ({real}) — {n} мест")
    else:
        print(f"настоящих вырезок нет или не готовы ({mf}) — проверено только на подставных")
    return 0


if __name__ == "__main__":
    sys.exit(main())
