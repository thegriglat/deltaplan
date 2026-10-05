"""Тесты SY-12: корпус hg_v2 (S1 v5, конвейер П6) — состав как hg_v1, h400 = hc400 П6, сверка с игрой (out/game_check_v2.json). После pack_hg2.py pack."""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE.parent / "corpus"))
import corpus_io as cio  # noqa: E402

SUM = json.loads((HERE / "out/hg_summary_v2.json").read_text()) if (HERE / "out/hg_summary_v2.json").exists() else None
CORPUS = Path(SUM["corpus_path"]) if SUM else None
needs = pytest.mark.skipif(not (CORPUS and (CORPUS / "corpus.h5").exists()), reason="корпус не упакован")
SITES = {s["site_id"]: s for s in json.loads((HERE.parent / "hg_sites/sites.json").read_text())}


@needs
def test_same_split_as_v1():
    sp = json.loads((HERE / "out/split_summary_v2.json").read_text())
    c = cio.Corpus(str(CORPUS))
    assert len(c) == SUM["n_places"] == sp["n_sites"] and c.attrs["geometry"].startswith("C2 v7") and c.attrs["generator_version"] == "real-hg-v2"
    pl = [c.place(k) for k in range(len(c))]
    assert sum(p["part"] == "train" for p in pl) == sp["n_train"] and sum(p["part"] == "holdout" for p in pl) == sp["n_holdout"]
    assert all(p["name"] in SITES and p["zoom"] in (11, 12) for p in pl)
    v1 = json.loads((HERE / "out/split_summary.json").read_text())
    assert sp["vs_hg_v1"]["holdout_same"] or sp["vs_hg_v1"]["newly_excluded"] or sp["vs_hg_v1"]["newly_included"]   # расхождение — только из-за исключений
    assert sp["min_dist_holdout_to_train_km"] >= 50 and v1["split_seed"] == sp["split_seed"]


@needs
def test_h400_block_mean_and_limits():
    c = cio.Corpus(str(CORPUS))
    for k in range(0, len(c), 7):
        h100, h400 = c.h100(k, np.float64), c.h400(k, np.float64)
        assert np.abs(cio.block_mean(h100, 4) - h400).max() <= 2 * cio.SCALE_M
        assert c.summary(k)["relief_m"] <= 3000.0 + 1e-6
    g = cio.Corpus(SUM["game_corpus_path"])
    assert [g.place(i)["name"] for i in range(len(g))] == ["askarovo", "aushkul", "altai", "ongudai"]
    assert SUM["readback_h400_vs_hc400_max_abs_m"] <= cio.SCALE_M / 2 + 1e-9 and SUM["g400_vs_hc400_max_abs_m"] <= 1e-6


@needs
def test_game_check_and_raw_deleted():
    gc = json.loads((HERE / "out/game_check_v2.json").read_text())
    assert gc["max_abs_diff_m"] <= 1e-3 and gc["n_failed"] == 0 and gc["n_checked"] >= 13
    assert {r["group"] for r in gc["places"]} == {"game", "was_out_of_layer", "random"}
    assert SUM["raw_deleted"]
