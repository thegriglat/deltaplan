#!/usr/bin/env python3
"""Подставной индекс П6 и подставной набор terrain (П1 v2 + метаданные решений П1 v3) («только область») для smoke П-2 — до настоящих данных
NN-P4 (вырезки) и NN-P6 (генератор). Формат — по контрактам П6 v1 и П1 v2 (docs/air_nn_contracts.md):

  <out>/tiles/v1/index.csv, manifest.json           — индекс П6: столбцы контракта, по строке на место t_0000…t_0009,
                                                       part pool/holdout, stratum, system (cut/ не пишется — пилоту
                                                       вырезки не нужны: рельеф клетки есть в образце `d400_hc`)
  <out>/datasets/<версия решателя>/smoke_terrain/   — набор П1 v2: manifest.json, plan.json (agl, centers[t_*],
                                                       cases), state.sqlite (схема NN-P1, meta с ctx и place),
                                                       cases/<id>.npz — только d400_h, d400_m, d400_hc, d400_H, d400_hbl

Случаи — первые `--n-cond` случаев мест набора main (только чтение), место переименовано в t_<NNNN> (id
`t_<NNNN>_<kkk>`), поля решателя побитно те же. Признаки индекса (h_*, relief_m, slope_p50/p95, tpi2k_p95) — по
`d400_hc` формулами контракта; lat/lon встроенных мест — из configs/locations, процедурных — условные.
Статусы решений (П1 v3, подставные метаданные — поля не пересчитываются): случаи с ord % 5 = 1 — `h` не сошлось, 2 — `m`,
3 — оба (target `late_mean`, `late_n` 11, `late_spread60_p90` 0,6…0,9 м/с); остальные — `ok`/`final` (по каждому из
двух решений), так что в каждой отложенной системе есть и сошедшиеся, и несошедшиеся решения обоих видов (tests/check_report_v3.py).
Слой `stratum` — по уклону p50 (пороги ниже — только для подставных данных). Повтор команды → те же файлы
(существующий каталог пересоздаётся целиком).

  .venv/bin/python tests/make_mock_p6.py [--out $AIR_NN_DATA/pilot/tmp/NN-P5_mock] [--n-cond 4]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import shutil
import sqlite3
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Dataset, solver_status, terrain_features  # noqa: E402

COLUMNS = ["id", "lat", "lon", "system", "part", "stratum", "zoom", "src_spacing_m", "h_mean", "h_min", "h_max",
           "relief_m", "slope_p50", "slope_p95", "tpi2k_p95", "sea_frac", "sha256"]
# t_<NNNN> ← место main, часть, система (отложенные — три системы, как решение пользователя 02.10)
MAPPING = [("altai", "pool", "other"), ("aushkul", "holdout", "caucasus"), ("askarovo", "pool", "other"),
           ("p_003", "pool", "other"), ("p_004", "pool", "other"), ("p_005", "holdout", "pyrenees"),
           ("p_006", "pool", "other"), ("p_007", "pool", "other"), ("p_008", "holdout", "appalachians"),
           ("p_009", "pool", "other")]
STRATA = ((0.015, "s0_gentle"), (0.03, "s1_mid"), (9e9, "s2_steep"))    # по slope_p50 (только подставные данные)
NAME = "smoke_terrain"


def stratum(s50):
    return next(n for lim, n in STRATA if s50 < lim)


def main():
    ap = argparse.ArgumentParser()
    data = os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")
    ap.add_argument("--out", default=f"{data}/pilot/tmp/NN-18_mock")
    ap.add_argument("--src", default=None, help="каталог набора main (по умолчанию — dataset.py path --dataset main)")
    ap.add_argument("--n-cond", type=int, default=4)
    a = ap.parse_args()
    if a.src:
        src = Path(a.src)
    else:
        import yaml   # main лежит под версией main_version (configs/dataset.yaml), а не под текущей версией решателя
        ver = yaml.safe_load((HERE / "configs" / "dataset.yaml").read_text())["main_version"]
        src = Path(data) / "pilot" / "datasets" / ver / "main"
    ds = Dataset(src)
    rows = [r for r in ds.case_rows() if solver_status(r) in ("ok", "max")]
    out = Path(a.out)
    tiles = out / "tiles" / "v1"
    dsd = out / "datasets" / src.parent.name / NAME
    for d in (tiles, dsd):
        if d.exists():
            shutil.rmtree(d)
    (dsd / "cases").mkdir(parents=True)
    tiles.mkdir(parents=True)
    src_con = sqlite3.connect(f"file:{src / 'state.sqlite'}?mode=ro", uri=True)
    schema = [r[0] for r in src_con.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE "
                                             "'sqlite_%' ORDER BY type DESC, name")]
    src_rows = {r[0]: r for r in src_con.execute("SELECT id, ord, cond, runs, meta, t_wall, iters, solve_status FROM cases")}
    src_con.close()
    con = sqlite3.connect(dsd / "state.sqlite")
    for sql in schema:
        con.execute(sql)
    index, plan_cases, centers = [], [], {}
    ord_ = 0
    SOLVER = dict(max_outer=3000, late_mean={"from": 2000, "step": 100})   # = предел main (ref_study.MAXIT); 11 снимков, как у настоящего П1 v3
    for k, (loc, part, system) in enumerate(MAPPING):
        tid = f"t_{k:04d}"
        mine = [r for r in rows if r["loc"] == loc][: a.n_cond]
        assert mine, f"нет случаев места {loc} в {src}"
        z0 = ds.load(mine[0]["id"])
        hc = z0["d400_hc"].astype(np.float64)
        f = terrain_features(hc)
        if loc in ("altai", "aushkul", "askarovo"):
            lj = json.loads((C.REPO / "configs" / "locations" / f"{loc}.json").read_text())
            lat, lon = float(lj["center_lat"]), float(lj["center_lon"])
        else:
            lat, lon = 42.0 + 0.5 * k, 1.0 + 3.0 * k                     # условные координаты (подставные)
        index.append(dict(id=tid, lat=lat, lon=lon, system=system, part=part, stratum=stratum(f["slope_p50"]), zoom=12,
                          src_spacing_m=25.0, h_mean=float(hc.mean()), h_min=float(hc.min()), h_max=float(hc.max()),
                          relief_m=float(hc.max() - hc.min()), slope_p50=f["slope_p50"], slope_p95=f["slope_p95"],
                          tpi2k_p95=float(np.percentile(P.tpi(hc, 2000.0), 95)), sea_frac=0.0, sha256=""))
        centers[tid] = ds.plan["centers"][loc]
        for j, r in enumerate(mine):
            cid = f"{tid}_{j:03d}"
            z = ds.load(r["id"])
            buf = io.BytesIO()
            np.savez_compressed(buf, **{key: z[key] for key in ("d400_h", "d400_m", "d400_hc", "d400_H", "d400_hbl")})
            b = buf.getvalue()
            C.atomic_write_bytes(dsd / "cases" / f"{cid}.npz", b)
            sid, sord, cond, runs, meta, t_wall, iters, solve_status = src_rows[r["id"]]
            cond = dict(json.loads(cond), id=cid, loc=tid)
            m = json.loads(meta)
            m.update(id=cid, loc=tid, mock_src=r["id"])
            m["runs"] = {kk: v for kk, v in m["runs"].items() if kk.startswith("d400")}
            bad = {"d400_h": ord_ % 5 in (1, 3), "d400_m": ord_ % 5 in (2, 3)}
            for kk in m["runs"]:
                if bad.get(kk):
                    m["runs"][kk].update(status="max", target="late_mean", late_n=11,
                                         late_spread60_p90=round(0.6 + 0.05 * (ord_ % 7), 3))
                else:
                    m["runs"][kk].update(status="ok", target="final", late_n=1, late_spread60_p90=0.0)
            m["status"] = solve_status = "max" if any(bad.values()) else "ok"

            for kk in [kk for kk in m if kk[:1] == "w" and kk[1:].isdigit()]:
                del m[kk]
            m["ctx"] = dict(lat=lat, lon=lon, month=7, day=15, utc_offset_h=round(lon / 15),
                            valley=(m.get("day") or {}).get("valley_msl"))
            m["place"] = dict(system=system, part=part)
            m["solver"] = SOLVER
            con.execute("INSERT INTO cases (id, loc, kind, ord, cond, status, attempts, t_wall, iters, solve_status, runs,"
                        " meta, file, bytes, sha256) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (cid, tid, "terrain", ord_, json.dumps(cond, ensure_ascii=False), "done", 1, t_wall, iters,
                         solve_status, json.dumps(m["runs"]), json.dumps(m, ensure_ascii=False), f"cases/{cid}.npz",
                         len(b), hashlib.sha256(b).hexdigest()))
            plan_cases.append(cond)
            ord_ += 1
    meta = dict(schema_version="1", solver_version=src.parent.name, contract="П1 v3", dataset=NAME, mock="1",
                created="mock")
    con.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", list(meta.items()))
    con.commit()
    con.close()
    plan = dict(agl=ds.plan["agl"], centers=centers, cases=plan_cases, places=[f"t_{k:04d}" for k in range(len(MAPPING))],
                dataset=NAME, n_cond=a.n_cond, mock=True, source=str(src), region_only=True, solver=SOLVER)
    C.atomic_write_json(dsd / "plan.json", plan)
    C.atomic_write_json(dsd / "manifest.json", dict(
        what=f"ПОДСТАВНОЙ набор terrain (П1 v3, только область; статусы, target, late_spread60_p90 — подставные) для smoke П-2: случаи main, места переименованы в t_*",
        contract="П1 v3", solver_version=src.parent.name, schema_version=1, mock=True, source=str(src), solver=SOLVER,
        mapping={f"t_{k:04d}": m[0] for k, m in enumerate(MAPPING)}, counts=dict(total=ord_, done=ord_),
        complete=True, command=" ".join(sys.argv)))
    with open(tiles / "index.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, COLUMNS, lineterminator="\n")
        w.writeheader()
        for r in index:
            w.writerow({k: (f"{v:.6f}" if isinstance(v, float) else v) for k, v in r.items()})
    parts = {p: sum(r["part"] == p for r in index) for p in ("pool", "holdout")}
    C.atomic_write_json(tiles / "manifest.json", dict(
        what="ПОДСТАВНОЙ индекс П6 для smoke П-2 (NN-P5); вырезок cut/ нет", contract="П6 v1", mock=True,
        command=" ".join(sys.argv), source=str(src), n_places=len(index), parts=parts,
        strata={s: sum(r["stratum"] == s for r in index) for _, s in STRATA},
        systems=sorted({r["system"] for r in index}), complete=True))
    print(f"ok: подставной П6 {tiles / 'index.csv'} ({len(index)} мест, {parts}); набор {dsd} ({ord_} случаев)")


if __name__ == "__main__":
    main()
