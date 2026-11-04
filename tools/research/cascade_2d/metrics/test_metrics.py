#!/usr/bin/env python3
"""Тесты метрик M1 на синтетических F1 (запуск: tools/research/cascade_2d/py metrics/test_metrics.py)."""
import json
import os
import sys
import tempfile
import traceback

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metrics as M  # noqa: E402
import plots  # noqa: E402

io = M.io
sys.path.insert(0, os.path.join(HERE, "..", "contract"))
import check_contract  # noqa: E402


def build(dx, ufun, wfun, hfun=None, case="C1", source="picard", variant=None, parent_dx=None, seed=None,
          top=1200.0, walls=True):
    """Синтетический F1: u(x,z), w(x,z) — функции; hfun(x) — высота земли по колоннам."""
    dz = dx / 4
    nx = int(io.X_LEN // dx)
    nz = int(np.ceil(top / dz)) + 1
    meta = dict(case=case, source=source, variant=variant, dx=dx, dz=dz, nx=nx, nz=nz, x0=-6400.0,
                z0=-dz, parent_dx=parent_dx, seed=seed, git="synthetic")
    xf = meta["x0"] + np.arange(nx + 1) * dx
    xc = 0.5 * (xf[:-1] + xf[1:])
    zf = -dz + np.arange(nz + 1) * dz
    zc = 0.5 * (zf[:-1] + zf[1:])
    h = np.zeros(nx) if hfun is None else hfun(xc)
    cell = (zc[:, None] > h[None, :]).astype(np.float32) if walls else np.ones((nz, nx), np.float32)
    tu = np.ones((nz, nx + 1), np.float32)
    tw = np.ones((nz + 1, nx), np.float32)
    if walls:
        tu[:, 1:-1] = (cell[:, :-1] * cell[:, 1:])
        tu[:, 0], tu[:, -1] = cell[:, 0], cell[:, -1]
        tw[1:-1, :] = cell[:-1, :] * cell[1:, :]
        tw[0, :] = 0
        tw[-1, :] = cell[-1, :]
    u = ufun(xf[None, :], zc[:, None]) * np.ones((nz, nx + 1)) * (tu > 0)
    w = wfun(xc[None, :], zf[:, None]) * np.ones((nz + 1, nx)) * (tw > 0)
    arrays = dict(u=u.astype(np.float32), w=w.astype(np.float32), th=np.zeros((nz, nx), np.float32),
                  cell=cell, tu=tu, tw=tw, h=h.astype(np.float32))
    return meta, arrays


def hill(xc):
    return 200.0 / (1.0 + (xc / 500.0) ** 2)


def flow_u(x, z):
    hl = 200.0 / (1 + (x / 500.0) ** 2)
    return 5.0 * (1 + 0.5 * np.exp(-((x) / 700.0) ** 2) * np.exp(-z / 200.0)) * np.log1p(np.maximum(z, 0) / 10 + 1)


def flow_w(x, z):
    return 1.5 * np.exp(-((x + 300.0) / 400.0) ** 2) * np.exp(-z / 300.0)


def ref_field(dx=25, **kw):
    return build(dx, flow_u, flow_w, hill, **kw)


def setup(meta, arr):
    U = M.u_ref_value(meta, arr)
    return U


def test_self():
    rm, ra = ref_field()
    U = setup(rm, ra)
    met = M.compute_metrics(rm, ra, rm, ra, 0.0, 500.0, U, "C1")
    for k in ("E_u", "E_w", "E_u_lee"):
        assert met[k] == 0.0, (k, met[k])
    assert all(v == 0.0 for v in met["dS"].values()), met["dS"]
    assert abs(met["r_w"] - 1.0) < 1e-12, met["r_w"]
    assert met["max_rel_div"] is not None and met["max_speed"] > 0


def test_linear_interp():
    lin_u = lambda x, z: 2.0 + 1e-4 * x + 2e-3 * z
    lin_w = lambda x, z: -1.0 + 5e-5 * x + 1e-3 * z
    rm, ra = build(25, lin_u, lin_w, walls=False)
    for k in (400, 200, 100, 50):
        m, a = build(k, lin_u, lin_w, walls=False)
        bm, ba = M.make_baseline(m, a, rm, ra)
        assert bm["variant"] == f"B{k}" and bm["source"] == "baseline"
        err_u = np.abs(ba["u"] - ra["u"].astype(np.float64)).max()
        err_w = np.abs(ba["w"] - ra["w"].astype(np.float64)).max()
        assert err_u <= 1e-6 and err_w <= 1e-6, (k, err_u, err_w)


def test_shift():
    flat_u = lambda x, z: 5.0 * np.log1p(np.maximum(z, 0) / 10 + 1)
    zero = lambda x, z: 0.0 * x * z
    rm, ra = build(25, flat_u, zero, None)
    U = setup(rm, ra)
    c = 0.7
    fa = dict(ra)
    fa["u"] = ra["u"] + np.float32(c) * (ra["tu"] > 0)
    met = M.compute_metrics(rm, fa, rm, ra, 0.0, 500.0, U, "C1")
    assert abs(met["E_u"] - c / U) <= 1e-6, (met["E_u"], c / U)
    assert abs(met["E_u_lee"] - c / U) <= 1e-6
    assert met["E_w"] == 0.0


def test_lrec():
    uf = lambda x, z: 5.0 + 0 * x * z
    rm, ra = build(25, uf, lambda x, z: 0 * x * z, None)
    i = int(np.floor((500.0 - rm["x0"]) / 25))
    fa = dict(ra)
    u = ra["u"].copy()
    u[:, i], u[:, i + 1], u[:, i + 2] = 1.0, -1.5, 2.0
    fa["u"] = u
    assert M.l_rec(rm, fa, 0.0, 500.0) == 25.0
    assert M.l_rec(rm, ra, 0.0, 500.0) is None
    u[:, i + 2] = -2.0  # две клетки подряд
    assert M.l_rec(rm, fa, 0.0, 500.0) == 50.0


def test_div_free():
    dx = 25
    rm, ra = build(dx, lambda x, z: 0 * x * z, lambda x, z: 0 * x * z, None, walls=False)
    nx, nz, dz = rm["nx"], rm["nz"], rm["dz"]
    xn = rm["x0"] + np.arange(nx + 1) * dx
    zn = rm["z0"] + np.arange(nz + 1) * dz
    psi = 40.0 * np.sin(xn[None, :] / 900.0) * np.cos(zn[:, None] / 600.0)  # (nz+1, nx+1)
    u = (psi[1:, :] - psi[:-1, :]) / dz  # (nz, nx+1)
    w = -(psi[:, 1:] - psi[:, :-1]) / dx  # (nz+1, nx)
    ra["u"], ra["w"] = u.astype(np.float32), w.astype(np.float32)
    rd = io.rel_div(io.div2d(rm, ra), dx, 5.0).max()
    assert rd <= 1e-6, rd


def test_nesting_baselines_and_thermal():
    rm, ra = ref_field()
    bm, ba = M.make_baseline(*ref_field(50), rm, ra)
    assert bm["dx"] == 25 and ba["u"].shape == ra["u"].shape
    # C3: термик
    tw = lambda x, z: 2.0 * np.exp(-(x / 300.0) ** 2) * (z > 0)
    m, a = build(25, flow_u, tw, None, case="C3")
    w_max, f_up = M.thermal(m, a, 0.0, 500.0)
    assert 1.5 < w_max <= 2.0 and f_up > 0, (w_max, f_up)
    met = M.compute_metrics(m, a, m, a, 0.0, 500.0, 5.0, "C3")
    assert met["w_max"] == met["w_max_ref"] and met["F_up"] == met["F_up_ref"]
    met1 = M.compute_metrics(m, a, m, a, 0.0, 500.0, 5.0, "C1")
    assert met1["w_max"] is None and met1["F_up"] is None


def test_end_to_end():
    with tempfile.TemporaryDirectory() as t:
        os.environ["CASCADE2D_DATA"] = t
        fd = os.path.join(t, "fields", "C1")
        for k in (400, 200, 100, 50, 25):
            m, a = ref_field(k)
            io.write_f1(os.path.join(fd, f"picard_none_d{k}.json"), m, a)
        for seed in (1, 2, 3):
            rng = np.random.default_rng(seed)
            m, a = ref_field(25, source="cascade", variant="V3h", parent_dx=400, seed=seed)
            a["u"] = (a["u"] + 0.3 * rng.standard_normal(a["u"].shape).astype(np.float32)) * (a["tu"] > 0)
            io.write_f1(os.path.join(fd, f"cascade_V3h_d25_from400_s{seed}.json"), m, a)
        m, a = ref_field(25, source="cascade", variant="V1", parent_dx=400)
        a["u"] = a["u"] * np.float32(1.1)
        io.write_f1(os.path.join(fd, "cascade_V1_d25_from400.json"), m, a)
        run_rec = os.path.join(fd, "x.run.json")
        with open(run_rec, "w") as f:
            json.dump({"format": "cascade2d-run"}, f)
        out = os.path.join(t, "out")
        assert M.main(["--case", "C1", "--out", out]) == 0
        assert check_contract.run([out]) == 0
        d = json.load(open(os.path.join(out, "C1.json")))
        names = {r["variant"] for r in d["rows"]}
        assert names == {"B400", "B200", "B100", "B50", "V3h", "V1"}, names
        assert d["E_ref"]["E_u"] is not None and d["U_ref"] > 0
        v1 = [r for r in d["rows"] if r["variant"] == "V1"][0]
        assert v1["E_u"] > 0.05
        v3 = [r for r in d["rows"] if r["variant"] == "V3h"]
        assert len(v3) == 3 and all(len(r["sigma_u"]) == 12 for r in v3)
        assert 0.1 < v3[0]["sigma_u"][0] < 0.5, v3[0]["sigma_u"]
        b = {r["variant"]: r["E_u"] for r in d["rows"]}
        assert b["B400"] > b["B50"] and b["B400"] > b["B200"] > b["B100"] - 1e-9 or b["B400"] > b["B100"]
        assert os.path.exists(os.path.join(out, "C1.csv"))
        figs = plots.make("C1", os.path.join(fd, "cascade_V1_d25_from400.json"), "B400",
                          os.path.join(fd, "picard_none_d25.json"), os.path.join(t, "fig"))
        for p in figs:
            assert 0 < os.path.getsize(p) <= 300 * 1024, p


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    bad = 0
    for n, f in tests:
        try:
            f()
            print("ok  ", n)
        except Exception:
            bad += 1
            print("FAIL", n)
            traceback.print_exc()
    print(f"тестов {len(tests)}, провалов {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
