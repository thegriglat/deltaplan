"""Обучение одной сети (основной или точки кривой): python -m pilotnn.train <каталог прогона>

Каталог содержит task.json (пишет pilot.py: списки случаев, кеш подготовки, раздел train конфига, зерно).
Всё состояние — в каталоге:
  ckpt/last.pt   — чекпойнт для продолжения (веса, AdamW, шаг расписания, EMA, ГСЧ, позиция: эпоха и шаг)
  ckpt/best.pt   — EMA-веса лучшей эпохи по проверке
  history.json   — по строке на эпоху; progress.json — прогресс для pilot.py; manifest.json — complete + хеш входов
Чекпойнт — каждые ckpt_every_min минут и в конце эпохи; запись атомарная (временный файл → fsync → rename).
Повтор команды: complete и тот же хеш → пропуск; иначе — продолжение с last.pt (результат = непрерванному).
Время эпохи (history, manifest) — без ожидания замка GPU.
Детерминированность: torch.use_deterministic_algorithms(True), cuDNN deterministic, порядок данных — перестановка
от (зерно, эпоха), инициализация — от зерна. Замок GPU — кусками ≤ lock_chunk_s, между кусками отпускается.
"""
from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import json  # noqa: E402
import math  # noqa: E402
import random  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

from . import common as C  # noqa: E402
from . import model as M  # noqa: E402
from .prep import AGL, N_CH, REFLECT_FILM_SIGN, REFLECT_MAP_SIGN, REFLECT_OUT_SIGN  # noqa: E402

CODE_FILES = [Path(__file__), Path(M.__file__), Path(__file__).with_name("prep.py")]


def set_determinism(seed):
    random.seed(seed)
    np.random.seed(seed % (2 ** 32))
    torch.manual_seed(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.use_deterministic_algorithms(True)


def case_file(prep, cid):
    """Файл кеша случая: prep — каталог кеша или список каталогов (кеш — по набору; id уникальны между наборами)."""
    dirs = [prep] if isinstance(prep, (str, Path)) else prep
    for d in dirs:
        p = Path(d) / "cases" / f"{cid}.npz"
        if p.exists():
            return p
    raise FileNotFoundError(f"нет кеша подготовки случая {cid} в {list(map(str, dirs))}")


def load_arrays(prep, ids, with_y=True):
    """Кеш подготовки (каталог или список каталогов) → массивы в ОЗУ: X (n,9,96,96) f32, F (n,18) f32,
    Y (n,91,96,96) f16."""
    X, F, Y, metas = [], [], [], []
    for cid in ids:
        with np.load(case_file(prep, cid)) as z:
            X.append(z["X"]); F.append(z["F"])
            if with_y:
                Y.append(z["Y"])
            metas.append(json.loads(str(z["meta"])))
    return np.stack(X), np.stack(F), (np.stack(Y) if with_y else None), metas


def channel_scale(Y):
    """std каждого из 91 каналов по обучению (масштаб потерь и выхода), не меньше пола канала."""
    s = np.sqrt(np.mean(Y.astype(np.float32) ** 2, axis=(0, 2, 3)) + 1e-12)   # rms (отклонение от притока, центр 0)
    floor = np.repeat([0.02, 0.02, 0.005, 0.02, 0.02, 0.005, 0.05], len(AGL)).astype(np.float32)
    return np.maximum(s, floor)


def height_weights(cfg):
    w = np.array([cfg["near_ground_weight"] if a <= cfg["near_ground_max_m"] else 1.0 for a in AGL], np.float32)
    return np.tile(w, N_CH)


class EMA:
    def __init__(self, model, decay):
        self.decay = decay
        self.shadow = {k: v.detach().clone().float() for k, v in model.state_dict().items()}
        self.n = 0

    @torch.no_grad()
    def update(self, model):
        self.n += 1
        d = min(self.decay, (1 + self.n) / (10 + self.n))
        for k, v in model.state_dict().items():
            if v.dtype.is_floating_point:
                self.shadow[k].mul_(d).add_(v.detach().float(), alpha=1 - d)
            else:
                self.shadow[k].copy_(v)

    def state_dict(self):
        return dict(shadow=self.shadow, n=self.n, decay=self.decay)

    def load_state_dict(self, s):
        self.shadow = s["shadow"]; self.n = s["n"]; self.decay = s["decay"]

    def copy_to(self, model):
        model.load_state_dict({k: v.to(model.state_dict()[k].dtype) for k, v in self.shadow.items()})


def lr_at(step, total, warm, base, final_frac=0.02):
    if step < warm:
        return base * (step + 1) / warm
    p = min(1.0, (step - warm) / max(1, total - warm))
    return base * (final_frac + (1 - final_frac) * 0.5 * (1 + math.cos(math.pi * p)))


def rng_state():
    return dict(py=random.getstate(), np=np.random.get_state(), torch=torch.get_rng_state(),
                cuda=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [])


def set_rng_state(s):
    random.setstate(s["py"]); np.random.set_state(s["np"]); torch.set_rng_state(s["torch"])
    if s["cuda"]:
        torch.cuda.set_rng_state_all(s["cuda"])


def save_ckpt(path: Path, obj):
    """Атомарно: временный файл → fsync → rename. PILOT_TEST_CKPT_PAUSE — пауза до rename (тест обрыва при записи)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp{os.getpid()}")
    with open(tmp, "wb") as f:
        torch.save(obj, f)
        f.flush()
        os.fsync(f.fileno())
    pause = float(os.environ.get("PILOT_TEST_CKPT_PAUSE", "0") or 0)
    if pause > 0:
        print(f"CKPT_TMP_WRITTEN {tmp}", flush=True)
        time.sleep(pause)
    os.replace(tmp, path)
    C.fsync_dir(path.parent)


class Progress:
    """progress.json для pilot.py: сделано/всего в эпохах (дробно), подпись."""

    def __init__(self, run: Path, total, label):
        self.p = run / "progress.json"
        self.total = total
        self.label = label
        self.t_last = 0.0

    def put(self, done, extra="", force=False):
        t = time.time()
        if force or t - self.t_last > 1.0:
            self.t_last = t
            C.atomic_write_json(self.p, dict(done=done, total=self.total, unit="эпох", label=self.label, extra=extra, t=t))


@torch.no_grad()
def evaluate_loss(model, X, F, Y, scale, hw, bs, dev):
    model.eval()
    tot, n = 0.0, 0
    for i in range(0, len(X), bs):
        xb = torch.from_numpy(X[i:i + bs]).to(dev)
        fb = torch.from_numpy(F[i:i + bs]).to(dev)
        yb = torch.from_numpy(Y[i:i + bs]).to(dev).float()
        with torch.autocast("cuda", dtype=torch.bfloat16):
            p = model(xb, fb)
        e = ((p.float() - yb) / scale[None, :, None, None]) ** 2 * hw[None, :, None, None]
        tot += float(e.mean(dim=(1, 2, 3)).sum())
        n += len(xb)
    model.train()
    return tot / max(n, 1)


def main(run: Path):
    run = Path(run)
    sig = C.Signals()
    task = json.loads((run / "task.json").read_text())
    tc = task["train"]
    inputs_hash = C.sha(dict(task=task, code=C.code_hash(*CODE_FILES)))
    state = C.step_state(run, inputs_hash)
    if state == "done":
        print(f"обучение {run.name}: уже готово (manifest complete) — пропуск")
        return C.EXIT_OK
    if state == "changed":
        print(f"обучение {run.name}: входы изменились против manifest.json — нужен новый прогон (другое имя)")
        return C.EXIT_ERROR
    C.write_manifest(run, f"обучение сети пилота: {task['label']}", inputs_hash, False, task=task)
    C.clean_tmp(run / "ckpt")
    C.clean_tmp(run)
    seed = int(tc["seed"])
    set_determinism(seed)
    dev = torch.device("cuda")
    prep = task["prep_dirs"]
    t0 = time.time()
    Xt, Ft, Yt, _ = load_arrays(prep, task["train_ids"])
    Xv, Fv, Yv, _ = load_arrays(prep, task["val_ids"])
    print(f"данные: обучение {len(Xt)}, проверка {len(Xv)} случаев, загрузка {time.time() - t0:.1f} с", flush=True)
    scale_np = channel_scale(Yt)
    scale = torch.from_numpy(scale_np).to(dev)
    hw = torch.from_numpy(height_weights(tc)).to(dev)
    model = M.build(tc["model"], Xt.shape[1], Ft.shape[1], Yt.shape[1]).to(dev)
    model.out_scale.copy_(scale)
    opt = torch.optim.AdamW(model.parameters(), lr=tc["lr"], weight_decay=tc["weight_decay"], betas=(0.9, 0.99))
    ema = EMA(model, tc["ema_decay"])
    bs = int(tc["batch"])
    n = len(Xt)
    reflect_on = bool(tc.get("reflect", False))
    sx = torch.from_numpy(REFLECT_MAP_SIGN).to(dev)[None, :, None, None]
    sf = torch.from_numpy(REFLECT_FILM_SIGN).to(dev)[None, :]
    sy = torch.from_numpy(REFLECT_OUT_SIGN).to(dev)[None, :, None, None]
    spe = max(1, n // bs)                                # шагов на эпоху (неполный хвост отбрасывается)
    E = int(tc["max_epochs"])
    total_steps = E * spe
    warm = max(1, int(tc["warmup_frac"] * total_steps))
    hist = []
    best = dict(val=math.inf, epoch=-1)
    bad = 0
    epoch, step0, gstep = 0, 0, 0
    acc = dict(loss=0.0, n=0, t=0.0)          # сумма потерь и время текущей эпохи (переживают продолжение)
    last = run / "ckpt" / "last.pt"
    if last.exists():
        ck = torch.load(last, map_location="cpu", weights_only=False)     # ГСЧ — тензоры CPU; веса/AdamW → GPU ниже
        model.load_state_dict(ck["model"]); opt.load_state_dict(ck["opt"])
        ck["ema"]["shadow"] = {k: v.to(dev) for k, v in ck["ema"]["shadow"].items()}
        ema.load_state_dict(ck["ema"])
        set_rng_state(ck["rng"])
        epoch, step0, gstep = ck["epoch"], ck["step"], ck["gstep"]
        hist, best, bad = ck["hist"], ck["best"], ck["bad"]
        acc = ck["acc"]
        print(f"продолжение с чекпойнта: эпоха {epoch}, шаг {step0}/{spe}", flush=True)
    prog = Progress(run, E, task["label"])
    prog.put(min(epoch + step0 / spe, E), "старт", force=True)
    lock = C.GpuLock(sig)
    t_ck = time.time()
    t_ep_start = [time.time()]
    w_start = [0.0]

    def ep_time():
        """Время эпохи под своим замком: стеночное минус ожидание замка GPU (чужие задачи на общей карте)."""
        now = time.time()
        acc["t"] += now - t_ep_start[0] - (lock.waited - w_start[0])
        t_ep_start[0] = now
        w_start[0] = lock.waited

    def ckpt(ep, st):
        nonlocal t_ck
        ep_time()
        save_ckpt(last, dict(model=model.state_dict(), opt=opt.state_dict(), ema=ema.state_dict(), rng=rng_state(),
                             epoch=ep, step=st, gstep=gstep, hist=hist, best=best, bad=bad, acc=acc))
        t_ck = time.time()

    stopped = False
    try:
        model.train()
        while epoch < E and not stopped:
            perm = np.random.default_rng([seed, epoch]).permutation(n)
            # П2 v4: отражение поперёк ветра с вероятностью 1/2 при каждом показе — от (зерно, эпоха, индекс примера)
            flip = (np.random.default_rng([seed, epoch, 4]).random(n) < 0.5) if reflect_on else np.zeros(n, bool)
            t_ep_start[0] = time.time()
            w_start[0] = lock.waited
            if step0 == 0:
                acc = dict(loss=0.0, n=0, t=0.0)
            for st in range(step0, spe):
                if lock.f is None:
                    prog.put(epoch + st / spe, "ожидание замка GPU", force=True)
                    try:
                        lock.acquire()                    # сигнал во время ожидания → StopRequested ниже
                    except C.StopRequested:
                        pass
                if sig.signum is not None:
                    lock.release()
                    ckpt(epoch, st)
                    sig.check()
                idx = np.sort(perm[st * bs:(st + 1) * bs])
                xb = torch.from_numpy(Xt[idx]).to(dev, non_blocking=True)
                fb = torch.from_numpy(Ft[idx]).to(dev)
                yb = torch.from_numpy(Yt[idx]).to(dev).float()
                fm = flip[idx]
                if fm.any():
                    m = torch.from_numpy(fm).to(dev)
                    xb = torch.where(m[:, None, None, None], xb.flip(-2) * sx, xb)
                    fb = torch.where(m[:, None], fb * sf, fb)
                    yb = torch.where(m[:, None, None, None], yb.flip(-2) * sy, yb)
                for g in opt.param_groups:
                    g["lr"] = lr_at(gstep, total_steps, warm, tc["lr"])
                with torch.autocast("cuda", dtype=torch.bfloat16):
                    p = model(xb, fb)
                loss = (((p.float() - yb) / scale[None, :, None, None]) ** 2 * hw[None, :, None, None]).mean()
                opt.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), tc["grad_clip"])
                opt.step()
                ema.update(model)
                gstep += 1
                acc["loss"] += float(loss.detach()); acc["n"] += 1
                if lock.held_for() > tc["lock_chunk_s"]:
                    lock.release()                          # очередь других GPU-задач проходит здесь
                if time.time() - t_ck > 60 * tc["ckpt_every_min"]:
                    ckpt(epoch, st + 1)
                prog.put(epoch + (st + 1) / spe, f"шаг {st + 1}/{spe}")
            step0 = 0
            # конец эпохи: проверка на EMA-весах
            live = {k: v.clone() for k, v in model.state_dict().items()}
            ema.copy_to(model)
            if lock.f is None:
                try:
                    lock.acquire()
                except C.StopRequested:              # проверка эпохи не начата: продолжение повторит её с конца эпохи
                    model.load_state_dict(live)
                    lock.release()
                    ckpt(epoch, spe)
                    raise
            vl = evaluate_loss(model, Xv, Fv, Yv, scale, hw, bs, dev)
            if vl < best["val"]:
                best = dict(val=vl, epoch=epoch)
                bad = 0
                save_ckpt(run / "ckpt" / "best.pt", dict(model=model.state_dict(), epoch=epoch, val=vl))
            else:
                bad += 1
            model.load_state_dict(live)
            ep_time()
            dt_ep = acc["t"]
            hist.append(dict(epoch=epoch, train=acc["loss"] / max(acc["n"], 1), val=vl,
                             lr=lr_at(gstep - 1, total_steps, warm, tc["lr"]), t_epoch_s=round(dt_ep, 3), steps=acc["n"]))
            print(f"эпоха {epoch + 1}/{E}: обучение {hist[-1]['train']}, проверка {vl:.5f} "
                  f"(лучшая {best['val']:.5f} @ {best['epoch'] + 1}), {dt_ep:.1f} с", flush=True)
            epoch += 1
            if bad >= tc["patience"]:
                print(f"ранняя остановка: {bad} эпох без улучшения", flush=True)
                stopped = True
            ckpt(epoch if not stopped else E, 0)
            prog.put(epoch if not stopped else E, force=True)
        lock.release()
    except C.StopRequested as e:
        lock.release()
        prog.put(epoch + step0 / spe, "прерван", force=True)
        print(f"остановлено по сигналу: состояние в {last}", flush=True)
        return e.code
    C.atomic_write_json(run / "history.json", hist)
    C.atomic_write_json(run / "scale.json", scale_np.tolist())
    pe = [h["t_epoch_s"] for h in hist if h.get("steps") == spe]
    C.write_manifest(run, f"обучение сети пилота: {task['label']}", inputs_hash, True, task=task,
                     n_params=M.n_params(model), best=best, epochs=len(hist), n_train=n, n_val=len(Xv),
                     steps_per_epoch=spe, t_epoch_median_s=float(np.median(pe)) if pe else None,
                     t_per_sample_ms=float(np.median(pe)) / n * 1000 if pe else None,
                     torch=torch.__version__, deterministic=True, gpu=torch.cuda.get_device_name(0),
                     gpu_lock_wait_s=round(lock.waited, 1))
    print(f"готово: лучшая проверка {best['val']:.5f} на эпохе {best['epoch'] + 1}", flush=True)
    return C.EXIT_OK


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
