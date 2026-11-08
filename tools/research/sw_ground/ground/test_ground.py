"""pytest sw_ground/ground: форматы SWG1/SWG2, правила выбора точек, воспроизведение точки SWD5 (PERD_NE, потенциал + JH)."""
import json
import sys

import numpy as np
import pytest

from ground import common as K
from ground import evaluate as E
from ground import points as GP
from ground import tables as T

sys.path.insert(0, str(K.SG / "contract"))
import check_contract as CC  # noqa: E402


def test_points_file_contract():
    if not K.OUT_POINTS.exists():
        pytest.skip("нет out/points/ground_points.json (py -m ground.points)")
    doc = json.load(open(K.OUT_POINTS))
    assert CC.check_points(doc)
    zs = {r["z_agl"] for r in doc["rows"]}
    assert {10.0, 50.0, 300.0} <= zs
    # правило: тип только из пяти, id уникален, s_nom конечен
    ids = [r["id"] for r in doc["rows"]]
    assert len(ids) == len(set(ids))
    assert all(np.isfinite(r["s_nom"]) and r["s_nom"] > 0 for r in doc["rows"])


def test_choose_step_and_cap():
    T_ = np.empty((40, 40), object)
    T_[:] = "lee"
    T_[:, :5] = "valley"
    k = GP.choose_step(T_)
    assert k >= 2
    sel = GP.select_cells(T_, k)
    n_lee = sum(1 for s in sel if s[2] == "lee")
    assert n_lee <= GP.CAP
    # valley (200 клеток > 150) прореживается тем же шагом, не берётся целиком
    assert sum(1 for s in sel if s[2] == "valley") < 200


def test_kd_groups_cover_and_bound():
    rng = np.random.default_rng(0)
    pl = [dict(x=float(a), y=float(b)) for a, b in rng.uniform(0, 3000, (300, 2))]
    ng, gid = E.kd_groups(pl, 40)
    assert len(gid) == 300 and set(gid) == set(range(ng))
    cnt = np.bincount(gid)
    assert cnt.max() <= 40


def test_rel_row_and_summary_pass_swg2_check():
    pts_rows = [dict(case="PERD_NE", id=f"G_PERD_NE_{i}", type="lee", z_agl=10.0) for i in range(3)]
    rows = [T.rel_row("PERD_NE", "potential", r["id"], r["type"], r["z_agl"], "picard_nom", 1.0, 1.0 + 0.1 * i)
            for i, r in enumerate(pts_rows)]
    assert [r["within_tol"] for r in rows] == [True, True, False]
    assert all(r["ref_use"] == "справочно" for r in rows)       # Пикар ниже 50 м
    summ = T.summarize(rows)
    assert summ[0]["n"] == 3 and abs(summ[0]["frac_tol"] - 2 / 3) < 1e-12
    doc = dict(format="swg-ground", version=1, git="x", created="t", task="swg-1", variants={"potential": "тест"},
               rows=rows, summary=summ, masts=[], decomp=[], scan=[])
    assert CC.check_ground(doc, {r["id"] for r in pts_rows})


@pytest.fixture(scope="module")
def ne_run():
    import core as C
    from ground import model as M
    refs = C.load_refs()
    keys = C.eval_set("PERD_NE", refs)
    run = M.GRun("PERD_NE", sorted({(k[0], k[1]) for k in keys}), focus_r_mul=10.0)
    yield run, keys, refs
    run.free()


def test_swd5_point_reproduced(ne_run):
    """Строка SWD5 (out/compare/points.json, potential_jh, PERD_NE, P_lee_0, 10 м): s_pan и s_pan/s_ref − 1 = +2,16."""
    import core as C
    from ground import model as M
    run, keys, refs = ne_run
    old = json.load(open(C.OUT / "points.json"))
    r = next(r for r in old["rows"] if r["case"] == "PERD_NE" and r["variant"] == "potential_jh" and r["name"] == "P_lee_0"
             and r["z_agl"] == 10.0 and r["ref_kind"] == "picard_nom")
    nm = refs["norm"]["PERD_NE"]
    X, Y, Z = run.abs_points([r["x"], nm["x"]], [r["y"], nm["y"]], [r["z_agl"], nm["z_agl"]])
    p = M.jh_parts(run, X, Y, Z)
    s = p["speed"][0] / p["speed"][1]
    assert abs(s - r["s_pan"]) < 2e-3 * r["s_pan"], (s, r["s_pan"])
    assert abs(s / r["s_ref"] - 1.0 - 2.158) < 0.02


def test_jh_parts_equals_velocity_jh(ne_run):
    from panels3d import velocity_jh
    from ground import model as M
    run, keys, _ = ne_run
    a = np.array(keys[:20], float)
    X, Y, Z = run.abs_points(a[:, 0], a[:, 1], a[:, 2])
    p = M.jh_parts(run, X, Y, Z)
    u, v, _ = velocity_jh(run.panels, run.sigma, run.bg, X, Y, Z, run.z0, infl=run.infl)
    ok = np.isfinite(u)
    assert np.allclose(np.hypot(u, v)[ok], p["speed"][ok], rtol=1e-9, atol=1e-9)
