#!/usr/bin/env python3
"""Контрактный тест П6 «Вырезка места» v2 (docs/contracts/air-nn.md) на готовых вырезках.

  .venv/bin/python tests/test_contract_terrain.py [--dir <каталог набора; по умолчанию paths.out из configs/terrain.yaml>] [--max N]

Проверяет: manifest.json (contract «П6 v2»), столбцы и типы index.csv, уникальность id, части pool/holdout;
у каждой строки — файл cut/<id>.npz с той же sha256; ключи h (1601×1601 float32), hc400 (96×96 float64), meta;
конечность; hc400 = блочное среднее h 16×16 по области [−19 200, 19 200] м (≤ 1e-6 м); признаки индекса
согласованы с hc400; размах ≤ 3000 м; неперекрытие пула; инварианты расстояний: места пула не ближе 100 км к Онгудаю, места пула — не ближе 50 км к местам отложенных систем; отложенные системы и число мест — из
configs/terrain.yaml (select.holdout: systems × per_system, сейчас 4 × 15), не константа; путь набора — из конфига.
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
import yaml

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[2]

COLUMNS = ["id", "lat", "lon", "system", "part", "stratum", "zoom", "src_spacing_m", "h_mean", "h_min", "h_max",
           "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac", "sha256"]
FLOATS = {"lat", "lon", "src_spacing_m", "h_mean", "h_min", "h_max", "relief_m", "slope_p50", "slope_p95",
          "tpi2k_p95", "sea_frac"}
N_NODES, SP, N400, DX = 1601, 25.0, 96, 400.0
R_EARTH = 6371008.8
RELIEF_MAX_M = 3000.0  # решение пользователя 02.10: предел размаха высот в квадрате
CONTRACT = "П6 v2"


def terrain_cfg():
    return yaml.safe_load((HERE / "configs/terrain.yaml").read_text())


def default_dir() -> Path:
    """Путь набора — из конфига (paths.out), корень данных — $AIR_NN_DATA или data_root конфига."""
    cfg = terrain_cfg()
    base = Path(os.environ.get("AIR_NN_DATA") or cfg["data_root"])
    return base / cfg["paths"]["out"]


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
    assert man.get("contract") == CONTRACT, man.get("contract")
    assert man.get("complete") is True, "manifest.complete != true"
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
    assert min(dist_km(p, q) for p in hold for q in pool) >= 50.0, "место пула ближе 50 км к месту отложенной системы"
    ho = terrain_cfg()["select"]["holdout"]
    want = {sname: int(ho["per_system"]) for sname in ho["systems"]}
    got = {}
    for r in rows:
        if r["part"] == "holdout":
            got[r["system"]] = got.get(r["system"], 0) + 1
    assert got == want, f"отложенные системы/места не как в конфиге: {got} ≠ {want}"
    assert not any(r["system"] in want for r in rows if r["part"] == "pool"), "в пуле место отложенной системы"
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
        assert meta.get("contract") == CONTRACT, meta.get("contract")
        assert abs(meta["lat"] - float(r["lat"])) < 1e-9 and abs(meta["lon"] - float(r["lon"])) < 1e-9
        assert abs(hc.max() - float(r["h_max"])) < 0.01 and abs(hc.min() - float(r["h_min"])) < 0.01, r["id"]
    print(f"{CONTRACT}: ок — мест {len(rows)} (пул {len(pool)}, отложено {len(hold)}: {len(want)} систем × {ho['per_system']}), "
          f"вырезок проверено {len(sel)}")


def test_contract_terrain():
    d = Path(os.environ.get("AIRNN_P6_DIR") or default_dir())
    if not (d / "index.csv").exists():
        import pytest
        pytest.skip(f"нет вырезок в {d}")
    check(d, max_cut=20)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=None)
    ap.add_argument("--max", type=int, default=0, help="проверить не больше N вырезок (равномерно по индексу)")
    a = ap.parse_args()
    d = Path(a.dir) if a.dir else default_dir()
    check(d, a.max)
