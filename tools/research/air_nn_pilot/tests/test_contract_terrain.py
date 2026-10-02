#!/usr/bin/env python3
"""Контрактный тест П6 «Вырезка места» v1 (docs/contracts/air-nn.md) на готовых вырезках.

  .venv/bin/python tests/test_contract_terrain.py [--dir $AIR_NN_DATA/pilot/tiles/v1] [--max N]

Проверяет: manifest.json (contract «П6 v1»), столбцы и типы index.csv, уникальность id, части pool/holdout;
у каждой строки — файл cut/<id>.npz с той же sha256; ключи h (1601×1601 float32), hc400 (96×96 float64), meta;
конечность; hc400 = блочное среднее h 16×16 по области [−19 200, 19 200] м (≤ 1e-6 м); признаки индекса
согласованы с hc400; размах ≤ 3000 м; неперекрытие пула; инварианты расстояний: места пула не ближе 100 км к Онгудаю, отложенные — не ближе 50 км к пулу.
Владелец (NN-P4) может дополнять проверки; менять формат — только через координатора (версия контракта).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[2]

COLUMNS = ["id", "lat", "lon", "system", "part", "stratum", "zoom", "src_spacing_m", "h_mean", "h_min", "h_max",
           "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac", "sha256"]
FLOATS = {"lat", "lon", "src_spacing_m", "h_mean", "h_min", "h_max", "relief_m", "slope_p50", "slope_p95",
          "tpi2k_p95", "sea_frac"}
N_NODES, SP, N400, DX = 1601, 25.0, 96, 400.0
R_EARTH = 6371008.8
RELIEF_MAX_M = 3000.0  # решение пользователя 02.10: предел размаха высот в квадрате


def block_mean_400(h):
    """Как air3d/terrain.block_mean(h, info(x0 = y0 = −20 000, spacing 25), −19 200, −19 200, 400, 96, 96)."""
    f = int(DX / SP)
    i0 = int(round((-19200.0 + 20000.0) / SP))
    blk = h[i0:i0 + f * N400, i0:i0 + f * N400].astype(np.float64).reshape(N400, f, N400, f)
    return blk.mean(axis=(1, 3))


def dist_km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h))) / 1000.0


def check(d: Path, max_cut=0):
    man = json.loads((d / "manifest.json").read_text())
    assert man.get("contract") == "П6 v1", man.get("contract")
    with open(d / "index.csv", newline="") as f:
        rd = csv.DictReader(f)
        assert rd.fieldnames == COLUMNS, rd.fieldnames
        rows = list(rd)
    assert rows, "пустой индекс"
    ids = [r["id"] for r in rows]
    assert len(set(ids)) == len(ids), "повтор id"
    assert ids == sorted(ids), "индекс не по порядку id"
    for r in rows:
        assert r["id"].startswith("t_") and r["id"][2:].isdigit(), r["id"]
        assert r["part"] in ("pool", "holdout"), r["part"]
        for k in FLOATS:
            v = float(r[k])
            assert math.isfinite(v), (r["id"], k)
        assert int(r["zoom"]) > 0
        assert abs(float(r["relief_m"]) - (float(r["h_max"]) - float(r["h_min"]))) < 1e-2, r["id"]
        assert float(r["relief_m"]) <= RELIEF_MAX_M, ("размах > 3000 м", r["id"])
    ong = json.loads((ROOT / "configs/locations/ongudai.json").read_text())
    og = (ong["center_lat"], ong["center_lon"])
    pool = [(float(r["lat"]), float(r["lon"])) for r in rows if r["part"] == "pool"]
    hold = [(float(r["lat"]), float(r["lon"])) for r in rows if r["part"] == "holdout"]
    assert pool and hold, "нужны обе части"
    assert min(dist_km(p, og) for p in pool) >= 100.0, "место пула ближе 100 км к Онгудаю"
    # неперекрытие квадратов пула 38,4 км: |Δx| ≥ 38,4 км или |Δy| ≥ 38,4 км (местная равнопромежуточная метрика,
    # допуск 1 % на выбор метрики владельцем)
    lim = 38.4 * 0.99
    for a in range(len(pool)):
        for b in range(a + 1, len(pool)):
            (la1, lo1), (la2, lo2) = pool[a], pool[b]
            dy = abs(la2 - la1) * math.pi / 180 * R_EARTH / 1000.0
            dlo = (lo2 - lo1 + 180.0) % 360.0 - 180.0
            dx = abs(dlo) * math.pi / 180 * R_EARTH / 1000.0 * math.cos(math.radians((la1 + la2) / 2))
            assert dx >= lim or dy >= lim, f"квадраты пула перекрываются: {pool[a]} {pool[b]}"
    assert min(dist_km(p, q) for p in hold for q in pool) >= 50.0, "отложенное место ближе 50 км к пулу"
    sel = rows if not max_cut else rows[:: max(1, len(rows) // max_cut)]
    for r in sel:
        p = d / "cut" / f"{r['id']}.npz"
        assert p.exists(), p
        assert hashlib.sha256(p.read_bytes()).hexdigest() == r["sha256"], f"sha256 {p}"
        z = np.load(p)
        assert set(z.files) >= {"h", "hc400", "meta"}, z.files
        h, hc = z["h"], z["hc400"]
        assert h.shape == (N_NODES, N_NODES) and h.dtype == np.float32, (h.shape, h.dtype)
        assert hc.shape == (N400, N400) and hc.dtype == np.float64, (hc.shape, hc.dtype)
        assert np.isfinite(h).all() and np.isfinite(hc).all(), r["id"]
        assert np.abs(hc - block_mean_400(h)).max() <= 1e-6, f"hc400 ≠ block_mean: {r['id']}"
        meta = json.loads(str(z["meta"]))
        assert meta.get("contract") == "П6 v1", meta.get("contract")
        assert abs(meta["lat"] - float(r["lat"])) < 1e-9 and abs(meta["lon"] - float(r["lon"])) < 1e-9
        assert abs(hc.max() - float(r["h_max"])) < 0.01 and abs(hc.min() - float(r["h_min"])) < 0.01, r["id"]
    print(f"П6 v1: ок — мест {len(rows)} (пул {len(pool)}, отложено {len(hold)}), вырезок проверено {len(sel)}")


def test_contract_terrain():
    d = Path(os.environ.get("AIRNN_P6_DIR") or
             Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")) / "pilot/tiles/v1")
    if not (d / "index.csv").exists():
        import pytest
        pytest.skip(f"нет вырезок в {d}")
    check(d, max_cut=20)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=None)
    ap.add_argument("--max", type=int, default=0, help="проверить не больше N вырезок (равномерно по индексу)")
    a = ap.parse_args()
    d = Path(a.dir) if a.dir else Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")) / "pilot/tiles/v1"
    check(d, a.max)
