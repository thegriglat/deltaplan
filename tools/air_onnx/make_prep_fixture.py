#!/usr/bin/env python3
"""Фикстура для теста AirNnPrep (O3, docs/contracts/air-onnx.md): входы (реальный рельеф и строки набора пилота) и
выходы prep.py (карты, числа FiLM, поворот, to_physical) в tests/air_onnx/fixtures/prep_*.

  make_prep_fixture.py            собрать фикстуру из набора пилота (только чтение ~/air_nn_data/…)
  make_prep_fixture.py --verify   пересоздать выходы из СОХРАНЁННЫХ входов во временный каталог, сравнить побитно

Запуск — venv пилота (только читать): CUDA_VISIBLE_DEVICES= <venv>/bin/python -B tools/air_onnx/make_prep_fixture.py
Файлы: prep_cases.json (строки, meta, film, поворот), prep_hc.bin / prep_heat.bin (float32, вход, значения float16
набора), prep_maps.bin (9 карт, float32, [случай][карта][j′][i′]), prep_phys.bin (to_physical на детерминированном out).
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/research/air_nn_pilot"))

import numpy as np  # noqa: E402

from pilotnn import prep  # noqa: E402

FIX = ROOT / "tests/air_onnx/fixtures"
DATASET = Path.home() / "air_nn_data/pilot/datasets/s0-3acd749/main"
PHYS_N = 12                      # сетка to_physical в фикстуре (малая — размер)
# (id образца, wdir, что проверяет). wdir переписан: k = 0..3 и r у границы сектора [−45°, 45°)
PICK = [
    ("altai_000", 270.0, "k=0, r=0"),
    ("ongudai_000", 315.0, "k=0, r=−45° (граница включена)"),
    ("aushkul_000", 224.9, "k=3, r≈−44.9° (у границы)"),
    ("askarovo_000", 135.0, "k=2, r=−45° (граница)"),
    ("altai_010", 150.0, "k=3, r=+30°"),
    ("s_ridge_000", 40.0, "k=1, пропуски в day/profile → умолчания FiLM"),
]


def out_formula(n: int) -> np.ndarray:
    """Детерминированный «выход сети» — одна формула в Python и GDScript."""
    return (np.sin(0.37 * np.arange(n, dtype=np.float64)) * 0.8).astype(np.float32)


def rotation_grid() -> list[float]:
    w = [round(0.7 * i, 6) for i in range(0, 515)]
    return [x for x in w if x < 360.0] + [0.0, 45.0, 135.0, 225.0, 315.0, 359.99, 44.99, 45.01, 314.99, 315.01]


def collect_inputs() -> dict:
    con = sqlite3.connect(f"file:{DATASET / 'state.sqlite'}?mode=ro", uri=True, timeout=30)
    cases, hcs, heats = [], [], []
    try:
        for cid, wdir, note in PICK:
            r = con.execute("SELECT meta FROM cases WHERE id=?", (cid,)).fetchone()
            if r is None or not r[0]:
                sys.exit(f"нет случая {cid} в {DATASET}")
            m = json.loads(r[0])
            row = {k: m[k] for k in ("id", "loc", "hour", "U10", "t_max", "profile", "day")}
            row["wdir"] = wdir
            row["d400"] = {"dx": m["d400"]["dx"]}
            if note.startswith("пропуски"):
                row["day"] = {"heat": 0.3, "z_i_msl": None, "cap_agl": None, "brk": 0}
                row["profile"] = {"alpha": 0.2, "max_profile": 1.5, "stab": "X"}
            z = np.load(DATASET / "cases" / f"{cid}.npz")
            hcs.append(z["d400_hc"].astype(np.float32))
            heats.append(z["d400_H"].astype(np.float32))
            cases.append({"row": row, "note": note})
    finally:
        con.close()
    return {"cases": cases, "hc": np.stack(hcs), "heat": np.stack(heats)}


def derive(inp: dict) -> dict[str, bytes]:
    """Входы → все файлы фикстуры (байты)."""
    cases, hc_all, heat_all = inp["cases"], inp["hc"], inp["heat"]
    maps_b, phys_b, out_cases = [], [], []
    for c, hc32, h32 in zip(cases, hc_all, heat_all):
        row = c["row"]
        z = {"d400_hc": hc32.astype(np.float16), "d400_H": h32.astype(np.float16)}
        hc = hc32.astype(np.float64)
        meta = prep.case_meta(dict(row, **{"id": row["id"], "loc": row["loc"]}), hc)
        f = prep.film(row, meta)
        mp = prep.maps(z, meta, row)
        maps_b.append(np.ascontiguousarray(mp, dtype="<f4").tobytes())
        n = PHYS_N
        phys = prep.to_physical(out_formula(prep.N_CH * len(prep.AGL) * n * n).reshape(prep.N_CH * len(prep.AGL), n, n),
                                meta)
        phys_b.append(np.ascontiguousarray(phys["m"], dtype="<f4").tobytes()
                      + np.ascontiguousarray(phys["h"], dtype="<f4").tobytes())
        out_cases.append({"note": c["note"], "row": row,
                          "meta": {k: meta[k] for k in ("k", "r", "U10", "alpha", "mp", "S", "hc_mean")},
                          "film": [float(x) for x in f]})
    rot = rotation_grid()
    rk = [prep.rotation_of(w) for w in rot]
    doc = {"ny": int(hc_all.shape[1]), "nx": int(hc_all.shape[2]), "dx": 400.0, "phys_n": PHYS_N,
           "map_names": list(prep.MAP_NAMES), "film_names": list(prep.FILM_NAMES),
           "cases": out_cases,
           "rotation": {"wdir": rot, "k": [int(a) for a, _ in rk], "r": [float(b) for _, b in rk]}}
    return {
        "prep_cases.json": (json.dumps(doc, ensure_ascii=False, indent=0) + "\n").encode(),
        "prep_hc.bin": np.ascontiguousarray(hc_all, dtype="<f4").tobytes(),
        "prep_heat.bin": np.ascontiguousarray(heat_all, dtype="<f4").tobytes(),
        "prep_maps.bin": b"".join(maps_b),
        "prep_phys.bin": b"".join(phys_b),
    }


def stored_inputs() -> dict:
    doc = json.loads((FIX / "prep_cases.json").read_text())
    ny, nx, n = doc["ny"], doc["nx"], len(doc["cases"])
    hc = np.fromfile(FIX / "prep_hc.bin", "<f4").reshape(n, ny, nx)
    heat = np.fromfile(FIX / "prep_heat.bin", "<f4").reshape(n, ny, nx)
    return {"cases": [{"row": c["row"], "note": c["note"]} for c in doc["cases"]], "hc": hc, "heat": heat}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()
    if a.verify:
        files = derive(stored_inputs())
        with tempfile.TemporaryDirectory() as td:
            bad = []
            for name, data in files.items():
                (Path(td) / name).write_bytes(data)
                if (Path(td) / name).read_bytes() != (FIX / name).read_bytes():
                    bad.append(name)
        if bad:
            print("prep fixture: РАСХОЖДЕНИЕ:", ", ".join(bad))
            return 1
        print("prep fixture: OK (побитно, %d файлов)" % len(files))
        return 0
    FIX.mkdir(parents=True, exist_ok=True)
    for name, data in derive(collect_inputs()).items():
        (FIX / name).write_bytes(data)
        print(name, len(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
