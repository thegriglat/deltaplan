#!/usr/bin/env python3
"""Контрактный тест П1 «Образец набора пилота» v1, v2 и v3 (docs/contracts/air-nn.md) на готовых случаях набора.

  .venv/bin/python tests/test_contract_sample.py [--dataset smoke] [--root КАТАЛОГ] [--data-root R] [--max N]
  (или .venv/bin/python -m pytest tests/test_contract_sample.py — набор из AIRNN_P1_DATASET, по умолчанию smoke)

Вариант — по `manifest.json → contract`: «П1 v1» (область + окна) или «П1 v2» (только область, набор terrain).
Проверяет: каталог набора по шаблону (s0-<7 знаков>/<имя>, manifest.json, plan.json, state.sqlite, cases/); ключи,
формы, dtype float16 и конечность массивов; v1 — число окон = центрам места в plan.json, v2 — окон нет; agl = 13
высот контракта; места — из plan.json и только встроенные/s_*/p_*/t_*; у каждого done — файл с той же sha256, у
файла — строка done; в метаданных случая — условия, day, profile, сетки d400/w<k>, статусы решений; v2 — + `ctx`
(lat, lon, month, day, utc_offset_h, долина) и `place` (system, part), `centers` для каждого места.
«П1 v3» = v2 + цель max — среднее поздних снимков: `solver.late_mean = {from, step}` в plan/manifest; у решений
`target`/`late_n`/`late_spread60_p90` (late_n = числу снимков from…max_outer через step у max, 1 у сошедшихся).
`--dataset smoke` проверяет ещё наборы v2 профиля smoke пилота (`config.yaml → profiles.smoke.datasets` с `root`,
подставной набор terrain — `tests/make_mock_p6.py`): smoke П-2 читает оба варианта.
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


class Dir:
    """Пути набора по каталогу (как dataset.Layout, но для любого каталога — в т. ч. подставного)."""

    def __init__(self, d):
        self.dir = Path(d)
        self.cases, self.db = self.dir / "cases", self.dir / "state.sqlite"
        self.plan, self.manifest = self.dir / "plan.json", self.dir / "manifest.json"

    def case_file(self, cid):
        return self.cases / f"{cid}.npz"


def check(dataset="smoke", data_root=None, max_cases=0):
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    L = DS.Layout(cfg, data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"], dataset)
    return check_dir(L, max_cases)


def check_dir(L, max_cases=0):
    if not isinstance(L, (DS.Layout, Dir)):
        L = Dir(L)
    assert re.fullmatch(r"s0-[0-9a-f]{7}", L.dir.parent.name), L.dir
    for p in (L.manifest, L.plan, L.db, L.cases):
        assert p.exists(), f"нет {p}"
    man = json.loads(L.manifest.read_text())
    contract = man["contract"]
    assert contract in ("П1 v1", "П1 v2", "П1 v3") and man["solver_version"] == L.dir.parent.name, contract
    plan = json.loads(L.plan.read_text())
    v3 = contract == "П1 v3"
    v2 = contract in ("П1 v2", "П1 v3")   # v3 = v2 + цель max — среднее поздних снимков
    region_only = bool(plan.get("region_only"))
    assert region_only == v2, "П1 v2 — только область (plan.json → region_only)"
    if v2:
        assert int(plan["solver"]["max_outer"]) > 0 and man["solver"] == plan["solver"], "предел итераций в plan/manifest"
    if v3:   # число снимков — по from…max_outer через step (последний — всегда предел)
        lm, mo_ = plan["solver"]["late_mean"], int(plan["solver"]["max_outer"])
        assert set(lm) >= {"from", "step"} and 0 < int(lm["from"]) <= mo_ and int(lm["step"]) > 0, lm
        pts = list(range(int(lm["from"]), mo_ + 1, int(lm["step"])))
        late_n = len(pts) + (pts[-1] != mo_)
    else:
        assert "late_mean" not in (plan.get("solver") or {}), "late_mean — только П1 v3"
    assert plan["agl"] == AGL, plan["agl"]
    for loc in plan["places"]:
        assert loc in REAL or re.fullmatch(r"[sp]_\w+", loc) or re.fullmatch(r"t_\d{4}", loc), loc
        assert plan["centers"].get(loc), f"нет centers для {loc}"
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
            # места П6 v2: от уровня моря (0 м, t_0065) до 6,2 км (t_0281)
            assert -450 < hc.min() and hc.max() < 6500, f"{cid}: высоты рельефа {hc.min()}…{hc.max()} (граница: дно ≤ 3000 + размах ≤ 3000, П6 v3)"
        m = json.loads(r["meta"])
        for k in ("hour", "U10", "wdir", "t_max", "sky", "day", "profile", "runs", "d400", "status", "t_wall"):
            assert k in m, f"{cid}: нет {k} в метаданных"
        assert set(m["profile"]) >= {"alpha", "max_profile", "stab", "sun_el", "sun_az"}
        for lv in ["d400"] + [f"w{k}" for k in range(nw)]:
            assert set(m[lv]) == LEVEL_KEYS, (cid, lv)
            for t in ("h", "m"):
                rr = m["runs"][f"{lv}_{t}"]
                assert rr["status"] in ("ok", "max", "diverged") and rr["iters"] > 0
                if v3 and lv == "d400":   # метаданные цели П1 v3
                    if rr["status"] == "max":
                        assert rr["target"] == "late_mean" and rr["late_n"] == late_n, (cid, t, rr)
                        assert isinstance(rr["late_spread60_p90"], float) and 0 <= rr["late_spread60_p90"] < 50, (cid, t, rr)
                    else:
                        assert rr["target"] == "final" and rr["late_n"] == 1 and rr["late_spread60_p90"] == 0.0, (cid, t, rr)
        assert m["d400"]["nx"] == 96 and m["d400"]["dx"] == 400
        assert r["solve_status"] == m["status"]
        if v2:
            assert not any(k[:1] == "w" and k[1:].isdigit() for k in m), f"{cid}: сетка окна в наборе v2"
            assert set(m.get("ctx") or {}) >= {"lat", "lon", "month", "day", "utc_offset_h"}, f"{cid}: ctx"
            assert (m.get("place") or {}).get("part") in ("pool", "holdout") and "system" in m["place"], f"{cid}: place"
            assert m["ctx"]["utc_offset_h"] == round(m["ctx"]["lon"] / 15.0), cid
            mo = plan["solver"]["max_outer"]
            assert m["solver"]["max_outer"] == mo and all(v["iters"] <= mo + 10 for v in m["runs"].values()), cid
    con.close()
    print(f"ok: контракт {contract} — {len(rows)} случаев набора {L.dir.name} ({L.dir})")
    return len(rows)


def smoke_v2_dirs():
    """Наборы с явным root из профиля smoke пилота (подставной terrain, профиль smoke_mock)."""
    sys.path.insert(0, str(HERE))
    from pilotnn import common as C
    cfg = C.load_config(HERE / "config.yaml", "smoke_mock")
    return [C.expand(d["root"], cfg) for d in cfg.get("datasets", []) if d.get("root")]


def test_contract_sample():
    check(os.environ.get("AIRNN_P1_DATASET", "smoke"))
    check("terrain_smoke")   # настоящие места tiles/v3 (П1 v3), если посчитан (NN-P7)
    for d in smoke_v2_dirs():
        if d.exists():
            check_dir(d)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="smoke")
    ap.add_argument("--root", default=None, help="каталог набора вместо --dataset (любой, в т. ч. подставной)")
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    if a.root:
        check_dir(a.root, a.max)
        sys.exit(0)
    check(a.dataset, a.data_root, a.max)
    if a.dataset == "smoke":
        dirs = smoke_v2_dirs()
        assert dirs, "в профиле smoke нет набора v2 (root) — config.yaml"
        for d in dirs:
            assert d.exists(), f"нет подставного набора v2 {d}: tests/make_mock_p6.py"
            n = check_dir(d, a.max)
            assert json.loads((d / "manifest.json").read_text())["contract"] in ("П1 v2", "П1 v3"), d
