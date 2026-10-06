"""Построитель плана AP-2 (P1/P2): состав серий, сквозные case_id, ссылки ref_line_id, явные Numerics, круг pb → разбор."""
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import plan_build as PB  # noqa: E402

FS1 = Path.home() / "air_synth_data/corpus/fs1_10k"


def test_fr_points():
    f = PB.fr_points()
    assert len(f) == 30 and np.all(np.diff(f) > 0) and f[0] == 0.1 and f[-1] == 5.0
    assert len(PB.sweep_points(f)) == 18


def test_u10_roundtrip():
    assert abs(PB.fr_from_u10(PB.u10_from_fr(0.7)) - 0.7) < 1e-12
    assert abs(PB.u10_from_fr(1.0) * PB.MAX_PROFILE - 5.0) < 1e-9     # U_sat = Fr·N·h = 5 м/с


def test_ideal_specs_unique():
    sp = PB.ideal_specs()
    assert len(sp) == len(set(sp)) == 33


@pytest.mark.skipif(not (FS1 / "corpus.h5").exists(), reason="нет fs1_10k")
def test_plan_series_and_ids(tmp_path):
    plan, tab = PB.build_plan("t", tmp_path, quiet=True, corpus_out=str(tmp_path / "ideal"), write=True)
    assert tab["GRID"] == [81, 2430] and tab["SWEEP"] == [162, 2916] and tab["RELAX"] == [108, 1053]
    assert tab["SEPARATION"] == [80, 100] and tab["ERODED"] == [6, 180]
    assert tab["ENVELOPE"] == [240, 300] and tab["ENVELOPE_REAL"][1] == tab["ENVELOPE_REAL"][0]
    assert plan.n_cases == sum(t[1] for t in tab.values())
    pos = 0
    ids = {r.relief_id for r in plan.reliefs}
    assert len(ids) == len(plan.reliefs), "relief_id уникальны в плане"
    assert len({(r.corpus, r.corpus_relief_id) for r in plan.reliefs}) == len(plan.reliefs)
    byid = {l.line_id: l for l in plan.lines}
    for ln in plan.lines:
        n = len(ln.fr_f64) // 8
        assert ln.first_case_id == pos
        pos += n
        nm = ln.numerics
        assert nm.tol > 0 and nm.k_floor_m2s > 0 and nm.omega_u > 0 and nm.snap_step > 0 and nm.late_step > 0
        if ln.ref_line_id >= 0 and ln.series in (PB.pb.SWEEP, PB.pb.RELAX, PB.pb.SEPARATION):
            r = byid[ln.ref_line_id]
            assert r.series == PB.pb.GRID and r.relief_id == ln.relief_id and r.heat_flux_wm2 == ln.heat_flux_wm2
            assert r.h_over_zi == ln.h_over_zi and r.wdir_from_deg == ln.wdir_from_deg
        assert (nm.envelope_angle_deg > 0) == (nm.envelope_wall != 0)
        if ln.series == PB.pb.ENVELOPE:
            r = byid[ln.ref_line_id]
            assert r.series == PB.pb.SEPARATION and r.numerics.dx_m == 100.0 and r.relief_id == ln.relief_id and r.fr_f64 == ln.fr_f64
            assert nm.dx_m == 400.0 and nm.envelope_angle_deg in (8.0, 12.0, 18.0)
        if ln.series == PB.pb.ENVELOPE_REAL:
            assert ln.conditions and ln.cond_id >= 0 and len(ln.fr_f64) == 8 and ln.heat_flux_wm2 in (-1.0, 0.0)
            if nm.envelope_angle_deg > 0:
                assert byid[ln.ref_line_id].cond_id == ln.cond_id and byid[ln.ref_line_id].numerics.envelope_angle_deg == 0
        if ln.series == PB.pb.SWEEP:
            fr = np.frombuffer(ln.fr_f64, "<f8")
            assert ln.start == PB.pb.WARM_PREV and ln.ref_line_id >= 0
            assert np.all(np.diff(fr) > 0) == (ln.direction == PB.pb.UP)
        if ln.series == PB.pb.SEPARATION:
            assert (nm.dx_m, nm.advection_order) in ((100.0, 2), (400.0, 1))
    assert (tmp_path / "t/plan.pb").exists() and (tmp_path / "t/plan.json").exists()
    p2 = PB.pb.Plan()
    p2.ParseFromString((tmp_path / "t/plan.pb").read_bytes())
    assert p2 == plan
    import corpus_io as cio
    c = cio.Corpus(str(tmp_path / "ideal"))
    assert len(c) == 33 and c.attrs["generator_version"] in ("ideal-v1", b"ideal-v1")
    c.close()


@pytest.mark.skipif(not (FS1 / "corpus.h5").exists(), reason="нет fs1_10k")
def test_eroded_deterministic():
    a, b = PB.pick_eroded(str(FS1), 33), PB.pick_eroded(str(FS1), 33)
    assert a == b and len(a) == 6 and len({x["id"] for x in a}) == 6
    assert all(PB.ERODED_RELIEF_RANGE[0] <= x["relief_m"] <= PB.ERODED_RELIEF_RANGE[1] and x["id"] >= 33 for x in a)


def test_fixed_u_composition():
    pts = PB.fixed_u_points()
    assert len(pts) == 74 and len(PB.fixed_u_relief_specs(pts)) == 62
    for p in pts:
        assert p["u_sat"] in (3.0, 6.0) and 0.15 * 0.99 <= p["fr"] <= 3.0 * 1.01
        assert p["fr"] * p["n_bv"] * p["h_m"] == pytest.approx(p["u_sat"])        # U_sat фиксирован точно
        if p["variant"] == "n_axis":
            assert PB.FU_N_RANGE[0] - 1e-12 <= p["n_bv"] <= PB.FU_N_RANGE[1] + 1e-12 and p["h_m"] in (250.0, 500.0, 1000.0, 1500.0)
        else:
            assert p["n_bv"] == 0.01 and PB.FU_H_RANGE[0] <= p["h_m"] <= PB.FU_H_RANGE[1] and p["h_m"] == round(p["h_m"])
    # ближайшее к 500 запасное h: Fr = 0,15 при U_sat = 3 → h = 1000 (250 даёт N = 0,08)
    p0 = [p for p in pts if p["variant"] == "n_axis" and p["u_sat"] == 3.0][0]
    assert p0["h_m"] == 1000.0 and abs(p0["fr"] - 0.15) < 1e-9


# ------------------------------------------------------------------ RERUN (P2 v6, AP-14) — на заглушке
def _stub_source(root, name, statuses):
    """Мини-план-источник: GRID (холодная, 3 точки), SWEEP (тёплая, 3), ENVELOPE_REAL (conditions, 1), RELAX (3) +
    часть P3 только с `cases` (case_id, status)."""
    import h5py
    pb = PB.pb
    plan = pb.Plan(contract="P2 v3", name=name)
    c = plan.context
    c.lat, c.lon, c.month, c.day, c.hour_local, c.utc_offset, c.alpha, c.max_profile = 50.0, 86.0, 7, 15, 12.0, 7.0, 0.24, 2.341
    for i, (corpus, cid) in enumerate((("corpus/ideal_v1", 4), ("real/hg_v2", 17))):
        r = plan.reliefs.add()
        r.relief_id, r.corpus, r.corpus_relief_id, r.h_m, r.name = i, corpus, cid, 500.0, f"r{i}"
    nxt = 0
    for ser, start, rel, fr, cond, variant, om in ((pb.GRID, pb.COLD, 0, [0.5, 0.7, 1.0], "", "", 1.0),
                                                   (pb.SWEEP, pb.WARM_PREV, 0, [0.5, 0.7, 1.0], "", "up", 1.0),
                                                   (pb.ENVELOPE_REAL, pb.COLD, 1, [0.3], "s2/x", "nonconv_lowfr", 1.0),
                                                   (pb.RELAX, pb.COLD, 0, [0.5, 0.7, 1.0], "", "kfloor", 1.0)):
        ln = plan.lines.add()
        ln.line_id, ln.series, ln.relief_id, ln.start, ln.variant = len(plan.lines) - 1, ser, rel, start, variant
        ln.heat_flux_wm2, ln.h_over_zi, ln.n_bv_s, ln.wdir_from_deg = (-1.0, 0.0, 0.0, 0.0) if cond else (100.0, 1.0, 0.01, 270.0)
        ln.conditions, ln.cond_id = (cond, 3) if cond else ("", -1)
        ln.ref_line_id = 0 if ser in (pb.SWEEP, pb.RELAX) else -1
        PB._numerics(ln.numerics, omega_u=om, omega_k=om, k_floor_m2s=10.0 if variant == "kfloor" else 1.0,
                     top_above_m=0.0, sponge_top_m=0.0)          # как в старых планах (P2 v3/v4)
        ln.fr_f64 = np.asarray(fr, "<f8").tobytes()
        ln.first_case_id = nxt
        nxt += len(fr)
    plan.n_cases = nxt
    d = root / name
    d.mkdir(parents=True)
    (d / "plan.pb").write_bytes(plan.SerializeToString())
    res = root / f"{name}__s1-stub000"
    res.mkdir()
    with h5py.File(res / "part-00000.h5", "w") as h:
        h["cases"] = np.array(list(zip(range(nxt), statuses)), dtype=[("case_id", "i8"), ("status", "i1")])
    return plan


def test_rerun_plan_stub(tmp_path):
    pb = PB.pb
    # GRID: 0 ok, 1 max, 2 max; SWEEP 3..5 — все max (пропуск); ENVELOPE_REAL 6 max; RELAX 7 max, 8 ok, 9 diverged
    src = _stub_source(tmp_path, "src_a", [0, 1, 1, 1, 1, 1, 1, 1, 0, 2])
    plan, tab = PB.build_rerun_plan("rr", ("src_a",), tmp_path, quiet=True)
    assert plan.contract == "P2 v6" and plan.context == src.context
    assert tab == {"GRID": [1, 2], "RELAX": [1, 2], "ENVELOPE_REAL": [1, 1]}
    lines = list(plan.lines)
    assert [pb.Series.Name(l.series) for l in lines] == ["RERUN"] * 3
    # порядок по приоритету исходной серии: GRID → RELAX → ENVELOPE_REAL; case_id сквозные
    ids = [np.frombuffer(l.src_case_ids_i64, "<i8").tolist() for l in lines]
    assert ids == [[1, 2], [7, 9], [6]]
    assert [l.first_case_id for l in lines] == [0, 2, 4] and plan.n_cases == 5
    srcl = {l.line_id: l for l in src.lines}
    for l, s in zip(lines, (srcl[0], srcl[3], srcl[2])):
        assert l.src_plan == "src_a" and l.start == pb.COLD and l.ref_line_id == -1 and l.direction == pb.DIR_NONE
        fr = np.frombuffer(l.fr_f64, "<f8")
        sfr = np.frombuffer(s.fr_f64, "<f8")
        assert np.allclose(fr, sfr[np.asarray(np.frombuffer(l.src_case_ids_i64, "<i8")) - s.first_case_id])
        nm = l.numerics
        assert (nm.omega_u, nm.omega_k, nm.max_outer, nm.late_from, nm.late_step) == (0.5, 0.5, 2000, 1500, 50)
        assert nm.k_floor_m2s == s.numerics.k_floor_m2s and nm.tol == s.numerics.tol      # остальное как у исходной
        assert nm.top_above_m == 3000.0 and nm.sponge_top_m == 1000.0 and nm.lam_m == 0.0
        assert (l.heat_flux_wm2, l.h_over_zi, l.n_bv_s, l.conditions, l.cond_id, l.variant) == \
            (s.heat_flux_wm2, s.h_over_zi, s.n_bv_s, s.conditions, s.cond_id, s.variant)
        r = {x.relief_id: x for x in plan.reliefs}[l.relief_id]
        r0 = {x.relief_id: x for x in src.reliefs}[s.relief_id]
        assert (r.corpus, r.corpus_relief_id) == (r0.corpus, r0.corpus_relief_id)
    assert len({(r.corpus, r.corpus_relief_id) for r in plan.reliefs}) == len(plan.reliefs) == 2
    # контрактный тест плана P2 и разбор через phase_io (src_case_id у Case)
    import os
    sys.path.insert(0, str(HERE))
    import test_contract_phase as TC
    os.environ["AP_PLAN_DIR"] = str(tmp_path / "rr")
    try:
        TC.test_plan_file()
    finally:
        del os.environ["AP_PLAN_DIR"]
    import phase_io as PIO
    _, _, _, _, cases = PIO.load_plan(tmp_path / "rr")
    assert [c.src_case_id for c in cases] == [1, 2, 7, 9, 6] and all(c.series == pb.RERUN for c in cases)
    # тёплая линия без пропуска — ошибка; разные контексты источников — ошибка
    with pytest.raises(ValueError):
        PB.build_rerun_plan("rr2", ("src_a",), tmp_path, skip=(), write=False, quiet=True)
    b = _stub_source(tmp_path, "src_b", [1] * 10)
    b.context.lat = 10.0
    (tmp_path / "src_b/plan.pb").write_bytes(b.SerializeToString())
    with pytest.raises(ValueError):
        PB.build_rerun_plan("rr3", ("src_a", "src_b"), tmp_path, write=False, quiet=True)
