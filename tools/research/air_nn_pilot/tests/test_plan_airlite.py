#!/usr/bin/env python3
"""План main воспроизводит план air-lite: те же id и условия, центры окон и высоты, что out/plan.json ветки
research/air-lite (7cc7e33); процедурные — сверху, все id уникальны, порядок чередует места.

  .venv/bin/python tests/test_plan_airlite.py      (или .venv/bin/python -m pytest tests/, если pytest есть)
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))

import dataset as DS  # noqa: E402

REF = "research/air-lite:tools/research/air_lite/out/plan.json"


def _ref():
    r = subprocess.run(["git", "-C", str(HERE), "show", REF], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def test_plan_matches_airlite():
    ref = _ref()
    if ref is None:
        print("ПРОПУСК: нет ветки research/air-lite")
        return
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    plan = json.loads(json.dumps(DS.build_plan(cfg, "main")))   # как после записи в plan.json
    n_ref = len(ref["cases"])
    assert plan["agl"] == ref["agl"]
    assert plan["seed"] == ref["seed"]
    assert plan["cases"][:n_ref] == ref["cases"], "условия air-lite не совпали"
    for loc, c in ref["centers"].items():
        assert plan["centers"][loc] == c, loc
    proc = plan["cases"][n_ref:]
    pc = cfg["plan"]
    assert len(proc) == pc["n_proc"] * pc["n_proc_cond"]
    assert all(c["loc"].startswith("p_") for c in proc)
    ids = [c["id"] for c in plan["cases"]]
    assert len(set(ids)) == len(ids)
    assert sorted(plan["order"]) == sorted(ids)
    first = plan["order"][: len(plan["places"])]
    assert len({i.rsplit("_", 1)[0] for i in first}) == len(plan["places"]), "префикс порядка не покрывает все места"
    for loc in plan["places"]:
        if loc.startswith("p_"):
            assert len(plan["centers"][loc]) == 1
            assert plan["centers"][loc][0] == list(plan["proc"]["params"][loc]["start"])
    print(f"ok: {n_ref} случаев air-lite совпали с {REF}; процедурных {len(proc)}; всего {len(ids)}")


if __name__ == "__main__":
    test_plan_matches_airlite()
