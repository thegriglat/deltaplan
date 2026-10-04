"""Запуск корпуса air-synth (контракт S3): gen / index / sample / bench. Описание — README.md.
  run_corpus.py gen --out DIR --n N --corpus-seed S --workers W [--shard-size 100] [--generator МОДУЛЬ] [--theta-cloud облако.json]
  run_corpus.py index DIR
  run_corpus.py sample DIR --n 50 --seed 1
  run_corpus.py bench [--generator МОДУЛЬ] [--shards 2] [--shard-size 2] [--workers W]
Продолжение после прерывания — той же командой gen: готовые шарды пропускаются, незаконченные (tmp/) удаляются."""
import argparse
import datetime
import hashlib
import importlib
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

pb = cio.pb


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
    """Рабочий процесс: рельефы шарда [lo, hi) -> файл шарда. Возвращает тайминги и размер."""
    gen_name, out, seed, shard, lo, hi, cloud_path = task
    gen = importlib.import_module(gen_name)
    cloud = load_cloud(cloud_path) if cloud_path else None
    t_gen = t_q = t_ser = 0.0
    recs = []
    for rid in range(lo, hi):
        t0 = time.perf_counter()
        if cloud is None:
            params, z100 = gen.generate(seed, rid)
        else:
            k, theta = cloud_point(cloud, seed, rid)
            params, z100 = gen.generate(seed, rid, theta=theta)
            params.extra["cloud_point"] = float(k)
        t1 = time.perf_counter()
        rel = cio.make_relief(seed, rid, gen.GENERATOR_VERSION, params, z100, compute_seconds=t1 - t0)
        t2 = time.perf_counter()
        recs.append(cio.encode_record(rel))
        t3 = time.perf_counter()
        t_gen += t1 - t0; t_q += t2 - t1; t_ser += t3 - t2
    t0 = time.perf_counter()
    nbytes = cio.write_shard(out, "relief", shard, recs)
    t_w = time.perf_counter() - t0
    return dict(shard=shard, n=hi - lo, sec_gen=t_gen, sec_quant=t_q, sec_serialize=t_ser, sec_write=t_w, bytes=nbytes)


def _git_commit():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def gen_corpus(out, n, seed, workers, shard_size, gen_name, quiet=False, theta_cloud=None):
    _single_thread()
    gen = importlib.import_module(gen_name)
    cloud_sha = ""
    if theta_cloud:
        theta_cloud = os.path.abspath(theta_cloud)
        load_cloud(theta_cloud)
        cloud_sha = hashlib.sha1(open(theta_cloud, "rb").read()).hexdigest()
    os.makedirs(out, exist_ok=True)
    shutil.rmtree(os.path.join(out, "tmp"), ignore_errors=True)
    mpath = os.path.join(out, "manifest.pb")
    if os.path.exists(mpath):
        m = cio.read_manifest(out)
        for name, a, b in (("n", m.n_records, n), ("corpus_seed", m.corpus_seed, seed), ("shard_size", m.shard_size, shard_size),
                           ("generator_version", m.generator_version, gen.GENERATOR_VERSION),
                           ("theta_cloud_sha1", m.notes.get("theta_cloud_sha1", ""), cloud_sha)):
            if a != b:
                raise SystemExit(f"продолжение невозможно: {name} в манифесте {a!r}, в запуске {b!r}")
    else:
        m = pb.CorpusManifest(contract=cio.CONTRACT["relief"], name=os.path.basename(os.path.normpath(out)), kind="relief",
                              generator_version=gen.GENERATOR_VERSION, corpus_seed=seed, n_records=n, shard_size=shard_size,
                              shard_pattern=cio.SHARD_PATTERN["relief"], complete=False, command=" ".join(sys.argv),
                              git_commit=_git_commit(), created=datetime.datetime.now().isoformat(timespec="seconds"))
        if theta_cloud:
            m.notes["theta_cloud_sha1"] = cloud_sha
            m.notes["theta_cloud"] = theta_cloud
    m.complete = False
    cio.write_manifest(out, m)
    nshards = (n + shard_size - 1) // shard_size
    have = set(cio.list_shards(out, "relief"))
    todo = [(gen_name, out, seed, k, k * shard_size, min(n, (k + 1) * shard_size), theta_cloud) for k in range(nshards) if k not in have]
    if not quiet:
        print(f"шардов {nshards}, готово {len(have & set(range(nshards)))}, осталось {len(todo)}", flush=True)
    stats = []
    t0 = time.time()
    if todo:
        with mp.get_context("spawn").Pool(max(1, min(workers, len(todo)))) as pool:
            for st in pool.imap_unordered(make_shard, todo):
                stats.append(st)
                with open(os.path.join(out, "timing.jsonl"), "a") as f:
                    f.write(json.dumps(st) + "\n")
                if not quiet:
                    print(f"шард {st['shard']:05d} готов ({len(stats)}/{len(todo)}), {time.time() - t0:.0f} с", flush=True)
    cio.build_index(out, "relief")
    m.complete = True
    cio.write_manifest(out, m)
    return stats


def cmd_sample(a):
    import numpy as np
    c = cio.Corpus(a.dir)
    ids = c.ids()
    k = min(a.n, len(ids))
    pick = sorted(int(ids[i]) for i in np.random.default_rng(a.seed).choice(len(ids), k, replace=False))
    print(" ".join(map(str, pick)))


def cmd_bench(a):
    """Где время: генерация / квантование+сводки / сериализация / запись; на одном рельефе и на --shards шардах параллельно."""
    _single_thread()
    gen = importlib.import_module(a.generator)
    gen.generate(0, 0) if a.warmup else None
    tmp = tempfile.mkdtemp(prefix="airsynth_bench_")
    try:
        t0 = time.perf_counter(); params, z = gen.generate(1, 0); t_gen = time.perf_counter() - t0
        t0 = time.perf_counter(); rel = cio.make_relief(1, 0, gen.GENERATOR_VERSION, params, z, t_gen); t_q = time.perf_counter() - t0
        t0 = time.perf_counter(); rec = cio.encode_record(rel); t_ser = time.perf_counter() - t0
        t0 = time.perf_counter(); cio.write_shard(tmp, "relief", 0, [rec]); t_w = time.perf_counter() - t0
        one = dict(sec_gen=t_gen, sec_quant=t_q, sec_serialize=t_ser, sec_write=t_w, bytes=len(rec))
        out = os.path.join(tmp, "c")
        t0 = time.time()
        st = gen_corpus(out, a.shards * a.shard_size, 1, a.workers, a.shard_size, a.generator, quiet=True)
        wall = time.time() - t0
        nrel = sum(s["n"] for s in st)
        agg = {k: sum(s[k] for s in st) / nrel for k in ("sec_gen", "sec_quant", "sec_serialize", "sec_write", "bytes")}
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
    i = sub.add_parser("index"); i.add_argument("dir")
    s = sub.add_parser("sample"); s.add_argument("dir"); s.add_argument("--n", type=int, default=50); s.add_argument("--seed", type=int, default=1)
    b = sub.add_parser("bench")
    b.add_argument("--generator", default="proto_generator"); b.add_argument("--shards", type=int, default=2)
    b.add_argument("--shard-size", type=int, default=1); b.add_argument("--workers", type=int, default=2)
    b.add_argument("--warmup", action="store_true"); b.add_argument("--json")
    a = ap.parse_args(argv)
    if a.cmd == "gen":
        gen_corpus(a.out, a.n, a.corpus_seed, a.workers, a.shard_size, a.generator, theta_cloud=a.theta_cloud)
    elif a.cmd == "index":
        idx = cio.build_index(a.dir)
        print(f"индекс: {len(idx.entries)} записей")
    elif a.cmd == "sample":
        cmd_sample(a)
    else:
        cmd_bench(a)


if __name__ == "__main__":
    main()
