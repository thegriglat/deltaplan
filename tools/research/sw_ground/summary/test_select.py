import math

from summary import select as S


def rec(v, cs, rm, lee, elig=True):
    return {"variant": v, "case": cs, "rmse_all": rm, "rmse_lee": lee, "eligible": elig}


def test_rule_small_example():
    t = []
    for cs in S.CASES:
        t.append(rec("potential_jh", cs, 0.20, 0.30))
        t.append(rec("a", cs, 0.15, 0.25))                       # лучше везде -> ранг 1
        t.append(rec("b", cs, 0.10 if cs == "PERD_NE" else 0.23, 0.2))   # в одном случае хуже базы на 0,03 -> вне
        t.append(rec("c", cs, 0.05, 0.1, elig=False))            # несошедшийся -> без ранга
    r = {o["variant"]: o for o in S.rank_rule(t)}
    assert r["a"]["rank"] == 1 and r["potential_jh"]["rank"] == 2
    assert r["b"]["rank"] is None and not r["b"]["passes_1"]
    assert r["c"]["rank"] is None and not r["c"]["eligible"]
    assert math.isclose(r["a"]["mean_rmse_all"], 0.15)


def test_mast_stats_rmse():
    rows = [{"case": "X", "variant": "v", "ref_kind": "mast", "type": "lee", "s_ref": 1.0, "s_pan": 1.3,
             "rel_err": 0.3, "within_tol": False},
            {"case": "X", "variant": "v", "ref_kind": "mast", "type": "lee", "s_ref": 1.0, "s_pan": 1.0,
             "rel_err": 0.0, "within_tol": True},
            {"case": "X", "variant": "v", "ref_kind": "picard_nom", "type": "lee", "s_ref": 1, "s_pan": 5,
             "rel_err": 4, "within_tol": False}]
    m = S.mast_stats(rows, "X", "v", "lee")
    assert m["n"] == 2 and math.isclose(m["rmse"], math.sqrt(0.09 / 2)) and m["frac_tol"] == 0.5
