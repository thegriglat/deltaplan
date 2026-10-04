"""Контрактный тест S5 v2 (без GPU): наборы, формы, типы, атрибуты; план; вид VDS = части; запись/чтение; NaN — ошибка."""
import sys
from pathlib import Path

import h5py
import numpy as np
import pytest

SOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOL))
import s5_io as S5   # noqa: E402

ATTRS = dict(shard_size=3, relief_corpus="/x", conditions="/y", solver_version="s0-abc1234", max_outer=1000, late_from=500, late_step=50,
             agl_m=np.array(S5.AGL_M, "<i4"), dx_m=400.0, x0_m=-19200.0, y0_m=-19200.0, device="gpu", workers=3)


def fake(m, first, seed=0):
    rng = np.random.default_rng(seed + first)
    cs = np.zeros(m, S5.CASES_DTYPE)
    cs["case"] = np.arange(first, first + m); cs["relief_id"] = cs["case"] // 2; cs["cond_id"] = cs["case"] % 2
    cs["status_h"] = 1; cs["target_h"] = 1; cs["late_n_h"] = 11
    f = lambda *s: rng.standard_normal((m,) + s).astype("f4")
    return cs, f(3, 13, 96, 96), f(4, 13, 96, 96), 1000 + f(96, 96), f(96, 96), 500 + f(96, 96)


def write(d, sizes=(3, 3, 2)):
    first = 0
    for k, m in enumerate(sizes):
        S5.write_part(d, k, *fake(m, first), ATTRS)
        first += m
    return first


def test_plan_groups():
    p = S5.make_plan([0, 1, 2], [7, 8], 12)
    assert len(p) == 60 and p[0] == [0, 0, "train"] and p[11] == [0, 11, "train"] and p[36] == [7, 0, "holdout"]
    assert p == S5.make_plan([0, 1, 2], [7, 8], 12)
    m = S5.plan_model()
    assert len(m) == 360 * 12 and {x[2] for x in m[:3600]} == {"train"} and m[3600] == [300, 0, "holdout"]
    assert S5.group_bounds(m) == {"train": (0, 3600), "holdout": (3600, 4320)}
    r = S5.plan_real([(5, "pool"), (3, "holdout"), (1, "pool"), (9, "game")], 2)
    assert r == [[1, 0, "train"], [1, 1, "train"], [5, 0, "train"], [5, 1, "train"], [3, 0, "holdout"], [3, 1, "holdout"]]


def test_part_schema_and_view(tmp_path):
    n = write(tmp_path)
    r = S5.build_view(tmp_path, n)
    assert r == dict(n_records=8, complete=True, parts=3)
    with h5py.File(tmp_path / "part-00000.h5") as f:
        assert f.attrs["contract"] == "S5 v2" and f.attrs["kind"] == "solve" and f.attrs["complete"]
        for a in S5.REQUIRED_ATTRS:
            assert a in f.attrs, a
        for name, (tail, dt) in S5.DATASETS.items():
            ds = f[name]
            assert ds.shape == (3,) + tail and ds.dtype == np.dtype(dt), name
            if name.startswith(("fields", "inputs")):
                assert ds.chunks == (1,) + tail and ds.compression == "gzip" and ds.shuffle
    with h5py.File(tmp_path / "solve.h5") as v:
        assert v.attrs["n_records"] == 8 and v.attrs["complete"]
        for name in S5.DATASETS:
            assert v[name].is_virtual if hasattr(v[name], "is_virtual") else True
        assert v["fields/h"].shape == (8, 4, 13, 96, 96)
    s = S5.Solve(tmp_path)
    assert len(s) == 8 and list(s.cases["case"]) == list(range(8))
    q = S5.Solve.__new__(S5.Solve)   # части напрямую: то же
    (tmp_path / "solve.h5").unlink()
    p = S5.Solve(tmp_path)
    for i in range(8):
        for name in ("fields/m", "fields/h", "inputs/hc"):
            assert np.array_equal(s.get(name, i), p.get(name, i))
    s.close(); p.close()


def test_roundtrip_values(tmp_path):
    cs, fm, fh, hc, hf, hb = fake(3, 0)
    S5.write_part(tmp_path, 0, cs, fm, fh, hc, hf, hb, ATTRS)
    s = S5.Solve(tmp_path)
    assert np.array_equal(s.get("fields/m", 1), fm[1].astype("f2")) and np.array_equal(s.get("inputs/hc", 2), hc[2])
    assert s.attrs["group_codes"] == "0=train,1=holdout"
    s.close()


def test_view_deterministic_and_incomplete(tmp_path):
    write(tmp_path)
    S5.build_view(tmp_path, 8)
    a = (tmp_path / "solve.h5").read_bytes()
    S5.build_view(tmp_path, 8)
    assert a == (tmp_path / "solve.h5").read_bytes()
    assert S5.build_view(tmp_path, 12)["complete"] is False


def test_nan_is_error(tmp_path):
    cs, fm, fh, hc, hf, hb = fake(2, 0)
    fm[1, 0, 0, 0, 0] = np.nan
    with pytest.raises(ValueError):
        S5.write_part(tmp_path, 0, cs, fm, fh, hc, hf, hb, ATTRS)
    assert not list(tmp_path.glob("part-*.h5"))


def test_tmp_invisible_and_unknown_contract(tmp_path):
    write(tmp_path, (2,))
    (tmp_path / "part-00001.h5.tmp").write_bytes(b"junk")
    assert S5.cio.list_parts(tmp_path) == [0]
    with h5py.File(tmp_path / "part-00000.h5", "r+") as f:
        f.attrs["contract"] = "S5 v9"
    with pytest.raises(ValueError):
        S5.Solve(tmp_path)
