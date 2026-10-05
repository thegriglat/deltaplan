"""S4 v1: модельный рельеф -> место решателя. Без GPU. Запуск: cd tools/research/air_synth/solver &&
../../air_nn_pilot/.venv/bin/python -m pytest -q tests"""
import sys
from pathlib import Path

import numpy as np
import pytest

SOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOL))
import model_place as M   # noqa: E402
import reliefs            # noqa: E402
import h7_run             # noqa: E402


def synthetic_g100(seed=0):
    rng = np.random.default_rng(seed)
    j, i = np.mgrid[0:384, 0:384]
    return 800 + 1.5 * i + 3.0 * j + 40 * rng.standard_normal((384, 384))   # несимметрично: на восток и сильнее на север


def quantize(h):
    off = (h.min() + h.max()) / 2
    sc = max(0.05, (h.max() - h.min()) / 65000)
    return off + sc * np.round((h - off) / sc), sc


def test_place_format():
    g = synthetic_g100()
    L = M.register("m_t0", g, 0.0)
    assert L.h.shape == (384, 384) and L.h.dtype == np.float64
    assert L.info == dict(spacing=100.0, x0=-19200.0, y0=-19200.0)
    assert L.water is None and L.sites == {}
    assert M.R.location("m_t0") is L
    c = M.R.context("m_t0")
    assert np.isfinite(c["lat"]) and np.isfinite(c["lon"])
    # оси: x растёт с i (восток), y — с j (север); высота растёт на восток и сильнее на север
    assert L.height_at(5000.0, -0.0) > L.height_at(-5000.0, -0.0)
    assert L.height_at(0.0, -5000.0) > L.height_at(0.0, 5000.0)   # z = -y: y = 5000 — север


def test_grid_domain_equals_g400():
    g = synthetic_g100(1)
    gq, sc = quantize(g)                                        # g100 после деквантования
    g400 = reliefs.block4(gq)                                   # g400 корпуса: блочное среднее g100 (до квантования)
    g400_q, sc4 = quantize(g400)
    M.register("m_t1", gq, 0.0)
    grid, hc = M.R.grid_domain("m_t1", 400)
    assert hc.shape == (96, 96) and grid.dx == 400.0 and grid.x0 == -19200.0
    assert np.abs(hc - g400_q).max() <= sc4 + 1e-9
    assert np.abs(hc - reliefs.block4(gq)).max() <= 1e-6        # блочное среднее z100


def test_base_offset():
    g = synthetic_g100(2)
    M.register("m_t2", g, 1000.0)
    _, hc = M.R.grid_domain("m_t2", 400)
    assert np.abs(hc - (reliefs.block4(g) + 1000.0)).max() <= 1e-6


def test_proto_reliefs():
    p = SOL / "proto_reliefs.npz"
    if not p.exists():
        pytest.skip("proto_reliefs.npz")
    rl = reliefs.load_proto()
    assert len(rl) == 4
    for nm, g100, g400, _ in rl:
        assert g100.shape == (384, 384) and np.isfinite(g100).all()
        M.register(nm, g100, h7_run.BASE_M)
        _, hc = M.R.grid_domain(nm, 400)
        assert np.abs(hc - (g400 + h7_run.BASE_M)).max() <= 1e-6


def test_plan_mechanical():
    rows = h7_run.plan(["a", "b", "c", "d"], 3, 1)
    assert len(rows) == 12 and len({r["id"] for r in rows}) == 12
    assert all(3.0 <= r["U10"] <= 8.0 for r in rows)
    assert len({(r["hour"], r["sky"]) for r in rows}) == 12
    assert h7_run.plan(["a", "b", "c", "d"], 3, 1) == rows


def test_solver_version():
    v = M.solver_version()
    assert v.startswith("s0-") and len(v) == 10


def test_corpus_hdf5_loader(tmp_path):
    h5py = pytest.importorskip("h5py")
    g = synthetic_g100(3)
    off, sc = 2500.0, 0.15
    q1 = np.round((g - off) / sc).astype(np.int16)
    gq = off + sc * q1.astype(np.float64)
    q4 = np.round((reliefs.block4(g) - off) / sc).astype(np.int16)
    with h5py.File(tmp_path / "corpus.h5", "w") as h:
        h["relief/id"] = np.array([7], dtype=np.int64)
        for nm, q in (("h100", q1), ("h400", q4)):
            ds = h.create_dataset(f"relief/{nm}", data=q[None]); ds.attrs["offset_m"] = off; ds.attrs["scale_m"] = sc
    (n, g100, g400, s), = reliefs.load_corpus(tmp_path, [7])
    assert n == "c_00007" and np.array_equal(g100, gq) and s == sc
    M.register(n, g100, 0.0)
    _, hc = M.R.grid_domain(n, 400)
    assert np.abs(hc - g400).max() <= sc + 1e-9
