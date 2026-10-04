"""SY-3: условия S2 — распределения P2, производные решателя, определение w*/U, детерминизм, CLI make.
Корпус S1 для CLI — временный; если corpus_io (SY-1) ещё не влит, подставляется минимальный писатель/читатель
из этого файла (тот же формат: шарды varint32 + сообщение, index.pb, manifest.pb)."""
import importlib
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "air_nn_pilot"))   # pilotnn.film_bg — эталон N, Fr (только импорт)

import conditions as C  # noqa: E402
from air_synth.v1 import corpus_pb2 as pb  # noqa: E402


# ------------------------------------------------------------ минимальный S1 (если нет corpus_io SY-1)
def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _rd_varint(buf, pos):
    n = sh = 0
    while True:
        b = buf[pos]
        pos += 1
        n |= (b & 0x7F) << sh
        sh += 7
        if not b & 0x80:
            return n, pos


class MiniIO:
    SHARD_PATTERN = {"relief": "reliefs-{shard:05d}.pb", "conditions": "conditions-{shard:05d}.pb"}

    @staticmethod
    def encode_record(m):
        b = m.SerializeToString(deterministic=True)
        return _varint(len(b)) + b

    @classmethod
    def list_shards(cls, d, kind):
        pre = kind + "s-" if kind == "relief" else "conditions-"
        return sorted(int(f[len(pre):len(pre) + 5]) for f in os.listdir(d) if f.startswith(pre) and f.endswith(".pb"))

    @classmethod
    def write_shard(cls, d, kind, sh, recs):
        os.makedirs(os.path.join(d, "tmp"), exist_ok=True)
        tmp = os.path.join(d, "tmp", f"{sh}.part")
        open(tmp, "wb").write(b"".join(recs))
        os.replace(tmp, os.path.join(d, cls.SHARD_PATTERN[kind].format(shard=sh)))

    @classmethod
    def _read_shard(cls, d, kind, sh, cls_msg):
        buf = open(os.path.join(d, cls.SHARD_PATTERN[kind].format(shard=sh)), "rb").read()
        pos, out = 0, []
        while pos < len(buf):
            n, pos = _rd_varint(buf, pos)
            out.append((pos, n, cls_msg.FromString(buf[pos:pos + n])))
            pos += n
        return out

    @classmethod
    def build_index(cls, d, kind=None):
        idx = pb.ShardIndex(kind=kind)
        msg = pb.Relief if kind == "relief" else pb.Conditions
        for sh in cls.list_shards(d, kind):
            for pos, n, m in cls._read_shard(d, kind, sh, msg):
                idx.entries.add(id=m.id if kind == "relief" else m.relief_id, shard=sh, offset=pos, length=n,
                                cond_id=getattr(m, "cond_id", 0))
        open(os.path.join(d, "index.pb"), "wb").write(idx.SerializeToString(deterministic=True))

    @classmethod
    def write_manifest(cls, d, m):
        open(os.path.join(d, "manifest.pb"), "wb").write(m.SerializeToString(deterministic=True))

    @staticmethod
    def to_float(g):
        q = np.frombuffer(g.h_i16, "<i2").reshape(g.ny, g.nx)
        return (g.offset_m + g.scale_m * q).astype(np.float32)

    class Corpus:
        def __init__(self, d):
            self.path = d
            self.manifest = pb.CorpusManifest.FromString(open(os.path.join(d, "manifest.pb"), "rb").read())

        def iter_shards(self):
            for sh in MiniIO.list_shards(self.path, "relief"):
                yield sh, [m for _, _, m in MiniIO._read_shard(self.path, "relief", sh, pb.Relief)]


def _grid(h, dx):
    lo, hi = float(h.min()), float(h.max())
    sc = max(0.05, (hi - lo) / 65000)
    off = (lo + hi) / 2
    q = np.round((h - off) / sc).astype("<i2")
    ny, nx = h.shape
    return pb.HeightGrid(nx=nx, ny=ny, dx_m=dx, x0_m=-19200.0, y0_m=-19200.0, offset_m=off, scale_m=sc, h_i16=q.tobytes())


def write_mini_corpus(d, n, shard_size=4, seed=3):
    """n искусственных рельефов (g100 из случайного поля, g400 — блочное среднее) в S1-формате."""
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(seed)
    recs = {}
    for rid in range(n):
        hc, s = C.fake_relief(rng)                         # 96 × 96
        z100 = np.kron(hc, np.ones((4, 4)))
        r = pb.Relief(id=rid, corpus_seed=1, generator_version="test", g100=_grid(z100, 100.0), g400=_grid(hc, 400.0),
                      summary=s)
        if rid % 3 == 2:
            r.place.CopyFrom(pb.Place(name=f"t_{rid:04d}", lat_deg=46.5, lon_deg=8.2, part="pool"))
        recs.setdefault(rid // shard_size, []).append(MiniIO.encode_record(r))
    for sh, rr in recs.items():
        MiniIO.write_shard(d, "relief", sh, rr)
    MiniIO.build_index(d, "relief")
    m = pb.CorpusManifest(contract="S1 v2", name="t", kind="relief", n_records=n, shard_size=shard_size,
                          shard_pattern="reliefs-{shard:05d}.pb", complete=True, generator_version="test")
    MiniIO.write_manifest(d, m)


@pytest.fixture(scope="module")
def cio():
    try:
        mod = importlib.import_module("corpus_io")
        return mod, True
    except ImportError:
        return MiniIO, False


@pytest.fixture
def use_io(cio, monkeypatch):
    mod, real = cio
    if not real:
        monkeypatch.setitem(sys.modules, "corpus_io", MiniIO)
    return real


def fake(seed=1):
    return C.fake_relief(np.random.default_rng(seed))


# ------------------------------------------------------------ распределения и определения
def test_w_star_formula():
    # Hs = 200 Вт/м², z_i = 1500 м: (9,81/300 · 200/1206 · 1500)^(1/3)
    exp = (9.81 / 300 * 200 / 1206.0 * 1500) ** (1 / 3)
    assert C.wstar(200.0, 1500.0) == pytest.approx(exp, rel=1e-12)
    assert C.wstar(-5.0, 1500.0) == 0.0 and C.wstar(100.0, -10.0) == 0.0


def test_place_weights():
    assert BOX_OK(C.BOX_P)
    sysw = {}
    for s, p in zip(C.BOX_SYS, C.BOX_P):
        sysw[s] = sysw.get(s, 0) + p
    assert max(sysw.values()) <= C.SYSTEM_CAP + 1e-9


def BOX_OK(p):
    return abs(p.sum() - 1) < 1e-9 and (p > 0).all()


def test_raw_ranges_and_mechanical_only():
    hc, s = fake(2)
    recs = []
    for rid in range(60):
        recs += C.sample(7, rid, s, 2, hc)
    assert all(c.derived.mechanical and c.derived.w_star_over_u < C.WSU_THR for c in recs)
    assert all(c.hour_local in C.HOURS and c.sky in C.SKIES for c in recs)
    assert all(0.5 <= c.u10_m_s <= 8.0 for c in recs)            # штиль не берём
    assert all(0 <= c.wind_from_deg <= 360 and 18 <= c.t_max_c <= 34 for c in recs)
    assert all((c.month, c.day) == (7, 15) for c in recs)
    assert all(not c.strat_override.enabled for c in recs)
    assert all(-56 <= c.lat_deg <= 70 for c in recs)
    for c in recs:
        assert c.utc_offset_h == round(c.lon_deg / 15)


def test_deterministic_and_ids():
    hc, s = fake(3)
    a = C.sample(11, 5, s, 3, hc)
    b = C.sample(11, 5, s, 3, hc)
    assert [x.SerializeToString(deterministic=True) for x in a] == [x.SerializeToString(deterministic=True) for x in b]
    assert [x.cond_id for x in a] == [0, 1, 2] and all(x.relief_id == 5 and x.cond_seed == 11 for x in a)
    assert a[0].SerializeToString() != C.sample(11, 6, s, 3, hc)[0].SerializeToString()
    # k=2 — префикс k=3 (тот же ГСЧ)
    assert C.sample(11, 5, s, 2, hc)[1].SerializeToString() == a[1].SerializeToString()
    # без поля рельефа (поддельная сводка) — тоже работает и конечно
    for x in C.sample(11, 5, s, 2):
        d = x.derived
        assert all(math.isfinite(getattr(d, f.name)) for f in d.DESCRIPTOR.fields if f.cpp_type == f.CPPTYPE_DOUBLE)


def test_derived_equal_solver_code():
    """alpha, max_profile, z_i, z_lcl, heat, brk — код решателя (WP.for_hour, W.Day); N и Fr — film_bg.bg_raw."""
    import weather as W
    import wind_prof as WP
    import air as A
    from pilotnn import film_bg as FB
    hc, s = fake(4)
    ctx, hcf = C._ctx(46.5, 8.2, 1.0, hc, s)
    for hour in C.HOURS:
        for sky in C.SKIES:
            raw = dict(hour=hour, sky=sky, U10=3.7, wdir=200.0, t_max=27.0)
            d = C.derive(raw, ctx, hcf, s.relief_m)
            D = W.Day(hour, 27.0, sky, ctx)
            P0 = A.Params()
            al, mp, cls, el = WP.for_hour(ctx, hour, sky, 3.7, P0.z0, P0.f_cor)
            assert (d["alpha"], d["max_profile"], d["sun_el_deg"]) == (al, mp, el)
            assert d["z_i_m"] == D.z_i and d["z_lcl_m"] == D.z_lcl and d["heat"] == D.heat and d["brk"] == D.st["brk"]
            bg = FB.bg_raw(D, hcf, 3.7, mp)
            assert d["n_bv_s"] == pytest.approx(bg["N_bl"], rel=1e-12)
            assert d["u_inflow_m_s"] == pytest.approx(bg["U"])
            fr = d["froude"]
            assert fr == pytest.approx(min(fr, FB.FR_MAX) if fr <= FB.FR_MAX else fr)
            if bg["Fr"] < FB.FR_MAX:   # где film_bg не обрезал — совпадает
                assert fr == pytest.approx(bg["Fr"], rel=1e-9)
            assert d["mechanical"] == (d["w_star_over_u"] < 0.5)


def test_night_is_mechanical_noon_clear_is_not():
    hc, s = fake(5)
    ctx, hcf = C._ctx(46.5, 8.2, 1.0, hc, s)
    n = C.derive(dict(hour=20.0, sky="clear", U10=2.0, wdir=0, t_max=30.0), ctx, hcf, s.relief_m)
    d = C.derive(dict(hour=12.0, sky="clear", U10=1.0, wdir=0, t_max=30.0), ctx, hcf, s.relief_m)
    assert n["mechanical"] and n["w_star_over_u"] < 0.3 * d["w_star_over_u"]
    assert d["w_star_over_u"] > 0.5 and not d["mechanical"]
    assert d["w_star_m_s"] > 1.0                   # Дирдорф: порядок 1–3 м/с над горным склоном


def test_real_place_overrides_lat_lon():
    hc, s = fake(6)
    p = pb.Place(name="t_0001", lat_deg=46.5, lon_deg=8.2)
    for c in C.sample(2, 1, s, 2, hc, place=p):
        assert (c.lat_deg, c.lon_deg, c.utc_offset_h) == (46.5, 8.2, 1.0)


# ------------------------------------------------------------ CLI make
def test_make_cli(tmp_path, use_io):
    corp, out = str(tmp_path / "relief"), str(tmp_path / "cond")
    write_mini_corpus(corp, 9, shard_size=4)
    man = C.make(corp, out, 2, 123)
    assert man.contract == "S2 v1" and man.kind == "conditions" and man.relief_corpus == str(Path(corp).resolve())
    assert man.n_records == 18 and man.complete and "reject_fraction_this_run" in man.notes
    import corpus_io as cio
    shards = cio.list_shards(out, "conditions")
    assert shards == [0, 1, 2]
    got = []
    for sh in shards:
        buf = open(os.path.join(out, f"conditions-{sh:05d}.pb"), "rb").read()
        pos = 0
        while pos < len(buf):
            n, pos = _rd_varint(buf, pos)
            got.append(pb.Conditions.FromString(buf[pos:pos + n]))
            pos += n
    assert [(c.relief_id, c.cond_id) for c in got] == [(r, c) for r in range(9) for c in range(2)]
    assert all(c.derived.mechanical for c in got)
    # реальное место (rid % 3 == 2) — координаты места
    assert all(c.lat_deg == 46.5 for c in got if c.relief_id % 3 == 2)
    # повтор — побитно те же шарды; продолжение после удаления шарда — тот же шард
    before = {sh: open(os.path.join(out, f"conditions-{sh:05d}.pb"), "rb").read() for sh in shards}
    os.remove(os.path.join(out, "conditions-00001.pb"))
    C.make(corp, out, 2, 123)
    assert {sh: open(os.path.join(out, f"conditions-{sh:05d}.pb"), "rb").read() for sh in shards} == before
    assert os.path.exists(os.path.join(out, "index.pb"))


def test_cli_subprocess(tmp_path, use_io):
    if not use_io:
        pytest.skip("CLI в подпроцессе нужен corpus_io SY-1")
    corp, out = str(tmp_path / "relief"), str(tmp_path / "cond")
    write_mini_corpus(corp, 3, shard_size=4)
    r = subprocess.run([sys.executable, str(HERE / "conditions.py"), "make", "--corpus", corp, "--out", out, "--k", "2",
                        "--seed", "5"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
