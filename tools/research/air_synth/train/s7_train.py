"""S7 (SY-11): обучение сети P2 без изменений (pilotnn.model.UNetFiLM) на кеше S5 v4, ускоренный цикл.

Рецепт — как P2 (README пилота, «Сеть и обучение»): AdamW lr 2e-3, wd 1e-4, betas (0,9; 0,99), прогрев 3 % + косинус до 2 % от lr,
bf16, EMA 0,999 (с прогревом (1+n)/(10+n)), клип градиента 1, потери — MSE по каналам / rms канала с весом 2 на высотах ≤ 100 м,
отражение поперёк ветра p = 1/2, batch 8, ≤ 150 эпох, терпение 30 эпох по проверке на EMA-весах.
Ускорение (на результат не влияет): Y — в закреплённой памяти, подготовка батчей в потоке, копия на GPU асинхронно; X, F — на GPU;
сумма потерь копится на GPU и читается раз в `log_every` шагов; EMA — torch._foreach_*; fused AdamW; без `.item()` на шаге.

Режимы:
  val   — обучение на group train (минус 10 % мест по хешу — проверка) с ранней остановкой; пишет ckpt/best.pt (EMA лучшей эпохи), снимки ckpt/ep{NNN}.pt каждые 5 эпох (EMA, без перезаписи), history.json;
  final — обучение на всех группах без проверки `--max-epochs` эпох (= лучшая эпоха режима val) по расписанию в `--schedule-epochs` (150) эпох;
          пишет ckpt/final.pt (EMA) и снимки каждые 5 эпох (ONNX — из снимка/final лучшей эпохи).
Продолжение после прерывания — тем же вызовом (last.pt: веса, AdamW, EMA, позиция; порядок данных — от (зерно, эпоха)).
"""
from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import argparse  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import queue  # noqa: E402
import sys  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s7_data as D  # noqa: E402
from pilotnn import model as M  # noqa: E402
from pilotnn import train as PT  # noqa: E402  (channel_scale, height_weights, lr_at — функции P2, без правок)
from pilotnn.prep import REFLECT_FILM_SIGN, REFLECT_MAP_SIGN, REFLECT_OUT_SIGN  # noqa: E402

# гиперпараметры P2 (air_nn_pilot/config.yaml → train)
P2 = dict(seed=1, model=dict(channels=[32, 64, 96, 128, 192], emb=128), batch=8, lr=2.0e-3, weight_decay=1.0e-4, warmup_frac=0.03,
          max_epochs=150, patience=30, ema_decay=0.999, grad_clip=1.0, reflect=True, near_ground_weight=2.0, near_ground_max_m=100)


def set_determinism(seed, strict=True):
    torch.manual_seed(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = strict
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.use_deterministic_algorithms(strict)


class Prefetch:
    """Поток: по списку батчей (индексы) собирает Y из кеша в закреплённые буферы; `get()` отдаёт (шаг, буфер Y, событие буфера)."""

    def __init__(self, cache, batches, bs, depth=3, pin=True):
        self.cache, self.batches = cache, batches
        n_buf = depth + 3
        self.bufs = [torch.empty((bs, 91, D.NY, D.NX), dtype=torch.float16, pin_memory=pin and torch.cuda.is_available()) for _ in range(n_buf)]
        self.events = [None] * n_buf
        self.q = queue.Queue(maxsize=depth)
        self.stop = False
        self.err = None
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        try:
            for i, idx in enumerate(self.batches):
                if self.stop:
                    return
                b = i % len(self.bufs)
                if self.events[b] is not None:
                    self.events[b].synchronize()            # копия прошлого содержимого буфера на GPU завершена
                self.cache.gather_y(idx, out=self.bufs[b].numpy()[:len(idx)])
                self.q.put((b, len(idx)))
            self.q.put(None)
        except Exception as e:  # noqa: BLE001
            self.err = e
            self.q.put(None)

    def get(self):
        it = self.q.get()
        if it is None:
            if self.err:
                raise self.err
            return None
        b, n = it
        return b, self.bufs[b][:n]

    def release(self, b, ev):
        self.events[b] = ev

    def close(self):
        self.stop = True
        try:
            while True:
                self.q.get_nowait()
        except queue.Empty:
            pass


class Trainer:
    def __init__(self, cache, train_idx, val_idx, run_dir, hp=None, device="cuda", strict=True, scale=None, log=print):
        self.hp = dict(P2, **(hp or {}))
        self.cache, self.run, self.dev, self.log = cache, Path(run_dir), torch.device(device), log
        self.run.mkdir(parents=True, exist_ok=True)
        self.tr = np.asarray(train_idx)
        self.va = np.asarray(val_idx) if val_idx is not None and len(val_idx) else None
        hp = self.hp
        set_determinism(hp["seed"], strict)
        t0 = time.time()
        self.Xt, self.Ft = [torch.from_numpy(a).to(self.dev) for a in cache.load_xf(self.tr)]
        if self.va is not None:
            self.Xv, self.Fv = [torch.from_numpy(a).to(self.dev) for a in cache.load_xf(self.va)]
            self.Yv = torch.from_numpy(cache.gather_y(self.va)).to(self.dev)
        log(f"данные: train {len(self.tr)}, проверка {0 if self.va is None else len(self.va)}, загрузка X,F,Yпроверки {time.time() - t0:.0f} с")
        if scale is None:
            sp = self.run / "scale.json"
            if sp.exists():
                scale = np.asarray(json.loads(sp.read_text()), np.float32)
            else:
                t0 = time.time()
                scale = PT.channel_scale(_YView(cache, self.tr))
                sp.write_text(json.dumps(scale.tolist()))
                log(f"масштабы каналов: {time.time() - t0:.0f} с")
        self.scale_np = np.asarray(scale, np.float32)
        self.scale = torch.from_numpy(self.scale_np).to(self.dev)
        self.hw = torch.from_numpy(PT.height_weights(hp)).to(self.dev)
        self.model = M.build(hp["model"], 9, 18, 91).to(self.dev)
        self.model.out_scale.copy_(self.scale)
        self.params = [p for p in self.model.parameters()]
        self.opt = torch.optim.AdamW(self.params, lr=hp["lr"], weight_decay=hp["weight_decay"], betas=(0.9, 0.99),
                                     fused=(self.dev.type == "cuda"))
        self.ema_model = M.build(hp["model"], 9, 18, 91).to(self.dev)
        self.ema_model.load_state_dict(self.model.state_dict())
        self.ema_params = [p for p in self.ema_model.parameters()]
        for p in self.ema_params:
            p.requires_grad_(False)
        self.ema_n = 0
        self.sx = torch.from_numpy(np.ascontiguousarray(REFLECT_MAP_SIGN)).to(self.dev)[None, :, None, None]
        self.sf = torch.from_numpy(REFLECT_FILM_SIGN).to(self.dev)[None, :]
        self.sy = torch.from_numpy(np.ascontiguousarray(REFLECT_OUT_SIGN)).to(self.dev)[None, :, None, None]
        self.bs = int(hp["batch"])
        self.spe = max(1, len(self.tr) // self.bs)
        self.gstep = 0
        self.epoch = 0
        self.snap_every = int(self.hp.get("snap_every", 5))
        self.hist, self.best, self.bad = [], dict(val=math.inf, epoch=-1, gstep=0), 0

    # --- состояние
    def ema_update(self):
        self.ema_n += 1
        d = min(self.hp["ema_decay"], (1 + self.ema_n) / (10 + self.ema_n))
        torch._foreach_mul_(self.ema_params, d)
        torch._foreach_add_(self.ema_params, [p.detach() for p in self.params], alpha=1 - d)

    def state(self):
        return dict(model=self.model.state_dict(), opt=self.opt.state_dict(), ema=self.ema_model.state_dict(), ema_n=self.ema_n,
                    gstep=self.gstep, epoch=self.epoch, hist=self.hist, best=self.best, bad=self.bad)

    def save(self, path, obj):
        tmp = Path(str(path) + f".tmp{os.getpid()}")
        with open(tmp, "wb") as f:
            torch.save(obj, f); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)

    def load(self, path):
        ck = torch.load(path, map_location=self.dev, weights_only=False)
        self.model.load_state_dict(ck["model"]); self.opt.load_state_dict(ck["opt"]); self.ema_model.load_state_dict(ck["ema"])
        self.ema_n, self.gstep, self.epoch = ck["ema_n"], ck["gstep"], ck["epoch"]
        self.hist, self.best, self.bad = ck["hist"], ck["best"], ck["bad"]

    # --- шаг
    def loss_fn(self, p, y):
        return (((p.float() - y) / self.scale[None, :, None, None]) ** 2 * self.hw[None, :, None, None]).mean()

    @torch.no_grad()
    def val_loss(self, bs=16):
        m = self.ema_model.eval()
        tot = torch.zeros((), device=self.dev)
        for i in range(0, len(self.Xv), bs):
            with torch.autocast(self.dev.type, dtype=torch.bfloat16):
                p = m(self.Xv[i:i + bs], self.Fv[i:i + bs])
            e = ((p.float() - self.Yv[i:i + bs].float()) / self.scale[None, :, None, None]) ** 2 * self.hw[None, :, None, None]
            tot += e.mean(dim=(1, 2, 3)).sum()
        return float(tot) / len(self.Xv)

    def epoch_batches(self, epoch, first_step=0):
        hp = self.hp
        perm = np.random.default_rng([hp["seed"], epoch]).permutation(len(self.tr))
        flip = (np.random.default_rng([hp["seed"], epoch, 4]).random(len(self.tr)) < 0.5) if hp["reflect"] else np.zeros(len(self.tr), bool)
        for st in range(first_step, self.spe):
            yield st, np.sort(perm[st * self.bs:(st + 1) * self.bs]), flip

    def run_steps(self, stop_steps=None, schedule_steps=None, max_epochs=None, ckpt_every_min=10.0, log_every=200, bench_steps=0):
        """Основной цикл. stop_steps — остановиться после стольких шагов (режим final / bench); schedule_steps — длина расписания lr."""
        hp = self.hp
        E = int(max_epochs or hp["max_epochs"])
        total = int(schedule_steps or E * self.spe)
        warm = max(1, int(hp["warmup_frac"] * total))
        (self.run / "ckpt").mkdir(exist_ok=True)
        last = self.run / "ckpt" / "last.pt"
        if last.exists() and not bench_steps:
            self.load(last)
            self.log(f"продолжение: эпоха {self.epoch}, шаг {self.gstep}")
        t_ck = time.time()
        stopped = False
        loss_acc = torch.zeros((), device=self.dev)
        n_acc, t_log = 0, time.time()
        t_epoch0 = time.time()
        self.model.train()
        while self.epoch < E and not stopped:
            first = self.gstep - self.epoch * self.spe if self.gstep > self.epoch * self.spe else 0
            batches = list(self.epoch_batches(self.epoch, first))
            pf = Prefetch(self.cache, [self.tr[b[1]] for b in batches], self.bs)
            try:
                for st, idx, flip in batches:
                    it = pf.get()
                    if it is None:
                        raise RuntimeError("поток данных прервался")
                    b, ybuf = it
                    yb = ybuf.to(self.dev, non_blocking=True).float()
                    ev = torch.cuda.Event() if self.dev.type == "cuda" else None
                    if ev is not None:
                        ev.record()
                    pf.release(b, ev) if ev is not None else None
                    pos = torch.from_numpy(idx).to(self.dev)          # idx — позиции в массивах обучающего набора (как в P2)
                    xb, fb = self.Xt[pos], self.Ft[pos]
                    fm = torch.from_numpy(flip[idx]).to(self.dev)
                    if hp["reflect"]:
                        xb = torch.where(fm[:, None, None, None], xb.flip(-2) * self.sx, xb)
                        fb = torch.where(fm[:, None], fb * self.sf, fb)
                        yb = torch.where(fm[:, None, None, None], yb.flip(-2) * self.sy, yb)
                    lr = PT.lr_at(self.gstep, total, warm, hp["lr"])
                    for g in self.opt.param_groups:
                        g["lr"] = lr
                    with torch.autocast(self.dev.type, dtype=torch.bfloat16):
                        p = self.model(xb, fb)
                    loss = self.loss_fn(p, yb)
                    self.opt.zero_grad(set_to_none=True)
                    loss.backward()
                    torch.nn.utils.clip_grad_norm_(self.params, hp["grad_clip"])
                    self.opt.step()
                    self.ema_update()
                    self.gstep += 1
                    loss_acc += loss.detach(); n_acc += 1
                    if n_acc >= log_every:
                        v = float(loss_acc) / n_acc
                        dt = time.time() - t_log
                        self.log(f"шаг {self.gstep} (эпоха {self.epoch + 1}): loss {v:.5f}, {dt / n_acc * 1000:.1f} мс/шаг")
                        self.step_ms = dt / n_acc * 1000
                        loss_acc.zero_(); n_acc = 0; t_log = time.time()
                    if bench_steps and self.gstep >= bench_steps:
                        if self.dev.type == "cuda":
                            torch.cuda.synchronize()
                        return
                    if stop_steps and self.gstep >= stop_steps:
                        stopped = True
                        break
                    if time.time() - t_ck > 60 * ckpt_every_min:
                        self.save(last, dict(self.state(), epoch=self.epoch)); t_ck = time.time()
            finally:
                pf.close()
            if stopped:
                break
            # конец эпохи
            tl = float(loss_acc) / max(n_acc, 1)
            loss_acc.zero_(); n_acc = 0
            rec = dict(epoch=self.epoch, gstep=self.gstep, train=tl, lr=PT.lr_at(self.gstep - 1, total, warm, hp["lr"]),
                       t_epoch_s=round(time.time() - t_epoch0, 2))
            if self.va is not None:
                vl = self.val_loss()
                rec["val"] = vl
                if vl < self.best["val"]:
                    self.best = dict(val=vl, epoch=self.epoch, gstep=self.gstep)
                    self.bad = 0
                    self.save(self.run / "ckpt" / "best.pt", dict(model=self.ema_model.state_dict(), epoch=self.epoch, val=vl, gstep=self.gstep,
                                                         scale=self.scale_np))
                else:
                    self.bad += 1
                self.log(f"эпоха {self.epoch + 1}/{E}: train {tl:.5f}, val {vl:.5f} (лучшая {self.best['val']:.5f} @ {self.best['epoch'] + 1}), "
                         f"{rec['t_epoch_s']:.0f} с")
                if self.bad >= hp["patience"]:
                    self.log(f"ранняя остановка: {self.bad} эпох без улучшения")
                    stopped = True
            else:
                self.log(f"эпоха {self.epoch + 1}/{E}: train {tl:.5f}, {rec['t_epoch_s']:.0f} с")
            self.hist.append(rec)
            self.epoch += 1
            if self.epoch % self.snap_every == 0:          # периодический снимок EMA-весов (требование пользователя 05.10), без перезаписи
                self.save(self.run / "ckpt" / f"ep{self.epoch:03d}.pt", dict(model=self.ema_model.state_dict(), epoch=self.epoch - 1, gstep=self.gstep,
                                                                           val=rec.get("val"), train=rec["train"], scale=self.scale_np))
            t_epoch0 = time.time()
            self.save(last, self.state()); t_ck = time.time()
            (self.run / "history.json").write_text(json.dumps(self.hist))
        return dict(spe=self.spe, total=total, gstep=self.gstep, best=self.best)


class _YView:
    """Вид Y кеша по индексам для PT.channel_scale (len, shape, срез по кускам)."""

    def __init__(self, cache, idx):
        self.cache, self.idx = cache, np.asarray(idx)
        self.shape = (len(self.idx), 91, D.NY, D.NX)

    def __len__(self):
        return len(self.idx)

    def __getitem__(self, sl):
        return self.cache.gather_y(self.idx[sl])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=("val", "final"), required=True)
    ap.add_argument("--cache", nargs="+", required=True, help="каталоги кеша наборов (train-набор; в final — и holdout, и game)")
    ap.add_argument("--run", required=True, help="каталог прогона ($AIR_SYNTH_DATA/train/<имя>)")
    ap.add_argument("--stop-steps", type=int, default=0)
    ap.add_argument("--schedule-steps", type=int, default=0)
    ap.add_argument("--bench", type=int, default=0, help="только N шагов (оценка времени), без записи чекпойнтов")
    ap.add_argument("--max-epochs", type=int, default=0, help="final: число эпох = лучшая эпоха первого обучения (1-based)")
    ap.add_argument("--schedule-epochs", type=int, default=0, help="длина расписания lr в эпохах (final: 150, как у первого обучения)")
    ap.add_argument("--snap-every", type=int, default=5)
    ap.add_argument("--val-frac", type=float, default=0.10)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--fast", action="store_true", help="без строгой детерминированности (замер)")
    a = ap.parse_args()
    cache = D.Cache(a.cache)
    if a.mode == "val":
        idx = cache.select(0)
        vm = D.split_val(cache.meta["relief_id"][idx], a.val_frac, seed=1)
        tr, va = idx[~vm], idx[vm]
    else:
        tr, va = cache.select([0, 1, 2]), None
    if a.bench:
        # замер цикла: обучающие данные — первые 3000 случаев (хватает на 200 шагов), масштабы по ним же
        tr = tr[:max(a.bench * 8, 64)]
    T = Trainer(cache, tr, va, a.run, hp=dict(snap_every=a.snap_every), device=a.device, strict=not a.fast)
    t0 = time.time()
    res = T.run_steps(stop_steps=a.stop_steps or None, schedule_steps=(a.schedule_epochs * T.spe) if a.schedule_epochs else (a.schedule_steps or None), max_epochs=a.max_epochs or None,
                      bench_steps=a.bench)
    dt = time.time() - t0
    if a.bench:
        print(json.dumps(dict(bench_steps=a.bench, seconds=dt, ms_per_step=T.__dict__.get("step_ms"), spe_full=len(cache.select(0)) // 8)))
        return
    run = Path(a.run)
    if a.mode == "final":
        T.save(run / "ckpt" / "final.pt", dict(model=T.ema_model.state_dict(), gstep=T.gstep, scale=T.scale_np))
    info = dict(mode=a.mode, train_seconds=dt, steps=T.gstep, spe=T.spe, n_train=int(len(tr)), n_val=0 if va is None else int(len(va)),
                best=T.best, epochs=len(T.hist), hp=T.hp)
    (run / f"result_{a.mode}.json").write_text(json.dumps(info, indent=1, default=str))
    print(json.dumps(info, default=str))


if __name__ == "__main__":
    main()
