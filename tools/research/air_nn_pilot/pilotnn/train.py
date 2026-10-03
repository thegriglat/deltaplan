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

CODE_FILES = [Path(__file__), Path(M.__file__), Path(__file__).with_name("prep.py"),
              Path(__file__).with_name("prep5.py"), Path(__file__).with_name("base.py")]
NA = len(AGL)
# выход v5 (П2 v5): каналы c·13 + a; c: 0 a_m, 1 sd_m, 2 cd_m, 3 wrel_m, 4 a_h, 5 sd_h, 6 cd_h, 7 wrel_h, 8 θ′
V5_W = ((3 * NA, 4 * NA), (7 * NA, 8 * NA))           # каналы w_rel (m, h)
V5_FLOOR = (0.02, 0.02, 0.02, 0.005, 0.02, 0.02, 0.02, 0.005, 0.05)
DIR_MIN_MS = 0.5                                      # поворот не учитывается при ‖V‖ < 0,5 м/с (П2 v5)


def enc_of(task):
    """Кодировка прогона (П2 v5): inputs/outputs v4|v5, gamma (γ_a, dict(m, h)), каталоги кеша v5."""
    e = dict(task.get("enc") or {})
    return dict(inputs=e.get("inputs", "v4"), outputs=e.get("outputs", "v4"), pack=int(e.get("pack", 0) or 0),
                gamma=e.get("gamma"), prep5_dirs=task.get("prep5_dirs") or [], w_rel_weight=float(e.get("w_rel_weight", 1.0)))


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
    # массивы выделяются сразу целиком и заполняются по случаю: без списка + np.stack (двойной пик ОЗУ)
    X = F = Y = None
    metas = []
    for i, cid in enumerate(ids):
        with np.load(case_file(prep, cid)) as z:
            if X is None:
                X = np.empty((len(ids),) + z["X"].shape, z["X"].dtype)
                F = np.empty((len(ids),) + z["F"].shape, z["F"].dtype)
                if with_y:
                    Y = np.empty((len(ids),) + z["Y"].shape, z["Y"].dtype)
            X[i] = z["X"]; F[i] = z["F"]
            if with_y:
                Y[i] = z["Y"]
            metas.append(json.loads(str(z["meta"])))
    return X, F, Y, metas


def load_arrays_enc(prep, enc, ids, with_y=True):
    """Как `load_arrays`, но по кодировке: вход v5 = карты v4 (кеш v4) + карты 9–26 (кеш v5); выход v5 — цель v5
    (117, f16) с w_rel = Y5[w] − γ_a·K, и вес скорости W = max(‖V‖, ε)/S (26, f16). → X, F, Y, W | None, metas.
    Массивы выделяются целиком и заполняются по случаю (без двойного пика ОЗУ)."""
    if enc["inputs"] == "v4" and enc["outputs"] == "v4":
        X, F, Y, metas = load_arrays(prep, ids, with_y)
        return X, F, Y, None, metas
    from . import prep5 as P5
    n = len(ids)
    nx_ = 9 + (P5.N_XE if enc["inputs"] == "v5" else 0)
    v5o = enc["outputs"] == "v5"
    X = F = Y = W = None
    metas = []
    if v5o and with_y:
        from .base import gamma_of
        gm = gamma_of(enc["gamma"]).astype(np.float32)            # (2, 13, 1, 1)
    for i, cid in enumerate(ids):
        with np.load(case_file(prep, cid)) as z:
            if X is None:
                X = np.empty((n, nx_) + z["X"].shape[1:], np.float32)
                F = np.empty((n,) + z["F"].shape, z["F"].dtype)
            X[i, :9] = z["X"]; F[i] = z["F"]
            if with_y and not v5o:
                if Y is None:
                    Y = np.empty((n,) + z["Y"].shape, z["Y"].dtype)
                Y[i] = z["Y"]
            metas.append(json.loads(str(z["meta"])))
        if nx_ > 9 or (v5o and with_y):
            with np.load(P5.case_file5(enc["prep5_dirs"], cid)) as z5:
                if nx_ > 9:
                    X[i, 9:] = z5["Xe"]
                if v5o and with_y:
                    if Y is None:
                        Y = np.empty((n,) + z5["Y5"].shape, np.float16)
                        W = np.empty((n,) + z5["V"].shape, np.float16)
                    Y[i] = z5["Y5"]
                    K = z5["K"].astype(np.float32)
                    for g, (a, b) in enumerate(V5_W):
                        Y[i, a:b] = (z5["Y5"][a:b].astype(np.float32) - gm[g] * K[g * NA:(g + 1) * NA]).astype(np.float16)
                    W[i] = z5["V"]
    return X, F, Y, W, metas


def v5_norms(Y, W):
    """Нормировка ошибки v5 по обучению: σ²_V(g, a) = средн. (‖V‖/S)²·(a² + sin²δ + (1 − cos δ)²) — квадрат
    «вектора отклонения от базы» (/S), пол 2·0,02²; → (2, 13) f32."""
    acc = np.zeros((2, NA), np.float64)
    for i in range(0, len(Y), 32):
        y = Y[i:i + 32].astype(np.float32).reshape(-1, 9, NA, *Y.shape[-2:])
        w2 = W[i:i + 32].astype(np.float32).reshape(-1, 2, NA, *Y.shape[-2:]) ** 2
        for g, c0 in ((0, 0), (1, 4)):
            q = w2[:, g] * (y[:, c0] ** 2 + y[:, c0 + 1] ** 2 + (1 - y[:, c0 + 2]) ** 2)
            acc[g] += q.sum(axis=(0, 2, 3), dtype=np.float64)
    s2 = acc / (len(Y) * Y.shape[-1] * Y.shape[-2])
    return np.maximum(s2, 2 * 0.02 ** 2).astype(np.float32)


def channel_scale(Y):
    """std каждого из 91 (v4) или 117 (v5) каналов по обучению (масштаб потерь и выхода), не меньше пола канала."""
    acc = np.zeros(Y.shape[1], np.float64)   # rms по кускам: целиком Y во f32 и его квадрат не влезают в ОЗУ
    for i in range(0, len(Y), 64):
        y = Y[i:i + 64].astype(np.float32)
        acc += np.einsum("nchw,nchw->c", y, y, dtype=np.float64)
    s = np.sqrt(acc / (len(Y) * Y.shape[2] * Y.shape[3]) + 1e-12).astype(np.float32)   # rms (отклонение от притока, центр 0)
    fl = [0.02, 0.02, 0.005, 0.02, 0.02, 0.005, 0.05] if Y.shape[1] == N_CH * NA else V5_FLOOR
    floor = np.repeat(fl, len(AGL)).astype(np.float32)
    return np.maximum(s, floor)


def loss_v5(p, y, wv, S, scale, sv2, hw13, w_rel_weight=1.0):
    """Ошибка выхода v5 (П2 v5, выбор NN-P12): разгон и поворот — с весом скорости, ≈ квадрат ошибки вектора
    (‖V‖/S)²·(Δa² + Δsin²δ + Δcos²δ) / (σ²_V/2) (считается как 2 канала, как u∥ и u⊥ в v4); поворот не считается
    при ‖V‖ < 0,5 м/с; w_rel и θ′ — по rms канала (как v4), w_rel × w_rel_weight. Среднее по 7 «каналам» и высотам
    с весом высоты (как v4: 91 канал = 7 × 13). p, y (B,117,H,W); wv (B,26,H,W) = max(‖V‖,ε)/S; S (B,)."""
    B_, _, Hh, Ww = p.shape
    d = (p - y).view(B_, 9, NA, Hh, Ww)
    wv = wv.view(B_, 2, NA, Hh, Ww)
    sc = scale.view(9, NA)
    tot = 0.0
    for g, c0 in ((0, 0), (1, 4)):
        v = wv[:, g]
        m = (v * S[:, None, None, None] >= DIR_MIN_MS).to(d.dtype)
        th = v * v * (d[:, c0] ** 2 + m * (d[:, c0 + 1] ** 2 + d[:, c0 + 2] ** 2)) / (0.5 * sv2[g])[None, :, None, None]
        tw = (d[:, c0 + 3] / sc[c0 + 3][None, :, None, None]) ** 2 * w_rel_weight
        tot = tot + th + tw
    tot = tot + (d[:, 8] / sc[8][None, :, None, None]) ** 2
    return tot / 7.0 * hw13[None, :, None, None]


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
def evaluate_loss(model, X, F, Y, scale, hw, bs, dev, lossf=None, W=None):
    model.eval()
    tot, n = 0.0, 0
    for i in range(0, len(X), bs):
        xb = torch.from_numpy(X[i:i + bs]).to(dev)
        fb = torch.from_numpy(F[i:i + bs]).to(dev)
        yb = torch.from_numpy(Y[i:i + bs]).to(dev).float()
        with torch.autocast("cuda", dtype=torch.bfloat16):
            p = model(xb, fb)
        if lossf is None:
            e = ((p.float() - yb) / scale[None, :, None, None]) ** 2 * hw[None, :, None, None]
        else:
            e = lossf(p.float(), yb, torch.from_numpy(W[i:i + bs]).to(dev).float(), fb)
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
    enc = enc_of(task)
    Xt, Ft, Yt, Wt, _ = load_arrays_enc(prep, enc, task["train_ids"])
    Xv, Fv, Yv, Wv, _ = load_arrays_enc(prep, enc, task["val_ids"])
    print(f"данные: обучение {len(Xt)}, проверка {len(Xv)} случаев, вход {Xt.shape[1]} карт, выход {Yt.shape[1]} каналов, "
          f"ОЗУ массивов {(Xt.nbytes + Yt.nbytes + (Wt.nbytes if Wt is not None else 0) + Xv.nbytes + Yv.nbytes + (Wv.nbytes if Wv is not None else 0)) / 2**30:.1f} ГиБ, "
          f"загрузка {time.time() - t0:.1f} с", flush=True)
    scale_np = channel_scale(Yt)
    scale = torch.from_numpy(scale_np).to(dev)
    hw = torch.from_numpy(height_weights(tc)).to(dev)
    v5o = enc["outputs"] == "v5"
    lossf = None
    if v5o:
        sv2_np = v5_norms(Yt, Wt)
        C.atomic_write_json(run / "v5_norms.json", dict(sigma_v2=sv2_np.tolist(), w_rel_weight=enc["w_rel_weight"]))
        sv2 = torch.from_numpy(sv2_np).to(dev)
        hw13 = hw[:NA]

        def lossf(p, y, wv, fb):
            S = torch.clamp(fb[:, 0] * 10.0, min=1.0)              # FiLM 0 = U10/10; S = max(U10, 1 м/с)
            return loss_v5(p, y, wv, S, scale, sv2, hw13, enc["w_rel_weight"])
    if enc["inputs"] == "v5" or v5o:
        from . import base as B
        from . import maps5 as M5
        rms = M5.REFLECT_MAP_SIGN_V5 if enc["inputs"] == "v5" else REFLECT_MAP_SIGN
        ros = B.REFLECT_OUT_SIGN_V5.astype(np.float32) if v5o else REFLECT_OUT_SIGN
    else:
        rms, ros = REFLECT_MAP_SIGN, REFLECT_OUT_SIGN
    model = M.build(tc["model"], Xt.shape[1], Ft.shape[1], Yt.shape[1]).to(dev)
    model.out_scale.copy_(scale)
    opt = torch.optim.AdamW(model.parameters(), lr=tc["lr"], weight_decay=tc["weight_decay"], betas=(0.9, 0.99))
    ema = EMA(model, tc["ema_decay"])
    bs = int(tc["batch"])
    n = len(Xt)
    reflect_on = bool(tc.get("reflect", False))
    sx = torch.from_numpy(np.ascontiguousarray(rms, np.float32)).to(dev)[None, :, None, None]
    sf = torch.from_numpy(REFLECT_FILM_SIGN).to(dev)[None, :]
    sy = torch.from_numpy(np.ascontiguousarray(ros, np.float32)).to(dev)[None, :, None, None]
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
                wb = torch.from_numpy(Wt[idx]).to(dev).float() if v5o else None
                fm = flip[idx]
                if fm.any():
                    m = torch.from_numpy(fm).to(dev)
                    xb = torch.where(m[:, None, None, None], xb.flip(-2) * sx, xb)
                    fb = torch.where(m[:, None], fb * sf, fb)
                    yb = torch.where(m[:, None, None, None], yb.flip(-2) * sy, yb)
                    if v5o:
                        wb = torch.where(m[:, None, None, None], wb.flip(-2), wb)
                for g in opt.param_groups:
                    g["lr"] = lr_at(gstep, total_steps, warm, tc["lr"])
                with torch.autocast("cuda", dtype=torch.bfloat16):
                    p = model(xb, fb)
                if v5o:
                    loss = lossf(p.float(), yb, wb, fb).mean()
                else:
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
            vl = evaluate_loss(model, Xv, Fv, Yv, scale, hw, bs, dev, lossf, Wv)
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
