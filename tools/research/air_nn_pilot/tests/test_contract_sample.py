#!/usr/bin/env python3
"""Контрактный тест П1 «Образец набора пилота» v1 (docs/air_nn_contracts.md) на готовых случаях набора.

  .venv/bin/python tests/test_contract_sample.py [--dataset smoke] [--data-root R] [--max N]
  (или .venv/bin/python -m pytest tests/test_contract_sample.py — набор из AIRNN_P1_DATASET, по умолчанию smoke)

Проверяет: каталог набора по шаблону (s0-<7 знаков>/<имя>, manifest.json, plan.json, state.sqlite, cases/); ключи,
формы, dtype float16 и конечность массивов; число окон = центрам места в plan.json; agl = 13 высот контракта;
места — из plan.json и только встроенные/s_*/p_*; у каждого done — файл с той же sha256, у файла — строка done;
в метаданных случая — условия, day, profile, сетки d400/w<k>, статусы решений.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))

import dataset as DS  # noqa: E402

AGL = [25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000]
REAL = {"ongudai", "aushkul", "altai", "askarovo"}
LEVEL_KEYS = {"dx", "dz", "x0", "y0", "nx", "ny", "nz", "z_bot"}


def check(dataset="smoke", data_root=None, max_cases=0):
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    L = DS.Layout(cfg, data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"], dataset)
    assert re.fullmatch(r"s0-[0-9a-f]{7}", L.dir.parent.name), L.dir
    for p in (L.manifest, L.plan, L.db, L.cases):
        assert p.exists(), f"нет {p}"
    man = json.loads(L.manifest.read_text())
    assert man["contract"] in ("П1 v1", "П1 v2") and man["solver_version"] == L.dir.parent.name
    plan = json.loads(L.plan.read_text())
    v2 = man["contract"] == "П1 v2"
    region_only = bool(plan.get("region_only"))
    assert region_only == v2, "П1 v2 — только область (plan.json → region_only)"
    if v2:
        assert int(plan["solver"]["max_outer"]) > 0 and man["solver"] == plan["solver"], "предел итераций в plan/manifest"
    assert plan["agl"] == AGL, plan["agl"]
    for loc in plan["places"]:
        assert loc in REAL or re.fullmatch(r"[sp]_\w+", loc) or (v2 and re.fullmatch(r"t_\d{4}", loc)), loc
    cases = {c["id"]: c for c in plan["cases"]}
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    meta = dict(con.execute("SELECT key, value FROM meta").fetchall())
    assert meta["contract"] == man["contract"] and meta["solver_version"] == L.dir.parent.name
    rows = con.execute("SELECT * FROM cases WHERE status='done' ORDER BY ord").fetchall()
    assert rows, "нет готовых случаев"
    assert con.execute("SELECT COUNT(*) FROM cases").fetchone()[0] == len(cases)
    done_ids = {r["id"] for r in rows}
    files = {p.stem for p in L.cases.glob("*.npz")}
    assert files <= set(cases), f"лишние файлы: {sorted(files - set(cases))[:5]}"
    assert done_ids <= files, f"done без файла: {sorted(done_ids - files)[:5]}"
    if max_cases:
        rows = rows[:max_cases]
    for r in rows:
        cid = r["id"]
        c = cases[cid]
        assert r["loc"] == c["loc"] and json.loads(r["cond"]) == c
        path = L.case_file(cid)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == r["sha256"], f"{cid}: sha256 файла ≠ базы"
        nw = 0 if region_only else len(plan["centers"][c["loc"]])
        with np.load(path, allow_pickle=False) as z:
            want = {"d400_h": (4, 13, 96, 96), "d400_m": (3, 13, 96, 96), "d400_hc": (96, 96), "d400_H": (96, 96),
                    "d400_hbl": (96, 96)}
            for k in range(nw):
                want.update({f"w{k}_h": (4, 13, 64, 64), f"w{k}_m": (3, 13, 64, 64), f"w{k}_hc": (64, 64),
                             f"w{k}_H": (64, 64), f"w{k}_hbl": (64, 64)})
            assert set(z.files) == set(want), f"{cid}: ключи {sorted(z.files)}"
            for k, shp in want.items():
                a = z[k]
                assert a.shape == shp and a.dtype == np.float16, f"{cid}/{k}: {a.shape} {a.dtype}"
                assert np.isfinite(a).all(), f"{cid}/{k}: не конечные значения"
            hc = z["d400_hc"].astype(np.float32)
            assert 0 < hc.min() and hc.max() < 6000, f"{cid}: высоты рельефа {hc.min()}…{hc.max()}"
        m = json.loads(r["meta"])
        for k in ("hour", "U10", "wdir", "t_max", "sky", "day", "profile", "runs", "d400", "status", "t_wall"):
            assert k in m, f"{cid}: нет {k} в метаданных"
        assert set(m["profile"]) >= {"alpha", "max_profile", "stab", "sun_el", "sun_az"}
        for lv in ["d400"] + [f"w{k}" for k in range(nw)]:
            assert set(m[lv]) == LEVEL_KEYS, (cid, lv)
            for t in ("h", "m"):
                rr = m["runs"][f"{lv}_{t}"]
                assert rr["status"] in ("ok", "max", "diverged") and rr["iters"] > 0
        assert m["d400"]["nx"] == 96 and m["d400"]["dx"] == 400
        assert r["solve_status"] == m["status"]
        if c["loc"].startswith("t_"):
            assert set(m["ctx"]) >= {"lat", "lon", "month", "day", "utc_offset_h"} and set(m["place"]) == {"system", "part"}, cid
            assert m["ctx"]["utc_offset_h"] == round(m["ctx"]["lon"] / 15.0), cid
        if v2:
            mo = plan["solver"]["max_outer"]
            assert m["solver"]["max_outer"] == mo and all(v["iters"] <= mo + 10 for v in m["runs"].values()), cid
    con.close()
    print(f"ok: контракт {man['contract']} — {len(rows)} случаев набора {dataset} ({L.dir})")
    return len(rows)


def test_contract_sample():
    check(os.environ.get("AIRNN_P1_DATASET", "smoke"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="smoke")
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    check(a.dataset, a.data_root, a.max)
