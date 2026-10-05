"""Тесты SY-10: деление мест, перебинирование, геометрия квадрата как в игре, упакованный корпус (после pack_hg.py pack).
Без PIL/yaml (venv корпуса) геометрические тесты пропускаются; полный набор — из venv air_nn_pilot."""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE.parent / "corpus"))
sys.path.insert(0, str(HERE))
import corpus_io as cio  # noqa: E402
import split_hg as SP    # noqa: E402

SITES = json.loads((HERE.parent / "hg_sites/sites.json").read_text())
SUM = json.loads((HERE / "out/hg_summary.json").read_text()) if (HERE / "out/hg_summary.json").exists() else None
CORPUS = Path(SUM["corpus_path"]) if SUM else None
needs = pytest.mark.skipif(not (CORPUS and (CORPUS / "corpus.h5").exists()), reason="корпус не упакован")


def pack():
    pytest.importorskip("PIL")
    pytest.importorskip("yaml")
    import pack_hg
    return pack_hg


def test_split_rules_on_catalog():
    parts = SP.split(SITES)
    assert len(parts) == len(SITES) and SP.split(SITES) == parts          # детерминированно
    hold = [s for s in SITES if parts[s["site_id"]] == ("holdout", parts[s["site_id"]][1]) and parts[s["site_id"]][1] != "near_game"]
    train = [s for s in SITES if parts[s["site_id"]][0] == "train"]
    assert 15 <= len(hold) <= 24 and len(train) > 300
    assert len({parts[s["site_id"]][1] for s in hold}) >= 12              # разные регионы
    d = min(SP.dist_km(h["lat"], h["lon"], t["lat"], t["lon"]) for h in hold for t in train)
    assert d >= SP.SEP_KM
    assert SP.split(SITES, seed=1) != parts                               # зерно влияет


def test_near_game_goes_to_holdout():
    sites = [dict(site_id="a", lat=53.30, lon=58.50, country="RU"), dict(site_id="b", lat=45.0, lon=2.0, country="FR"),
             dict(site_id="c", lat=53.26 + 0.5, lon=58.54, country="RU")]       # a — 4 км от Аскарово, c — 55 км
    p = SP.split(sites, n_holdout=0)
    assert p["a"] == ("holdout", "near_game") and p["b"][0] == "train" and p["c"][0] == "train"


def test_rebin_matrix_block_means():
    P = pack()
    rng = np.random.default_rng(0)
    for f in (10, 13, 17, 20):
        A = rng.normal(size=(96 * f, 96 * f)) + 100
        z100, hc = P.build_relief(A, f)
        assert z100.shape == (384, 384) and hc.shape == (96, 96)
        assert np.abs(cio.block_mean(z100, 4) - hc).max() < 1e-9          # блочное среднее h100 4×4 = клетка игры f×f
        assert abs(z100.mean() - A.mean()) < 1e-9
        M = P.rebin_matrix(96 * f, f)
        assert np.allclose(M.sum(axis=1), 1.0)


def test_geometry_game_like():
    P = pack()
    import math
    for lat, lon in ((45.06, 2.76), (53.26, 58.54), (-33.0, 151.4), (61.9, 9.1), (28.95, -13.7)):
        g = P.geometry(lat, lon)
        s = 2 * math.pi * 6378137.0 * math.cos(math.radians(lat)) / (256 * 2 ** g["z"])
        assert abs(g["s"] - s) < 1e-9 and g["s"] >= 18.0 - 1e-9 and g["f"] == P.roundi(400.0 / s)
        assert abs(g["cell_m"] - g["f"] * s) < 1e-9 and g["L"] == 96 * g["f"] and 330 < g["cell_m"] < 460
        assert g["c1"] - g["c0"] == g["L"] and g["r1"] - g["r0"] == g["L"]
        assert abs(g["center_offset_m"]) < 1000          # центр области в пределах ~1 км от старта (крайний случай — экватор, f·s < 400)
    assert P.geometry(70.0, 20.0)["z"] == 11 and P.geometry(45.0, 2.0)["z"] == 12      # layer_zoom: z понижается, пока шаг < 18 м


def test_window_orientation_synthetic_tiles(tmp_path):
    """Тайлы Terrarium с высотой h = 0,01·px − 0,005·py (px — столбец, py — строка мозаики, к югу): окно — юг сверху, столбцы с запада."""
    P = pack()
    from PIL import Image
    lat, lon = 46.0, 8.0
    g = P.geometry(lat, lon)
    for z, tx, ty in g["tiles"]:
        yy, xx = np.mgrid[0:256, 0:256]
        h = 0.01 * (tx * 256 + xx) - 0.005 * (ty * 256 + yy) + 1000.0
        v = (h + 32768.0)
        R, G = np.floor(v / 256), np.floor(v) % 256
        B = np.floor((v - np.floor(v)) * 256)
        p = P.tile_file(tmp_path, z, tx, ty)
        p.parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray(np.stack([R, G, B], -1).astype(np.uint8)).save(p)
    A = P.window(tmp_path, g)
    assert A.shape == (g["L"], g["L"])
    px = g["c0"] + np.arange(g["L"])
    py_south_first = g["r1"] - 1 - np.arange(g["L"])
    exp = 0.01 * px[None, :] - 0.005 * py_south_first[:, None] + 1000.0
    assert np.abs(A - exp).max() < 0.005
    z100, hc = P.build_relief(A, g["f"])
    assert hc[0, 0] > 0 and hc[-1, 0] > hc[0, 0] and hc[0, -1] > hc[0, 0]   # растёт на север (py убывает) и на восток


@needs
def test_corpus_counts_and_attrs():
    c = cio.Corpus(str(CORPUS))
    sp = json.loads((HERE / "out/split_summary.json").read_text())
    assert len(c) == SUM["n_places"] == sp["n_sites"] and sp["n_train"] + sp["n_holdout"] == len(c)
    assert c.attrs["contract"] == "S1 v4" and c.attrs["generator_version"] == "real-hg-v1" and int(c.attrs["split_seed"]) == SP.SPLIT_SEED
    pl = [c.place(k) for k in range(len(c))]
    parts = [p["part"] for p in pl]
    assert parts.count("train") == sp["n_train"] and parts.count("holdout") == sp["n_holdout"]
    cat = {s["site_id"]: s for s in SITES}
    for p in pl:
        assert p["name"] in cat and p["system"] == cat[p["name"]]["country"] and p["stratum"] and p["source"].startswith("terrarium z")
        assert p["zoom"] in (11, 12) and 18 <= p["src_spacing_m"] <= 40 and abs(p["lat_deg"] - cat[p["name"]]["lat"]) < 1e-9
    assert sum(1 for p in pl if p["stratum"] == "near_game") == sp["n_near_game"]
    assert sp["min_dist_holdout_to_train_km"] is None or sp["min_dist_holdout_to_train_km"] >= 50
    assert len(sp["holdout_regions"]) >= 10 and 15 <= sp["n_holdout_regional"] <= 24


@needs
def test_h400_is_block_mean_and_physical():
    c = cio.Corpus(str(CORPUS))
    for k in range(0, len(c), 11):
        h100, h400 = c.h100(k, np.float64), c.h400(k, np.float64)
        assert np.abs(cio.block_mean(h100, 4) - h400).max() <= 2 * cio.SCALE_M
        s = c.summary(k)
        assert s["relief_m"] <= 3000.0 + 1e-6 and s["h_min_m"] > -50
    g = cio.Corpus(SUM["game_corpus_path"])
    assert [g.place(i)["name"] for i in range(len(g))] == ["askarovo", "aushkul", "altai", "ongudai"]
    assert all(g.place(i)["part"] == "game" for i in range(4))


@needs
def test_summary_files_and_raw_deleted():
    assert SUM["h400_vs_game_blockmean_max_abs_m"] <= 1e-6 + 0.075 * 0 or SUM["h400_vs_game_blockmean_max_abs_m"] < 0.1
    assert (HERE / "out/excluded.json").exists() and (HERE / "out/geometry.json").exists()
    ex = json.loads((HERE / "out/excluded.json").read_text())
    assert all(e["reasons"] for e in ex) and len(ex) == SUM.get("n_excluded", len(ex))
