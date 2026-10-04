"""Контрактный тест S1/S2 (docs/contracts/air-synth.md): без генератора, на искусственных полях."""
import os
import numpy as np
import pytest
import corpus_io as cio

pb = cio.pb


def field(seed=0):
    """Несимметричное поле: растёт на восток (i) и сильнее на север (j), плюс шум."""
    rng = np.random.default_rng(seed)
    j, i = np.mgrid[0:384, 0:384]
    return 1000.0 + 2.0 * i + 5.0 * j + rng.normal(0, 3, (384, 384))


def make_corpus(path, n=5, shard_size=2, kind="relief"):
    os.makedirs(path, exist_ok=True)
    nsh = (n + shard_size - 1) // shard_size
    for k in range(nsh):
        recs = []
        for rid in range(k * shard_size, min(n, (k + 1) * shard_size)):
            r = cio.make_relief(7, rid, "test-1", pb.GenParams(mix=rid / 10, extra={"a": 1.0}), field(rid) + 10 * rid, 0.5)
            recs.append(cio.encode_record(r))
        cio.write_shard(path, "relief", k, recs)
    m = pb.CorpusManifest(contract="S1 v1", name="t", kind="relief", corpus_seed=7, n_records=n, shard_size=shard_size,
                          shard_pattern=cio.SHARD_PATTERN["relief"], generator_version="test-1", complete=True)
    cio.write_manifest(path, m)
    cio.build_index(path, "relief")
    return path


@pytest.fixture
def corpus(tmp_path):
    return make_corpus(str(tmp_path / "c"))


def test_roundtrip_bitwise(corpus):
    c = cio.Corpus(corpus)
    assert len(c) == 5
    r = c.get(3)
    exp = cio.make_relief(7, 3, "test-1", pb.GenParams(mix=0.3, extra={"a": 1.0}), field(3) + 30, 0.5)
    assert r.SerializeToString(deterministic=True) == exp.SerializeToString(deterministic=True)
    assert r.g100.h_i16 == exp.g100.h_i16 and r.id == 3 and r.params.extra["a"] == 1.0


def test_quantization_error(corpus):
    c = cio.Corpus(corpus)
    for rid in range(5):
        r = c.get(rid)
        z = field(rid) + 10 * rid
        err = np.abs(cio.to_float(r.g100, np.float64) - z).max()
        assert err <= r.g100.scale_m / 2 + 1e-9
        assert r.g100.scale_m >= 0.05
        assert len(r.g100.h_i16) == 2 * 384 * 384
    assert cio.to_float(r.g100).dtype == np.float32 and cio.to_float(r.g100).shape == (384, 384)


def test_axis_order(corpus):
    h = cio.to_float(cio.Corpus(corpus).get(0).g100)
    assert h[0, 300] > h[0, 10] + 400          # растёт на восток (i)
    assert h[300, 0] > h[10, 0] + 1000         # растёт на север (j), сильнее
    assert (h[300, 0] - h[10, 0]) > (h[0, 300] - h[0, 10])
    g = cio.Corpus(corpus).get(0).g100
    q = np.frombuffer(g.h_i16, "<i2")
    assert q[300 * 384] > q[10 * 384] and q[300] > q[10]       # k = j·nx + i


def test_g400_is_block_mean(corpus):
    r = cio.Corpus(corpus).get(2)
    a = cio.to_float(r.g100, np.float64)
    b = cio.to_float(r.g400, np.float64)
    assert b.shape == (96, 96) and r.g400.dx_m == 400 and r.g400.x0_m == -19200 and r.g100.x0_m == -19200
    bm = a.reshape(96, 4, 96, 4).mean(axis=(1, 3))
    assert np.abs(b - bm).max() <= r.g100.scale_m / 2 + r.g400.scale_m / 2 + 1e-9
    assert r.summary.relief_m == pytest.approx(r.summary.h_max_m - r.summary.h_min_m)


def test_random_access_equals_sequential(corpus):
    c = cio.Corpus(corpus)
    seq = {r.id: r.SerializeToString(deterministic=True) for sh, recs in c.iter_shards() for r in recs}
    assert sorted(seq) == list(range(5))
    for rid in (4, 0, 3, 1, 2):
        assert c.get(rid).SerializeToString(deterministic=True) == seq[rid]
    assert [r.id for r in c] == list(range(5))
    with pytest.raises(KeyError):
        c.get(99)


def test_shard_layout(corpus):
    assert cio.list_shards(corpus, "relief") == [0, 1, 2]
    data = open(cio.shard_path(corpus, "relief", 0), "rb").read()
    ids = [pb.Relief.FromString(b).id for _, _, b in cio.iter_shard_bytes(data)]
    assert ids == [0, 1]
    assert [e.id for e in pb.ShardIndex.FromString(open(corpus + "/index.pb", "rb").read()).entries] == [0, 1, 2, 3, 4]


def test_index_rebuild_bitwise(corpus):
    a = open(corpus + "/index.pb", "rb").read()
    os.remove(corpus + "/index.pb")
    cio.build_index(corpus, "relief")
    assert open(corpus + "/index.pb", "rb").read() == a


def test_partial_write_invisible(corpus):
    os.makedirs(corpus + "/tmp", exist_ok=True)
    open(corpus + "/tmp/reliefs-00003.pb.123.part", "wb").write(b"\x05garbage")
    assert cio.list_shards(corpus, "relief") == [0, 1, 2]
    assert len(cio.Corpus(corpus)) == 5
    # без индекса — тоже только готовые шарды
    os.remove(corpus + "/index.pb")
    assert len(cio.Corpus(corpus)) == 5


def test_wrong_contract_rejected(corpus):
    m = cio.read_manifest(corpus)
    m.contract = "S1 v2"
    cio.write_manifest(corpus, m)
    with pytest.raises(ValueError, match="контракт"):
        cio.Corpus(corpus)
    m.contract = "S2 v1"                      # kind relief требует S1 v1
    cio.write_manifest(corpus, m)
    with pytest.raises(ValueError):
        cio.Corpus(corpus)


def make_conditions(path, relief_dir, ids_k):
    """ids_k — {relief_id: число условий}; шард S = 2."""
    os.makedirs(path, exist_ok=True)
    by_shard = {}
    for rid in sorted(ids_k):
        for cid in range(ids_k[rid]):
            by_shard.setdefault(rid // 2, []).append(pb.Conditions(relief_id=rid, cond_id=cid, cond_seed=1, u10_m_s=5.0 + cid, hour_local=12.0,
                                                                   sky="clear", derived=pb.Derived(froude=0.5, mechanical=True)))
    for k, recs in by_shard.items():
        cio.write_shard(path, "conditions", k, [cio.encode_record(r) for r in recs])
    cio.write_manifest(path, pb.CorpusManifest(contract="S2 v1", name="cond", kind="conditions", shard_size=2, relief_corpus=relief_dir,
                                               shard_pattern=cio.SHARD_PATTERN["conditions"], complete=True))
    cio.build_index(path, "conditions")


def test_conditions_s2(tmp_path, corpus):
    cd = str(tmp_path / "cond")
    make_conditions(cd, corpus, {0: 2, 1: 1, 4: 2})
    c = cio.Corpus(cd)
    assert c.kind == "conditions" and len(c) == 5
    assert c.get(0, 1).u10_m_s == 6.0 and c.get(4, 0).derived.mechanical
    assert [x.cond_id for x in c.conditions_for(0)] == [0, 1]
    assert c.validate_refs()
    a = open(cd + "/index.pb", "rb").read()
    os.remove(cd + "/index.pb")
    cio.build_index(cd, "conditions")
    assert open(cd + "/index.pb", "rb").read() == a
    bad = str(tmp_path / "cond_bad")
    make_conditions(bad, corpus, {0: 1, 77: 1})
    with pytest.raises(ValueError, match="77"):
        cio.Corpus(bad).validate_refs()
    m = cio.read_manifest(cd)
    m.contract = "S1 v1"
    cio.write_manifest(cd, m)
    with pytest.raises(ValueError):
        cio.Corpus(cd)
