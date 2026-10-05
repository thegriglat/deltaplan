"""Шаг 2: план прогонов генератора по латинскому гиперкубу в пределах TUNABLE, наблюдаемые на каждый (точка, зерно).
Запуск (фоном, dp job start): OMP_NUM_THREADS=1 ../corpus/.venv/bin/python run_design.py --points 150 --seeds 4 --workers 12
Продолжение — той же командой (готовые строки out/runs.jsonl пропускаются). Пробное время: --trial 2 (точки, 1 зерно).
Генератор: ../corpus/generator.py (S3 v3): TUNABLE, generate(corpus_seed, relief_id, theta) -> (params, z100)."""
import argparse, json, os, sys, time
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.environ.get("SY5_GENERATOR_DIR", os.path.join(HERE, "..", "corpus")))
import tunelib as T  # noqa: E402
import observables as ob  # noqa: E402

CORPUS_SEED = 5001


def task(a):
    import generator as G
    p, s, theta = a
    t0 = time.time()
    _, z = G.generate(CORPUS_SEED, p * 100 + s, theta)
    o = ob.observables(z)
    return dict(point=p, seed=s, obs=o, t_gen=0.0, t=time.time() - t0, version=G.GENERATOR_VERSION)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", type=int, default=150)
    ap.add_argument("--seeds", type=int, default=4)
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--trial", type=int, default=0)
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    a = ap.parse_args()
    import generator as G
    sp = T.Space(G.TUNABLE)
    os.makedirs(a.out, exist_ok=True)
    dpath = os.path.join(a.out, "design.json")
    if os.path.exists(dpath):
        D = json.load(open(dpath))
        assert D["names"] == sp.names and D["generator"] == G.GENERATOR_VERSION and D["n_points"] == a.points, \
            "план в out/design.json не совпадает с генератором/параметрами — удалить out/ для нового плана"
        U = np.array(D["U"])
    else:
        U = T.lhs(len(sp.names), a.points, seed=12345)
        json.dump(dict(names=sp.names, lo=sp.lo.tolist(), hi=sp.hi.tolist(), log=sp.log.tolist(), n_points=a.points,
                       n_seeds=a.seeds, corpus_seed=CORPUS_SEED, generator=G.GENERATOR_VERSION, U=U.tolist()),
                  open(dpath, "w"))
    rpath = os.path.join(a.out, "runs.jsonl")
    done = set()
    if os.path.exists(rpath):
        for l in open(rpath):
            r = json.loads(l); done.add((r["point"], r["seed"]))
    if a.trial:
        todo = [(p, 0, sp.theta(U[p])) for p in range(a.trial)]
    else:
        todo = [(p, s, sp.theta(U[p])) for s in range(a.seeds) for p in range(a.points) if (p, s) not in done]
    print(f"к выполнению {len(todo)} прогонов, готово {len(done)}", flush=True)
    from multiprocessing import Pool
    t0 = time.time()
    with Pool(a.workers) as pool, open(rpath if not a.trial else os.devnull, "a") as f:
        for k, r in enumerate(pool.imap_unordered(task, todo, chunksize=1), 1):
            f.write(json.dumps(r) + "\n"); f.flush()
            if a.trial or k % 20 == 0:
                print(k, f"{time.time() - t0:.0f} с, прогон {r['t']:.1f} с", flush=True)
    print(f"готово: {time.time() - t0:.0f} с стенных", flush=True)


if __name__ == "__main__":
    main()
