"""AN-2: физика входа/выхода сети ann2 (контракт A2 v1): профили притока U(η), θ̄(η), условия (скаляры),
обратное преобразование выхода колонки в м/с и К исходной системы (ЕДИНСТВЕННАЯ функция `to_physical`).

Система координат — как П2 v4 (`air_nn_pilot/pilotnn/prep.py`): поворот на k·90° (ветер «с запада» ±45°), остаток угла r
в условиях (cos r, sin r); повороты и отражение — импортом из prep (rot_scalar, rot_vec, reflect).
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "air_nn_pilot"))
from pilotnn import prep as P  # noqa: E402

AGL = np.asarray(P.AGL, np.float64)            # 13 уровней П1, м над рельефом клетки
ETA_MIN, ETA_MAX = 25.0, 2000.0                # диапазон высот обучения (A2)
U_FLOOR = 1.0                                  # м/с, знаменатель долей: max(U(η), 1)
OUT_NAMES = ("du_par", "du_perp", "w", "theta", "logsig_du_par", "logsig_du_perp", "logsig_w", "logsig_theta")
MAP_IDX = (0, 1, 4, 5, 6, 7, 8)               # карты П2 v3, берутся в ann2: без x, y (нет абсолютных координат)
MAP_NAMES = tuple(P.MAP_NAMES[i] for i in MAP_IDX)
N_MAPS = len(MAP_IDX)
# фоновая стратификация решателя (air3d/solver.py, Cond): dθ̄/dz = 3 К/км ниже 3500 м над морем, 6 К/км выше
GAM_LOW, GAM_HIGH, Z_BREAK = 3.0e-3, 6.0e-3, 3500.0
N_PROF_CH = 3                                  # каналы 1D профиля: U/10, θ̄/5, log(η/25)/log(80)
N_SCAL = 18 + 4                                # 18 чисел FiLM П2 + dx, heated, Fr⁻¹, N_случая/0,02 (A2 v2)
NORM_N = 0.02                                  # 1/с, нормировка N в скалярах
HEAT_ZERO = (5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17)   # числа F, обнуляемые у решения без нагрева (m)
G, TH0 = 9.81, 300.0
N2_BG = G / TH0 * GAM_LOW                      # N² фона, 1/с²


def u_profile(eta, alpha, mp, U10):
    """U(η) притока, м/с (как решатель, `prep.ubg`); поддерживает numpy и torch (broadcast)."""
    z_sat = 10.0 * mp ** (1.0 / alpha)
    lib = _lib(eta)
    return U10 * mp * lib.clip((lib.clip(eta, min=P.Z0) / z_sat) ** alpha, max=1.0)


def _lib(x):
    import torch
    return torch if isinstance(x, torch.Tensor) else _NP


class _NpClip:
    @staticmethod
    def clip(x, min=None, max=None):
        return np.clip(x, min, max)

    log = staticmethod(np.log)


_NP = _NpClip()


def min_(a, b, lib):
    import torch
    return torch.clamp(a, max=b) if isinstance(a, torch.Tensor) else min(a, b)


def max_(a, b, lib):
    import torch
    return torch.clamp(a, min=b) if isinstance(a, torch.Tensor) else max(a, b)


def log_eta(eta):
    lib = _lib(eta)
    return lib.log(eta / ETA_MIN) / math.log(ETA_MAX / ETA_MIN)


def case_par(meta):
    """Параметры профиля притока случая: (α, max_profile, U10, hc_mean) — из мета кеша П2."""
    return np.array([meta["alpha"], meta["mp"], meta["U10"], meta["hc_mean"]], np.float32)


_BG = None


def bg_theta_of(meta):
    """θ̄(η) − θ̄(0) решателя случая на 13 уровнях П1, К: `weather.Day.gamma` случая (bg_theta.py → bg_theta.npz).
    Фон у решателя свой у каждого случая (нейтральный слой перемешивания, инверсия, 5,8 К/км выше), а не 3/6 К/км."""
    global _BG
    if _BG is None:
        import os
        f = Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")) / "ann2" / "bg_theta.npz"
        z = np.load(f)
        _BG = dict(zip(z["ids"].tolist(), z["th"]))
    return _BG[meta["id"]]


def theta_interp(eta, th13):
    """θ̄(η), К: линейно по η между 0 (θ̄ = 0) и уровнями П1; torch. eta (B,...) м, th13 (B,13) К."""
    import torch
    nodes = torch.cat([torch.zeros(1), torch.as_tensor(AGL, dtype=torch.float32)]).to(eta.device)
    y = torch.cat([torch.zeros_like(th13[:, :1]), th13], 1)                       # (B,14)
    B = eta.shape[0]
    e = eta.reshape(B, -1).float().clamp(max=float(AGL[-1]))
    j = torch.searchsorted(nodes, e, right=True).clamp(1, len(nodes) - 1)        # (B,N)
    x0, x1 = nodes[j - 1], nodes[j]
    y0, y1 = torch.gather(y, 1, j - 1), torch.gather(y, 1, j)
    return (y0 + (y1 - y0) * (e - x0) / (x1 - x0)).view(eta.shape)


def profile_input(par, th13):
    """Вход 1D энкодера: (N_PROF_CH, 13) на уровнях П1. par — (4,) numpy, th13 — θ̄ случая (bg_theta_of)."""
    a, mp, U10, hm = (float(x) for x in par)
    u = u_profile(AGL, a, mp, U10)
    th = np.asarray(th13, np.float64)
    return np.stack([u / 10.0, th / 5.0, log_eta(AGL)]).astype(np.float32)


def scalars(F, heated, dx=400.0, N=None):
    """Скаляры условий (N_SCAL,) из чисел FiLM П2 (18, уже после отражения, если оно было) + dx/400 − 1, heated.
    Fr⁻¹ добавляет сеть из карты рельефа окна (см. model.condition_scalars). Без нагрева (heated=0) числа нагрева —
    нули, кроме устойчивости."""
    s = np.zeros(N_SCAL, np.float32)
    s[:18] = F
    if not heated:
        s[list(HEAT_ZERO)] = 0.0
    s[18] = dx / 400.0 - 1.0
    s[19] = 1.0 if heated else 0.0
    s[21] = (math.sqrt(N2_BG) if N is None else float(N)) / NORM_N      # N случая (A2 v2); None — фон 3 К/км (AN-3)
    return s            # s[20] — Fr⁻¹, заполняет model.condition


def fr_inv(terrain_map, U10, N=None):
    """Fr⁻¹ = N·σ_h / max(U10, 1) окна: σ_h — СКО рельефа окна (карта terrain, нормировка /1000 м); torch (B,1|…,H,W).
    N — N случая, 1/с (B,) (A2 v2: из Day.gamma случая, regime.n_bl); None — фон 3 К/км (AN-3)."""
    sd = terrain_map.float().flatten(1).std(dim=1) * P.NORM_TERRAIN_M
    n = math.sqrt(N2_BG) if N is None else N
    return (n * sd / U10.clamp(min=U_FLOOR)).clamp(max=5.0)


# ------------------------------------------------------------------------------------------ выход → физика
def to_physical(mu, meta, eta):
    """ЕДИНСТВЕННОЕ обратное преобразование выхода (A2): mu (4, n, ny, nx) = du_par, du_perp, w (доли max(U(η), 1 м/с)),
    θ′ (К) в повёрнутой системе, на высотах eta (n,) м → (4, n, ny, nx) u, v, w (м/с), θ′ (К) в исходной системе
    (x — восток, y — север). Как `prep.to_physical`, но масштаб — U(η) на высоте колонки, а не U10."""
    mu = np.asarray(mu, np.float64)
    eta = np.asarray(eta, np.float64)
    k, r = meta["k"], meta["r"]
    U = u_profile(eta, meta["alpha"], meta["mp"], meta["U10"])[:, None, None]
    sc = np.maximum(U, U_FLOOR)
    up = mu[0] * sc + U * math.cos(r)
    vp = mu[1] * sc + U * math.sin(r)
    u, v = P.rot_vec(up, vp, -k % 4)
    w = P.rot_scalar(mu[2] * sc, -k % 4)
    th = P.rot_scalar(mu[3], -k % 4)
    return np.ascontiguousarray(np.stack([u, v, w, th]))


def from_p2_target(y91, meta, eta):
    """Цель П2 (91 канал, доли S = max(U10, 1), отклонение от профиля притока) на уровнях П1 → выход ann2 на тех же
    высотах eta (13,) — доли max(U(η), 1): (2 решения × 4 канала, 13, ny, nx): [m: du_par, du_perp, w, (θ′=0)], [h: …].
    Нужна тесту и загрузчику (там — с интерполяцией по η)."""
    y = np.asarray(y91, np.float64).reshape(7, 13, *y91.shape[-2:])
    S = meta["S"]
    U = u_profile(np.asarray(eta, np.float64), meta["alpha"], meta["mp"], meta["U10"])
    sc = np.maximum(U, U_FLOOR)[:, None, None]
    out = np.zeros((2, 4, 13) + y.shape[-2:])
    for j, (c0, n) in enumerate(((0, 3), (3, 4))):
        for c in range(3):
            out[j, c] = y[c0 + c] * S / sc
        if n == 4:
            out[j, 3] = y[c0 + 3]
    return out
