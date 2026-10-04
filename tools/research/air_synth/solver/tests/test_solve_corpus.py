"""Счёт на искусственном мини-корпусе (3 гладких рельефа) настоящим решателем P2 — 3 случая, GPU под замком (--own-lock).
Проверяет: части и вид S5, продолжение (стёртая часть пересчитывается, остальные не трогаются, поля те же), hc решателя = h400 корпуса."""
import sys
from pathlib import Path

import h5py
import numpy as np
import pytest

SOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOL))
import s5_io as S5   # noqa: E402
import solve_corpus as SC   # noqa: E402
import make_p2c12 as MK   # noqa: E402

cio = S5.cio


def hill(a, sx):
    j, i = np.mgrid[0:384, 0:384].astype(float)
    return 1200 + 300 * np.exp(-(((i - 192) / 60) ** 2 + ((j - 192) / (60 * sx)) ** 2)) + a * i


def test_mini_corpus_real_solver(tmp_path, monkeypatch):
    corpus, cond, out = tmp_path / "corpus", tmp_path / "cond", tmp_path / "solve"
    cio.write_reliefs(str(corpus), [dict(z100=hill(a, s), params=dict(p=1.0)) for a, s in ((0.1, 1.0), (0.3, 1.5), (0.2, 0.8))], shard_size=100)
    MK.main(["--relief-corpus", str(corpus), "--plan", "model", "--out", str(cond), "--k-cond", "1", "--n-train", "2", "--n-holdout", "1"])
    assert len(cio.Conditions(str(cond))) == 3
    monkeypatch.setattr(SC, "SHARD", 2)
    argv = ["--relief-corpus", str(corpus), "--conditions", str(cond), "--plan", "model", "--k-cond", "1", "--n-train", "2", "--n-holdout", "1",
            "--workers", "2", "--out", str(out), "--own-lock", "--progress", str(tmp_path / "progress.json")]
    SC.main(argv)
    assert cio.list_parts(str(out)) == [0, 1]
    s = S5.Solve(out)
    assert len(s) == 3 and s.attrs["complete"] and list(s.cases["group"]) == [0, 0, 1]
    assert np.all(s.cases["status_m"] <= 1) and np.all(s.cases["iters_m"] > 0) and np.all(s.cases["seconds"] > 0)
    assert S5.read_plan(str(out)) == [[0, 0, "train"], [1, 0, "train"], [2, 0, "holdout"]]
    c0 = cio.Corpus(str(corpus))
    for i in range(3):   # S4: клетки решателя на 400 м = h400 корпуса (до шага квантования)
        assert np.abs(s.get("inputs/hc", i) - c0.h400(i, np.float32)).max() <= 0.15
        for n in ("fields/m", "fields/h"):
            a = s.get(n, i).astype(np.float32)
            assert np.all(np.isfinite(a)) and a.std() > 0
    # физический смысл: на гладком холме есть ненулевой ветер у земли
    assert np.abs(s.get("fields/m", 0)[0, 0]).max() > 0.5
    first = s.get("fields/h", 2).copy(); p0 = (out / "part-00000.h5").stat().st_mtime_ns
    s.close()
    # продолжение: стираем часть 1 и вид, та же команда
    (out / "part-00001.h5").unlink(); (out / "solve.h5").unlink()
    SC.main(argv)
    assert (out / "part-00000.h5").stat().st_mtime_ns == p0
    s = S5.Solve(out)
    assert len(s) == 3 and np.array_equal(s.get("fields/h", 2), first)
    prog = __import__("json").load(open(tmp_path / "progress.json"))
    assert prog["dirs"]["solve"]["cases_done"] == 3 and "train" in prog["dirs"]["solve"]["stage_done"]
    s.close()
