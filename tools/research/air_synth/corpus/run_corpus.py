"""Запуск корпуса air-synth (контракт S3): gen / index / sample / bench. Описание — README.md.
  run_corpus.py gen --out DIR --n N --corpus-seed S --workers W [--shard-size 100] [--generator МОДУЛЬ] [--theta-cloud облако.json]
  run_corpus.py view DIR
  run_corpus.py sample DIR --n 50 --seed 1
  run_corpus.py bench [--generator МОДУЛЬ] [--shards 2] [--shard-size 2] [--workers W]
Продолжение после прерывания — той же командой gen: готовые части пропускаются, *.tmp удаляются."""
import argparse
import datetime
import hashlib
import importlib
import numpy as np
import json
import multiprocessing as mp
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import corpus_io as cio  # noqa: E402



def _single_thread():
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMBA_NUM_THREADS"):
        os.environ[k] = "1"


def load_cloud(path):
    """Облако настроек (S3 v2): {"names": [...], "points": [[...], ...], "weights": [...]?, "source": "..."}."""
    c = json.load(open(path))
    if not c["points"] or any(len(p) != len(c["names"]) for p in c["points"]):
        raise ValueError("облако: points не согласованы с names")
    if "weights" in c and c["weights"] is not None and len(c["weights"]) != len(c["points"]):
        raise ValueError("облако: weights не по числу points")
    return c


def cloud_point(c, seed, rid):
    """Точка облака для рельефа: детерминированно из SeedSequence([corpus_seed, id, 1]). -> (номер, theta-словарь)."""
    import numpy as np
    rng = np.random.default_rng(np.random.SeedSequence([seed, rid, 1]))
    w = c.get("weights")
    if w:
        w = np.asarray(w, float)
        k = int(rng.choice(len(w), p=w / w.sum()))
    else:
        k = int(rng.integers(len(c["points"])))
    return k, {n: float(v) for n, v in zip(c["names"], c["points"][k])}


def make_shard(task):
    """Рабочий процесс: рельефы части [lo, hi) -> part-{k}.h5. Возвращает тайминги и размер."""
    gen_name, out, seed, shard, lo, hi, cloud_path, attrs = task
    gen = importlib.import_module(gen_name)
    cloud = load_cloud(cloud_path) if cloud_path else None
    names = list(gen.PARAM_NAMES)
    dt = np.dtype([("id", "<i8"), ("corpus_seed", "<u8"), ("cloud_point", "<i4")] + [(n, "<f8") for n in names])
    t_gen = t_q = 0.0
    q100, q400, summ, pa = [], [], [], np.zeros(hi - lo, dt)
    for j, rid in enumerate(range(lo, hi)):
        t0 = time.perf_counter()
        k = -1
        if cloud is None:
            params, z100 = gen.generate(seed, rid)
        else:
            k, theta = cloud_point(cloud, seed, rid)
            params, z100 = gen.generate(seed, rid, theta=theta)
        t1 = time.perf_counter()
        a, b, s = cio.encode_relief(rid, z100, t1 - t0)
        q100.append(a); q400.append(b); summ.append(s)
        pa[j]["id"], pa[j]["corpus_seed"], pa[j]["cloud_point"] = rid, seed, k
        for n in names:
            pa[j][n] = params[n]
        t_gen += t1 - t0; t_q += time.perf_counter() - t1
    t0 = time.perf_counter()
    nbytes = cio.write_part(out, shard, np.arange(lo, hi), np.stack(q100), np.stack(q400), np.array(summ), params=pa, attrs=attrs, columns=names)
    t_w = time.perf_counter() - t0
    return dict(shard=shard, n=hi - lo, sec_gen=t_gen, sec_quant=t_q, sec_write=t_w, bytes=nbytes)


def _git_commit():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def gen_corpus(out, n, seed, workers, shard_size, gen_name, quiet=False, theta_cloud=None):
    _single_thread()
    gen = importlib.import_module(gen_name)
    cloud_id = ""
    if theta_cloud:
        theta_cloud = os.path.abspath(theta_cloud)
        load_cloud(theta_cloud)
        cloud_id = theta_cloud + " sha1:" + hashlib.sha1(open(theta_cloud, "rb").read()).hexdigest()
    os.makedirs(out, exist_ok=True)
    cio.clean_tmp(out)
    want = dict(contract=cio.CONTRACT["relief"], kind="relief", n_total=n, corpus_seed=seed, shard_size=shard_size,
                generator_version=gen.GENERATOR_VERSION, theta_cloud=cloud_id)
    man = cio.read_manifest(out)
    if man:
        for k, v in want.items():
            if man.get(k) != v:
                raise SystemExit(f"продолжение невозможно: {k} в манифесте {man.get(k)!r}, в запуске {v!r}")
    else:
        man = dict(want, command=" ".join(sys.argv), git_commit=_git_commit(), created=datetime.datetime.now().isoformat(timespec="seconds"),
                   complete=False)
        cio.write_manifest(out, man)
    attrs = dict(shard_size=shard_size, n_total=n, generator_version=gen.GENERATOR_VERSION, corpus_seed=np.uint64(seed), theta_cloud=cloud_id,
                 command=man["command"], git_commit=man["git_commit"])
    nshards = (n + shard_size - 1) // shard_size
    have = set(cio.list_parts(out))
    todo = [(gen_name, out, seed, k, k * shard_size, min(n, (k + 1) * shard_size), theta_cloud, attrs) for k in range(nshards) if k not in have]
    if not quiet:
        print(f"частей {nshards}, готово {len(have & set(range(nshards)))}, осталось {len(todo)}", flush=True)
    stats = []
    t0 = time.time()
    if todo:
        with mp.get_context("spawn").Pool(max(1, min(workers, len(todo)))) as pool:
            for st in pool.imap_unordered(make_shard, todo):
                stats.append(st)
                with open(os.path.join(out, "timing.jsonl"), "a") as f:
                    f.write(json.dumps(st) + "\n")
                if not quiet:
                    print(f"часть {st['shard']:05d} готова ({len(stats)}/{len(todo)}), {time.time() - t0:.0f} с", flush=True)
    cio.build_view(out, "relief")
    return stats


def cmd_sample(a):
    c = cio.Corpus(a.dir)
    ids = c.ids()
    k = min(a.n, len(ids))
    pick = sorted(int(ids[i]) for i in np.random.default_rng(a.seed).choice(len(ids), k, replace=False))
    print(" ".join(map(str, pick)))


def cmd_bench(a):
    """Где время: генерация / квантование+сводки / запись части HDF5; на одном рельефе и на --shards шардах параллельно."""
    _single_thread()
    gen = importlib.import_module(a.generator)
    gen.generate(0, 0) if a.warmup else None
    tmp = tempfile.mkdtemp(prefix="airsynth_bench_")
    try:
        t0 = time.perf_counter(); params, z = gen.generate(1, 0); t_gen = time.perf_counter() - t0
        t0 = time.perf_counter(); q1, q4, s = cio.encode_relief(0, z, t_gen); t_q = time.perf_counter() - t0
        t0 = time.perf_counter()
        nb = cio.write_part(tmp, 0, np.array([0]), q1[None], q4[None], np.array([s]), attrs=dict(shard_size=1))
        t_w = time.perf_counter() - t0
        one = dict(sec_gen=t_gen, sec_quant=t_q, sec_write=t_w, bytes=nb)
        out = os.path.join(tmp, "c")
        t0 = time.time()
        st = gen_corpus(out, a.shards * a.shard_size, 1, a.workers, a.shard_size, a.generator, quiet=True)
        wall = time.time() - t0
        nrel = sum(s["n"] for s in st)
        agg = {k: sum(s[k] for s in st) / nrel for k in ("sec_gen", "sec_quant", "sec_write", "bytes")}
        res = dict(generator=a.generator, version=gen.GENERATOR_VERSION, one_relief=one,
                   shards=dict(n_shards=a.shards, shard_size=a.shard_size, workers=a.workers, wall_s=wall, per_relief=agg))
        print(json.dumps(res, indent=1))
        if a.json:
            json.dump(res, open(a.json, "w"), indent=1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--out", required=True); g.add_argument("--n", type=int, required=True)
    g.add_argument("--corpus-seed", type=int, required=True); g.add_argument("--workers", type=int, default=os.cpu_count())
    g.add_argument("--shard-size", type=int, default=100); g.add_argument("--generator", default="generator")
    g.add_argument("--theta-cloud", help="облако настроек .json (S3 v2); без него theta=None")
    i = sub.add_parser("view"); i.add_argument("dir")
    s = sub.add_parser("sample"); s.add_argument("dir"); s.add_argument("--n", type=int, default=50); s.add_argument("--seed", type=int, default=1)
    b = sub.add_parser("bench")
    b.add_argument("--generator", default="proto_generator"); b.add_argument("--shards", type=int, default=2)
    b.add_argument("--shard-size", type=int, default=1); b.add_argument("--workers", type=int, default=2)
    b.add_argument("--warmup", action="store_true"); b.add_argument("--json")
    a = ap.parse_args(argv)
    if a.cmd == "gen":
        gen_corpus(a.out, a.n, a.corpus_seed, a.workers, a.shard_size, a.generator, theta_cloud=a.theta_cloud)
    elif a.cmd == "view":
        print(cio.build_view(a.dir))
    elif a.cmd == "sample":
        cmd_sample(a)
    else:
        cmd_bench(a)


if __name__ == "__main__":
    main()
