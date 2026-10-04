"""SY-3: условия S2 — распределения P2, производные решателя, определение w*/U, детерминизм, CLI make.
Корпус S1 для CLI — временный, пишется настоящим corpus_io (SY-1, HDF5)."""
import math
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "air_nn_pilot"))   # pilotnn.film_bg — эталон N, Fr (только импорт)

import conditions as C  # noqa: E402
import corpus_io as cio  # noqa: E402
import h5py  # noqa: E402


def write_mini_corpus(d, n, shard_size=4, seed=3):
    """n искусственных рельефов (g100 из случайного поля, g400 — блочное среднее) через corpus_io SY-1 (S1 v3);
    рельефы с id % 3 == 2 — «реальные места» с place (одна запись — одна часть формата)."""
    rng = np.random.default_rng(seed)
    rels = []
    for rid in range(n):
        hc, s = C.fake_relief(rng)                         # 96 × 96
        r = dict(z100=np.kron(hc, np.ones((4, 4))))
        r["params"] = dict(mix=0.5)
        rels.append(r)
    cio.write_reliefs(d, rels, shard_size=shard_size, generator_version="test", columns=["mix"])


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
    rows = np.concatenate([C.sample(7, rid, s, 2, hc) for rid in range(60)])
    assert rows.dtype == cio.CONDITIONS_DTYPE
    assert rows["mechanical"].all() and (rows["w_star_over_u"] < C.WSU_THR).all()
    assert set(np.unique(rows["hour_local"])) <= set(C.HOURS) and set(np.unique(rows["sky"])) <= {0, 1, 2}
    assert ((rows["u10_m_s"] >= 0.5) & (rows["u10_m_s"] <= 8.0)).all()            # штиль не берём
    assert ((rows["wind_from_deg"] >= 0) & (rows["wind_from_deg"] <= 360) & (rows["t_max_c"] >= 18) & (rows["t_max_c"] <= 34)).all()
    assert ((rows["month"] == 7) & (rows["day"] == 15)).all()                     # модельные — июль, север
    assert not rows["strat_override"].any() and np.isnan(rows["n_bv_override_s"]).all() and np.isnan(rows["z_i_override_agl_m"]).all()
    assert ((rows["lat_deg"] >= 0) & (rows["lat_deg"] <= 70)).all()            # только северное полушарие
    assert (rows["utc_offset_h"] == np.round(rows["lon_deg"] / 15)).all()
    assert np.allclose(rows["u_sat_m_s"], rows["u10_m_s"] * rows["max_profile"]) and (rows["hs_w_m2"] >= 0).all()
    assert np.allclose(rows["w_star_over_u"], rows["w_star_m_s"] / np.maximum(rows["u_sat_m_s"], 0.1))


def test_deterministic_and_ids():
    hc, s = fake(3)
    a = C.sample(11, 5, s, 3, hc)
    b = C.sample(11, 5, s, 3, hc)
    assert a.tobytes() == b.tobytes()
    assert a["cond_id"].tolist() == [0, 1, 2] and (a["relief_id"] == 5).all()
    assert a[0].tobytes() != C.sample(11, 6, s, 3, hc)[0].tobytes()
    assert C.sample(11, 5, s, 2, hc)[1].tobytes() == a[1].tobytes()     # k=2 — префикс k=3 (тот же ГСЧ)
    x = C.sample(11, 5, s, 2)                                          # без поля рельефа — конечно
    assert all(np.isfinite(x[n]).all() for n in x.dtype.names if x.dtype[n].kind == "f" and "override" not in n)


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
            d = C.derive(raw, ctx, hcf, s["relief_m"])
            D = W.Day(hour, 27.0, sky, ctx)
            P0 = A.Params()
            al, mp, cls, el = WP.for_hour(ctx, hour, sky, 3.7, P0.z0, P0.f_cor)
            assert (d["alpha"], d["max_profile"], d["sun_el_deg"]) == (al, mp, el)
            assert d["z_i_m"] == D.z_i and d["z_lcl_m"] == D.z_lcl and d["heat"] == D.heat and d["brk"] == D.st["brk"]
            bg = FB.bg_raw(D, hcf, 3.7, mp)
            assert d["n_bv_s"] == pytest.approx(bg["N_bl"], rel=1e-12)
            assert d["u_sat_m_s"] == pytest.approx(bg["U"])
            fr = d["froude"]
            assert fr == pytest.approx(min(fr, FB.FR_MAX) if fr <= FB.FR_MAX else fr)
            if bg["Fr"] < FB.FR_MAX:   # где film_bg не обрезал — совпадает
                assert fr == pytest.approx(bg["Fr"], rel=1e-9)
            assert d["mechanical"] == (d["w_star_over_u"] < 0.5)


def test_night_is_mechanical_noon_clear_is_not():
    hc, s = fake(5)
    ctx, hcf = C._ctx(46.5, 8.2, 1.0, hc, s)
    n = C.derive(dict(hour=20.0, sky="clear", U10=2.0, wdir=0, t_max=30.0), ctx, hcf, s["relief_m"])
    d = C.derive(dict(hour=12.0, sky="clear", U10=1.0, wdir=0, t_max=30.0), ctx, hcf, s["relief_m"])
    assert n["mechanical"] and n["w_star_over_u"] < 0.3 * d["w_star_over_u"]
    assert d["w_star_over_u"] > 0.5 and not d["mechanical"]
    assert d["w_star_m_s"] > 1.0                   # Дирдорф: порядок 1–3 м/с над горным склоном


def test_real_place_overrides_lat_lon():
    hc, s = fake(6)
    for c in C.sample(2, 1, s, 2, hc, place=dict(name="t_0001", lat_deg=46.5, lon_deg=8.2)):
        assert (c["lat_deg"], c["lon_deg"], c["utc_offset_h"], c["month"], c["day"]) == (46.5, 8.2, 1.0, 7, 15)
    for c in C.sample(2, 1, s, 2, hc, place=dict(name="t_0002", lat_deg=-43.5, lon_deg=170.1)):   # юг — 15 января
        assert (c["lat_deg"], c["month"], c["day"]) == (-43.5, 1, 15) and c["mechanical"]


# ------------------------------------------------------------ CLI make (настоящий corpus_io SY-1)
def test_make_cli(tmp_path):
    corp, out = str(tmp_path / "relief"), str(tmp_path / "cond")
    write_mini_corpus(corp, 9, shard_size=4)
    info = C.make(corp, out, 2, 123)
    assert info["n_records"] == 18 and info["complete"] and info["parts"] == 3
    c = cio.Conditions(out)
    assert c.attrs["contract"] == "S2 v2" and c.attrs["kind"] == "conditions" and c.attrs["mechanical_only"]
    assert c.attrs["k_per_relief"] == 2 and c.attrs["cond_seed"] == 123 and 0 <= c.attrs["reject_fraction"] < 1
    assert c.validate_refs()
    t = c.table
    assert [(r, k) for r, k in zip(t["relief_id"], t["cond_id"])] == [(r, k) for r in range(9) for k in range(2)]
    assert t["mechanical"].all() and np.isfinite(t["froude"]).all()
    # строки совпадают с sample() на тех же g400 (деквантованных)
    cor = cio.Corpus(corp)
    one = C.sample(123, 5, cor.summary(5), 2, cor.h400(5, np.float64))
    assert one.tobytes() == t[t["relief_id"] == 5].tobytes()
    # повтор — побитно те же части; продолжение после удаления части — та же часть
    names = ["part-00000.h5", "part-00001.h5", "part-00002.h5"]
    def table_of(n):
        with h5py.File(os.path.join(out, n), "r") as f:
            return f["conditions/table"][:].tobytes()
    before = [table_of(n) for n in names]
    os.remove(os.path.join(out, "part-00001.h5"))
    C.make(corp, out, 2, 123)
    assert [table_of(n) for n in names] == before
    assert os.path.exists(os.path.join(out, "conditions.h5"))


def test_make_real_places(tmp_path):
    corp, out = str(tmp_path / "real"), str(tmp_path / "cond")
    rng = np.random.default_rng(9)
    rels = []
    for i, (la, lo) in enumerate([(46.5, 8.2), (-43.5, 170.1), (50.7, 86.1)]):
        hc, s = C.fake_relief(rng)
        rels.append(dict(z100=np.kron(hc, np.ones((4, 4))), place=dict(name=f"t_{i:04d}", lat_deg=la, lon_deg=lo, system="x", part="pool")))
    cio.write_reliefs(corp, rels, shard_size=2, generator_version="real-p6v3")
    C.make(corp, out, 1, 4)
    t = cio.Conditions(out).table
    assert t["lat_deg"].tolist() == [46.5, -43.5, 50.7] and t["month"].tolist() == [7, 1, 7]


def test_cli_subprocess(tmp_path):
    corp, out = str(tmp_path / "relief"), str(tmp_path / "cond")
    write_mini_corpus(corp, 3, shard_size=4)
    r = subprocess.run([sys.executable, str(HERE / "conditions.py"), "make", "--corpus", corp, "--out", out, "--k", "2",
                        "--seed", "5"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert len(cio.Conditions(out)) == 6
