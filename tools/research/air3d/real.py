"""Реальный рельеф для эталона (AM-01): сетки места (область 400/200 м, окна 100/50 м у старта),
условия из погоды игры на час (weather.py), ключевые числа у старта.

Координаты: x — восток, y — север (= −Z мира), м от центра места (как terrain.py).
"""
from __future__ import annotations

import math
from dataclasses import replace
from functools import lru_cache

import numpy as np

import air as A
import terrain as T
import weather as W
import wind_prof as WP

DOMAIN_L = 38400.0       # сторона области, м (слой detail — 40 км; 38,4 = 96·400 = 192·200)
TOP_ABOVE = 3000.0       # потолок над максимумом рельефа области, м (губка — верхний 1 км)
START = dict(ongudai="kayancha_south", aushkul="ridge_west")


@lru_cache(maxsize=None)
def location(loc):
    return T.Location(loc)


@lru_cache(maxsize=None)
def context(loc):
    L = location(loc)
    return W.location_ctx(loc, L.height_at)


def block_mean(loc, x0, y0, dx, nx, ny):
    L = location(loc)
    return T.block_mean(L.h, L.info, x0, y0, dx, nx, ny)


def water(loc, g):
    L = location(loc)
    if L.water is None:
        return None
    f = int(round(g.dx / 25.0))
    i0 = int(round((g.x0 - L.info["x0"]) / 25.0)); j0 = int(round((g.y0 - L.info["y0"]) / 25.0))
    w = L.water[j0:j0 + f * g.ny, i0:i0 + f * g.nx]
    return w.reshape(g.ny, f, g.nx, f).mean(axis=(1, 3))


def grid_domain(loc, dx, dz=None):
    n = int(round(DOMAIN_L / dx))
    x0 = y0 = -DOMAIN_L / 2
    hc = block_mean(loc, x0, y0, dx, n, n)
    dz = dz or (105.0 if dx >= 200 else dx / 2)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + TOP_ABOVE - zb) / dz)); nz += nz % 2
    return A.Grid(dx, n, n, dz, zb, nz, x0, y0), hc


def grid_window(loc, dx, n=64, top_above=2000.0, center=None, dz=None):
    L = location(loc)
    s = L.sites[START[loc]]
    cx, cy = center if center is not None else (s["x"], s["y"])
    cx = round((cx - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    cy = round((cy - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    dz = dz or dx / 2
    x0, y0 = cx - n * dx / 2, cy - n * dx / 2
    hc = block_mean(loc, x0, y0, dx, n, n)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + top_above - zb) / dz)); nz += nz % 2
    return A.Grid(dx, n, n, dz, zb, nz, x0, y0), hc


def day(loc, hour, t_max=None, sky="clear"):
    ctx = context(loc)
    t_max = W.typical_max_c(ctx["month"], ctx["day"]) if t_max is None else t_max
    return W.Day(hour, t_max, sky, ctx)


def case(loc, g, hc, hour, U10, wdir, t_max=None, sky="clear", heat=True):
    """Условия на час: θ̄(z), z_i и поток тепла из погоды игры; heat=False — H = 0 (механика).
    Профиль притока случая (c.alpha, c.max_profile) — по устойчивости на час (wind_prof, C2 v4, как
    WindProfile.apply_to_case игры); make() ставит их в Params."""
    ctx = context(loc)
    D = day(loc, hour, t_max, sky)
    doy = W.day_of_year(ctx["month"], ctx["day"])
    H, sun = A.solar_flux(hc, g.dx, D, ctx["lat"], ctx["lon"], ctx["utc_offset_h"], doy, water=water(loc, g),
                          lag_h=W.CFG["heating"]["lag_h"]["none"])
    c = A.Case(U10=U10, wdir=wdir, gam=D.gamma, z_i=D.z_i, H=H if heat else None,
               label=f"{loc} {hour:g}h U{U10:g} {wdir:g}° t{D.t_max:g} {sky}{'' if heat else ' noheat'}")
    c.day = D
    c.sun = sun
    P0 = A.Params()
    c.alpha, c.max_profile, c.stab_class, c.sun_elev = WP.for_hour(ctx, hour, sky, U10, P0.z0, P0.f_cor)
    return c


def probes(loc):
    L = location(loc)
    s = L.sites[START[loc]]
    out = dict(start=(s["x"], s["y"]))
    if loc == "ongudai":
        out["saddle"] = (s["x"] + 300.0, s["y"] + 800.0)   # как прикидка (common.probes)
    return out


def key_numbers(S, fields=None):
    """Ключевые числа: подъём (max w на 200 м AGL в 1,5 км от старта), w и ветер на 50 м над
    стартом, седловина (Онгудай)."""
    from synth import agl
    u, v, w, th = fields if fields is not None else S.centers()
    sp = np.sqrt(u ** 2 + v ** 2)
    g = S.g
    loc = S.loc
    P = probes(loc)
    X, Y = np.meshgrid(g.x, g.y)
    sx, sy = P["start"]
    near = (X - sx) ** 2 + (Y - sy) ** 2 < 1500.0 ** 2
    w200, w50, s50, th50 = agl(S, w, 200.0), agl(S, w, 50.0), agl(S, sp, 50.0), agl(S, th, 50.0)
    out = dict(start_w200_max=float(np.nanmax(np.where(near, w200, np.nan))),
               start_w50=bil(g, w50, sx, sy), start_speed50=bil(g, s50, sx, sy), start_th50=bil(g, th50, sx, sy),
               w200_p99=float(np.nanpercentile(w200, 99)), w200_p01=float(np.nanpercentile(w200, 1)),
               w_max=float(np.nanmax(w)), w_min=float(np.nanmin(w)), th_max=float(np.nanmax(th)), th_min=float(np.nanmin(th)))
    if "saddle" in P:
        out["saddle_speed50"] = bil(g, s50, *P["saddle"])
    return out


def bil(g, M, x, y):
    fi = (x - g.x0) / g.dx - 0.5
    fj = (y - g.y0) / g.dx - 0.5
    i0 = int(np.clip(np.floor(fi), 0, g.nx - 2)); j0 = int(np.clip(np.floor(fj), 0, g.ny - 2))
    a, b = fi - i0, fj - j0
    return float((1 - b) * ((1 - a) * M[j0, i0] + a * M[j0, i0 + 1]) + b * ((1 - a) * M[j0 + 1, i0] + a * M[j0 + 1, i0 + 1]))


def make(loc, g, hc, cond, parent=None, prm=None, dtype=np.float32):
    """Решатель случая; α и max_profile — профиль притока случая (case(): по устойчивости на час), если он есть."""
    prm = prm or A.Params()
    if getattr(cond, "alpha", None) is not None:
        prm = replace(prm, alpha=cond.alpha, max_profile=cond.max_profile)
    S = A.Air(g, hc, cond, prm, nest=None if parent is None else dict(parent=parent), dtype=dtype)
    S.loc = loc
    return S
