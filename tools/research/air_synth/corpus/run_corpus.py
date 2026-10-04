"""Запуск корпуса air-synth (контракт S3): gen / index / sample / bench. Описание — README.md.
  run_corpus.py gen --out DIR --n N --corpus-seed S --workers W [--shard-size 100] [--generator МОДУЛЬ] [--theta-cloud облако.json]
  run_corpus.py view DIR
  run_corpus.py sample DIR --n 50 --seed 1
  run_corpus.py stats DIR --n 60 --seed 1 --json out_corpus/stats_sample.json   # наблюдаемые SY-5 выборки против реальных квадратов
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
    if not np.all(np.isfinite(np.asarray(c["points"], float))):
        raise ValueError("облако: в points есть NaN/inf")
    if c.get("weights") is not None and not np.all(np.isfinite(np.asarray(c["weights"], float))):
        raise ValueError("облако: в weights есть NaN/inf")
    # T (t_total_yr) — одно для всего облака: столбец t_total_yr с разными значениями или поле t_total_yr-списком — отказ
    tt = []
    if "t_total_yr" in c["names"]:
        k = c["names"].index("t_total_yr")
        tt += [p[k] for p in c["points"]]
    if isinstance(c.get("t_total_yr"), (list, tuple)):
        tt += list(c["t_total_yr"])
    if len(set(tt)) > 1:
        raise ValueError("облако: разные t_total_yr в точках")
    return c


def cloud_point(c, seed, rid, weights="equal"):
    """Точка облака для рельефа: детерминированно из SeedSequence([corpus_seed, id, 1]). -> (номер, theta-словарь)."""
    import numpy as np
    rng = np.random.default_rng(np.random.SeedSequence([seed, rid, 1]))
    w = c.get("weights") if weights == "file" else None
    if w:
        w = np.asarray(w, float)
        k = int(rng.choice(len(w), p=w / w.sum()))
    else:
        k = int(rng.integers(len(c["points"])))
    return k, {n: float(v) for n, v in zip(c["names"], c["points"][k])}


def make_shard(task):
    """Рабочий процесс: рельефы части [lo, hi) -> part-{k}.h5. Возвращает тайминги и размер."""
    gen_name, out, seed, shard, lo, hi, cloud_path, attrs, wmode = task
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
            k, theta = cloud_point(cloud, seed, rid, wmode)
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


def gen_corpus(out, n, seed, workers, shard_size, gen_name, quiet=False, theta_cloud=None, cloud_weights="equal"):
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
                generator_version=gen.GENERATOR_VERSION, theta_cloud=cloud_id,
                cloud_weights=cloud_weights if theta_cloud else "")
    man = cio.read_manifest(out)
    if not man and cio.list_parts(out):
        # части без manifest.json: сверка по атрибутам корня первой части или отказ
        import h5py
        with h5py.File(cio.part_path(out, cio.list_parts(out)[0]), "r") as f0:
            ra = dict(f0.attrs)
        bad = [k for k in ("contract", "kind", "n_total", "corpus_seed", "shard_size", "generator_version", "theta_cloud", "cloud_weights")
               if str(ra.get(k, "")) != str(want.get(k, ""))]
        if bad:
            raise SystemExit("части без manifest.json, атрибуты первой части не совпадают с запуском: " + ", ".join(bad))
        man = dict(want, command=str(ra.get("command", "")), git_commit=str(ra.get("git_commit", "")),
                   created=str(ra.get("created", "")), complete=False, manifest_restored=True)
        cio.write_manifest(out, man)
    if man:
        for k, v in want.items():
            if man.get(k) != v:
                raise SystemExit(f"продолжение невозможно: {k} в манифесте {man.get(k)!r}, в запуске {v!r}")
    else:
        man = dict(want, command=" ".join(sys.argv), git_commit=_git_commit(), created=datetime.datetime.now().isoformat(timespec="seconds"),
                   complete=False)
        cio.write_manifest(out, man)
    attrs = dict(shard_size=shard_size, n_total=n, generator_version=gen.GENERATOR_VERSION, corpus_seed=np.uint64(seed), theta_cloud=cloud_id, cloud_weights=want["cloud_weights"],
                 command=man["command"], git_commit=man["git_commit"])
    nshards = (n + shard_size - 1) // shard_size
    have = set(cio.list_parts(out))
    todo = [(gen_name, out, seed, k, k * shard_size, min(n, (k + 1) * shard_size), theta_cloud, attrs, cloud_weights) for k in range(nshards) if k not in have]
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


def _obs_job(a):
    path, rid = a
    sys.path.insert(0, os.path.join(HERE, "..", "tune"))
    import observables as ob  # noqa: E402  (SY-5: те же наблюдаемые, что в настройке; statistics — terrain_stats/stats.py)
    c = cio.Corpus(path)
    z = c.h100(rid, np.float64)
    c.close()
    return ob.vec(ob.observables(z))


def cmd_stats(a):
    """Статистики выборки корпуса (n рельефов, seed как у sample) против реальных квадратов настройки SY-5 (4 detail + 64 far + 299 пул):
    те же 17 наблюдаемых (tune/observables.py). Флаг out: медиана выборки вне [p5, p95] реальных квадратов; frac_outside — доля
    рельефов выборки вне [min, max] реальных. -> JSON (таблица, out_of_range)."""
    _single_thread()
    sys.path.insert(0, os.path.join(HERE, "..", "tune"))
    import observables as ob  # noqa: E402
    c = cio.Corpus(a.dir)
    ids = c.ids()
    pick = sorted(int(ids[i]) for i in np.random.default_rng(a.seed).choice(len(ids), min(a.n, len(ids)), replace=False))
    man = dict(cio.read_manifest(a.dir) or {})
    c.close()
    t0 = time.time()
    with mp.get_context("spawn").Pool(max(1, a.workers)) as pool:
        V = np.array(pool.map(_obs_job, [(a.dir, r) for r in pick], chunksize=1))
    tune_out = os.path.join(HERE, "..", "tune", "out")
    sq = json.load(open(os.path.join(tune_out, "ref_obs.json")))["squares"] + json.load(open(os.path.join(tune_out, "ref_obs_pool.json")))["squares"]
    keep = set(json.load(open(os.path.join(tune_out, "theta_cloud_meta.json")))["squares"])     # те 367 квадратов, по которым настроено облако
    sq = [r for r in sq if r["name"] in keep]
    R = np.array([[np.nan if r["obs"][n] is None else r["obs"][n] for n in ob.NAMES] for r in sq], float)
    table, n_out = [], 0
    q = lambda x, p: float(np.nanpercentile(x, p))
    for j, n in enumerate(ob.NAMES):
        v, r = V[:, j], R[:, j]
        row = dict(name=n, n_nan_sample=int(np.isnan(v).sum()), n_nan_real=int(np.isnan(r).sum()),
                   sample=dict(median=q(v, 50), p10=q(v, 10), p90=q(v, 90), min=float(np.nanmin(v)), max=float(np.nanmax(v))),
                   real=dict(median=q(r, 50), p5=q(r, 5), p10=q(r, 10), p90=q(r, 90), p95=q(r, 95), min=float(np.nanmin(r)), max=float(np.nanmax(r))),
                   frac_outside=float(np.nanmean((v < np.nanmin(r)) | (v > np.nanmax(r)))),
                   shift_in_real_sd=float((q(v, 50) - q(r, 50)) / (np.nanstd(r) + 1e-12)))
        row["out"] = bool(not (row["real"]["p5"] <= row["sample"]["median"] <= row["real"]["p95"]))
        n_out += row["out"]
        table.append(row)
    res = dict(corpus=a.dir, generator_version=man.get("generator_version"), n=len(pick), seed=a.seed, ids=pick, n_real=len(sq),
               real_source="tune/out/ref_obs.json + ref_obs_pool.json (квадраты облака theta_cloud_meta.json: 4 detail, 64 far, 299 pool)", out_of_range=int(n_out),
               rule="out: медиана выборки вне [p5, p95] реальных квадратов", seconds=round(time.time() - t0, 1), table=table)
    print(f"{'наблюдаемая':16s} {'выборка p10/мед/p90':26s} {'реальные p5/мед/p95':26s} вне  доля вне [min,max]")
    for r in table:
        s_, r_ = r["sample"], r["real"]
        print(f"{r['name']:16s} {s_['p10']:8.3g}/{s_['median']:8.3g}/{s_['p90']:8.3g}  {r_['p5']:8.3g}/{r_['median']:8.3g}/{r_['p95']:8.3g}  {'ВНЕ' if r['out'] else '   '} {r['frac_outside']:.2f}")
    print("out_of_range =", n_out)
    if a.json:
        os.makedirs(os.path.dirname(os.path.abspath(a.json)), exist_ok=True)
        json.dump(res, open(a.json, "w"), indent=1, ensure_ascii=False)


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
    g.add_argument("--cloud-weights", choices=("equal", "file"), default="equal", help="равные веса точек облака (по умолчанию; решение 10-05) или поле weights файла")
    g.add_argument("--theta-cloud", help="облако настроек .json (S3 v2); без него theta=None")
    i = sub.add_parser("view"); i.add_argument("dir")
    s = sub.add_parser("sample"); s.add_argument("dir"); s.add_argument("--n", type=int, default=50); s.add_argument("--seed", type=int, default=1)
    st = sub.add_parser("stats"); st.add_argument("dir"); st.add_argument("--n", type=int, default=60); st.add_argument("--seed", type=int, default=1)
    st.add_argument("--workers", type=int, default=4); st.add_argument("--json")
    b = sub.add_parser("bench")
    b.add_argument("--generator", default="proto_generator"); b.add_argument("--shards", type=int, default=2)
    b.add_argument("--shard-size", type=int, default=1); b.add_argument("--workers", type=int, default=2)
    b.add_argument("--warmup", action="store_true"); b.add_argument("--json")
    a = ap.parse_args(argv)
    if a.cmd == "gen":
        gen_corpus(a.out, a.n, a.corpus_seed, a.workers, a.shard_size, a.generator, theta_cloud=a.theta_cloud, cloud_weights=a.cloud_weights)
    elif a.cmd == "stats":
        cmd_stats(a)
    elif a.cmd == "view":
        print(cio.build_view(a.dir))
    elif a.cmd == "sample":
        cmd_sample(a)
    else:
        cmd_bench(a)


if __name__ == "__main__":
    main()
