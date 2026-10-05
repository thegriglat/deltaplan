"""AP-3: run_phase.py — запись P3, продолжение после обрыва, тёплые цепочки (ckpt, фантомы), bubble.

Заглушка решателя (искусственные поля, детерминированные; состояние цепочки накапливается) проверяет каркас без GPU;
тест с настоящим `batch_solver` (если есть) — короткий счёт max_outer = 150 мини-плана (запускать под `dp lock gpu`).
"""
from __future__ import annotations

import dataclasses
import importlib.util
import os
import sys
import types
from pathlib import Path

import h5py
import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import phase_io as IO  # noqa: E402
import run_phase as RP  # noqa: E402
import bubble as B  # noqa: E402
import test_contract_phase as TC  # noqa: E402

pb = IO.pb
PLAN = IO.data_root() / "phase" / "ap_v1"


# ------------------------------------------------------------------ заглушка решателя
@dataclasses.dataclass
class State:
    acc: np.ndarray


@dataclasses.dataclass
class CaseSpec:
    g100: np.ndarray
    ctx: dict
    u10: float
    wdir_from_deg: float
    alpha: float
    max_profile: float
    n_bv_s: float | None
    z_i_agl_m: float | None
    heat_flux_wm2: float | None
    dx_m: float = 400.0
    cond_row: dict | None = None


@dataclasses.dataclass
class Numerics:
    advection_order: int = 1
    omega_u: float = 1.0
    omega_k: float = 1.0
    k_floor_m2s: float | None = None
    criterion: str = "abs"
    tol: float | None = None
    max_outer: int = 1000
    snap_from: int = 100
    snap_step: int = 50
    late_from: int = 500
    late_step: int = 50
    envelope_angle_deg: float = 0.0
    envelope_wall: str = "none"
    envelope_z0_m: float | None = None


def make_stub(fail_at=None):
    calls = dict(n=0)

    def solve_batch(specs, nums, init=None):
        calls["n"] += 1
        if fail_at is not None and calls["n"] == fail_at:
            raise RuntimeError("обрыв (заглушка)")
        out = []
        for sp, nm, st in zip(specs, nums, init or [None] * len(specs)):
            prev = st.acc if st is not None else np.zeros(8, np.float32)
            acc = (prev * np.float32(0.9) + np.float32(sp.u10)).astype(np.float32)
            g400 = sp.g100.reshape(96, 4, 96, 4).mean(axis=(1, 3))
            f = np.zeros((4, 13, 96, 96), np.float32)
            f[0] = acc[0] + np.linspace(0, 1, 96, dtype=np.float32)[None, None, :]
            f[1] = 0.1 * acc[0]
            f[2] = np.float32(1e-3) * (g400 - g400.mean())[None]
            f[3] = 0.01
            T = (nm.max_outer - nm.snap_from) // nm.snap_step + 1
            nt = min(T, 3)
            tr = dict(iter=np.array([nm.snap_from + nm.snap_step * i for i in range(nt)], np.int32),
                      resid=np.full(nt, 1e-4, np.float32), du_max=np.full(nt, 0.01, np.float32),
                      fields=np.repeat(f[None, :3][:, :, [0, 8]], nt, axis=0))
            r = dict(status="max" if sp.u10 < 1 else "ok", iters=nm.max_outer if sp.u10 < 1 else 300,
                     target="late_mean" if sp.u10 < 1 else "final", late_n=3, late_spread60_p90=0.1,
                     resid_final=1e-5, resid_rel_final=1e-3, fields=f, hc=g400.astype(np.float32),
                     heat_flux=np.full((96, 96), 50.0, np.float32), hbl=np.full((96, 96), 500.0, np.float32),
                     trace=tr, state=State(acc), seconds=0.0, froude_table=sp.u10 * sp.max_profile / 5.0,
                     zi_over_L=0.0)
            if nm.envelope_angle_deg > 0:
                r["h_eff"] = g400.astype(np.float32) + 1.0
            if sp.dx_m == 100.0:
                ny = 40 if sp.u10 < 5 else 48      # окна разной величины в одной части
                r["window"] = dict(meta=dict(dx_m=100.0, x0_m=-3000.0, y0_m=-2000.0, brink_x_m=0.0, brink_y_m=0.0,
                                             downwind_fit_over_h=15.5),
                                   fields=np.ones((4, 13, ny, 120), np.float32), status="ok", iters=200,
                                   agl_m=list(IO.AGL_M), hc=np.full((ny, 120), 1200.0, np.float32))
            out.append(r)
        return out

    m = types.SimpleNamespace(CaseSpec=CaseSpec, Numerics=Numerics, State=State, solve_batch=solve_batch,
                              solver_version=lambda: "s9-stub000", DEFAULT_BATCH=3, calls=calls)
    return m


def mini_plan(dst, per_series=None, npts=4, max_outer=None):
    """Мини-план из ap_v1: несколько линий каждой серии, ≤ npts точек, case_id перенумерованы плотно."""
    if not (PLAN / "plan.pb").exists():
        pytest.skip("нет плана ap_v1")
    plan = pb.Plan()
    plan.ParseFromString((PLAN / "plan.pb").read_bytes())
    per_series = per_series or {pb.GRID: 2, pb.SWEEP: 2, pb.SEPARATION: 2, pb.ENVELOPE: 1, pb.ENVELOPE_REAL: 1,
                                pb.RELAX: 1, pb.ERODED: 1}
    out = pb.Plan()
    out.CopyFrom(plan)
    del out.lines[:]
    cnt, nxt = {}, 0
    for ln in plan.lines:
        want = per_series.get(ln.series, 0)
        if ln.series == pb.SEPARATION:      # оба шага сетки
            key = (ln.series, ln.numerics.dx_m)
            want = 1 if per_series.get(ln.series, 0) else 0
        else:
            key = ln.series
        if cnt.get(key, 0) >= want:
            continue
        cnt[key] = cnt.get(key, 0) + 1
        n = out.lines.add()
        n.CopyFrom(ln)
        fr = np.frombuffer(ln.fr_f64, "<f8")[:npts]
        n.fr_f64 = fr.astype("<f8").tobytes()
        n.first_case_id = nxt
        if max_outer:
            n.numerics.max_outer = max_outer
            n.numerics.late_from = min(n.numerics.late_from, max_outer)
        nxt += fr.size
    out.n_cases = nxt
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "plan.pb").write_bytes(out.SerializeToString())
    return dst


def fields_by_case(d):
    out = {}
    for p in IO.parts(d):
        with h5py.File(p, "r") as h:
            ids = h["cases"]["case_id"][:]
            f = h["fields/f"][...]
            st = h["cases"]["start_case_id"][:]
            for j, c in enumerate(ids):
                out[int(c)] = (f[j], int(st[j]))
    return out


def check_contract(d):
    os.environ["AP_RESULTS_DIR"] = str(d)
    try:
        TC.test_results_parts()
    finally:
        del os.environ["AP_RESULTS_DIR"]


@pytest.fixture
def plan_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("AIR_SYNTH_DATA", str(IO.data_root()))
    return mini_plan(tmp_path / "plan" / "ap_mini")


def test_run_and_resume_bitwise(plan_dir, tmp_path):
    plan, _, _, _, cases = IO.load_plan(plan_dir)
    ra = RP.Runner(plan_dir, tmp_path / "A", batch=3, chunk=3, solver=make_stub(), inline_writer=True)
    assert ra.run() == 0
    fa = fields_by_case(ra.dir)
    assert sorted(fa) == [c.case_id for c in cases]
    check_contract(ra.dir)
    # обрыв на 4-м пакете, затем ckpt отстаёт (как при убийстве между частью и ckpt) и один пропадает совсем
    rb = RP.Runner(plan_dir, tmp_path / "B", batch=3, chunk=3, solver=make_stub(fail_at=4), inline_writer=False)
    assert rb.run() == 1
    ck = sorted((rb.dir / "ckpt").glob("*.h5")) if (rb.dir / "ckpt").exists() else []
    for p in ck[:1]:
        p.unlink()
    rb2 = RP.Runner(plan_dir, tmp_path / "B", batch=3, chunk=3, solver=make_stub(), inline_writer=False)
    assert rb2.run() == 0
    fb = fields_by_case(rb2.dir)
    assert sorted(fb) == sorted(fa), "без потерь и дублей"
    for cid in fa:
        assert np.array_equal(fa[cid][0], fb[cid][0]), cid
        assert fa[cid][1] == fb[cid][1], cid
    check_contract(rb2.dir)
    assert not list((rb2.dir / "ckpt").glob("*.h5")), "ckpt досчитанных линий удалены"
    # повтор — ничего не считает
    n_parts = len(IO.parts(rb2.dir))
    st = make_stub()
    assert RP.Runner(plan_dir, tmp_path / "B", batch=3, chunk=3, solver=st, inline_writer=True).run() == 0
    assert st.calls["n"] == 0 and len(IO.parts(rb2.dir)) == n_parts


def test_warm_chain_and_lost_part(plan_dir, tmp_path):
    """Тёплая цепочка: пропала последняя часть, ckpt новее нужного → пересчёт от холодного k = 0 (фантомы), поля те же."""
    ref = RP.Runner(plan_dir, tmp_path / "R", series="sweep", batch=2, chunk=2, solver=make_stub(), inline_writer=True)
    assert ref.run() == 0
    fr = fields_by_case(ref.dir)
    r = RP.Runner(plan_dir, tmp_path / "C", series="sweep", batch=2, chunk=2, limit=4, solver=make_stub(), inline_writer=True)
    assert r.run() == 0
    last = IO.parts(r.dir)[-1]
    last.unlink()
    st = make_stub()
    r2 = RP.Runner(plan_dir, tmp_path / "C", series="sweep", batch=2, chunk=2, solver=st, inline_writer=True)
    assert r2.run() == 0
    fc = fields_by_case(r2.dir)
    assert sorted(fc) == sorted(fr)
    for cid in fr:
        assert np.array_equal(fr[cid][0], fc[cid][0]), cid
    runs = [l for l in (r2.dir / "run.jsonl").read_text().splitlines() if '"batch"' in l]
    assert any('"phantoms": 0' not in l for l in runs), "был пересчёт без записи"


def test_series_order_and_batches(plan_dir, tmp_path):
    r = RP.Runner(plan_dir, tmp_path / "O", batch=2, chunk=2, solver=make_stub(), inline_writer=True)
    assert r.run() == 0
    import json
    first = []
    for l in (r.dir / "run.jsonl").read_text().splitlines():
        d = json.loads(l)
        if d["event"] == "batch":
            first.append(d["series"])
    assert first[0] == ["GRID"]
    ranks = [min(IO.SERIES_ORDER.index(s) for s in ss) for ss in first]
    assert ranks == sorted(ranks), "порядок серий"
    with h5py.File(IO.parts(r.dir)[0], "r") as h:
        c = h["cases"][:]
        assert len(set(c["k"].tolist())) == 1, "пакет поперёк линий: одна точка k"


# ------------------------------------------------------------------ bubble на аналитическом поле
def test_bubble_analytic():
    dx, nx, ny = 100.0, 200, 40
    x0, y0 = -5000.0, -2000.0
    xs = x0 + dx / 2 + dx * np.arange(nx)
    h, a = 500.0, 500.0
    z1 = h * (1 - np.tanh(xs / a)) / 2 + 1000
    ground = np.repeat(z1[None], ny, 0)
    agl = np.array(IO.AGL_M, float)
    d2 = np.gradient(np.gradient(z1, dx), dx)
    xb = xs[np.argmin(d2[: np.argmin(np.gradient(z1, dx)) + 1])]
    L, H, U = 3000.0, 160.0, 10.0
    f = np.zeros((4, 13, ny, nx), np.float32)
    for k, z in enumerate(agl):
        rev = (xs > xb) & (xs < xb + L) & (z < H)
        f[0, k] = np.where(rev, -2.0, U)[None]
    b = B.bubble(f, agl, x0, y0, dx, ground, (1.0, 0.0), h, U, 0.01,
                 up_profile=(agl, np.full(13, U), 1000.0))
    assert b["has_reverse"] == 1
    assert abs(b["L_over_h"] - L / h) < 0.5, b
    assert 150 / h <= b["H_over_h"] <= 200 / h, b
    assert b["urev_over_U"] == pytest.approx(-0.2)
    zr = np.interp(xb + L, xs, z1)
    ang = np.degrees(np.arctan2(np.interp(xb, xs, z1) - zr, L))
    assert abs(b["shadow_angle_deg"] - ang) < 1.0
    assert b["fr_local"] == pytest.approx(U / (0.01 * h))
    assert 0 < b["xc_over_h"] < L / h and b["zc_over_h"] < H / h + 0.2
    assert b["slope_lee"] == pytest.approx(h / (2 * a), rel=0.05)
    f[0] = U
    b0 = B.bubble(f, agl, x0, y0, dx, ground, (1.0, 0.0), h, U, 0.01)
    assert b0["has_reverse"] == 0 and b0["shadow_angle_deg"] == -1


# ------------------------------------------------------------------ настоящий решатель (GPU, под dp lock gpu)
def _real_solver():
    if importlib.util.find_spec("cupy") is None or not (HERE.parent / "batch_solver.py").exists():
        return None
    try:
        return RP.get_solver()
    except Exception:
        return None


def test_real_solver_mini(tmp_path, monkeypatch):
    S = _real_solver()
    if S is None:
        pytest.skip("batch_solver (AP-1) нет")
    pdir = mini_plan(tmp_path / "plan" / "ap_real", per_series={pb.GRID: 2, pb.SWEEP: 1, pb.SEPARATION: 1,
                                                                 pb.ENVELOPE: 1}, npts=2, max_outer=150)
    r = RP.Runner(pdir, tmp_path / "res", batch=2, chunk=2, solver=S)
    assert r.run() == 0
    check_contract(r.dir)
    plan, _, _, _, cases = IO.load_plan(pdir)
    assert len(IO.done_cases(r.dir)) == len(cases)
