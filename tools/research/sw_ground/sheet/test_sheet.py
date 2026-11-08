"""pytest sw_ground/sheet (SWG-7): без листа → potential_jh побитно; ровная земля — листа нет; совпадение с
velocity_jh(extra, couple=True); петли замкнуты; хребет Аньези H/L = 0,5 — дефицит на 10 м за гребнем (числом)."""
import numpy as np
import pytest

import filaments3d as F
from ground import model as M
from panels3d import velocity_jh
from sheet import core as SH
from wake import core as W
from wake import synth as S

XS = np.array([-300.0, 0.0, 150.0, 300.0, 450.0, 600.0, 900.0, 1200.0])


@pytest.fixture(scope="module")
def agnesi():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    geo = SH.SheetGeom(g, r.terrain)
    return r, geo, SH.Sheet(r, geo, "rest")


def test_flat_ground_no_sheet():
    import panels3d as P
    x = np.arange(-1000.0, 1000.1, 50.0)
    t = P.Terrain3D(x, x, np.zeros((x.size, x.size)), far_m=3000.0)
    geo = SH.SheetGeom(W.WakeGrid(t, (1.0, 0.0), 50.0), t)
    assert geo.n_nodes == 0 and not geo.segs


def test_no_sheet_bitwise(agnesi):
    r, geo, sh = agnesi
    empty = SH.Sheet(r, geo, "rest", gamma=np.zeros(geo.n_nodes))
    assert len(empty.fil.seg) == 0
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)
        for s in (None, empty):
            ps = SH.sheet_parts(r, XS, 0 * XS, z, s)
            assert np.array_equal(pj["speed"], ps["speed"]) and np.array_equal(pj["pot_speed"], ps["pot_speed"])


def test_matches_velocity_jh_couple(agnesi):
    r, geo, sh = agnesi
    for zagl in (10.0, 50.0, 300.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        ps = SH.sheet_parts(r, XS, 0 * XS, z, sh)
        u, v, _ = velocity_jh(r.panels, r.sigma + sh.sig_ex, r.bg, XS, 0 * XS, z, r.z0, extra=sh.extra,
                              infl=r.infl, couple=True)
        assert np.max(np.abs(np.hypot(u, v) / ps["speed"] - 1)) < 1e-9


def test_loops_closed_and_converged(agnesi):
    r, geo, sh = agnesi
    assert F.imbalance(sh.fil) < 1e-9 * max(1.0, float(np.abs(sh.fil.gamma).max()))
    assert sh.info["converged"] and sh.info["n_unconverged"] == 0
    assert sh.info["hist"][-1] < SH.TOL
    seg = [q for q in geo.segs if abs(q["c"]) < 1]
    assert seg and 0.0 <= seg[0]["s_s"] <= 150.0 and 600.0 <= seg[0]["s_r"] <= 900.0


def test_agnesi_deficit_numbers(agnesi):
    """H = 125 м, a = 250 м: на 10 м в середине лее (x = 300, 450 м, под листом) sheet_jh / potential_jh < 0,35
    (лист «rest»: 4,4 → 0,9 м/с; SWD-10 на однородном фоне: 9,0–9,5 → 1,1–2,2 м/с); на 300 м — изменение < 5 %;
    перед холмом (x = −300) и далеко за присоединением (x = 1200) — < 3 %."""
    r, geo, sh = agnesi
    out = {}
    for zagl in (10.0, 300.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)
        ps = SH.sheet_parts(r, XS, 0 * XS, z, sh)
        out[zagl] = ps["speed"] / pj["speed"]
        if zagl == 10.0:
            assert ps["under"][3] and ps["under"][4] and not ps["under"][0]
    k = {x: i for i, x in enumerate(XS)}
    assert out[10.0][k[300.0]] < 0.35 and out[10.0][k[450.0]] < 0.35
    assert abs(out[10.0][k[-300.0]] - 1) < 0.03 and abs(out[10.0][k[1200.0]] - 1) < 0.03
    assert np.max(np.abs(out[300.0] - 1)) < 0.05
