#!/usr/bin/env python3
"""Деление v3 (контракт П2 v3, `pilotnn/split.py`) на искусственном наборе размера П-2:
ongudai (б) вне всего; (г) = все места П6 с part = holdout; (б′) = holdout_proc_n мест p_*; части не пересекаются и
покрывают все случаи; (а) — доля новых условий у мест пула; кривая — вложенные подмножества мест П6 пула размером
25/50/100/200/300, порядок «слои по кругу, внутри слоя — по хешу», прочие места пула — в каждой точке; точка полного
пула = основная сеть (те же случаи обучения); детерминизм и независимость от порядка строк; набор без П6 — кривая по
пулу; t_* без строки индекса — ошибка.

  .venv/bin/python tests/test_split.py
"""
from __future__ import annotations

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pilotnn.split import make_split, u01  # noqa: E402

SC = dict(seed=20261002, holdout_places=["ongudai"], holdout_proc_prefix="p_", holdout_proc_n=5, newcond_frac=0.15,
          val_frac=0.10, curve_sizes=[25, 50, 100, 200, 300])
STRATA = ("s0_low", "s1_mid", "s2_steep", "s3_alpine")


def fake(n_pool=300, n_hold=45, n_cond=11):
    rows, p6 = [], {}
    for loc, n in (("ongudai", 110), ("aushkul", 110), ("altai", 110), ("askarovo", 110)):
        rows += [dict(id=f"{loc}_{k:03d}", loc=loc) for k in range(n)]
    for loc in ("s_ridge", "s_saddle", "s_hill", "s_valley", "s_scarp"):
        rows += [dict(id=f"{loc}_{k:03d}", loc=loc) for k in range(50)]
    for p in range(40):
        rows += [dict(id=f"p_{p:03d}_{k:03d}", loc=f"p_{p:03d}") for k in range(30)]
    for t in range(n_pool + n_hold):
        loc = f"t_{t:04d}"
        hold = t >= n_pool
        p6[loc] = dict(part="holdout" if hold else "pool",
                       stratum=STRATA[int(u01("strat", loc) * len(STRATA))],
                       system=("caucasus", "pyrenees", "appalachians")[t % 3] if hold else "other")
        rows += [dict(id=f"{loc}_{k:03d}", loc=loc) for k in range(n_cond)]
    return rows, p6


def check_disjoint(s, rows):
    parts = ("train_ids", "val_ids", "newcond_ids", "holdout_place_ids", "holdout_sys_ids", "holdout_proc_ids")
    seen = {}
    for p in parts:
        for i in s[p]:
            assert i not in seen, (i, p, seen[i])
            seen[i] = p
    assert set(seen) == {r["id"] for r in rows}, "части не покрывают все случаи"


def test_split_v3():
    rows, p6 = fake()
    s = make_split(rows, SC, p6)
    loc = {r["id"]: r["loc"] for r in rows}
    check_disjoint(s, rows)
    # (б)
    assert s["holdout_places"] == ["ongudai"]
    assert {loc[i] for i in s["holdout_place_ids"]} == {"ongudai"} and len(s["holdout_place_ids"]) == 110
    for k in ("train_ids", "val_ids", "newcond_ids", "holdout_sys_ids", "holdout_proc_ids"):
        assert all(loc[i] != "ongudai" for i in s[k]), k
    # (г) — ровно места part = holdout, все их случаи
    want = sorted(l for l, r in p6.items() if r["part"] == "holdout")
    assert s["holdout_sys"] == want
    assert {loc[i] for i in s["holdout_sys_ids"]} == set(want) and len(s["holdout_sys_ids"]) == 45 * 11
    # (б′) — 5 процедурных, не t_*
    assert len(s["holdout_proc"]) == 5 and all(l.startswith("p_") for l in s["holdout_proc"])
    assert len(s["holdout_proc_ids"]) == 5 * 30
    # пул
    pool = set(s["pool_order"])
    assert pool == ({r["loc"] for r in rows} - {"ongudai"} - set(want) - set(s["holdout_proc"]))
    assert set(s["p6_pool"]) == {l for l, r in p6.items() if r["part"] == "pool"} and len(s["p6_pool"]) == 300
    assert set(s["others"]) == pool - set(s["p6_pool"]) and len(s["others"]) == 3 + 5 + 35
    # (а): доля новых условий ~15 %, у каждого места пула есть обучение
    n_pool_cases = sum(1 for r in rows if r["loc"] in pool)
    fr = len(s["newcond_ids"]) / n_pool_cases
    assert 0.13 < fr < 0.17, fr
    assert set(s["newcond_ids"]) == set(s["newcond_p6_ids"]) | set(s["newcond_old_ids"])
    assert all(loc[i].startswith("t_") for i in s["newcond_p6_ids"])
    assert not any(loc[i].startswith("t_") for i in s["newcond_old_ids"])
    tr_locs = {loc[i] for i in s["train_ids"]}
    assert tr_locs == pool
    # кривая
    cv = s["curve"]
    assert [c["n_places"] for c in cv] == [25, 50, 100, 200, 300]
    assert [c["is_main"] for c in cv] == [False, False, False, False, True]
    order = s["curve_order"]
    assert sorted(order) == s["p6_pool"]
    for a, b in zip(cv, cv[1:]):
        assert set(a["curve_places"]) < set(b["curve_places"]), "не вложенные"
        assert set(a["train_ids"]) < set(b["train_ids"])
    for c in cv:
        assert set(c["curve_places"]) == set(order[: c["n_places"]])
        assert set(s["others"]) <= set(c["places"]), "прочие места пула — в каждой точке"
        assert set(c["places"]) == set(c["curve_places"]) | set(s["others"])
        assert not set(c["train_ids"]) & set(s["holdout_sys_ids"] + s["holdout_place_ids"] + s["holdout_proc_ids"])
    assert cv[-1]["train_ids"] == s["train_ids"] and cv[-1]["val_ids"] == s["val_ids"], "полная точка ≠ основная сеть"
    # порядок: слои по кругу — первые 4 места из 4 разных слоёв, в порядке имён слоёв
    first = [p6[l]["stratum"] for l in order[:len(STRATA)]]
    assert first == sorted(STRATA), first
    for st in STRATA:                                     # внутри слоя — по хешу
        mine = [l for l in order if p6[l]["stratum"] == st]
        assert mine == sorted(mine, key=lambda l: (u01(SC["seed"], "curve", l), l))
    # точка 25: слои представлены почти поровну (по кругу)
    cnt = {st: sum(p6[l]["stratum"] == st for l in cv[0]["curve_places"]) for st in STRATA}
    assert max(cnt.values()) - min(cnt.values()) <= 1, cnt
    # детерминизм и независимость от порядка строк
    rows2 = rows[:]
    random.Random(5).shuffle(rows2)
    assert make_split(rows2, SC, p6) == s
    # другое зерно — другое деление
    assert make_split(rows, dict(SC, seed=1), p6)["curve_order"] != order


def test_no_p6():
    rows, p6 = fake(0, 0)
    s = make_split(rows, dict(SC, curve_sizes=[5, 10, 20, 40]), None)
    check_disjoint(s, rows)
    assert s["holdout_sys"] == [] and s["p6_pool"] == []
    assert [c["n_places"] for c in s["curve"]] == [5, 10, 20, 40]
    assert s["curve"][-1]["n_places"] == 40 and not s["curve"][-1]["is_main"]      # пул 43 места
    assert s["curve_order"] == s["pool_order"]


def test_small_curve_and_unknown_t():
    rows, p6 = fake(7, 3, 3)
    s = make_split(rows, dict(SC, curve_sizes=[2, 4, 7, 25]), p6)
    assert [c["n_places"] for c in s["curve"]] == [2, 4, 7]
    assert s["curve"][-1]["is_main"]
    rows.append(dict(id="t_9999_000", loc="t_9999"))
    try:
        make_split(rows, SC, p6)
    except ValueError:
        pass
    else:
        raise AssertionError("t_* без индекса П6 должно падать")


if __name__ == "__main__":
    test_split_v3()
    test_no_p6()
    test_small_curve_and_unknown_t()
    print("ok: деление v3 — (б), (г), (б′), (а), кривая 25…300 (слои по кругу, точка полного пула = основная сеть)")
