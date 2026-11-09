"""Формат SWG3 и хотя бы один хребет на синтетике (гауссов хребет, вытянутый по y). Запуск: sw_ground/py -m pytest -q rotor"""
import json
import os
import sys
import tempfile

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "contract"))
import check_contract as CC  # noqa: E402
import panels3d as P  # noqa: E402
import rotor3d  # noqa: E402


@pytest.fixture(scope="module")
def synth():
    ds = 60.0
    x = np.arange(-2400, 3600.1, 50.0)
    y = np.arange(-3000, 3000.1, 50.0)
    H, a = 250.0, 300.0
    h = H * np.exp(-(x / a) ** 2)                       # крутой хребет (уклон > 0,27), вытянут по y
    t = P.Terrain3D(x, y, np.tile(h, (len(y), 1)), smooth_m=25.0, far_m=5000)
    bg = P.bg_profile(8.0, 0.235, 400.0, t, smooth_m=250.0)
    foc = [(xx, yy) for xx in np.arange(-300, 1200, 2 * ds) for yy in np.arange(-2400, 2401, 4 * ds)]
    p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=2.5 * ds, ds_max=1000, growth=2.0)
    infl = P.assemble(p)
    return t, bg, p, infl


def test_synthetic_ridge_candidate_and_filament(synth):
    t, bg, p, infl = synth
    fil, sig, info = rotor3d.rotor_vortex(p, bg, 0.1, infl, {"closure": "reattach", "R_rule": 0.25, "gate": "slope",
                                                              "slope_min": 0.27})
    assert info["candidates"], "хребет не найден"
    c = info["candidates"][0]
    assert c["slope_lee"] > 0.27 and c["slope"]
    assert info["ridges"] and info["ridges"][0]["converged"] and info["ridges"][0]["Gamma"] > 0


def test_contract_format(tmp_path):
    H = {"git": "0000000", "created": "2026-11-08T00:00:00"}
    rows = [{"case": c, "transect": "T", "variant": "rotor_jh", "present": False, "L_m": 0.0, "depth_m": 0.0,
             "u_min_over_U": 0.1, "L_menke": None, "L_picard_nom": None, "L_picard_adv1": None} for c in sorted(CC.CASES)]
    rid = [{"case": "PERD_NE", "ridge": 0, "slope_max": 0.3, "gate_pass": True, "placed": True, "converged": True,
            "Gamma": 1.0, "R": 1.0, "x_c": 0.0, "x_r": 1.0, "reverse_15m": True, "picard_reverse": True, "false_rotor": False}]
    doc = dict(H, format="swg-rotor", version=1, task="t", params={"slope_min": 0.27}, criterion="x", rows=rows, ridges=rid,
               timing=[{"case": "PERD_NE", "t_s": 1.0, "n_solves": 2}])
    assert "хребт" in CC.check_rotor(doc)
    doc["params"] = {}
    with pytest.raises(CC.Bad):
        CC.check_rotor(doc)
