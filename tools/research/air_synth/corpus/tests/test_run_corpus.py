"""Запуск корпуса (S3): детерминизм по числу процессов, продолжение после прерывания (resume), sample."""
import glob
import os
import signal
import subprocess
import sys
import time
import numpy as np
import corpus_io as cio

CORPUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(CORPUS, "tests")


def run(args, env_extra=None, **kw):
    env = dict(os.environ, PYTHONPATH=TESTS, **(env_extra or {}))
    cmd = [sys.executable, os.path.join(CORPUS, "run_corpus.py"), *args, "--generator", "fakegen"]
    return subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)


def gen_args(out, n, workers, shard_size=2, seed=5, cloud=None):
    return ["gen", "--out", out, "--n", str(n), "--corpus-seed", str(seed), "--workers", str(workers), "--shard-size", str(shard_size)]


def shards_normalized(d):
    """Части -> байты наборов relief/*, gen/params, summary без compute_seconds (побитное сравнение кроме compute_seconds)."""
    import h5py
    out = {}
    for k in cio.list_parts(d):
        with h5py.File(cio.part_path(d, k), "r") as f:
            s = f["summary"][:]
            s["compute_seconds"] = 0.0
            out[k] = [f["relief/id"][:].tobytes(), f["relief/h100"][:].tobytes(), f["relief/h400"][:].tobytes(), f["gen/params"][:].tobytes(), s.tobytes()]
    return out


def test_workers_independent(tmp_path):
    a, b = str(tmp_path / "a"), str(tmp_path / "b")
    assert run(gen_args(a, 7, 1)).wait(180) == 0
    assert run(gen_args(b, 7, 3)).wait(180) == 0
    assert shards_normalized(a) == shards_normalized(b)
    c = cio.Corpus(a)
    assert len(c) == 7 and c.attrs["complete"] and c.attrs["n_records"] == 7 and cio.list_parts(a) == [0, 1, 2, 3]
    assert os.path.exists(a + "/manifest.json") and os.path.exists(a + "/corpus.h5")
    assert c.attrs["generator_version"] == "fake-1" and c.params(5)["corpus_seed"] == 5


def test_resume_after_kill(tmp_path):
    ref, out = str(tmp_path / "ref"), str(tmp_path / "out")
    n = 12
    assert run(gen_args(ref, n, 2)).wait(300) == 0
    env = {"FAKEGEN_SLEEP": "0.4"}
    p = run(gen_args(out, n, 2), env, start_new_session=True)
    deadline = time.time() + 120
    while time.time() < deadline and not (os.path.isdir(out) and len(cio.list_parts(out)) >= 2):
        time.sleep(0.1)
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    time.sleep(1.5)                                       # осиротевшие рабочие дописывают свой шард или падают
    part = len(cio.list_parts(out))
    assert 1 <= part < n // 2, part                        # прервали посередине
    assert not cio.read_manifest(out).get("complete") and not os.path.exists(out + "/corpus.h5")
    assert run(gen_args(out, n, 2)).wait(300) == 0         # тем же вызовом
    assert cio.read_manifest(out)["complete"] and cio.Corpus(out).attrs["complete"]
    assert shards_normalized(out) == shards_normalized(ref)
    a, b = cio.Corpus(out), cio.Corpus(ref)
    assert a.ids() == b.ids() == list(range(n))
    assert all(np.array_equal(a.h100(i), b.h100(i)) for i in range(n))
    assert not glob.glob(out + "/*.tmp")


def test_resume_mismatch_refused(tmp_path):
    out = str(tmp_path / "o")
    assert run(gen_args(out, 4, 1)).wait(120) == 0
    assert run(gen_args(out, 6, 1)).wait(120) != 0        # другой n — отказ, не молчаливая порча


def test_sample_deterministic(tmp_path, capsys):
    out = str(tmp_path / "o")
    assert run(gen_args(out, 9, 2)).wait(120) == 0
    def s(seed):
        r = subprocess.run([sys.executable, os.path.join(CORPUS, "run_corpus.py"), "sample", out, "--n", "4", "--seed", str(seed)], capture_output=True, text=True)
        return list(map(int, r.stdout.split()))
    a = s(1)
    assert a == s(1) and len(set(a)) == 4 and a == sorted(a) and all(0 <= i < 9 for i in a) and a != s(2)


def test_theta_cloud(tmp_path):
    import json
    cl = str(tmp_path / "cloud.json")
    json.dump({"names": ["shift", "a"], "points": [[10.0, 0.1], [50.0, 0.2], [90.0, 0.3]], "weights": [1, 1, 2], "source": "test"}, open(cl, "w"))
    a, b = str(tmp_path / "a"), str(tmp_path / "b")
    assert run(gen_args(a, 6, 1) + ["--theta-cloud", cl]).wait(120) == 0
    assert run(gen_args(b, 6, 3) + ["--theta-cloud", cl]).wait(120) == 0
    assert shards_normalized(a) == shards_normalized(b)
    c = cio.Corpus(a)
    pts = []
    for rid in range(6):
        p = c.params(rid)
        k = p["cloud_point"]
        pts.append(k)
        assert p["shift"] == [10.0, 50.0, 90.0][k] and p["a"] == [0.1, 0.2, 0.3][k]
    assert len(set(pts)) > 1
    assert "sha1:" in c.attrs["theta_cloud"]
    assert run(gen_args(a, 6, 1)).wait(120) != 0          # продолжение без облака у корпуса с облаком — отказ
