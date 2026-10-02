#!/usr/bin/env python3
"""Подставной каталог П6 v1 (вырезки мест t_*) для тестов и пробы генератора П-2 до готовности NN-P4.

Формат — как у NN-P4 (docs/contracts/air-nn.md, П6 v1): manifest.json (contract «П6 v1», complete, fake = true),
index.csv (все столбцы), cut/<id>.npz (h float32 1601², hc400 float64 96² = блочное среднее h, meta). Рельефы —
из уже имеющихся: встроенные места (слой detail 25 м 1601² с центром в центре места — та же сетка, что вырезка П6;
настоящий рельеф Алтая/Урала), синтетика air-lite и процедурные p_* (климат — координаты, приписанные здесь).
Координаты синтетики/процедурных условные (широта Онгудая, долгота со сдвигом), так что инварианты расстояний П6
выполняются; встроенные — свои координаты (ongudai — только «отложенное», он ближе 100 км к себе самому).

  .venv/bin/python tests/make_fake_p6.py --out DIR [--places altai,askarovo,p_000]
Побитно повторяемо (zip с фиксированной датой). Используется: tests/test_places_terrain.py, тест прерывания
terrain, проба `probe`, если настоящих вырезок ещё нет.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402
import places as P  # noqa: E402
import procedural as PR  # noqa: E402
import terrain as T  # noqa: E402

COLUMNS = ["id", "lat", "lon", "system", "part", "stratum", "zoom", "src_spacing_m", "h_mean", "h_min", "h_max",
           "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac", "sha256"]
DEFAULT = "altai,askarovo,p_000"
PROBE8 = "altai,aushkul,askarovo,ongudai,s_scarp,s_valley,p_000,p_003"
HOLDOUT = {"askarovo", "ongudai"}
ONG = (50.79, 86.13)


def source_h(name, proc_seed):
    """→ (h float32 1601², lat, lon, система)."""
    if name in P.REAL:
        L = T.Location(name)
        assert L.h.shape == (P.N_NODES, P.N_NODES) and L.info["x0"] == -20000.0 and L.info["y0"] == -20000.0, name
        return L.h.astype(np.float32), L.meta["center_lat"], L.meta["center_lon"], \
            "altai" if name in ("altai", "ongudai") else "ural"
    PR.configure(proc_seed)
    L = P.SynthLocation(name)
    k = (P.SYNTH.index(name) if name.startswith("s_") else 10 + int(name[2:]))
    return L.h.astype(np.float32), ONG[0], round(ONG[1] + 3.0 * (k + 1), 4), "fake_" + name[:2].rstrip("_")


def features(h, hc):
    from scipy.ndimage import gaussian_filter
    gy, gx = np.gradient(hc, 400.0)
    s = np.hypot(gx, gy)[1:-1, 1:-1]
    tpi = hc - gaussian_filter(hc, 2000.0 / 400.0, mode="nearest")
    return dict(h_mean=float(hc.mean()), h_min=float(hc.min()), h_max=float(hc.max()),
                relief_m=float(hc.max() - hc.min()), slope_p50=float(np.percentile(s, 50)),
                slope_p95=float(np.percentile(s, 95)), tpi2k_p95=float(np.percentile(tpi, 95)),
                sea_frac=float(np.mean(h <= 0.5)))


def make(out, names, proc_seed=20261002):
    out = Path(out)
    (out / "cut").mkdir(parents=True, exist_ok=True)
    rows = []
    for k, name in enumerate(names):
        tid = f"t_{k:04d}"
        h, lat, lon, system = source_h(name, proc_seed)
        info = dict(spacing=25.0, x0=-20000.0, y0=-20000.0)
        hc = T.block_mean(h.astype(np.float64), info, -19200.0, -19200.0, 400.0, 96, 96)
        meta = dict(contract="П6 v1", lat=lat, lon=lon, zoom=12, src_spacing_m=25.0, tiles=[], fake=True, source=name)
        buf = io.BytesIO()
        DS.write_npz(buf, dict(h=h, hc400=hc, meta=np.array(json.dumps(meta, ensure_ascii=False))))
        data = buf.getvalue()
        (out / "cut" / f"{tid}.npz").write_bytes(data)
        f = features(h, hc)
        stratum = "s%d" % min(3, int(f["slope_p50"] / 0.1))
        rows.append(dict(id=tid, lat=lat, lon=lon, system=system, part="holdout" if name in HOLDOUT else "pool",
                         stratum=stratum, zoom=12, src_spacing_m=25.0, **f, sha256=hashlib.sha256(data).hexdigest()))
    with open(out / "index.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLUMNS, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: (repr(v) if isinstance(v, float) else v) for k, v in r.items()})
    man = dict(contract="П6 v1", complete=True, fake=True, n_places=len(rows),
               what="ПОДСТАВНОЙ каталог П6 (tests/make_fake_p6.py) — рельефы встроенных мест, синтетики и процедурных",
               sources={r["id"]: n for r, n in zip(rows, names)}, proc_seed=proc_seed,
               license="рельефы встроенных мест — как data/terrain (см. ASSETS.md); синтетика — своя")
    (out / "manifest.json").write_text(json.dumps(man, ensure_ascii=False, indent=1) + "\n")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--places", default=DEFAULT, help=f"источники мест через запятую; проба: {PROBE8}")
    a = ap.parse_args()
    rows = make(a.out, [s for s in a.places.split(",") if s])
    for r in rows:
        print(f"{r['id']} {r['part']:7s} {r['system']:10s} уклон p50 {r['slope_p50']:.3f} размах {r['relief_m']:.0f} м")


if __name__ == "__main__":
    main()
