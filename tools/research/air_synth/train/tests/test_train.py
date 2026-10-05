"""Цикл обучения S7 на синтетическом кеше (CPU, малая сеть): порядок данных, EMA, продолжение, падение потерь."""
import numpy as np
import pytest
import torch

import s7_data as D
import s7_train as T

HP = dict(model=dict(channels=[8, 16, 16, 16, 16], emb=16), batch=4, warmup_frac=0.1)


def make_cache(d, n=12, seed=0):
    d.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    X = rng.normal(size=(n, 9, 96, 96)).astype(np.float32)
    F = rng.normal(size=(n, 18)).astype(np.float32)
    # цель — простая функция входа: сеть должна уметь подгонять
    Y = np.zeros((n, 91, 96, 96), np.float16)
    Y[:, :13] = (0.5 * X[:, :1]).astype(np.float16)
    Y[:, 13:26] = (0.3 * X[:, 4:5]).astype(np.float16)
    fx, ff, fy, fm = D.part_files(d, 0)
    for p, a in ((fx, X), (ff, F), (fy, Y)):
        np.save(p, a)
    z = np.arange(n)
    np.savez(fm, case=z, relief_id=z // 3, cond_id=z % 3, group=np.zeros(n, int), status_m=np.zeros(n, int), status_h=np.zeros(n, int))
    return D.Cache(d)


def test_prefetch_order_and_values(tmp_path):
    c = make_cache(tmp_path)
    tr = np.arange(12)[::-1].copy()
    tt = T.Trainer(c, tr, None, tmp_path / "run", hp=HP, device="cpu", strict=False, log=lambda *a: None)
    bl = list(tt.epoch_batches(0))
    pf = T.Prefetch(c, [tt.tr[b[1]] for b in bl], tt.bs, pin=False)
    for st, idx, flip in bl:
        b, y = pf.get()
        assert (y.numpy() == c.gather_y(tt.tr[idx])).all()
        # позиции батча в X на «GPU» (здесь CPU) соответствуют кешу
        assert np.allclose(tt.Xt[torch.from_numpy(idx)].numpy(), c.load_xf(tt.tr[idx])[0])
    assert pf.get() is None


def test_ema_matches_pilot(tmp_path):
    from pilotnn.train import EMA
    c = make_cache(tmp_path)
    tt = T.Trainer(c, np.arange(12), None, tmp_path / "run", hp=HP, device="cpu", strict=False, log=lambda *a: None)
    ref = EMA(tt.model, 0.999)
    ref.shadow = {k: v.clone() for k, v in tt.model.state_dict().items()}
    for i in range(5):
        with torch.no_grad():
            for p in tt.params:
                p.add_(0.01 * (i + 1))
        tt.ema_update(); ref.update(tt.model)
    for (k, v), p in zip(tt.ema_model.named_parameters(), tt.ema_params):
        assert torch.allclose(v, ref.shadow[k].to(v.dtype), atol=1e-6)


def test_loss_decreases_and_resume_identical(tmp_path):
    c = make_cache(tmp_path / "c")
    tr = np.arange(12)

    def run(d, epochs, **kw):
        t = T.Trainer(c, tr, None, d, hp=HP, device="cpu", strict=True, log=lambda *a: None)
        t.run_steps(max_epochs=epochs, schedule_steps=12, **kw)     # 3 шага/эпоху, расписание 12 шагов
        return t

    a = run(tmp_path / "a", 4)
    losses = [h["train"] for h in a.hist]
    assert losses[-1] < losses[0]
    b1 = run(tmp_path / "b", 2)
    b2 = run(tmp_path / "b", 4)                     # продолжение с last.pt
    assert b2.gstep == a.gstep == 12
    for p, q in zip(a.ema_params, b2.ema_params):
        assert torch.allclose(p, q, atol=1e-6)
    for p, q in zip(a.params, b2.params):
        assert torch.allclose(p, q, atol=1e-6)


def test_val_and_early_stop(tmp_path):
    c = make_cache(tmp_path / "c")
    t = T.Trainer(c, np.arange(8), np.arange(8, 12), tmp_path / "r", hp=dict(HP, patience=1), device="cpu", strict=False, log=lambda *a: None)
    r = t.run_steps(max_epochs=6)
    assert (tmp_path / "r" / "ckpt" / "best.pt").exists()
    assert all("val" in h for h in t.hist) and np.isfinite(t.best["val"])


def test_stop_steps(tmp_path):
    c = make_cache(tmp_path / "c")
    t = T.Trainer(c, np.arange(12), None, tmp_path / "r", hp=HP, device="cpu", strict=False, log=lambda *a: None)
    t.run_steps(stop_steps=5, schedule_steps=30)
    assert t.gstep == 5


def test_periodic_snapshots_not_overwritten(tmp_path):
    c = make_cache(tmp_path / "c")
    t = T.Trainer(c, np.arange(8), np.arange(8, 12), tmp_path / "r", hp=dict(HP, snap_every=2, patience=99), device="cpu", strict=False, log=lambda *a: None)
    t.run_steps(max_epochs=5)
    ck = tmp_path / "r" / "ckpt"
    assert sorted(p.name for p in ck.glob("ep*.pt")) == ["ep002.pt", "ep004.pt"]
    a = torch.load(ck / "ep002.pt", weights_only=False)
    assert a["epoch"] == 1 and a["val"] is not None and "model" in a
    assert (ck / "last.pt").exists() and (ck / "best.pt").exists()
