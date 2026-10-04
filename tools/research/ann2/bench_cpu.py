"""AN-4 (A2 v2): скорость инференса на CPU (torch, 6 потоков, карта 96², 13 высот П1): энкодер (карта признаков + условия),
голова (13 высот), итого и P2 тем же способом (`runs/2026-10-03_p2b/main`). Печатает encoder_ms, head_ms, total_ms, p2_ms,
`ratio_to_p2 <итого ann2 / P2>`.   bench_cpu.py --run <имя прогона> [--random_init --head mlp|deeponet]"""
from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

import numpy as np
import torch

import data as D
import model as M
import phys
from pilotnn import evaluate as E


def timeit(fn, n, warm=3):
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(n):
        t = time.perf_counter(); fn(); ts.append((time.perf_counter() - t) * 1000)
    return statistics.median(ts), min(ts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default=None)
    ap.add_argument("--random_init", action="store_true")
    ap.add_argument("--head", default="deeponet")
    ap.add_argument("--threads", type=int, default=6)
    ap.add_argument("--n", type=int, default=20)
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    cpu = torch.device("cpu")
    if a.run and not a.random_init:
        f = D.RUNS / a.run / ("best.pt" if (D.RUNS / a.run / "best.pt").exists() else "model.pt")
        net, _ = M.load_run(f)
    else:
        net = M.Ann2(head=a.head)
    net.eval()
    split = D.p2_split()
    st = D.Store(split["holdout_sys_ids"][:1])
    inp = D.eval_inputs(st.X, st.F, st.par, st.prof, True, cpu, N=st.N)
    eta = torch.tensor(phys.AGL, dtype=torch.float32).view(1, 13, 1, 1).expand(1, 13, 96, 96)
    with torch.inference_mode():
        enc = lambda: net.features(inp["maps"], inp["scal"], inp["prof"])  # noqa: E731
        Fm, c = enc()
        head = lambda: net.decode(Fm, c, inp["par"], eta, inp["prof"])  # noqa: E731
        tot = lambda: net(inp["maps"], inp["scal"], inp["prof"], inp["par"], eta)  # noqa: E731
        te, _ = timeit(enc, a.n); th, _ = timeit(head, a.n); tt, tt_min = timeit(tot, a.n)
        info = D.p2_info()
        p2, _ = E.load_net(Path(info.get("main_dir") or D.P2_RUN / "main"), cpu)
        X, F = torch.from_numpy(st.X), torch.from_numpy(st.F)
        tp, tp_min = timeit(lambda: p2(X, F), a.n)
    print(f"threads {a.threads} params_M {M.count_params(net) / 1e6:.3f} head {net.head_kind}")
    print(f"encoder_ms {te:.1f}\nhead_ms {th:.1f}\ntotal_ms {tt:.1f}\np2_ms {tp:.1f}")
    print(f"ratio_to_p2 {tt / tp:.2f}   (по минимумам {tt_min / tp_min:.2f})")


if __name__ == "__main__":
    main()
