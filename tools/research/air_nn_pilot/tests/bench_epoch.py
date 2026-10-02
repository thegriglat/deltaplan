#!/usr/bin/env python3
"""Замер времени эпохи полного размера (приёмка NN-P2 п. 4): кеш подготовки smoke-набора размножается до
n_train обучающих образцов (индексы по кругу), шаг обучения — как в pilotnn/train.py (bf16, детерминированный
режим, AdamW, EMA, конфиг основной сети); + проверка на n_val. Под замком GPU. → tests/out/bench_epoch.json.

  .venv/bin/python tests/bench_epoch.py <каталог кеша подготовки> [--n-train 1220] [--n-val 160] [--epochs 3]
"""
from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import argparse  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn import model as M  # noqa: E402
from pilotnn.train import EMA, channel_scale, evaluate_loss, height_weights, load_arrays, set_determinism  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prep")
    ap.add_argument("--n-train", type=int, default=1220)
    ap.add_argument("--n-val", type=int, default=160)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--deterministic", type=int, default=1)
    a = ap.parse_args()
    cfg = C.load_config(HERE / "config.yaml")
    tc = cfg["train"]
    ids = sorted(p.stem for p in (Path(a.prep) / "cases").glob("*.npz"))
    X, F, Y, _ = load_arrays(Path(a.prep), ids)
    set_determinism(1)
    if not a.deterministic:
        torch.use_deterministic_algorithms(False)
        torch.backends.cudnn.deterministic = False
        torch.backends.cudnn.benchmark = True
    dev = torch.device("cuda")
    scale = torch.from_numpy(channel_scale(Y)).to(dev)
    hw = torch.from_numpy(height_weights(tc)).to(dev)
    model = M.build(tc["model"], X.shape[1], F.shape[1], Y.shape[1]).to(dev)
    model.out_scale.copy_(scale)
    opt = torch.optim.AdamW(model.parameters(), lr=tc["lr"], weight_decay=tc["weight_decay"])
    ema = EMA(model, tc["ema_decay"])
    bs = tc["batch"]
    n = a.n_train
    vi = np.arange(a.n_val) % len(X)
    Xv, Fv, Yv = X[vi], F[vi], Y[vi]
    res = dict(n_src=len(X), n_train=n, n_val=a.n_val, batch=bs, deterministic=bool(a.deterministic),
               n_params=M.n_params(model), epochs=[])
    with C.GpuLock():
        for ep in range(a.epochs):
            perm = np.random.default_rng([1, ep]).permutation(n) % len(X)
            torch.cuda.synchronize()
            t0 = time.perf_counter()
            for st in range(n // bs):
                idx = perm[st * bs:(st + 1) * bs]
                xb = torch.from_numpy(X[idx]).to(dev); fb = torch.from_numpy(F[idx]).to(dev)
                yb = torch.from_numpy(Y[idx]).to(dev).float()
                with torch.autocast("cuda", dtype=torch.bfloat16):
                    p = model(xb, fb)
                loss = (((p.float() - yb) / scale[None, :, None, None]) ** 2 * hw[None, :, None, None]).mean()
                opt.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), tc["grad_clip"])
                opt.step()
                ema.update(model)
            torch.cuda.synchronize()
            t_tr = time.perf_counter() - t0
            t1 = time.perf_counter()
            evaluate_loss(model, Xv, Fv, Yv, scale, hw, bs, dev)
            torch.cuda.synchronize()
            t_val = time.perf_counter() - t1
            res["epochs"].append(dict(t_train_s=t_tr, t_val_s=t_val, loss=float(loss)))
            print(res["epochs"][-1], flush=True)
    e = res["epochs"][1:] or res["epochs"]
    t_ep = float(np.median([x["t_train_s"] + x["t_val_s"] for x in e]))
    res["t_epoch_s"] = t_ep
    res["t_per_sample_ms"] = t_ep / n * 1000
    res["gpu_mem_max_gb"] = torch.cuda.max_memory_allocated() / 1e9
    out = HERE / "tests" / "out"
    out.mkdir(exist_ok=True)
    name = "bench_epoch.json" if a.deterministic else "bench_epoch_nondet.json"
    C.atomic_write_json(out / name, res)
    print(json.dumps({k: v for k, v in res.items() if k != "epochs"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
