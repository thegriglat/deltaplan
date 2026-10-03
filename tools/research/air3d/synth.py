"""Синтетические рельефы и проверки эталона (AM-01): слова пилота (docs/archive/plan/wind-field.md → «Проверка» 3–7),
тепловые условия прототипа в 3D, сходимость по клетке, потенциальное обтекание для сравнения.

  ../heat_ca/.venv/bin/python synth.py pilot      → out/ref/pilot.json   (проверки 3–7)
  ../heat_ca/.venv/bin/python synth.py heat       → out/ref/heat.json    (тепловые сценарии 1–4)
  ../heat_ca/.venv/bin/python synth.py cells      → out/ref/synth_cells.json (Аньези 400…25 м)
Замеры — под flock /tmp/heat_ca_gpu.lock.
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np

import air as A

HERE = Path(__file__).resolve().parent
OUT = HERE / "out" / "ref"
OUT.mkdir(parents=True, exist_ok=True)
N_DAY = 0.01                                   # «обычный день», 1/с
GAM_N = N_DAY ** 2 * A.THETA0 / A.G             # dθ̄/dz, К/м (3,06 К/км)


def jdump(obj, path):
    def conv(o):
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
        if isinstance(o, np.bool_):
            return bool(o)
        raise TypeError(type(o))
    Path(path).write_text(json.dumps(obj, ensure_ascii=False, indent=1, default=conv))


# ============================================================================== рельефы
def agnesi(x, H, L):
    return H / (1 + (x / L) ** 2)


def hill3d(X, Y, H, L):
    return H / (1 + (X ** 2 + Y ** 2) / L ** 2) ** 1.5


def ridge3d(X, Y, H, L, half_len, end_L=None):
    """Хребет вдоль y длиной 2·half_len, поперёк — Аньези полуширины L, концы скруглены."""
    end_L = end_L or L
    e = np.exp(-np.maximum(np.abs(Y) - half_len, 0) ** 2 / (2 * end_L ** 2))
    return agnesi(X, H, L) * e


def saddle3d(X, Y, H=500.0, depth=250.0, L=600.0, s=400.0, half_len=3500.0):
    """Хребет H вдоль y с седловиной глубиной depth шириной ~2,4 s (по полувысоте) в y = 0."""
    crest = H - depth * np.exp(-Y ** 2 / (2 * s ** 2))
    e = np.exp(-np.maximum(np.abs(Y) - half_len, 0) ** 2 / (2 * L ** 2))
    return crest / (1 + (X / L) ** 2) * e


# ============================================================================== сетки и запуск
def grid2d(dx, Lx, top, dz=None, ny=16):
    dz = dz or dx / 2
    nx = int(round(Lx / dx)); nx += nx % 2
    nz = int(math.ceil(top / dz)) + 1; nz += nz % 2
    return A.Grid(dx, nx, ny, dz, -dz, nz, -nx * dx / 2, -ny * dx / 2)


def grid3d(dx, L, top, dz=None):
    dz = dz or dx / 2
    n = int(round(L / dx)); n += n % 2
    nz = int(math.ceil(top / dz)) + 1; nz += nz % 2
    return A.Grid(dx, n, n, dz, -dz, nz, -n * dx / 2, -n * dx / 2)


def XY(g):
    return np.meshgrid(g.x, g.y)


def const_gam(val):
    return lambda z: np.full_like(np.asarray(z, float), val)


def cbl_gam(z_i, gam_above, gam_inv=None, inv_depth=0.0):
    """Слой перемешивания (dθ̄/dz = 0) до z_i, над ним — gam_inv на inv_depth (инверсия), выше gam_above."""
    def f(z):
        z = np.asarray(z, float)
        g = np.where(z < z_i, 0.0, gam_above)
        if gam_inv is not None:
            g = np.where((z >= z_i) & (z < z_i + inv_depth), gam_inv, g)
        return g
    return f


def sun_flux(hc, dx, az, el, H0=330.0, diffuse=0.10, lw=40.0, sky_heat=1.0):
    """Поток тепла (Вт/м² на горизонтальную площадь) от солнца (азимут от севера, высота) — как
    weather.Day.heat_flux: H0·[max(0, cos угла к склону) + diffuse·sin h] − выхолаживание lw."""
    gy, gx = np.gradient(hc, dx)
    e, a = math.radians(el), math.radians(az)
    sx, sy, sz = math.cos(e) * math.sin(a), math.cos(e) * math.cos(a), math.sin(e)
    cos_inc = -gx * sx - gy * sy + sz
    return H0 * sky_heat * (np.clip(cos_inc, 0, None) + diffuse * max(sz, 0)) - lw


def run(g, hc, case, prm=None, dtype=np.float32, max_outer=3000, verbose=False, finalize=True, taper=True):
    prm = prm or A.Params()
    S = A.Air(g, hc, case, prm, dtype=dtype, taper=taper)
    t0 = time.perf_counter()
    S.init_background()
    st = S.solve(max_outer=max_outer, verbose=verbose)
    if finalize:
        S.finalize()
    S.t_total = time.perf_counter() - t0
    return S


def info(S):
    last = S.hist[-1] if S.hist else {}
    return dict(status=S.status, iters=S.outer, t_solve=round(S.wall - S.t_check, 3),
                div_rms=last.get("div_rms"), mom_rms=last.get("mom_rms"), th_rms=last.get("th_rms"),
                closure=S.closure_info)


def agl(S, F, h):
    """Поле F (nz, ny, nx) на высоте h над рельефом (линейно по z; ниже центра первой воздушной
    клетки — её значение)."""
    g = S.g
    z = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
    zt = S.hc + h
    kf = (zt - z[0]) / g.dz
    kb = S.kb - 1
    kf = np.maximum(kf, kb)
    k0 = np.clip(np.floor(kf).astype(int), 0, g.nz - 2)
    a = np.clip(kf - k0, 0, 1)
    jj, ii = np.indices(S.hc.shape)
    f0 = F[k0, jj, ii]
    f1 = F[k0 + 1, jj, ii]
    f1 = np.where(np.isnan(f1), f0, f1)
    return (1 - a) * f0 + a * f1


def speed(u, v, w=None):
    return np.sqrt(u ** 2 + v ** 2 + (0 if w is None else w ** 2))


def potential(g, hc, ex=1.0, ey=0.0, U=1.0, sponge_axes="xy"):
    """Потенциальное обтекание на той же сетке (эталон формы): u = U − ∇φ, ∇²φ = ∇·U, непротекание
    у земли, приток/выход — U (проекция решателя с K = 1, 60 V-циклов)."""
    case = A.Case(U10=U / 1.8, wdir=math.degrees(math.atan2(-ex, -ey)) % 360)
    prm = A.Params(sponge_axes=sponge_axes)
    S = A.Air(g, hc, case, prm, dtype=np.float64)
    cp = S.cp
    # однородный фон (без профиля) и проводимости 1 (обычный Пуассон)
    S.ubg[...] = cp.where(S.tu != 0, U * ex, 0)
    S.vbg[...] = cp.where(S.tv != 0, U * ey, 0)
    S.ubg_np = S.ubg.get(); S.vbg_np = S.vbg.get()
    S._setup_boundary()
    one = np.ones(S.shape)
    Kx = one * (S.tu_np == 1); Ky = one * (S.tv_np == 1); Kz = one * (S.tw_np == 1)
    S.Kx, S.Ky, S.Kz = cp.asarray(Kx), cp.asarray(Ky), cp.asarray(Kz)
    S.mg = A.MG(Kx[1:-1, 1:-1, 1:] / g.dx ** 2, Ky[1:-1, 1:, 1:-1] / g.dx ** 2, Kz[1:, 1:-1, 1:-1] / g.dz ** 2,
                S.fluid_np[1:-1, 1:-1, 1:-1], np.float64)
    S.u[...] = cp.where(S.tu == 1, S.ubg, 0); S.v[...] = cp.where(S.tv == 1, S.vbg, 0); S.w[...] = 0
    S.set_ghosts_background()
    for _ in range(6):
        S.project(cycles=10, update_p=False)
    return S


# ============================================================================== проверки пилота
def upstream_profile(S, F, x_up, hs):
    """Среднее по y значение F на высотах hs над землёй в столбце x = x_up."""
    i = int(np.argmin(np.abs(S.g.x - x_up)))
    return np.array([np.nanmean(agl(S, F, h)[:, i]) for h in hs])


def check3(dx=50.0, N=0.0):
    """Аньези H = 300 м, L = 300 и 800 м (квази-2D): w на наветренной стороне 50–300 м против
    потенциального, разгон над гребнем 20–100 м против потенциального, круче — сильнее."""
    res = {}
    H = 300.0
    hs_w = [50, 100, 200, 300]
    hs_s = [20, 50, 100]
    for L in (300.0, 800.0):
        g = grid2d(dx, 16000 + 8 * L, 3500)
        hc = np.tile(agnesi(g.x, H, L), (g.ny, 1))
        case = A.Case(U10=5.0, wdir=270, gam=const_gam(N ** 2 * A.THETA0 / A.G))
        S = run(g, hc, case, A.Params(sponge_axes="x"))
        P = potential(g, hc, sponge_axes="x")
        u, v, w, th = S.centers()
        pu, pv, pw, _ = P.centers()
        x_up = -6000.0
        sp = speed(u, v); psp = speed(pu, pv)
        Uref_w = upstream_profile(S, sp, x_up, hs_w)
        Uref_s = upstream_profile(S, sp, x_up, hs_s)
        wind = g.x < 0
        row = dict(info=info(S), L=L, H=H, N=N, w=[], speedup=[],
                   taylor_lee=dict(B=2.0, A=3.0, dS_max=2.0 * min(H / L, 0.5)))
        for h, Ur in zip(hs_w, Uref_w):
            wm = np.nanmax(agl(S, w, h)[:, wind]) / Ur
            wp = np.nanmax(agl(P, pw, h)[:, wind]) / 1.0
            row["w"].append(dict(agl=h, model=wm, potential=wp, ratio=wm / wp))
        ic = int(np.argmin(np.abs(g.x)))
        for h, Ur in zip(hs_s, Uref_s):
            sm = np.nanmean(agl(S, sp, h)[:, ic]) / Ur - 1
            spp = np.nanmean(agl(P, psp, h)[:, ic]) - 1
            tl = 2.0 * min(H / L, 0.5) * math.exp(-3.0 * h / L)
            row["speedup"].append(dict(agl=h, model=sm, potential=spp, ratio=sm / spp, taylor_lee=tl))
        res[f"L{int(L)}"] = row
        np.savez_compressed(OUT / f"sec_check3_L{int(L)}_N{N:g}.npz", u=np.nanmean(u, axis=1), w=np.nanmean(w, axis=1),
                            pu=np.nanmean(pu, axis=1), pw=np.nanmean(pw, axis=1), x=g.x, z=g.z, h=hc[0])
        print("check3", L, json.dumps(row["w"]), json.dumps(row["speedup"]), row["info"]["iters"], flush=True)
    return res


def check4(dx=50.0, N=0.0):
    """Уединённый хребет H = 500 м (квази-2D, L = 500 м): на 2 H над подножием разгон ≤ 10 %,
    |w| ≤ 0,1·U/5; на 2,5 H — разгон ≤ 5 %; максимум разгона — у бровки у земли."""
    H, L = 500.0, 500.0
    g = grid2d(dx, 24000, 4500)
    hc = np.tile(agnesi(g.x, H, L), (g.ny, 1))
    case = A.Case(U10=5.0, wdir=270, gam=const_gam(N ** 2 * A.THETA0 / A.G))
    S = run(g, hc, case, A.Params(sponge_axes="x"))
    P = potential(g, hc, sponge_axes="x")
    pu, pv, pw, _ = P.centers()
    psp = speed(pu, pv)
    u, v, w, th = S.centers()
    sp = speed(u, v)
    z = g.z
    iu = int(np.argmin(np.abs(g.x + 8000)))
    up = np.nanmean(sp[:, :, iu], axis=1)          # профиль скорости вдали против ветра (по z над морем = над подножием)
    out = dict(info=info(S), H=H, L=L, N=N, U_aloft=S.U_a)
    near = np.abs(g.x) <= 3 * L                      # над хребтом ±3 L
    for mult in (1.0, 1.5, 2.0, 2.5, 3.0):
        k = int(np.argmin(np.abs(z - mult * H)))
        row = np.nanmean(sp[k], axis=0)
        rel = np.nanmax(row[near]) / up[k] - 1
        wmax = float(np.nanmax(np.abs(np.nanmean(w[k], axis=0))[near]))
        prel = np.nanmax(np.nanmean(psp[k], axis=0)[near]) - 1
        pwmax = float(np.nanmax(np.abs(np.nanmean(pw[k], axis=0))[near]))
        out[f"z{mult:g}H"] = dict(z=z[k], speedup_max=rel, w_absmax=wmax, w_limit=0.1 * case.U10 / 5.0,
                                  U_at_z=up[k], potential_speedup=prel, potential_w_over_U=pwmax)
    # где максимум разгона (над землёй, по отношению к скорости на той же высоте над землёй вдали)
    hs = [10, 25, 50, 100, 200, 400]
    best = None
    for h in hs:
        s_h = np.nanmean(agl(S, sp, h), axis=0)
        ref = np.nanmean(agl(S, sp, h)[:, iu])
        i = int(np.nanargmax(s_h))
        r = s_h[i] / ref - 1
        out.setdefault("speedup_by_agl", []).append(dict(agl=h, max=r, x=g.x[i]))
    np.savez_compressed(OUT / f"sec_check4_N{N:g}.npz", u=np.nanmean(u, axis=1), w=np.nanmean(w, axis=1),
                        x=g.x, z=g.z, h=hc[0])
    print("check4", json.dumps({k: v for k, v in out.items() if k != "info"}), flush=True)
    return out


def check5(dx=100.0, angles=(0.0, 15.0)):
    """Седловина: хребет H = 500 м с седловиной 250 м, ветер вдоль оси седловины (x) и под 15°."""
    res = {}
    g = grid3d(dx, 12800, 3000)
    X, Y = XY(g)
    hc = saddle3d(X, Y)
    for ang in angles:
        wdir = (270.0 - ang) % 360          # 0° — с запада вдоль x; 15° — с запад-юго-запада
        case = A.Case(U10=5.0, wdir=wdir, gam=const_gam(GAM_N))
        S = run(g, hc, case)
        u, v, w, th = S.centers()
        sp = speed(u, v)
        row = dict(info=info(S), angle=ang)
        j0 = int(np.argmin(np.abs(g.y)))
        i_sad = int(np.argmin(np.abs(g.x)))
        i_up = int(np.argmin(np.abs(g.x + 3000)))       # перед склоном (подножие ~ 3 L)
        i_lee = int(np.argmin(np.abs(g.x - 1500)))
        for h in (20, 50):
            s_sad = agl(S, sp, h)[j0, i_sad]
            s_up = agl(S, sp, h)[j0, i_up]
            row[f"ratio_{h}"] = s_sad / s_up
        uu, vv = agl(S, u, 20)[j0, i_sad], agl(S, v, 20)[j0, i_sad]
        row["dir_dev_20"] = math.degrees(math.atan2(vv, uu))   # отклонение от оси x
        row["lee50_over_Ua"] = agl(S, sp, 50)[j0, i_lee] / S.U_a
        row["lee50_over_up50"] = agl(S, sp, 50)[j0, i_lee] / agl(S, sp, 50)[j0, i_up]
        # за вершиной (для сравнения): y = 2500 м
        jp = int(np.argmin(np.abs(g.y - 2500)))
        row["lee50_behind_peak_over_up50"] = agl(S, sp, 50)[jp, i_lee] / agl(S, sp, 50)[j0, i_up]
        row["w_lee50_saddle"] = agl(S, w, 50)[j0, i_lee]
        row["w_lee50_peak"] = agl(S, w, 50)[jp, i_lee]
        res[f"a{int(ang)}"] = row
        np.savez_compressed(OUT / f"map_check5_a{int(ang)}.npz", s20=agl(S, sp, 20.0), u20=agl(S, u, 20.0), v20=agl(S, v, 20.0),
                            w50=agl(S, w, 50.0), x=g.x, y=g.y, h=hc)
        print("check5", json.dumps({k: v for k, v in row.items() if k != "info"}), row["info"]["iters"], flush=True)
    return res


def check6(dx=100.0, N=0.0):
    """Косой ветер: хребет H = 300 м, L = 500 м, длина 8 км; 0° и 45° к нормали."""
    res = {}
    g = grid3d(dx, 12800, 3000)
    X, Y = XY(g)
    hc = ridge3d(X, Y, 300.0, 500.0, 3000.0)
    for ang in (0.0, 45.0):
        case = A.Case(U10=5.0, wdir=(270.0 - ang) % 360, gam=const_gam(N ** 2 * A.THETA0 / A.G))
        S = run(g, hc, case)
        u, v, w, th = S.centers()
        sp = speed(u, v)
        mid = np.abs(g.y) < 1000
        wind = g.x < 0
        row = dict(info=info(S), angle=ang)
        for h in (50, 100, 200):
            row[f"wmax_{h}"] = float(np.nanmax(agl(S, w, h)[np.ix_(mid, wind)]))
        ic = int(np.argmin(np.abs(g.x)))
        up_i = int(np.argmin(np.abs(g.x + 4000)))
        for h in (20, 50):
            row[f"speedup_{h}"] = float(np.nanmean(agl(S, sp, h)[mid, ic]) / np.nanmean(agl(S, sp, h)[mid, up_i]) - 1)
        res[f"a{int(ang)}"] = row
        print("check6", json.dumps({k: v for k, v in row.items() if k != "info"}), row["info"]["iters"], flush=True)
    for h in (50, 100, 200):
        res[f"w45_over_w0_{h}"] = res["a45"][f"wmax_{h}"] / res["a0"][f"wmax_{h}"]
    return res


def check7(dx=100.0):
    """Устойчивость: сопка H = 500 м (L = 700 м), N = 0,02 1/с против нейтрального (N ≈ 0)."""
    res = {}
    g = grid3d(dx, 12800, 3500)
    X, Y = XY(g)
    hc = hill3d(X, Y, 500.0, 700.0)
    for name, N in (("neutral", 0.0), ("day", 0.01), ("stable", 0.02)):
        case = A.Case(U10=5.0, wdir=270, gam=const_gam(N ** 2 * A.THETA0 / A.G))
        S = run(g, hc, case)
        u, v, w, th = S.centers()
        sp = speed(u, v)
        j0 = int(np.argmin(np.abs(g.y)))
        i0 = int(np.argmin(np.abs(g.x)))
        up_i = int(np.argmin(np.abs(g.x + 5000)))
        row = dict(info=info(S), N=N)
        for h in (50, 100):
            ref = agl(S, sp, h)[j0, up_i]
            s = agl(S, sp, h)
            # фланги: вдоль x = 0, |y| от 0,7 до 1,5 км (подножие склона сбоку)
            fl = (np.abs(g.y) > 700) & (np.abs(g.y) < 1500)
            row[f"flank_max_{h}"] = float(np.nanmax(s[fl, i0]) / ref)
            row[f"top_{h}"] = float(s[j0, i0] / ref)
            row[f"w_windward_max_{h}"] = float(np.nanmax(agl(S, w, h)[j0, :i0]) / ref)
        res[name] = row
        print("check7", name, json.dumps({k: v for k, v in row.items() if k != "info"}), row["info"]["iters"], flush=True)
    return res


def cmd_pilot(which):
    res = {}
    path = OUT / "pilot.json"
    if path.exists():
        res = json.loads(path.read_text())
    for c in which:
        res[f"check{c}"] = globals()[f"check{c}"]()
        jdump(res, path)
        if c in (3, 4):
            res[f"check{c}_N001"] = globals()[f"check{c}"](N=N_DAY)
            jdump(res, path)


# ============================================================================== тепловые сценарии
def heat_ridge(dx=100.0):
    g = grid3d(dx, 12800, 3500)
    X, Y = XY(g)
    # хребет H = 500 м: восточный склон круче (L 500), западный положе (L 900), длина 6 км
    Lx = np.where(X > 0, 500.0, 900.0)
    hc = 500.0 / (1 + (X / Lx) ** 2) * np.exp(-np.maximum(np.abs(Y) - 2500, 0) ** 2 / (2 * 700.0 ** 2))
    return g, hc


def heat_case(name, g, hc):
    zi = 2000.0
    if name == "one_slope":              # солнце с востока, 40°: прогрет восточный склон, западный в тени
        return A.Case(U10=0.0, gam=cbl_gam(zi, 5.8e-3), z_i=zi, H=sun_flux(hc, g.dx, 90.0, 40.0))
    if name == "both":                   # солнце в зените (симметрично)
        return A.Case(U10=0.0, gam=cbl_gam(zi, 5.8e-3), z_i=zi, H=sun_flux(hc, g.dx, 180.0, 89.9))
    if name == "wind":                   # как one_slope + ветер 3 м/с с запада (поперёк)
        return A.Case(U10=3.0, wdir=270.0, gam=cbl_gam(zi, 5.8e-3), z_i=zi, H=sun_flux(hc, g.dx, 90.0, 40.0))
    if name == "inversion":              # инверсия на 1500 м: +6 К на 300 м, выше 5,8 К/км
        return A.Case(U10=0.0, gam=cbl_gam(1500.0, 5.8e-3, gam_inv=20e-3, inv_depth=300.0), z_i=1500.0,
                      H=sun_flux(hc, g.dx, 90.0, 40.0))
    raise KeyError(name)


def cmd_heat():
    res = {}
    g, hc = heat_ridge()
    for name in ("one_slope", "both", "wind", "inversion"):
        case = heat_case(name, g, hc)
        # нагрев до самых стенок (без гашения у края): иначе остывший край области сам
        # задаёт циркуляцию масштаба области (опускание у стенок, подъём над всей долиной)
        S = run(g, hc, case, taper=False)
        u, v, w, th = S.centers()
        hb = S.heat_budget()
        mid = np.abs(g.y) < 1000
        wy = lambda F, h: np.nanmean(agl(S, F, h)[mid], axis=0)     # средний по середине хребта профиль по x
        row = dict(info=info(S), budget=hb)
        w300 = wy(w, 300.0); w100 = wy(w, 100.0); u50 = wy(u, 50.0)
        i_max = int(np.nanargmax(w300))
        row["w300_max"] = float(w300[i_max]); row["w300_max_x"] = float(g.x[i_max])
        row["w100_max"] = float(np.nanmax(w100)); row["w100_max_x"] = float(g.x[int(np.nanargmax(w100))])
        # приток у подножия прогретого (восточного) склона: u на 50 м AGL при x = +1,5 км (к склону — u < 0)
        i_foot_e = int(np.argmin(np.abs(g.x - 1500))); i_foot_w = int(np.argmin(np.abs(g.x + 2500)))
        row["u50_east_foot"] = float(u50[i_foot_e]); row["u50_west_foot"] = float(u50[i_foot_w])
        # опускание над долиной (3–5 км от гребня), средний w на 300 м
        val = (np.abs(g.x) > 3000) & (np.abs(g.x) < 5000)
        row["w300_valley_mean"] = float(np.nanmean(w300[val]))
        # теневой склон (запад, x −1…−0,3 км)
        sh = (g.x > -1000) & (g.x < -300)
        row["w100_shade_mean"] = float(np.nanmean(w100[sh]))
        # симметрия (both): |w(x) − w(−x)| / max
        row["asym300"] = float(np.nanmax(np.abs(w300 - w300[::-1])) / max(np.nanmax(np.abs(w300)), 1e-9))
        # по высоте над гребнем: max w в столбе над гребнем (±500 м)
        z = g.z
        col = np.abs(g.x) < 700
        wz = np.nanmax(np.nanmean(w[:, mid][:, :, col], axis=1), axis=1)
        row["w_profile_crest"] = [dict(z=float(z[k]), w=float(wz[k])) for k in range(0, g.nz, 4)]
        zi = case.z_i
        below = (z > zi - 700) & (z < zi - 300); above = z > zi + 400
        row["w_below_zi"] = float(np.nanmax(wz[below])); row["w_above_zi"] = float(np.nanmax(np.abs(wz[above])))
        # растекание под крышкой: |u| у z_i − 150 м над гребнем против |u| на половине слоя
        k_top = int(np.argmin(np.abs(z - (zi - 150)))); k_mid = int(np.argmin(np.abs(z - zi / 2)))
        spread = lambda k: float(np.nanmax(np.abs(np.nanmean(u[k][mid], axis=0))[(np.abs(g.x) > 700) & (np.abs(g.x) < 3000)]))
        row["u_spread_top"] = spread(k_top); row["u_spread_mid"] = spread(k_mid)
        # наклон по ветру: x максимума w на 300 и на 1000 м AGL
        w1000 = wy(w, 1000.0)
        row["x_wmax_300"] = float(g.x[int(np.nanargmax(w300))]); row["x_wmax_1000"] = float(g.x[int(np.nanargmax(w1000))])
        res[name] = row
        print(name, json.dumps({k: v for k, v in row.items() if k not in ("info", "w_profile_crest")}),
              row["info"]["status"], row["info"]["iters"], row["info"]["t_solve"], flush=True)
        (HERE / "fields").mkdir(exist_ok=True)
        np.savez_compressed(HERE / "fields" / f"heat_{name}.npz", u=np.float32(u), v=np.float32(v), w=np.float32(w), th=np.float32(th),
                            hc=hc, dx=g.dx, dz=g.dz, z_bot=g.z_bot, x0=g.x0, y0=g.y0)
        jdump(res, OUT / "heat.json")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "pilot":
        cmd_pilot([int(c) for c in (sys.argv[2] if len(sys.argv) > 2 else "34567")])
    elif cmd == "heat":
        cmd_heat()
