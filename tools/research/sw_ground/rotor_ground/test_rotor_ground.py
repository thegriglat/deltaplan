"""pytest SWG-5: формат SWG2; без нити поле = potential_jh; нить на синтетическом хребте меняет поле только за ним."""
import json
import os
import sys

import numpy as np
import pytest

from ground import common as K
from ground import tables as T

sys.path.insert(0, str(K.SG / "contract"))
import check_contract as CC  # noqa: E402
import panels3d as P  # noqa: E402
import rotor3d  # noqa: E402
import sheet3d.foppl as _fp  # noqa: E402


@pytest.fixture(scope="module")
def synth():
    ds = 60.0
    x = np.arange(-2400, 3600.1, 50.0)
    y = np.arange(-3000, 3000.1, 50.0)
    h = 250.0 * np.exp(-(x / 300.0) ** 2)
    t = P.Terrain3D(x, y, np.tile(h, (len(y), 1)), smooth_m=25.0, far_m=5000)
    bg = P.bg_profile(8.0, 0.235, 400.0, t, smooth_m=250.0)
    foc = [(xx, yy) for xx in np.arange(-300, 1200, 2 * ds) for yy in np.arange(-2400, 2401, 4 * ds)]
    p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=2.5 * ds, ds_max=1000, growth=2.0)
    return t, bg, p, P.assemble(p)


def test_no_filament_equals_potential_jh(synth):
    """Пустая нить: velocity_jh(extra=None) тождественна базе; _induced_fn(None) = None."""
    t, bg, p, infl = synth
    sig, _ = P.solve(p, bg, None, infl)
    X = np.array([100.0, 300.0, 600.0])
    Y = np.zeros(3)
    Z = p.height(X, Y) + 10.0
    u0, v0, _ = P.velocity_jh(p, sig, bg, X, Y, Z, 0.1, infl=infl)
    assert _fp._induced_fn(None) is None
    u1, v1, _ = P.velocity_jh(p, sig, bg, X, Y, Z, 0.1, extra=_fp._induced_fn(None), infl=infl, couple=True)
    assert np.allclose(u0, u1) and np.allclose(v0, v1)


def test_filament_changes_lee_not_upstream(synth):
    t, bg, p, infl = synth
    fil, _, info = rotor3d.rotor_vortex(p, bg, 0.1, infl, {"closure": "reattach", "R_rule": 0.25, "gate": "slope", "slope_min": 0.27})
    assert len(fil.seg) > 0
    ind = _fp._induced_fn(fil)
    sig0, _ = P.solve(p, bg, None, infl)
    sig1, _ = P.solve(p, bg, ind, infl)
    X = np.array([-1500.0, 400.0])
    Y = np.zeros(2)
    Z = p.height(X, Y) + 10.0
    u0, _, _ = P.velocity_jh(p, sig0, bg, X, Y, Z, 0.1, infl=infl)
    u1, _, _ = P.velocity_jh(p, sig1, bg, X, Y, Z, 0.1, extra=ind, infl=infl, couple=True)
    assert abs(u1[0] - u0[0]) < 0.1 * abs(u0[0])               # далеко наветренной — почти нет влияния
    assert abs(u1[1] - u0[1]) > 0.1 * abs(u0[1])               # за хребтом — заметное


def test_ground_json_format():
    f = K.SG / "out" / "swg-5" / "ground.json"
    if not f.exists():
        pytest.skip("нет out/swg-5/ground.json")
    doc = json.load(open(f))
    ids = {r["id"] for r in json.load(open(K.OUT_POINTS))["rows"]}
    assert CC.check_ground(doc, ids)
    assert {"potential_jh", "rotor_jh"} <= set(doc["variants"])


def test_rel_row_roundtrip():
    r = T.rel_row("PERD_NE", "rotor_jh", "G_PERD_NE_1", "lee", 10.0, "picard_nom", 1.0, 1.2)
    assert not r["within_tol"] and r["ref_use"] == "справочно"
