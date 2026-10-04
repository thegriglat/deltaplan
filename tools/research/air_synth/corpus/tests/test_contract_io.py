"""Контрактный тест S1 v3 / S2 v2 (docs/contracts/air-synth.md): HDF5, части, вид VDS; на искусственных полях, без генератора."""
import os
import h5py
import numpy as np
import pytest
import corpus_io as cio

NAMES = ["mix", "t_total_yr"]


def field(seed=0):
    """Несимметричное поле: растёт на восток (i) и сильнее на север (j), плюс шум."""
    rng = np.random.default_rng(seed)
    j, i = np.mgrid[0:384, 0:384]
    return 1000.0 + 2.0 * i + 5.0 * j + rng.normal(0, 3, (384, 384))


def model_reliefs(n):
    return [dict(z100=field(i) + 10 * i, compute_seconds=0.5, params={"mix": i / 10, "t_total_yr": 1e6}, cloud_point=i % 3 - 1) for i in range(n)]


def make_corpus(path, n=5, shard_size=2):
    cio.write_reliefs(path, model_reliefs(n), shard_size=shard_size, generator_version="test-1", corpus_seed=7, columns=NAMES)
    return path


@pytest.fixture
def corpus(tmp_path):
    return make_corpus(str(tmp_path / "c"))


def test_layout_and_attrs(corpus):
    assert cio.list_parts(corpus) == [0, 1, 2] and os.path.exists(corpus + "/manifest.json")
    with h5py.File(corpus + "/corpus.h5", "r") as f:
        a = f.attrs
        assert a["contract"] == "S1 v3" and a["kind"] == "relief" and a["complete"] and a["n_records"] == 5 and a["shard_size"] == 2
        assert a["generator_version"] == "test-1" and a["corpus_seed"] == 7
        for k in ("created", "git_commit", "command"):
            assert k in a
        assert f["relief/id"].dtype == np.int64 and f["relief/id"].shape == (5,)
        assert f["relief/h100"].shape == (5, 384, 384) and f["relief/h100"].dtype == np.int16
        assert f["relief/h400"].shape == (5, 96, 96) and f["relief/h400"].dtype == np.int16
        for n, dx in (("relief/h100", 100), ("relief/h400", 400)):
            at = f[n].attrs
            assert at["offset_m"] == 2500.0 and at["scale_m"] == 0.15 and at["dx_m"] == dx and at["x0_m"] == at["y0_m"] == -19200
            assert at["units"] == "m above sea level" and at["axes"] == "record, j (north), i (east)"
        assert f["summary"].dtype.names == ("id", "h_min_m", "h_max_m", "relief_m", "slope_mean_deg_400", "slope_p95_deg_100", "compute_seconds")
        assert f["gen/params"].dtype.names == ("id", "corpus_seed", "cloud_point", "mix", "t_total_yr")
        assert f["gen/params"].dtype["cloud_point"] == np.int32 and f["gen/params"].dtype["corpus_seed"] == np.uint64
        assert "place" not in f
    with h5py.File(cio.part_path(corpus, 0), "r") as f:
        assert f["relief/h100"].chunks == (1, 384, 384) and f["relief/h100"].compression == "gzip" and f["relief/h100"].shuffle
        assert f["relief/h400"].chunks == (1, 96, 96) and f.attrs["complete"] and f.attrs["n_records"] == 2


def test_roundtrip_and_quantization(corpus):
    c = cio.Corpus(corpus)
    assert len(c) == 5 and c.ids() == [0, 1, 2, 3, 4]
    for rid in range(5):
        z = field(rid) + 10 * rid
        h = c.h100(rid, np.float64)
        assert np.abs(h - z).max() <= cio.SCALE_M / 2 + 1e-9
        assert c.h100(rid).dtype == np.float32 and c.h100(rid).shape == (384, 384) and c.h400(rid).shape == (96, 96)
    assert c.params(3)["mix"] == 0.3 and c.params(3)["cloud_point"] == -1 and c.params(3)["corpus_seed"] == 7
    s = c.summary(2)
    assert s["relief_m"] == pytest.approx(s["h_max_m"] - s["h_min_m"]) and s["compute_seconds"] == 0.5
    with pytest.raises(KeyError):
        c.h100(99)
    with pytest.raises(KeyError):
        c.place(0)


def test_axis_order(corpus):
    c = cio.Corpus(corpus)
    h = c.h100(0)
    assert h[0, 300] > h[0, 10] + 400 and h[300, 0] > h[10, 0] + 1000
    assert (h[300, 0] - h[10, 0]) > (h[0, 300] - h[0, 10])
    q = c._view["relief/h100"][0]
    assert q[300, 0] > q[10, 0] and q[0, 300] > q[0, 10]


def test_h400_is_block_mean(corpus):
    c = cio.Corpus(corpus)
    a, b = c.h100(2, np.float64), c.h400(2, np.float64)
    assert np.abs(b - a.reshape(96, 4, 96, 4).mean(axis=(1, 3))).max() <= cio.SCALE_M + 1e-9


def test_out_of_range_is_error(tmp_path):
    z = field(0)
    z[5, 5] = 9000.0
    with pytest.raises(ValueError, match="int16"):
        cio.encode_relief(0, z)
    z[5, 5] = np.nan
    with pytest.raises(ValueError):
        cio.encode_relief(0, z)
    with pytest.raises(ValueError):
        cio.write_reliefs(str(tmp_path / "x"), [dict(z100=field(0) + 9000, params={"mix": 0, "t_total_yr": 1})], columns=NAMES)
    assert not [p for p in os.listdir(tmp_path / "x") if p.endswith(".h5")]


def test_view_equals_parts_and_rebuild_bitwise(corpus):
    v = cio.Corpus(corpus)
    os.rename(corpus + "/corpus.h5", corpus + "/corpus.h5.bak")
    p = cio.Corpus(corpus)                        # без вида — по частям
    assert p._view is None and p.ids() == v.ids()
    for rid in range(5):
        assert np.array_equal(p.h100(rid), v.h100(rid)) and p.summary(rid) == v.summary(rid) and p.params(rid) == v.params(rid)
    a = open(corpus + "/corpus.h5.bak", "rb").read()
    cio.build_view(corpus)
    assert open(corpus + "/corpus.h5", "rb").read() == a
    assert [x[0].tolist() for x in cio.Corpus(corpus).iter_batches(2)] == [[0, 1], [2, 3], [4]]
    assert [d["id"] for d in cio.Corpus(corpus)] == list(range(5))


def test_view_survives_move(tmp_path, corpus):
    new = str(tmp_path / "moved")
    os.rename(corpus, new)
    assert np.array_equal(cio.Corpus(new).h100(4), cio.Corpus(new).h100(4)) and cio.Corpus(new).h100(4)[0, 0] > 0


def test_tmp_invisible_and_incomplete(corpus):
    open(corpus + "/part-00003.h5.tmp", "wb").write(b"garbage")
    assert cio.list_parts(corpus) == [0, 1, 2]
    assert len(cio.Corpus(corpus)) == 5
    os.remove(cio.part_path(corpus, 2))
    cio.build_view(corpus)
    with h5py.File(corpus + "/corpus.h5", "r") as f:
        assert f.attrs["n_records"] == 4 and not f.attrs["complete"]
    cio.clean_tmp(corpus)
    assert not os.path.exists(corpus + "/part-00003.h5.tmp")


def test_unknown_contract_rejected(corpus):
    for p in (corpus + "/corpus.h5", cio.part_path(corpus, 0)):
        with h5py.File(p, "r+") as f:
            f.attrs["contract"] = "S1 v2"
    with pytest.raises(ValueError, match="контракт"):
        cio.Corpus(corpus)
    os.remove(corpus + "/corpus.h5")
    with pytest.raises(ValueError, match="контракт"):
        cio.Corpus(corpus)


def test_place_real(tmp_path):
    rels = [dict(z100=field(0), place=dict(name="t_0007", lat_deg=50.1, lon_deg=86.2, system="altai", part="holdout", stratum="s3",
                                           source="terrarium z12", zoom=12, src_spacing_m=25.0, source_sha256="ab" * 32)),
            dict(z100=field(1), place=dict(name="askarovo", lat_deg=53.0, lon_deg=58.0, system="game", part="game", stratum="", source="", zoom=0,
                                           src_spacing_m=25.0, source_sha256=""))]
    d = str(tmp_path / "real")
    cio.write_reliefs(d, rels, shard_size=1, generator_version="real-p6v3")
    c = cio.Corpus(d)
    assert c.attrs["generator_version"] == "real-p6v3" and c.attrs["corpus_seed"] == 0 and len(c) == 2
    p = c.place(0)
    assert p["name"] == "t_0007" and p["part"] == "holdout" and p["source_sha256"] == "ab" * 32 and p["zoom"] == 12 and p["id"] == 0
    assert c.place(1)["part"] == "game" and next(iter(c))["place"]["name"] == "t_0007"
    with pytest.raises(KeyError):
        c.params(0)
    with h5py.File(d + "/corpus.h5", "r") as f:
        assert "place" in f and "gen" not in f


def cond_rows(spec):
    rows = []
    for rid, k in spec:
        for cid in range(k):
            r = np.zeros((), cio.CONDITIONS_DTYPE)
            r["relief_id"], r["cond_id"], r["u10_m_s"], r["sky"], r["mechanical"], r["froude"] = rid, cid, 5.0 + cid, 1, True, 0.5
            r["n_bv_override_s"] = r["z_i_override_agl_m"] = np.nan
            rows.append(r)
    return np.array(rows, cio.CONDITIONS_DTYPE)


def make_conditions(path, relief_dir, spec, n_total=None):
    attrs = dict(shard_size=2, relief_corpus=relief_dir, cond_seed=3, k_per_relief=2, mechanical_only=True, reject_fraction=0.1)
    ids = sorted({r for r, _ in spec})
    for k in sorted({i // 2 for i in ids}):
        cio.write_conditions_part(path, k, cond_rows([s for s in spec if s[0] // 2 == k]), attrs)
    cio.write_manifest(path, dict(n_total=sum(c for _, c in spec) if n_total is None else n_total))
    return cio.build_view(path, "conditions")


def test_conditions_s2(tmp_path, corpus):
    cd = str(tmp_path / "cond")
    info = make_conditions(cd, corpus, [(0, 2), (1, 1), (4, 2)])
    assert info["n_records"] == 5 and cio.list_parts(cd) == [0, 2]
    with h5py.File(cd + "/conditions.h5", "r") as f:
        assert f.attrs["contract"] == "S2 v2" and f.attrs["kind"] == "conditions" and f.attrs["relief_corpus"] == corpus
        t = f["conditions/table"]
        assert t.shape == (5,) and t.attrs["sky_codes"] and t.dtype["sky"] == np.int8 and t.dtype["mechanical"] == np.bool_
    c = cio.Conditions(cd)
    assert len(c) == 5 and c.for_relief(0)["u10_m_s"].tolist() == [5.0, 6.0] and c.for_relief(4)["mechanical"].all()
    assert np.isnan(c.table["n_bv_override_s"]).all() and not c.table["strat_override"].any()
    assert c.validate_refs()
    a = open(cd + "/conditions.h5", "rb").read()
    cio.build_view(cd, "conditions")
    assert open(cd + "/conditions.h5", "rb").read() == a
    bad = str(tmp_path / "bad")
    make_conditions(bad, corpus, [(0, 1), (77, 1)])
    with pytest.raises(ValueError, match="77"):
        cio.Conditions(bad).validate_refs()
    with pytest.raises(ValueError):
        cio.write_conditions_part(str(tmp_path / "u"), 0, np.concatenate([cond_rows([(1, 1)]), cond_rows([(0, 1)])]))
    with h5py.File(cd + "/conditions.h5", "r+") as f:
        f.attrs["contract"] = "S2 v1"
    with pytest.raises(ValueError):
        cio.Conditions(cd)
