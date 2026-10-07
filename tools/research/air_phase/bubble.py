"""air-phase AP-3: параметры «пузыря» обратного течения за подветренной бровкой (контракт P3 v2, набор `bubble`).

Числа для калибровки полуэмпирики срыва в игре (`configs/atmosphere.json` → `lee`: shadow_angle_deg, rotor_reverse,
rotor_height_fraction, depth_scale_m, relief_scale_m) и порогов по крутизне и местному Fr.

Метод (вертикальное сечение по ветру через центр формы):
- сечение — прямая c + s·e (e — единичный вектор «куда дует», c — центр формы, по умолчанию (0, 0)), шаг ds = dx сетки
  случая; поля и земля — билинейно по центрам клеток (x_i = x0 + dx/2 + dx·i), высоты полей — над землёй (AGL);
- бровка — точка наибольшей выпуклости рельефа (min d²z/ds²) не дальше по ветру, чем самый крутой спуск (min dz/ds);
  у гауссова хребта/холма это гребень, у уступа tanh — начало спуска (x = −0,66 a);
- обратное течение — u·e < 0 на нижнем уровне (25 м AGL) по ветру от бровки; присоединение — первая точка за
  обратной зоной, где u·e ≥ 0 (линейная интерполяция нуля); L — от бровки до присоединения (если зона доходит до края
  сечения — L до края, это нижняя оценка);
- H — наибольшая высота AGL, до которой u·e < 0 непрерывно от земли в колоннах обратной зоны (интерполяция нуля по
  высоте);
- центр вихря — минимум функции тока ψ(s, z) = ∫₀^z u·e dz' (двумерное несжимаемое приближение в координатах над
  землёй, u·e = 0 у земли) в колоннах обратной зоны;
- area_rev_frac — доля клеток всей сетки (окна) с u·e < 0 на нижнем уровне (на сетке 400 м — без края EDGE клеток);
- shadow_angle_deg = atan(Δz/L), Δz — перепад бровка → земля в точке присоединения; −1, если обратного течения нет;
- fr_local = U невозмущённого профиля притока на высоте h над землёй / (N·h): U(z) = U_sat·min((z/z_sat)^α, 1),
  z_sat = 10·max_profile^(1/α) (фон решателя `air.wind_profile`, профиль ветра игры) — аргумент `inflow`. AP-10: прежнее
  определение по колонне поля 400 м у края (`up_profile`, 5 клеток = ширина боковой губки 2 км) брало скорость из
  возмущённого поля: при Fr ≤ 0,5 и переносе 2-го порядка колонна у губки несёт выброс 2–3 м/с при U_sat = 1,5
  (fr_local 0,61 вместо 0,30); `up_profile` оставлен только для старых вызовов;
- сечение — через `center`; None (AP-10) — через точку наибольшего подветренного уклона −∇z·e сетки (при равенстве —
  ближайшую к центру сетки): окно 100 м при косом ветре лежит у конца хребта и не содержит (0, 0), прежнее сечение
  через (0, 0) окно не пересекало (slope_lee = 0, has_reverse = 0 у всех косых случаев);
- slope_lee — max уклон спуска (−dz/ds) по ветру от бровки на сетке случая (тангенс).
Если обратного течения нет: has_reverse = 0, L, H, xc, zc = 0, urev = min(0, …), shadow = −1.
Границы: двумерное сечение (у холма и при косом ветре течение трёхмерное — ψ лишь оценка центра); разрешение по
вертикали — 13 уровней S5 (25 … 2000 м), H меньше 25 м не различается; на сетке 400 м форма с s = 0,5 недоразрешена.
"""
from __future__ import annotations

import numpy as np

BUBBLE_DTYPE = np.dtype([("has_reverse", "i1"), ("L_over_h", "f4"), ("H_over_h", "f4"), ("urev_over_U", "f4"),
                         ("xc_over_h", "f4"), ("zc_over_h", "f4"), ("area_rev_frac", "f4"),
                         ("shadow_angle_deg", "f4"), ("fr_local", "f4"), ("slope_lee", "f4")])


def bilinear(a, x0, y0, dx, px, py):
    """a (..., ny, nx) по центрам клеток x_i = x0 + dx/2 + dx·i; px, py — точки (n,). → (..., n)."""
    ny, nx = a.shape[-2:]
    fi = np.clip((np.asarray(px) - x0) / dx - 0.5, 0, nx - 1)
    fj = np.clip((np.asarray(py) - y0) / dx - 0.5, 0, ny - 1)
    i0 = np.minimum(np.floor(fi).astype(int), nx - 2)
    j0 = np.minimum(np.floor(fj).astype(int), ny - 2)
    ti, tj = fi - i0, fj - j0
    return (a[..., j0, i0] * (1 - ti) * (1 - tj) + a[..., j0, i0 + 1] * ti * (1 - tj)
            + a[..., j0 + 1, i0] * (1 - ti) * tj + a[..., j0 + 1, i0 + 1] * ti * tj)


def section(ny, nx, x0, y0, dx, e, center=(0.0, 0.0)):
    """Точки сечения c + s·e внутри области центров клеток; → (s, px, py)."""
    xlo, xhi = x0 + dx / 2, x0 + dx / 2 + dx * (nx - 1)
    ylo, yhi = y0 + dx / 2, y0 + dx / 2 + dx * (ny - 1)
    smax = np.hypot(xhi - xlo, yhi - ylo)
    s = np.arange(-smax, smax + dx / 2, dx)
    px, py = center[0] + s * e[0], center[1] + s * e[1]
    m = (px >= xlo - 1e-6) & (px <= xhi + 1e-6) & (py >= ylo - 1e-6) & (py <= yhi + 1e-6)
    return s[m], px[m], py[m]


def _zero_cross(x0, x1, f0, f1):
    """Точка нуля линейной интерполяции между (x0, f0 < 0) и (x1, f1 ≥ 0)."""
    d = f1 - f0
    return x1 if d <= 0 else x0 + (x1 - x0) * (-f0) / d


def inflow_at(agl, along, z):
    """Скорость по профилю колонны (agl, along) на высоте z над землёй (вне диапазона — крайние значения)."""
    return float(np.interp(z, agl, along))


def inflow_speed(z, u_sat, alpha, max_profile):
    """Невозмущённый профиль притока решателя (air.wind_profile): U_sat·min((z/z_sat)^α, 1), z_sat = 10·max_profile^(1/α)."""
    z_sat = 10.0 * max_profile ** (1.0 / alpha)
    return u_sat * np.minimum((np.maximum(np.asarray(z, float), 0.1) / z_sat) ** alpha, 1.0)


def steepest_lee_point(ground, x0, y0, dx, e):
    """Центр клетки с наибольшим подветренным уклоном −∇z·e (при равенстве — ближайшая к центру сетки). → (x, y)."""
    g = np.asarray(ground, np.float64)
    ny, nx = g.shape
    gy, gx = np.gradient(g, dx)
    xs = x0 + dx / 2 + dx * np.arange(nx)
    ys = y0 + dx / 2 + dx * np.arange(ny)
    X, Y = np.meshgrid(xs, ys)
    xm, ym = xs.mean(), ys.mean()
    lee = -(gx * e[0] + gy * e[1])
    lee = np.round(lee, 6) - 1e-12 * ((X - xm) ** 2 + (Y - ym) ** 2)
    j, i = np.unravel_index(int(np.argmax(lee)), lee.shape)
    return float(xs[i]), float(ys[j])


def bubble(fields, agl, x0, y0, dx, ground, e, h, u_sat, n_bv, up_profile=None, center=(0.0, 0.0), edge=0, inflow=None):
    """fields (C ≥ 2, K, ny, nx) — u, v[, w, θ′] на высотах agl (K,) над землёй; ground (ny, nx) — земля, м н. у. м.;
    e — единичный вектор «куда дует»; h — перепад формы, м; u_sat — U насыщения притока, м/с; n_bv — N, 1/с;
    inflow = (alpha, max_profile) — профиль притока для fr_local = U(h)/(N·h) (AP-10);
    up_profile = (agl_up, along_up, z_ground_up) — старое определение fr_local по колонне поля (если inflow нет;
    оба None — fr_local = 0); center — точка сечения, None — наибольший подветренный уклон сетки;
    edge — край, не входящий в area_rev_frac (клетки). → запись BUBBLE_DTYPE (np.void)."""
    out = np.zeros((), BUBBLE_DTYPE)
    agl = np.asarray(agl, np.float64)
    f = np.asarray(fields, np.float32)
    ny, nx = f.shape[-2:]
    if center is None:
        center = steepest_lee_point(ground, x0, y0, dx, e)
    s, px, py = section(ny, nx, x0, y0, dx, e, center)
    alongs = bilinear(f[0], x0, y0, dx, px, py) * e[0] + bilinear(f[1], x0, y0, dx, px, py) * e[1]   # (K, n)
    zs = bilinear(np.asarray(ground, np.float64), x0, y0, dx, px, py)
    along2d = f[0, 0] * e[0] + f[1, 0] * e[1]
    sl = slice(edge, ny - edge if edge else None), slice(edge, nx - edge if edge else None)
    out["area_rev_frac"] = float((along2d[sl] < 0).mean())
    out["shadow_angle_deg"] = -1.0
    if s.size < 5:
        return out[()]
    d1 = np.gradient(zs, s)
    d2 = np.gradient(d1, s)
    i_lee = int(np.argmin(d1))
    if d1[i_lee] >= 0:          # спуска по ветру нет
        return out[()]
    ib = int(np.argmin(d2[: i_lee + 1]))
    sb, zb = s[ib], zs[ib]
    out["slope_lee"] = float(max(0.0, -d1[ib:].min()))
    if inflow is not None and n_bv > 0 and h > 0:
        out["fr_local"] = float(inflow_speed(h, u_sat, *inflow)) / (n_bv * h)
    elif up_profile is not None and n_bv > 0 and h > 0:
        agl_up, along_up, zg_up = up_profile
        out["fr_local"] = inflow_at(agl_up, along_up, max(zb - zg_up, float(agl_up[0]))) / (n_bv * h)
    a0 = alongs[0]
    out["urev_over_U"] = float(min(0.0, a0[ib:].min()) / max(u_sat, 1e-6))
    rv = np.nonzero(a0[ib:] < 0)[0]
    if rv.size == 0:
        return out[()]
    j1 = ib + int(rv[0])
    jr = j1
    while jr < s.size and a0[jr] < 0:
        jr += 1
    if jr < s.size:
        sr = _zero_cross(s[jr - 1], s[jr], a0[jr - 1], a0[jr])
        zr = float(np.interp(sr, s, zs))
    else:
        sr, zr = s[-1], zs[-1]
    L = sr - sb
    out["has_reverse"] = 1
    out["L_over_h"] = L / h
    hmax = 0.0
    cols = range(j1, jr)
    for j in cols:
        col = alongs[:, j]
        k = 0
        while k < col.size and col[k] < 0:
            k += 1
        if k == 0:
            continue
        hh = agl[-1] if k == col.size else _zero_cross(agl[k - 1], agl[k], col[k - 1], col[k])
        hmax = max(hmax, hh)
    out["H_over_h"] = hmax / h
    # функция тока: ψ_k = ∫₀^{z_k} u·e dz, u·e(0) = 0 (прилипание)
    zz = np.concatenate([[0.0], agl])
    aa = np.concatenate([np.zeros((1, alongs.shape[1])), alongs], axis=0)
    psi = np.concatenate([np.zeros((1, aa.shape[1])), np.cumsum(0.5 * (aa[1:] + aa[:-1]) * np.diff(zz)[:, None], axis=0)])[1:]
    sub = psi[:, j1:jr]
    kc, jc = np.unravel_index(int(np.argmin(sub)), sub.shape)
    out["xc_over_h"] = (s[j1 + jc] - sb) / h
    out["zc_over_h"] = agl[kc] / h
    out["shadow_angle_deg"] = float(np.degrees(np.arctan2(zb - zr, L))) if L > 0 else -1.0
    return out[()]
