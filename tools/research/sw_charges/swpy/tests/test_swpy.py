"""Проверки решателя по аналитике (T1–T11 карточки SWC-4): покой, Риттер, Бернулли, M_c, масса, 1D=2D, трение, нагрев, статусы SW3.
F0 = U0/√(b0 h0), M = H/h0, M_c(F0) = 1 + F0²/2 − 1,5·F0^(2/3)."""
import json
import math
import os
import subprocess

import numpy as np
import pytest

from swpy import case as swcase
from swpy import io as swio
from swpy import solver

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
H0, B0 = 500.0, 0.1
C0 = math.sqrt(B0 * H0)


def Mc(F0):
    return 1 + F0 ** 2 / 2 - 1.5 * F0 ** (2 / 3)


def ridge_a(H, a):
    """крутизна s, при которой масштаб гауссианы равен a"""
    return H * math.sqrt(2.0) * math.exp(-0.5) / a


def make(name, **kw):
    kw.setdefault("cd", 0.0)
    kw.setdefault("forcing", "none")
    return swcase.make_case(name, **kw)


def run(tmp_path, meta_arr, **kw):
    return solver.run(meta_arr, str(tmp_path / "out"), **kw)


def steps_time(nsteps, dx, c=C0, cfl=0.45, extra=0.0):
    return nsteps * cfl * dx / (c + extra)


def eta_root(F0, M_z, branch):
    """η + F0²/(2η²) = 1 + F0²/2 − z/h0 (M_z = z/h0), ветвь 'sub' (η > F0^(2/3)) или 'sup'."""
    rhs = 1 + F0 ** 2 / 2 - M_z
    f = lambda e: e + F0 ** 2 / (2 * e * e) - rhs
    ec = F0 ** (2 / 3)
    lo, hi = (ec, 3.0) if branch == "sub" else (1e-3, ec)
    flo = f(lo)
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if (f(mid) > 0) == (flo > 0):
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def ridge_case(name, F0, M, nx=800, dx=50.0, a=1000.0, t_end=40000.0, tol=5e-4, sponge_w=5000.0):
    H = M * H0
    meta, arr = make(name, shape="ridge", H=H, s=ridge_a(H, a), nx=nx, dx=dx, h0=H0, b0=B0, U0=F0 * C0,
                     sponge=(sponge_w, 600.0), t_end=t_end, steady_tol=tol)
    return meta, arr


# ---------------- генератор и ввод-вывод ----------------

def test_shapes_params():
    meta, arr = swcase.make_case("a", shape="ridge", H=100.0, s=0.25, nx=2000, dx=5.0)
    z = arr["zb"][0]
    assert z.max() == pytest.approx(100.0, rel=1e-3)
    assert np.abs(np.diff(z)).max() / 5.0 == pytest.approx(0.25, rel=2e-2)
    m2, a2 = swcase.make_case("b", shape="hill", dim=2, nx=40, ny=30, dx=100.0, H=60.0)
    assert a2["zb"].shape == (30, 40) and m2["grid"]["dy"] == 100.0
    assert m2["grid"]["x0"] == -2000.0 and m2["grid"]["y0"] == -1500.0
    m3, a3 = swcase.make_case("c", shape="step_up", H=80.0, s=0.1, nx=400, dx=50.0)
    assert a3["zb"][0, 0] < 1.0 and a3["zb"][0, -1] > 79.0


def test_io_roundtrip(tmp_path):
    meta, arr = make("t", nx=50)
    path = swcase.write_case(str(tmp_path), meta, arr)
    m2, a2 = swio.read_pair(path)
    assert m2["name"] == "t" and np.allclose(a2["zb"], arr["zb"], atol=1e-3)


# ---------------- T1 покой ----------------

@pytest.mark.parametrize("dim", [1, 2])
def test_T1_rest_dry_summit(tmp_path, dim):
    n = 160 if dim == 1 else 48
    kw = dict(shape="hill", H=1.4 * H0, s=0.5, dim=dim, nx=n, ny=1 if dim == 1 else n, dx=100.0, h0=H0, b0=B0,
              U0=0.0, bc=("wall",) * 4, sponge=None, h_min=0.5)
    meta, arr = make("t1", **kw)
    meta["run"]["t_end"] = steps_time(2000, 100.0)
    meta["run"]["steady_tol"] = -1.0
    f, rec = run(tmp_path, (meta, arr))
    assert rec["steps"] >= 1800 and rec["dry_cells"] > 0
    assert np.abs(f["hu"]).max() < 1e-10 * H0 * C0 and np.abs(f["hv"]).max() < 1e-10 * H0 * C0
    # сухие остаются сухими
    assert (f["wet"][arr["zb"] > H0 + 1.0] == 0).all()


# ---------------- T2 Риттер ----------------

def test_T2_ritter(tmp_path):
    hL, nx, dx = 100.0, 1200, 4.0
    meta, arr = make("t2", shape="flat", nx=nx, dx=dx, h0=hL, b0=B0, U0=0.0, bc=("transmissive",) * 2 + (None,) * 2,
                     sponge=None, t_end=120.0, steady_tol=-1.0)
    x = meta["grid"]["x0"] + (np.arange(nx) + 0.5) * dx
    arr["h_init"] = np.where(x < 0, hL, 0.0)[None, :]
    f, rec = run(tmp_path, (meta, arr))
    t, cL = rec["t"], math.sqrt(B0 * hL)
    xi = x / t
    inside = (xi > -cL) & (xi < 2 * cL)
    h_ex = np.where(xi <= -cL, hL, np.where(inside, (2 * cL - xi) ** 2 / (9 * B0), 0.0))
    l1 = np.abs(f["h"][0] - h_ex).sum() / h_ex.sum()
    assert l1 < 0.03
    assert rec["mass_rel_err"] < 1e-10


# ---------------- T3, T4, T5, T6 стационарные режимы над гребнем ----------------

def _bern_check(tmp_path, F0, M, branch):
    meta, arr = ridge_case("bern", F0, M)
    f, rec = run(tmp_path, (meta, arr))
    assert rec["status"] == "steady", rec
    a = meta["source"]["a"]
    x = meta["grid"]["x0"] + (np.arange(meta["grid"]["nx"]) + 0.5) * meta["grid"]["dx"]
    sel = np.abs(x) < 5 * a
    z = arr["zb"][0]
    ex = np.array([eta_root(F0, zz / H0, branch) for zz in z[sel]]) * H0
    err = np.abs(f["h"][0][sel] - ex).max() / H0
    return err, f, rec, meta, arr


def test_T3_subcritical_bernoulli(tmp_path):
    err, *_ = _bern_check(tmp_path, 0.5, 0.1, "sub")
    assert err < 5e-3


def test_T4_supercritical_bernoulli(tmp_path):
    err, *_ = _bern_check(tmp_path, 2.0, 0.2, "sup")
    assert err < 5e-3


def _crest(f, arr, meta):
    # гребень в x = 0 лежит между двумя центрами клеток: значения на гребне — среднее двух соседних клеток
    z = arr["zb"][0]
    i = int(np.argmax(z))
    j = i + 1 if z[i + 1] > z[i - 1] else i - 1
    h = 0.5 * (f["h"][0][i] + f["h"][0][j])
    hu = 0.5 * (f["hu"][0][i] + f["hu"][0][j])
    return i, abs(hu / h) / math.sqrt(B0 * h), hu, h


T5 = {}


def run_T5(tmp_path):
    if "r" not in T5:
        meta, arr = ridge_case("t5", 0.5, 0.5)
        T5["r"] = run(tmp_path, (meta, arr)) + (meta, arr)
    return T5["r"]


def test_T5_critical_crest(tmp_path):
    f, rec, meta, arr = run_T5(tmp_path)
    assert rec["status"] == "steady", rec
    i, fr, q, h = _crest(f, arr, meta)
    assert 0.85 <= fr <= 1.15
    assert q == pytest.approx(math.sqrt(B0 * h ** 3), rel=0.02)
    a = meta["source"]["a"]
    x = meta["grid"]["x0"] + (np.arange(meta["grid"]["nx"]) + 0.5) * meta["grid"]["dx"]
    sel = (x > a) & (x < 1.5 * a)  # прыжок стоит у ~1,8a (сопряжённая глубина), поэтому до 1,5a
    frs = np.abs(f["hu"][0][sel] / f["h"][0][sel]) / np.sqrt(B0 * f["h"][0][sel])
    assert frs.min() > 1.0


CASES6 = [(F0, k * 1.0, m) for F0 in (0.3, 0.5, 0.7) for k, m in ((0.5, "lo"), (1.25, "hi"))] + \
         [(1.5, 0.5, "lo"), (2.0, 0.5, "lo")]


@pytest.mark.parametrize("F0,k,kind", CASES6)
def test_T6_regime_switch(tmp_path, F0, k, kind):
    M = k * Mc(F0)
    meta, arr = ridge_case("t6", F0, M, nx=400, dx=100.0)
    f, rec = run(tmp_path, (meta, arr))
    i, fr, q, h = _crest(f, arr, meta)
    if kind == "lo":
        branch = "sub" if F0 < 1 else "sup"
        eta = eta_root(F0, M, branch)
        assert rec["status"] == "steady", rec
        assert abs(fr - F0 / eta ** 1.5) < 0.03
    else:
        assert 0.85 <= fr <= 1.15


# ---------------- T7 масса, T8 1D = 2D ----------------

def test_T7_mass_2d_periodic(tmp_path):
    n = 40
    meta, arr = make("t7", shape="hill", H=200.0, s=0.4, dim=2, nx=n, ny=n, dx=200.0, h0=H0, b0=B0, U0=3.0, V0=1.0,
                     bc=("periodic",) * 4, sponge=None, steady_tol=-1.0)
    meta["run"]["t_end"] = steps_time(1000, 200.0)
    f, rec = run(tmp_path, (meta, arr))
    assert rec["steps"] >= 900 and rec["status"] != "diverged"
    assert rec["mass_rel_err"] < 1e-10


def test_T8_1d_equals_2d(tmp_path):
    kw = dict(shape="ridge", H=100.0, s=0.3, nx=200, dx=100.0, h0=H0, b0=B0, U0=3.0, sponge=(3000.0, 600.0),
              steady_tol=-1.0, t_end=1500.0)
    m1, a1 = make("o1", dim=1, **kw)
    m2, a2 = make("o2", dim=2, ny=4, bc=("farfield", "farfield", "periodic", "periodic"), **kw)
    f1, r1 = run(tmp_path, (m1, a1))
    f2, r2 = run(tmp_path, (m2, a2))
    assert np.abs(f2["h"] - f1["h"]).max() / H0 < 1e-10
    assert np.abs(f2["hv"]).max() == 0.0


# ---------------- T9 трение + сила, T10 нагрев ----------------

def test_T9_friction_balance(tmp_path):
    meta, arr = swcase.make_case("t9", shape="flat", nx=100, dx=100.0, h0=H0, b0=B0, U0=4.0, cd=0.003,
                                 forcing="balance", sponge=None, steady_tol=-1.0)
    meta["run"]["t_end"] = steps_time(1000, 100.0, extra=4.0)
    f, rec = run(tmp_path, (meta, arr))
    assert rec["steps"] >= 900
    assert np.abs(f["hu"] / f["h"] - 4.0).max() / 4.0 < 1e-10


def test_T10_heating(tmp_path):
    Q, t = 200.0, 1000.0
    meta, arr = swcase.make_case("t10", shape="flat", nx=20, dx=100.0, h0=H0, b0=B0, U0=0.0, cd=0.0,
                                 forcing="none", bc=("periodic",) * 2 + (None,) * 2, sponge=None, q_heat=Q,
                                 steady_tol=-1.0, t_end=t)
    f, rec = run(tmp_path, (meta, arr))
    rate = 9.81 / 290.0 * Q / 1206.0
    exp = H0 * B0 - rate * t
    assert np.abs(f["hb"] / exp - 1).max() < 1e-10
    assert rec["b_clipped"] == 0
    meta["run"]["t_end"] = H0 * B0 / rate * 1.2
    meta["name"] = "t10b"
    f, rec = run(tmp_path, (meta, arr))
    assert rec["b_clipped"] == 20
    assert (f["hb"] / f["h"]).min() >= 1e-4 * (1 - 1e-9)


# ---------------- T11 статусы SW3, CLI ----------------

def test_T11_statuses(tmp_path):
    f, rec, meta, arr = run_T5(tmp_path)
    assert rec["status"] == "steady"
    m = json.loads(json.dumps(meta))
    m["name"] = "t11a"
    m["run"]["t_end"] = 300.0
    f, rec = run(tmp_path, (m, arr))
    assert rec["status"] == "max_time" and "h_mean" not in f
    m["name"] = "t11b"
    m["run"]["avg_from"] = 100.0
    f, rec = run(tmp_path, (m, arr))
    assert rec["status"] == "averaged" and "u_mean" in f
    d = json.load(open(rec["field"]))
    assert d["mean"]["t_from"] == pytest.approx(100.0) and d["mean"]["n"] > 0


def test_cli_exit_and_contract(tmp_path):
    py = os.path.join(ROOT, "py")
    out = str(tmp_path / "x")
    subprocess.run([py, "-m", "swpy", "case", "ideal", "--name", "cli1", "--nx", "100", "--H", "20", "--U0", "2",
                    "--t-end", "600", "--out", out], check=True, capture_output=True)
    r = subprocess.run([py, "-m", "swpy", "run", os.path.join(out, "cli1.json"), "--out", out, "-q"],
                       capture_output=True)
    assert r.returncode == 0
    chk = subprocess.run(["python3", os.path.join(ROOT, "contract", "check_contract.py"), out],
                         capture_output=True, text=True)
    assert chk.returncode == 0 and "проверено 3, FAIL 0" in chk.stdout, chk.stdout
