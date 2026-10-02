"""Процедурные рельефы пилота `p_000…p_NNN` — дешёвое разнообразие форм для обучения сети (NN-P1).

Каждый рельеф — та же «синтетика» air-lite (`places.SynthLocation`): 40 × 40 км, узлы по 25 м (1601²),
центр места в (0, 0), x — восток, y — север, климат и солнце Онгудая (июль), высота базы — случайная.
Формы (в своей повёрнутой системе: x′ — поперёк, y′ — вдоль оси формы):
  ridge  — хребет: профиль Аньези H/(1 + (x′/L)²), концы гаснут по Гауссу за half_len (как s_ridge);
  hill   — отдельная гора H/(1 + r²/L²)^1.5 (как s_hill), с вытянутостью (L по осям разная);
  saddle — хребет с седловиной глубины depth·H и ширины s (как s_saddle);
  valley — два параллельных хребта на расстоянии gap (как s_valley), высоты разные;
  scarp  — уступ плато: H·(1 + tanh(x′/L))/2, плато шириной plateau, вдоль half_len (как s_scarp).
Главная форма — у центра (сдвиг ≤ 3 км), поворот — любой; в половине рельефов к ней добавляются 1–2 второстепенные
(гора или хребет 0,3–0,8 высоты главной в 2–9 км). Поверх — слабая «шероховатость»: сглаженный по Гауссу белый шум
(σ 0–25 м, масштаб 300–1200 м) — реальный рельеф не гладкий. Крутизна ограничена: L ≥ H / 1,2 (скат Аньези
≤ ~38°) — как крутые склоны встроенных мест на 25 м.

«Старт» (точка ключевых чисел пилота и центр окна 100 м) — вершина/бровка главной формы:
ridge/saddle — середина гребня (у saddle — седловина, как s_saddle), hill — вершина, valley — гребень первого хребта,
scarp — бровка (перегиб выпуклости tanh: x′ = 0,658·L, плато — выше).

Всё — от зерна: рельеф k строится генератором `np.random.default_rng([seed, k])`, независимо от остальных.
"""
from __future__ import annotations

import math

import numpy as np

N_NODES, SP = 1601, 25.0
TYPES = ("ridge", "hill", "saddle", "valley", "scarp")
MAX_SLOPE_HL = 1.2

_SEED = None


def configure(seed):
    """Зерно процедурных рельефов (из плана набора); до первого обращения к месту p_*."""
    global _SEED
    _SEED = int(seed)


def _u(rng, a, b, nd=1):
    return float(np.round(rng.uniform(a, b), nd))


def _form(rng, kind, H, xc, yc):
    L = _u(rng, 300.0, 2000.0, 0)
    L = max(L, math.ceil(H / MAX_SLOPE_HL))
    f = dict(kind=kind, H=H, L=L, xc=xc, yc=yc, rot=_u(rng, 0.0, 360.0))
    if kind in ("ridge", "saddle", "valley", "scarp"):
        f["half_len"] = _u(rng, 2000.0, 9000.0, 0)
        f["end_L"] = _u(rng, 0.7 * L, 2.0 * L, 0)
    if kind == "hill":
        f["aspect"] = _u(rng, 1.0, 2.0, 2)
    if kind == "saddle":
        f["depth"] = _u(rng, 0.3, 0.7, 2)
        f["s"] = _u(rng, 300.0, 1200.0, 0)
    if kind == "valley":
        f["gap"] = _u(rng, 2.5 * L, 6.0 * L, 0)
        f["H2"] = _u(rng, 0.6 * H, 1.0 * H, 0)
    if kind == "scarp":
        f["plateau"] = _u(rng, 3000.0, 10000.0, 0)
    return f


def params(k, seed=None):
    """Параметры рельефа p_<k> (dict): база, формы, шум, старт — детерминированно от (seed, k)."""
    seed = _SEED if seed is None else seed
    assert seed is not None, "procedural.configure(seed) не вызван"
    rng = np.random.default_rng([int(seed), int(k)])
    base = _u(rng, 600.0, 1600.0, 0)
    kind = TYPES[k % len(TYPES)] if k < len(TYPES) * 2 else TYPES[int(rng.integers(len(TYPES)))]
    r, a = 3000.0 * math.sqrt(rng.uniform()), rng.uniform(0, 2 * math.pi)
    H = _u(rng, 150.0, 900.0, 0)
    forms = [_form(rng, kind, H, round(r * math.cos(a), 0), round(r * math.sin(a), 0))]
    n_sec = int(rng.choice([0, 0, 1, 2]))
    for _ in range(n_sec):
        d, b = rng.uniform(2000.0, 9000.0), rng.uniform(0, 2 * math.pi)
        xc, yc = forms[0]["xc"] + d * math.cos(b), forms[0]["yc"] + d * math.sin(b)
        sk = ("hill", "ridge")[int(rng.integers(2))]
        forms.append(_form(rng, sk, _u(rng, 0.3 * H, 0.8 * H, 0), round(xc, 0), round(yc, 0)))
    noise = dict(sigma=_u(rng, 0.0, 25.0, 1), scale=_u(rng, 300.0, 1200.0, 0), seed=int(rng.integers(2 ** 31)))
    return dict(id=f"p_{k:03d}", base=base, forms=forms, noise=noise, start=_start(forms[0]))


def _rot(f, X, Y):
    t = math.radians(f["rot"])
    dx, dy = X - f["xc"], Y - f["yc"]
    return dx * math.cos(t) + dy * math.sin(t), -dx * math.sin(t) + dy * math.cos(t)


def _to_world(f, xp, yp):
    t = math.radians(f["rot"])
    return f["xc"] + xp * math.cos(t) - yp * math.sin(t), f["yc"] + xp * math.sin(t) + yp * math.cos(t)


def _start(f):
    k = f["kind"]
    if k == "valley":
        return _to_world(f, f["gap"] / 2, 0.0)
    if k == "scarp":
        return _to_world(f, 0.658 * f["L"], 0.0)
    return f["xc"], f["yc"]


def _agnesi(x, H, L):
    return H / (1 + (x / L) ** 2)


def _ends(Y, half_len, L):
    return np.exp(-np.maximum(np.abs(Y) - half_len, 0) ** 2 / (2 * L ** 2))


def form_height(f, X, Y):
    xp, yp = _rot(f, X, Y)
    k, H, L = f["kind"], f["H"], f["L"]
    if k == "ridge":
        return _agnesi(xp, H, L) * _ends(yp, f["half_len"], f["end_L"])
    if k == "hill":
        return H / (1 + (xp / L) ** 2 + (yp / (L * f["aspect"])) ** 2) ** 1.5
    if k == "saddle":
        crest = H - f["depth"] * H * np.exp(-yp ** 2 / (2 * f["s"] ** 2))
        return crest / (1 + (xp / L) ** 2) * _ends(yp, f["half_len"], f["end_L"])
    if k == "valley":
        g = f["gap"] / 2
        return (_agnesi(xp - g, H, L) + _agnesi(xp + g, f["H2"], L)) * _ends(yp, f["half_len"], f["end_L"])
    if k == "scarp":
        step = H * 0.5 * (1 + np.tanh(xp / L))
        e = _ends(yp, f["half_len"], f["end_L"]) * np.exp(-np.maximum(xp - f["plateau"], 0) ** 2 / (2 * 2000.0 ** 2))
        return step * e
    raise KeyError(k)


def height(p, X, Y):
    """Высота над морем, м, на узлах X, Y (м от центра)."""
    h = np.full(X.shape, p["base"], dtype=np.float64)
    for f in p["forms"]:
        h += form_height(f, X, Y)
    nz = p["noise"]
    if nz["sigma"] > 0:
        from scipy.ndimage import gaussian_filter
        rng = np.random.default_rng(nz["seed"])
        w = gaussian_filter(rng.standard_normal(X.shape), nz["scale"] / SP, mode="wrap")
        h += nz["sigma"] * w / w.std()
    return h


def grid():
    x = (np.arange(N_NODES) - (N_NODES - 1) / 2) * SP
    return np.meshgrid(x, x)
