"""Тесты SWG-3: сетка окна игры, сборка timing.json по контракту SWG4. Без GPU."""
import json
import math
import os
import subprocess
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import window_grid as W  # noqa: E402
import assemble_timing as A  # noqa: E402

CONTRACT = os.path.join(HERE, "..", "contract", "check_contract.py")


@pytest.fixture(scope="module")
def grid():
    return W.load_ongudai()


@pytest.mark.parametrize("dx,nz", [(100, 62), (50, 112)])
def test_window_levels_match_game(grid, dx, nz):
    cx, cz = W.FOCUS_XZ
    X, Y, Z, info = W.window_points(grid, dx, (cx, -cz))
    assert info["nz"] == nz and X.shape == (nz, 64, 64)
    assert info["dz"] == dx / 2 and info["dom"]["x0"] % 25 == 0 and info["dom"]["y0"] % 25 == 0
    assert Z.max() + info["dz"] / 2 >= info["hc_max"] + W.TOP_ABOVE      # потолок 2000 м над максимумом рельефа


def test_vertical_even_and_floor():
    dz, z_bot, nz = W.window_vertical(np.array([1003.0, 1500.0]), 100.0)
    assert dz == 50.0 and z_bot == 950.0 and nz % 2 == 0


def test_z0_median_in_range(grid):
    z0, names = W.z0_median(grid["cls"])
    assert 0.0002 <= z0 <= 1.0 and names[1] == "forest"


def _fake_raw(tmp_path):
    for dx in (100, 50):
        for rep in range(2):
            rows = [dict(stage=s, t_total_s=1.0 + rep, parts={"solve": 0.5}, pure=0.2, extra=dict(under_frac=0.1), residual=0.0)
                    for s in ("cold", "wind_change")]
            json.dump(dict(dx=dx, method="panels", rep=rep, N_panels=10, ds_min=float(dx), n_points=64 * 64 * (62 if dx == 100 else 112),
                           nx=64, ny=64, nz=62 if dx == 100 else 112, z0=1.0, mem_gb=0.1, gpu_before="0, 1", gpu_after="0, 1", rows=rows),
                      open(tmp_path / f"panels_{dx}_{rep}.json", "w"))
    win = lambda dx: dict(dx=dx, x0=0, y0=0, warm=False, iters=[1, 2], stop=["a", "b"], secs=[0.1, 0.2, 0.3, 0.4], t_s=1.0)
    rep = dict(wall_s=5.0, passes=[dict(secs=[1, 1, 1, 1])], windows=[win(100.0), win(50.0)])
    json.dump(dict(threads=8, tol_scale=5.0, cold=rep, wind_change=rep), open(tmp_path / "picard_8_5_0.json", "w"))


def test_assemble_passes_contract(tmp_path):
    _fake_raw(tmp_path)
    out = tmp_path / "timing.json"
    old = sys.argv
    sys.argv = ["x", str(tmp_path), str(out)]
    try:
        A.main()
    finally:
        sys.argv = old
    d = json.load(open(out))
    assert {(r["method"], r["window_dx"], r["stage"]) for r in d["rows"]} >= {("panels", 100, "cold"), ("picard", 50, "wind_change")}
    assert all(math.isfinite(r["t_total_s"]) and r["t_total_s"] > 0 for r in d["rows"])
    r = subprocess.run([os.path.join(HERE, "..", "py"), CONTRACT, str(out)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
