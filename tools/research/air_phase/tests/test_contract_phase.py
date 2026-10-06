"""Контрактные тесты air-phase (docs/contracts/air-phase.md, P1 v1, P2 v5, P3 v2, P4 v4, P5 v1).

Без данных проверяется схема (.proto, константы P3); с данными — реальные файлы:
  AP_PLAN_DIR=<$AIR_SYNTH_DATA/phase/<plan>>          — plan.pb (P2)
  AP_RESULTS_DIR=<$AIR_SYNTH_DATA/phase/<plan>__<v>>  — part-*.h5 (P3)
Исполнители дополняют тестами круга «запись → чтение» на искусственных данных (P1, P3, P4), не меняя схему ниже
без правки контракта (версия +1).
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
PROTO = HERE.parent / "proto" / "phase_plan.proto"

P2_CONTRACT = "P2 v5"
P3_CONTRACT = "P3 v2"
AGL_M = [25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000]
SNAP_LEVELS = [25, 600]

PROTO_FIELDS = {
    "Context": ["lat", "lon", "month", "day", "hour_local", "utc_offset", "alpha", "max_profile", "base_m", "h_m"],
    "Relief": ["relief_id", "name", "shape", "slope", "h_m", "a_m", "length_m", "corpus", "corpus_relief_id"],
    "Numerics": ["dx_m", "advection_order", "omega_u", "omega_k", "k_floor_m2s", "criterion", "tol", "max_outer",
                 "snap_from", "snap_step", "late_from", "late_step", "envelope_angle_deg", "envelope_wall",
                 "envelope_z0_m", "top_above_m", "sponge_top_m"],
    "Line": ["line_id", "series", "relief_id", "heat_flux_wm2", "h_over_zi", "n_bv_s", "wdir_from_deg", "numerics",
             "start", "direction", "fr_f64", "ref_line_id", "first_case_id", "variant", "conditions", "cond_id"],
    "Plan": ["contract", "name", "created", "git_commit", "command", "context", "reliefs", "lines", "n_cases"],
}

CASES_FIELDS = {
    "case_id": "i8", "line_id": "i4", "k": "i4", "series": "i1", "relief_id": "i4", "fr": "f4", "froude_table": "f4",
    "u10": "f4", "u_sat": "f4", "wdir_from_deg": "f4", "n_bv": "f4", "z_i_agl_m": "f4", "heat_flux_wm2": "f4",
    "zi_over_L": "f4", "dx_m": "f4", "start_case_id": "i8", "status": "i1", "iters": "i4", "target": "i1",
    "late_n": "i2", "late_spread60_p90": "f4", "resid_final": "f4", "resid_rel_final": "f4", "seconds": "f4",
    "batch_size": "i2", "cond_id": "i4", "envelope_angle_deg": "f4", "envelope_wall": "i1",
}
BUBBLE_FIELDS = ["has_reverse", "L_over_h", "H_over_h", "urev_over_U", "xc_over_h", "zc_over_h", "area_rev_frac",
                 "shadow_angle_deg", "fr_local", "slope_lee"]
ROOT_ATTRS = ["contract", "kind", "plan", "plan_sha256", "solver_version", "device", "batch_size", "git_commit",
              "created", "command", "n_records", "agl_m", "snap_levels_agl_m"]
SERIES_SEPARATION = 4
SERIES_ENVELOPE = (6, 7)


def _messages(text):
    out = {}
    for m in re.finditer(r"message\s+(\w+)\s*\{(.*?)\n\}", text, re.S):
        out[m.group(1)] = re.findall(r"^\s*(?:repeated\s+)?[\w.]+\s+(\w+)\s*=\s*\d+;", m.group(2), re.M)
    return out


def test_proto_schema():
    text = PROTO.read_text(encoding="utf-8")
    assert "package deltaplan.airphase.v1;" in text
    msgs = _messages(text)
    for name, fields in PROTO_FIELDS.items():
        assert name in msgs, name
        missing = [f for f in fields if f not in msgs[name]]
        assert not missing, (name, missing)
    assert re.search(r"bytes\s+fr_f64\s*=", text), "точки Fr — bytes, не repeated double"


def _plan_pb2():
    """Модуль, сгенерированный из .proto (AP-2 кладёт phase_plan_pb2.py рядом с .proto)."""
    import importlib.util
    p = PROTO.with_name("phase_plan_pb2.py")
    if not p.exists():
        pytest.skip("phase_plan_pb2.py ещё не сгенерирован (AP-2)")
    spec = importlib.util.spec_from_file_location("phase_plan_pb2", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.mark.skipif(not os.environ.get("AP_PLAN_DIR"), reason="AP_PLAN_DIR не задан")
def test_plan_file():
    pb2 = _plan_pb2()
    plan = pb2.Plan()
    plan.ParseFromString((Path(os.environ["AP_PLAN_DIR"]) / "plan.pb").read_bytes())
    assert plan.contract in (P2_CONTRACT, "P2 v4", "P2 v3")   # ap_v1 записан как v3 (без FIXED_U) — читается
    ids = {r.relief_id for r in plan.reliefs}
    assert len(ids) == len(plan.reliefs), "relief_id уникален в плане"
    assert len({(r.corpus, r.corpus_relief_id) for r in plan.reliefs}) == len(plan.reliefs)
    expect = 0
    for ln in sorted(plan.lines, key=lambda x: x.first_case_id):
        assert ln.relief_id in ids
        fr = np.frombuffer(ln.fr_f64, dtype="<f8")
        assert fr.size > 0 and np.all(np.isfinite(fr)) and np.all(fr > 0)
        assert ln.first_case_id == expect, "case_id сквозные и плотные"
        expect += fr.size
        nm = ln.numerics
        assert nm.dx_m in (100.0, 400.0) and nm.advection_order in (1, 2) and nm.max_outer > 0
        assert ln.start in (1, 2)
        if ln.conditions:
            assert ln.cond_id >= 0 and fr.size == 1 and ln.heat_flux_wm2 in (-1.0, 0.0)
        else:
            assert ln.n_bv_s > 0 and ln.h_over_zi > 0 and ln.cond_id == -1
        assert (nm.envelope_angle_deg > 0) == (nm.envelope_wall != 0)
    assert plan.n_cases == expect


@pytest.mark.skipif(not os.environ.get("AP_RESULTS_DIR"), reason="AP_RESULTS_DIR не задан")
def test_results_parts():
    h5py = pytest.importorskip("h5py")
    parts = sorted(Path(os.environ["AP_RESULTS_DIR"]).glob("part-*.h5"))
    assert parts, "нет частей"
    seen = set()
    for p in parts:
        with h5py.File(p, "r") as h:
            for a in ROOT_ATTRS:
                assert a in h.attrs, (p.name, a)
            assert h.attrs["contract"] == P3_CONTRACT and h.attrs["kind"] == "phase"
            assert list(h.attrs["agl_m"]) == AGL_M and list(h.attrs["snap_levels_agl_m"]) == SNAP_LEVELS
            c = h["cases"]
            m = c.shape[0]
            assert m == int(h.attrs["n_records"])
            for f, t in CASES_FIELDS.items():
                assert f in c.dtype.names, (p.name, f)
                assert c.dtype[f] == np.dtype(t), (p.name, f, c.dtype[f])
            ids = c["case_id"][:]
            assert not (seen & set(ids.tolist())), "дубли case_id между частями"
            seen |= set(ids.tolist())
            f = h["fields/f"]
            assert f.shape == (m, 4, 13, 96, 96) and f.dtype == np.float16
            assert np.all(np.isfinite(f[...]))
            for k, dt in (("inputs/hc", np.float32), ("inputs/heat_flux", np.float16), ("inputs/hbl", np.float16)):
                assert h[k].shape == (m, 96, 96) and h[k].dtype == dt
            t = h["trace/iter"].shape[1]
            assert h["trace/iter"].shape == (m, t) and h["trace/iter"].dtype == np.int32
            assert h["trace/resid"].shape == (m, t) and h["trace/du_max"].shape == (m, t)
            assert h["trace/fields"].shape == (m, t, 3, 2, 96, 96) and h["trace/fields"].dtype == np.float16
            assert h["order"].shape == (m,)
            if np.any(c["series"][:] == SERIES_SEPARATION):
                assert "bubble" in h and h["bubble"].shape == (m,)
                for bf in BUBBLE_FIELDS:
                    assert bf in h["bubble"].dtype.names, bf
            if np.any(np.isin(c["series"][:], SERIES_ENVELOPE)):
                assert h["inputs/h_eff"].shape == (m, 96, 96) and h["inputs/h_eff"].dtype == np.float32
            if "window" in h:
                w = h["window/fields"]
                assert w.ndim == 5 and w.shape[1] == 4 and w.dtype == np.float16
                for a in ("dx_m", "x0_m", "y0_m", "agl_m", "case_id"):
                    assert a in w.attrs or a in h["window"], a


# --- P6, P7 (этап разбора) ---
P6_PLAN_FIELDS = ["shape", "slope", "h_m", "h_over_zi", "variant", "ref_case_id", "u10", "fr"]
P6_GROUPS = ("th_", "sl_", "lee_")
ANALYSIS = HERE.parent / "analysis"


@pytest.mark.skipif(not os.environ.get("AP_FEATURES"), reason="AP_FEATURES не задан")
def test_features_table():
    h5py = pytest.importorskip("h5py")
    import json
    with h5py.File(os.environ["AP_FEATURES"], "r") as h:
        for a in ("plan", "results", "git_commit", "p6_names"):
            assert a in h.attrs, a
        names = h["features"].dtype.names
        for f in list(CASES_FIELDS) + P6_PLAN_FIELDS:
            assert f in names, f
        for g in P6_GROUPS:
            assert any(n.startswith(g) for n in names), g
        desc = json.loads(h.attrs["p6_names"])
        assert all(n in desc for n in names if n.startswith(P6_GROUPS)), "у метрик слоёв нет описания с единицами"


@pytest.mark.parametrize("d", sorted(p for p in ANALYSIS.glob("AP-*") if p.is_dir()) if ANALYSIS.exists() else [],
                         ids=lambda p: p.name)
def test_analysis_dir(d):
    import json
    for f in ("run.py", "summary.json", "section.md"):
        assert (d / f).exists(), (d.name, f)
    json.loads((d / "summary.json").read_text(encoding="utf-8"))
    figs = list(d.glob("fig_*.png"))
    assert len(figs) <= 6, (d.name, len(figs))
    text = (d / "section.md").read_text(encoding="utf-8")
    for m in re.findall(r"\]\((fig_[^)]+\.png)\)", text):
        assert (d / m).exists(), (d.name, m)
