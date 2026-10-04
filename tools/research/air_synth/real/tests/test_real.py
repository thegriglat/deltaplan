"""Тесты SY-6: корпус реальных мест (после pack_real.py pack), сводка out/real_summary.json."""
import json, os, sys
from pathlib import Path
import numpy as np
import pytest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE.parent / "corpus"))
sys.path.insert(0, str(HERE))
import corpus_io as cio  # noqa: E402
import pack_real as P    # noqa: E402

SUM = json.loads((HERE / "out/real_summary.json").read_text()) if (HERE / "out/real_summary.json").exists() else None
CORPUS = Path(SUM["corpus_path"]) if SUM else None
needs = pytest.mark.skipif(not (CORPUS and (CORPUS / "corpus.h5").exists()), reason="корпус не упакован")


def test_grids_block_mean_synthetic():
    h = np.random.default_rng(0).normal(size=(1601, 1601)) + 100
    z100, z400 = P.grids(h)
    assert z100.shape == (384, 384) and z400.shape == (96, 96)
    assert np.allclose(cio.block_mean(z100, 4), z400, atol=1e-9)
    assert np.isclose(z100[0, 0], h[32:36, 32:36].mean())   # j — юг/север, i — восток: узел 32 = −19 200 м
    assert np.isclose(z100[-1, -1], h[1564:1568, 1564:1568].mean())


@needs
def test_count_and_parts():
    c = cio.Corpus(str(CORPUS))
    assert len(c) == SUM["n_places"] >= 360
    pl = [c.place(k) for k in range(len(c))]
    parts = [bytes(p["part"]).decode() if not isinstance(p["part"], str) else p["part"] for p in pl]
    assert parts.count("pool") == 300 and parts.count("holdout") == 60
    for p in pl:
        for k in ("name", "system", "stratum", "source", "source_sha256"):
            assert str(p[k]) not in ("", "b''"), (k, p)
        assert p["zoom"] > 0 and p["src_spacing_m"] > 0 and -90 < p["lat_deg"] < 90


@needs
def test_g400_is_block_mean_of_g100():
    c = cio.Corpus(str(CORPUS))
    for k in range(0, len(c), 17):
        h100, h400 = c.h100(k, np.float64), c.h400(k, np.float64)
        assert np.abs(cio.block_mean(h100, 4) - h400).max() <= 2 * cio.SCALE_M


def test_summary_match():
    assert SUM and SUM["systems_match_v3"] is True
    assert SUM["g400_vs_hc400_max_abs_m"] <= 1e-6
