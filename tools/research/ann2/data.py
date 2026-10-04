"""AN-2: загрузчик данных ann2 (контракт A1/A2 v1). Образцы, повороты к ветру, карты П2 v3 и деление — ИМПОРТОМ из
`tools/research/air_nn_pilot/` (кеш подготовки П2: карты уже повёрнуты на k·90°, остаток r — в числах F; цель П2 —
91 канал = 7 × 13 уровней П1). Здесь только то, чего в пилоте нет: вырезки 64² из областей 96², случайные непрерывные
высоты η, пересчёт цели в доли max(U(η), 1 м/с) с интерполяцией между уровнями, решение без нагрева `m` как образец с
нулевой картой потока тепла и маской на θ′, отражение поперёк ветра (`prep.reflect`, правила П2 v4).
"""
from __future__ import annotations

import json
import math
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import torch

import phys
from phys import P  # pilotnn.prep

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "air_nn_pilot"))
from pilotnn.train import case_file  # noqa: E402
from pilotnn.data import Datasets, case_groups  # noqa: E402

AIR_NN_DATA = Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data"))
PILOT = AIR_NN_DATA / "pilot"
P2_RUN = PILOT / "runs" / "2026-10-03_p2b"           # деление и сеть P2 (A1)
P2_REPORT = PILOT / "reports" / "2026-10-03_p2b"
RUNS = AIR_NN_DATA / "ann2" / "runs"
SETS = ("holdout_sys", "holdout_place", "holdout_proc", "newcond_p6", "newcond_old", "train")


def p2_split():
    return json.loads((P2_RUN / "split.json").read_text())


def p2_info():
    return json.loads((P2_RUN / "run_info.json").read_text())


def p2_config():
    return json.loads((P2_RUN / "config.json").read_text())


class Store:
    """Кеш подготовки П2 в ОЗУ: X (n,9,96,96) f32, F (n,18), Y (n,91,96,96) f16, metas, par (n,4), prof (n,3,13)."""

    def __init__(self, ids, with_y=True, threads=8):
        prep = p2_info()["prep_dirs"]
        self.ids = list(ids)
        n = len(self.ids)
        with np.load(case_file(prep, self.ids[0])) as z:
            self.X = np.empty((n,) + z["X"].shape, np.float32)
            self.F = np.empty((n,) + z["F"].shape, np.float32)
            self.Y = np.empty((n,) + z["Y"].shape, np.float16) if with_y else None
        self.metas = [None] * n

        def one(i):
            with np.load(case_file(prep, self.ids[i])) as z:
                self.X[i], self.F[i] = z["X"], z["F"]
                if with_y:
                    self.Y[i] = z["Y"]
                self.metas[i] = json.loads(str(z["meta"]))

        with ThreadPoolExecutor(threads) as ex:
            list(ex.map(one, range(n)))
        self.par = np.stack([phys.case_par(m) for m in self.metas])
        self.prof = np.stack([phys.profile_input(p, phys.bg_theta_of(m)) for p, m in zip(self.par, self.metas)])
        self.N = np.array([phys_N(m) for m in self.metas], np.float32)      # N случая (A2 v2)

    def __len__(self):
        return len(self.ids)


def phys_N(meta):
    """N случая, 1/с (A2 v2): regime.n_bl; env AN4_OLD_N=1 — фон 3 К/км, как в AN-3 (проба «что даёт Fr случая»)."""
    import os
    import regime
    return math.sqrt(phys.N2_BG) if os.environ.get("AN4_OLD_N") else regime.n_bl(meta)


def inputs_from(X, F, par, prof, heated, device, N=None):
    """Вход сети из кеша П2 (после поворота; опционально — после отражения, делает вызывающий). X (B,9,H,W), F (B,18),
    heated (B,) bool → dict maps (B,7,H,W), scal (B,21), prof (B,3,13), par (B,4) — float32 на device.
    heated=False: карта потока тепла = 0 и числа нагрева = 0 (решение без нагрева, A2)."""
    maps = np.ascontiguousarray(X[:, list(phys.MAP_IDX)])
    hi = phys.MAP_NAMES.index("heat_flux")
    maps[~np.asarray(heated, bool), hi] = 0.0
    scal = np.stack([phys.scalars(F[i], bool(heated[i]), N=None if N is None else N[i]) for i in range(len(F))])
    t = lambda a: torch.from_numpy(np.ascontiguousarray(a, np.float32)).to(device, non_blocking=True)  # noqa: E731
    return dict(maps=t(maps), scal=t(scal), prof=t(prof), par=t(par))


def reflect_batch(X, F, Y):
    """Отражение поперёк ветра y′ → −y′ (правила П2 v4, `prep.reflect`), массивы [B,…]; R∘R = тождество."""
    return P.reflect(X, F, Y)


def sample_batch(st: Store, idx, rng, device, crop=64, K=4, Kd=2, reflect=True, p_heat=0.5, eta_range=(25.0, 2000.0),
                 fixed_eta=None):
    """Пакет обучения: вырезки crop² случайного положения из областей 96² случаев idx; на колонку K случайных высот
    (лог-равномерно в eta_range), цель — линейно между соседними уровнями П1, в долях max(U(η), 1 м/с); решение h с
    вероятностью p_heat, иначе m (карта тепла и числа нагрева = 0, θ′ в потере маскируется).
    → dict(maps, scal, prof, par, eta (B,K,h,w), eta_div (B,Kd,2), y (B,K,4,h,w), mask (B,4))."""
    B = len(idx)
    H, W = st.X.shape[-2:]
    X = np.empty((B, 9, crop, crop), np.float32)
    Y = np.empty((B, 91, crop, crop), np.float16)
    F = st.F[idx].copy()
    for b, i in enumerate(idx):
        j0, i0 = rng.integers(0, H - crop + 1), rng.integers(0, W - crop + 1)
        X[b] = st.X[i, :, j0:j0 + crop, i0:i0 + crop]
        Y[b] = st.Y[i, :, j0:j0 + crop, i0:i0 + crop]
    if reflect:
        fl = rng.random(B) < 0.5
        if fl.any():
            X[fl], F[fl], Y[fl] = P.reflect(X[fl], F[fl], Y[fl])
    heated = rng.random(B) < p_heat
    inp = inputs_from(X, F, st.par[idx], st.prof[idx], heated, device, N=st.N[idx])
    # высоты и цель
    lo_, hi_ = np.log(eta_range[0]), np.log(eta_range[1])
    # A2 v2: высота общая для всех клеток окна (ветвь по η разложенной головы считается один раз на высоту)
    e1 = np.exp(rng.uniform(lo_, hi_, (B, K, 1, 1))).astype(np.float32) if fixed_eta is None else \
        np.broadcast_to(np.asarray(fixed_eta, np.float32)[None, :, None, None], (B, len(fixed_eta), 1, 1))
    eta = np.ascontiguousarray(np.broadcast_to(e1, (B, e1.shape[1], crop, crop)))
    eta_div = np.exp(rng.uniform(np.log(30.0), np.log(1400.0), (B, Kd, 1))).astype(np.float32)
    eta_div = np.concatenate([eta_div, eta_div * 1.15], -1)
    dev = device
    Yt = torch.from_numpy(Y).to(dev).float().view(B, 7, 13, crop, crop)
    et = torch.from_numpy(eta).to(dev)
    agl = torch.tensor(phys.AGL, dtype=torch.float32, device=dev)
    hi_i = torch.searchsorted(agl, et.contiguous()).clamp(1, 12)
    lo_i = hi_i - 1
    t = ((et - agl[lo_i]) / (agl[hi_i] - agl[lo_i])).clamp(0, 1)
    gat = lambda ii: Yt.gather(2, ii[:, None].expand(B, 7, -1, -1, -1))  # noqa: E731
    Yi = gat(lo_i) * (1 - t[:, None]) + gat(hi_i) * t[:, None]              # (B,7,K,h,w), доли S
    par = inp["par"]
    a, mp, U10 = (par[:, i].view(B, 1, 1, 1) for i in range(3))
    S = U10.clamp(min=1.0)
    sc = phys.u_profile(et, a, mp, U10).clamp(min=phys.U_FLOOR)
    h_t = torch.from_numpy(heated).to(dev)
    # каналы: h → [3,4,5,6]; m → [0,1,2] и θ′ (маска)
    sel_h, sel_m = Yi[:, 3:7], torch.cat([Yi[:, 0:3], torch.zeros_like(Yi[:, :1])], 1)
    y = torch.where(h_t.view(B, 1, 1, 1, 1), sel_h, sel_m)                   # (B,4,K,h,w)
    y = torch.cat([y[:, :3] * (S / sc)[:, None], y[:, 3:]], 1).permute(0, 2, 1, 3, 4).contiguous()
    y = torch.nan_to_num(y)
    mask = torch.stack([torch.ones_like(h_t, dtype=torch.float32)] * 3 + [h_t.float()], 1)
    inp.update(eta=et, eta_div=torch.from_numpy(eta_div).to(dev), y=y, mask=mask)
    return inp


def eval_inputs(X, F, par, prof, heated, device, N=None):
    """Вход сети на полной карте (без вырезок, без отражения): X (B,9,H,W) из кеша П2; N (B,) — N случая."""
    return inputs_from(X, F, par, prof, np.full(len(X), heated), device, N=N)
