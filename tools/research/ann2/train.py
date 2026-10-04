"""AN-2: обучение сети ann2 (A2). Прогон — `$AIR_NN_DATA/ann2/runs/<имя>/`: config.json, model.pt (state_dict + config),
train_log.csv (шаг, потеря обучения, nll, дивергенция, потеря проверки, шаг lr, время), ckpt.pt (точка сохранения: модель,
EMA, оптимизатор, шаг — продолжение после прерывания тем же `--run`; `--fresh` — с нуля).
Пример пробы:  train.py --smoke --steps 60 --run an2_smoke   (печатает `loss_ratio <x>` = средняя потеря последних 10
шагов / первых 10).  Полное обучение — AN-3: `train.py --run <имя> --steps N --batch 16` (весь набор обучения, ~8 ГБ ОЗУ).
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import math
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import torch

import data as D
import losses as L
import regime as RG
import model as M


def git_head():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=Path(__file__).parent, capture_output=True,
                              text=True).stdout.strip()
    except Exception:
        return ""


def lr_at(step, total, warm, base, final=0.02):
    if step < warm:
        return base * (step + 1) / warm
    p = (step - warm) / max(1, total - warm)
    return base * (final + (1 - final) * 0.5 * (1 + math.cos(math.pi * min(p, 1.0))))


class Ema:
    def __init__(self, model, decay):
        self.m, self.decay, self.n = copy.deepcopy(model).eval(), decay, 0
        for p in self.m.parameters():
            p.requires_grad_(False)

    @torch.no_grad()
    def update(self, model):
        self.n += 1
        d = min(self.decay, (1 + self.n) / (10 + self.n))
        for e, p in zip(self.m.state_dict().values(), model.state_dict().values()):
            if e.dtype.is_floating_point:
                e.mul_(d).add_(p.detach(), alpha=1 - d)
            else:
                e.copy_(p)


def pick_ids(split, args):
    rng = np.random.default_rng(1)          # выбор подмножеств — не зависит от зерна обучения (одинаковая проверка у проб)
    tr, va = list(split["train_ids"]), list(split["val_ids"])
    # A1 v2: проверка — всегда механические случаи; обучение — механические (--regime mech) или все (проба «что даёт режим»)
    va = [i for i in va if RG.regime(i) == "mech"]
    if args.regime == "mech":
        tr = [i for i in tr if RG.regime(i) == "mech"]
    if args.max_train and args.max_train < len(tr):
        tr = sorted(rng.choice(tr, args.max_train, replace=False).tolist())
    if args.n_val < len(va):
        va = sorted(rng.choice(va, args.n_val, replace=False).tolist())
    return tr, va


def loss_fn(model, b, args, amp):
    B, K = b["eta"].shape[:2]
    Kd = b["eta_div"].shape[1]
    H, W = b["eta"].shape[-2:]
    with torch.autocast("cuda", dtype=torch.bfloat16, enabled=amp):
        Fm, c = model.features(b["maps"], b["scal"], b["prof"])
        ed = b["eta_div"]
        ediv = torch.cat([ed[..., 0], ed[..., 1]], 1)[:, :, None, None].expand(B, 2 * Kd, H, W)
        eta = torch.cat([b["eta"], ediv], 1)
        out = model.decode(Fm, c, b["par"], eta, b["prof"])
    nll, per = L.nll(out[:, :K], b["y"], b["mask"])
    div = L.divergence_penalty(out[:, K:], ed, b["par"]) if args.div_w > 0 else nll.new_zeros(())
    return nll + args.div_w * div, nll, div, per


@torch.no_grad()
def validate(model, vst, args, dev, amp):
    rng = np.random.default_rng(12345)
    tot = []
    for k in range(args.val_batches):
        idx = rng.choice(len(vst), min(args.batch, len(vst)), replace=False)
        b = D.sample_batch(vst, idx, rng, dev, crop=args.crop, K=args.K, Kd=args.Kd, reflect=False)
        tot.append(float(loss_fn(model, b, args, amp)[0]))
    return float(np.mean(tot))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--smoke", action="store_true", help="малое подмножество случаев, быстрый старт, всегда с нуля")
    ap.add_argument("--steps", type=int, default=20000)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--wd", type=float, default=0.05)
    ap.add_argument("--warmup", type=int, default=0, help="шагов разогрева lr (0 — 3 %% шагов, не меньше 10)")
    ap.add_argument("--K", type=int, default=8, help="высот на колонку за шаг")
    ap.add_argument("--Kd", type=int, default=2, help="пар высот для штрафа дивергенции")
    ap.add_argument("--div_w", type=float, default=0.02, help="вес штрафа дивергенции массового потока")
    ap.add_argument("--crop", type=int, default=64)
    ap.add_argument("--ema", type=float, default=0.999)
    ap.add_argument("--amp", type=int, default=1, help="1 — bfloat16 autocast")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max_train", type=int, default=0, help="подмножество случаев обучения (0 — все)")
    ap.add_argument("--n_val", type=int, default=128)
    ap.add_argument("--val_batches", type=int, default=8)
    ap.add_argument("--val_every", type=int, default=500)
    ap.add_argument("--save_every", type=int, default=1000)
    ap.add_argument("--fresh", action="store_true")
    ap.add_argument("--head", default="deeponet", choices=("deeponet", "mlp"), help="голова колонки (A2 v2: deeponet)")
    ap.add_argument("--regime", default="mech", choices=("mech", "all"), help="случаи обучения (A1 v2: mech)")
    ap.add_argument("--fr_old", type=int, default=0, help="1 — N фона 3 К/км (как AN-3) вместо N случая (проба)")
    ap.add_argument("--patience", type=int, default=0, help="остановка, если проверка не улучшалась столько проверок подряд (0 — нет)")
    args = ap.parse_args()
    if args.smoke:
        args.max_train, args.n_val, args.val_batches, args.val_every, args.fresh = args.max_train or 64, 16, 2, 20, True
        args.batch = min(args.batch, 8)
    if args.fr_old:
        os.environ["AN4_OLD_N"] = "1"
    args.warmup = args.warmup or max(10, int(0.03 * args.steps))
    dev = torch.device("cuda")
    run = D.RUNS / args.run
    run.mkdir(parents=True, exist_ok=True)
    split = D.p2_split()
    tr_ids, va_ids = pick_ids(split, args)
    t0 = time.time()
    tst, vst = D.Store(tr_ids), D.Store(va_ids)
    print(f"данные: обучение {len(tst)} случаев, проверка {len(vst)}, загрузка {time.time() - t0:.0f} с", flush=True)
    torch.manual_seed(args.seed)
    model = M.Ann2(head=args.head).to(dev)
    ema = Ema(model, args.ema)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.wd, betas=(0.9, 0.99))
    cfg = dict(vars(args), params=M.count_params(model), split_seed=split["seed"], p2_run=str(D.P2_RUN),
               n_train=len(tst), n_val=len(vst), commit=git_head(), model=f"Ann2(head={args.head})", wsu_thr=RG.WSU_THR, torch=torch.__version__,
               gpu=torch.cuda.get_device_name(0))
    cfg["config_hash"] = hashlib.sha256(json.dumps({k: v for k, v in cfg.items() if k not in ("steps", "commit")},
                                                   sort_keys=True, default=str).encode()).hexdigest()[:12]
    (run / "config.json").write_text(json.dumps(cfg, ensure_ascii=False, indent=1))
    step, t_prev, log_rows = 0, 0.0, []
    best, best_step, bad = float("inf"), 0, 0
    ck = run / "ckpt.pt"
    if ck.exists() and not args.fresh:
        s = torch.load(ck, map_location=dev, weights_only=False)
        if s["config_hash"] != cfg["config_hash"]:
            raise SystemExit("ckpt.pt от другой конфигурации; --fresh — начать заново")
        model.load_state_dict(s["model"]); ema.m.load_state_dict(s["ema"]); ema.n = s["ema_n"]
        opt.load_state_dict(s["opt"]); step, t_prev = s["step"], s["time"]
        best, best_step, bad = s.get("best", best), s.get("best_step", 0), s.get("bad", 0)
        print(f"продолжение с шага {step}", flush=True)
    logf = run / "train_log.csv"
    if not (logf.exists() and step > 0):
        logf.write_text("step,train_loss,nll,div,val_loss,lr,time_s\n")
    amp = bool(args.amp)
    q: queue.Queue = queue.Queue(maxsize=4)
    stop = threading.Event()

    def producer(s0):
        for s in range(s0, args.steps):
            if stop.is_set():
                return
            rng = np.random.default_rng([args.seed, s])
            idx = rng.choice(len(tst), args.batch, replace=len(tst) < args.batch)
            q.put(D.sample_batch(tst, idx, rng, dev, crop=args.crop, K=args.K, Kd=args.Kd))
        q.put(None)

    th = threading.Thread(target=producer, args=(step,), daemon=True)
    th.start()
    losses, t_start = [], time.time()
    def save(final=False):
        st = dict(model=model.state_dict(), ema=ema.m.state_dict(), ema_n=ema.n, opt=opt.state_dict(), step=step,
                  time=t_prev + time.time() - t_start, config_hash=cfg["config_hash"], best=best, best_step=best_step, bad=bad)
        torch.save(st, ck.with_suffix(".tmp")); ck.with_suffix(".tmp").replace(ck)
        torch.save(dict(state_dict=ema.m.state_dict(), config=cfg, step=step), run / "model.pt")
    model.train()
    while step < args.steps:
        b = q.get()
        if b is None:
            break
        lr = lr_at(step, args.steps, args.warmup, args.lr)
        for g in opt.param_groups:
            g["lr"] = lr
        loss, nll, div, per = loss_fn(model, b, args, amp)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); ema.update(model)
        step += 1
        lv = float(loss.detach())
        losses.append(lv)
        vl = ""
        if step % args.val_every == 0 or step == args.steps:
            ema.m.eval(); v = validate(ema.m, vst, args, dev, amp); vl = f"{v:.5f}"
            if v < best:      # A2 v2: лучшая точка по проверке (ранняя остановка) — best.pt рядом с model.pt
                best, best_step, bad = v, step, 0
                torch.save(dict(state_dict=ema.m.state_dict(), config=cfg, step=step, val_loss=v), run / "best.pt")
            else:
                bad += 1
        if vl or step % 10 == 0 or step <= 10:
            with open(logf, "a") as f:
                f.write(f"{step},{lv:.5f},{float(nll):.5f},{float(div):.5f},{vl},{lr:.3e},{t_prev + time.time() - t_start:.1f}\n")
        if step % 50 == 0 or step == args.steps:
            el = time.time() - t_start
            print(f"шаг {step}/{args.steps} потеря {np.mean(losses[-50:]):.4f} nll {float(nll):.4f} div {float(div):.4f} "
                  f"val {vl or '-'} {el / max(1, len(losses)) * 1000:.0f} мс/шаг", flush=True)
        if step % args.save_every == 0 and step < args.steps:
            save()
        if args.patience and vl and bad >= args.patience:
            print(f"ранняя остановка: проверка не улучшалась {bad} проверок; лучший шаг {best_step} ({best:.4f})", flush=True)
            break
    stop.set()
    save(True)
    print(f"best_step {best_step} best_val {best:.4f}")
    el = time.time() - t_start
    print(f"время шага {el / max(1, len(losses)) * 1000:.0f} мс (батч {args.batch}, вырезка {args.crop}², K {args.K}); "
          f"пик памяти GPU {torch.cuda.max_memory_allocated() / 2**30:.2f} ГБ")
    if len(losses) >= 20:
        print(f"loss_ratio {np.mean(losses[-10:]) / np.mean(losses[:10]):.4f}")


if __name__ == "__main__":
    main()
