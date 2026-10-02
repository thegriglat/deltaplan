"""Вход и выход сети области (контракт П2 v1): поворот к ветру «с запада», карты, числа FiLM, цель (91 канал)
и ОДНА функция обратного преобразования выхода в м/с и К исходной системы (`to_physical`).

Системы координат: x — восток (ось i), y — север (ось j), массивы `[..., j, i]`; центр области в (0, 0).
Ветер `wdir` — откуда дует (метео), куда дует — ê = (−sin wdir, −cos wdir) (как air-lite features.unit).

Поворот: поле поворачивается вокруг вертикали против часовой стрелки на k·90°, k выбран так, что
направление «куда дует» в повёрнутой системе φ' = φ + k·90° ∈ [−45°, 45°) (ветер «с запада» ±45°); остаток
r = φ' — в числа (cos r, sin r). Только вращение, без отражений (знак Кориолиса сохраняется). Скалярная карта:
новая[j', i'] = старая(R⁻¹p'), что для массива [j, i] (j — север) = np.rot90(·, −k, axes=(−2, −1)); вектор
(u, v) → R(k·90°)(u, v). Сетка 96² симметрична относительно центра — клетки переходят в клетки точно.

Цель: 7 каналов × 13 высот (порядок [канал][высота], канал·13 + высота):
  0..2 — без нагрева (u∥, u⊥, w); 3..6 — с нагревом (u∥, u⊥, w, θ′);
  u∥, u⊥ — компоненты по осям x', y' повёрнутой системы (x' — номинальное «по ветру»).
  Скорости: (поле − профиль притока Ub(a)·(cos r, sin r, 0)) / max(U10, 1 м/с); θ′ — в К (без масштаба).
Профиль притока решателя (air3d/air.py → wind_profile, Case.U_a): Ub(a) = U10·mp·min((max(a, z0)/z_sat)^α, 1),
z_sat = 10·mp^(1/α), z0 = 0,1 м; α, mp = max_profile — из метаданных случая (`profile`).
"""
from __future__ import annotations

import math

import numpy as np

AGL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
N_MECH, N_HEAT = 3, 4
N_CH = N_MECH + N_HEAT                 # 7
Z0 = 0.1
MAP_NAMES = ("terrain", "heat_flux", "x", "y")
FILM_NAMES = ("U10", "cos_r", "sin_r", "alpha", "max_profile", "z_i", "z_lcl", "sun_el", "sun_x", "sun_y", "heat",
              "t_max", "stab", "cap_flag", "cap_agl", "hour", "brk", "t_air")
STAB = "ABCDEF"


def ubg(agl, alpha, mp, U10):
    agl = np.asarray(agl, float)
    z_sat = 10.0 * mp ** (1.0 / alpha)
    return U10 * mp * np.minimum((np.maximum(agl, Z0) / z_sat) ** alpha, 1.0)


def rotation_of(wdir):
    """→ (k, r): k — число поворотов на 90° против часовой, r — остаток угла «куда дует» в повёрнутой системе, рад."""
    a = math.radians(wdir)
    phi = math.atan2(-math.cos(a), -math.sin(a))          # угол ê от оси x (восток), против часовой
    k = int(round(-phi / (math.pi / 2))) % 4
    r = phi + k * math.pi / 2
    r = (r + math.pi) % (2 * math.pi) - math.pi
    if r >= math.pi / 4 - 1e-12:                           # граница сектора: [−45°, 45°)
        k = (k - 1) % 4
        r -= math.pi / 2
    elif r < -math.pi / 4 - 1e-12:
        k = (k + 1) % 4
        r += math.pi / 2
    return k, r


def rot_scalar(a, k):
    """Поворот карты(карт) [..., j, i] против часовой на k·90° в физической системе (j — север)."""
    return np.rot90(a, -k, axes=(-2, -1))


def rot_vec(u, v, k):
    """Поворот векторного поля: и карты, и компоненты (против часовой на k·90°)."""
    u, v = rot_scalar(u, k), rot_scalar(v, k)
    k %= 4
    if k == 0:
        return u, v
    if k == 1:
        return -v, u
    if k == 2:
        return -u, -v
    return v, -u


def case_meta(row, hc):
    """Числа случая для подготовки и обратного преобразования."""
    pr = row["profile"]
    k, r = rotation_of(float(row["wdir"]))
    U10 = float(row["U10"])
    return dict(id=row["id"], loc=row["loc"], k=k, r=r, U10=U10, alpha=float(pr["alpha"]),
                mp=float(pr["max_profile"]), S=max(U10, 1.0), hc_mean=float(np.mean(hc)))


def film(row, meta):
    """Числа FiLM (порядок FILM_NAMES, нормировки — README «Вход и выход сети»)."""
    pr, day = row["profile"], row.get("day") or {}
    hm = meta["hc_mean"]

    def g(key, default):
        v = day.get(key)
        return default if v is None or (isinstance(v, float) and not math.isfinite(v)) else float(v)

    az = math.radians(float(pr.get("sun_az", 180.0)))
    sx, sy = math.sin(az), math.cos(az)                    # на солнце: x — восток, y — север
    k = meta["k"]
    for _ in range(k):                                     # в повёрнутую систему
        sx, sy = -sy, sx
    cap = day.get("cap_agl")
    cap_ok = cap is not None and isinstance(cap, (int, float)) and math.isfinite(cap)
    st = str(pr.get("stab", "D"))
    v = [meta["U10"] / 10.0, math.cos(meta["r"]), math.sin(meta["r"]),
         (meta["alpha"] - 0.2) / 0.1, (meta["mp"] - 1.5) / 0.5,
         (g("z_i_msl", hm) - hm) / 1000.0, (g("z_lcl_msl", hm + 3000.0) - hm) / 1000.0,
         float(pr.get("sun_el", 0.0)) / 90.0, sx, sy, g("heat", 0.0), (float(row["t_max"]) - 26.0) / 8.0,
         (STAB.index(st) - 2.5) / 2.5 if st in STAB else 0.0, 1.0 if cap_ok else 0.0,
         (float(cap) / 1000.0 if cap_ok else 0.0), (float(row["hour"]) - 14.0) / 6.0, g("brk", 1.0),
         (g("t", 20.0) - 20.0) / 10.0]
    return np.asarray(v, np.float32)


def maps(z, meta, row):
    """Карты входа (порядок MAP_NAMES) в повёрнутой системе, float32 (4, ny, nx)."""
    hc = z["d400_hc"].astype(np.float64)
    H = z["d400_H"].astype(np.float64)
    ny, nx = hc.shape
    d = row.get("d400") or {}
    dx = float(d.get("dx", 400.0))
    half = 0.5 * nx * dx
    x = (np.arange(nx) + 0.5) * dx - half
    y = (np.arange(ny) + 0.5) * dx - half
    X, Y = np.meshgrid(x / half, y / half)
    k = meta["k"]
    return np.stack([rot_scalar((hc - hc.mean()) / 1000.0, k), rot_scalar(H / 800.0, k), X, Y]).astype(np.float32)


def target(z, meta, agl=AGL):
    """Цель (7·13, ny, nx), float64, из полей образца (d400_m (3,13,…), d400_h (4,13,…))."""
    k, r, S = meta["k"], meta["r"], meta["S"]
    ub = ubg(agl, meta["alpha"], meta["mp"], meta["U10"])[:, None, None]
    out = []
    for key, n in (("d400_m", 3), ("d400_h", 4)):
        f = np.asarray(z[key], np.float64)
        u, v = rot_vec(f[0], f[1], k)
        out += [(u - ub * math.cos(r)) / S, (v - ub * math.sin(r)) / S, rot_scalar(f[2], k) / S]
        if n == 4:
            out.append(rot_scalar(f[3], k))
    return np.concatenate(out, axis=0)


def to_physical(y, meta, agl=AGL):
    """Обратное преобразование выхода сети (91, ny, nx) → dict(m=(3,13,ny,nx) u,v,w; h=(4,13,ny,nx) u,v,w,θ′)
    в м/с и К исходной системы (x — восток, y — север). Единственная функция; ею пользуются оценка и отчёт."""
    y = np.asarray(y, np.float64)
    nA = len(agl)
    y = y.reshape(N_CH, nA, *y.shape[-2:])
    k, r, S = meta["k"], meta["r"], meta["S"]
    ub = ubg(agl, meta["alpha"], meta["mp"], meta["U10"])[:, None, None]
    res = {}
    for key, c0, n in (("m", 0, 3), ("h", 3, 4)):
        up = y[c0] * S + ub * math.cos(r)
        vp = y[c0 + 1] * S + ub * math.sin(r)
        u, v = rot_vec(up, vp, -k % 4)
        w = rot_scalar(y[c0 + 2] * S, -k % 4)
        ch = [u, v, w]
        if n == 4:
            ch.append(rot_scalar(y[c0 + 3], -k % 4))
        res[key] = np.ascontiguousarray(np.stack(ch))
    return res


def prepare_case(z, row, agl=AGL):
    hc = z["d400_hc"].astype(np.float64)
    meta = case_meta(row, hc)
    return dict(X=maps(z, meta, row), F=film(row, meta), Y=target(z, meta, agl).astype(np.float16), meta=meta)
