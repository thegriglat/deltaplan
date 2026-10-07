"""AP-10: срыв за подветренной бровкой (SEPARATION) и огибающая «линии тени» (ENVELOPE, ENVELOPE_REAL).

Запуск (CPU, ~2–4 мин на 16 процессах):
  /home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python \
      tools/research/air_phase/analysis/AP-10/run.py [--plan DIR] [--results DIR] [--jobs N]

Вход — только чтение: план P2 (`plan.json`) и части P3 (`cases`, `fields/f`, `inputs/*`, `window/*`).
Выход (P7): summary.json, fig_*.png рядом со скриптом; out/bubble_v2.csv — `bubble` P3, пересчитанный bubble.py
(AP-10: сечение через бровку окна, fr_local по профилю притока) + диагностика пузыря и подгонка модели игры.

Части:
  1. SEPARATION: пузырь по окну 100 м и по сетке 400 м против s, Fr, H, угла ветра; пороги; подгонка параметров
     `lee` игры (`atmosphere.gd::_lee_flow`, `ground_field.gd` линия тени) к сечению поля решателя.
  2. Диагностика длины пузыря: определения длины, толщина слоя смешения и скорость её роста против литературы.
  3. ENVELOPE против эталона (окно 100 м): скорость и w на 50–300 м над огибающей и за пузырём, простые метрики
     подветренной зоны, сходимость; ENVELOPE_REAL: доля сошедшихся по variant, изменение поля у сошедшихся.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import h5py
import numpy as np
from scipy.optimize import least_squares

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
import bubble as B  # noqa: E402

AGL = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], float)
SER = {"SEPARATION": 4, "ENVELOPE": 6, "ENVELOPE_REAL": 7}
X0 = -19200.0
DXD = 400.0
EDGE = 5
GAME_LEE = dict(shadow_angle_deg=12.0, rotor_reverse=0.9, rotor_height_fraction=0.4, depth_scale_m=40.0,
                relief_scale_m=60.0, shear_layer_m=60.0, wind_reduction=0.6, danger_sink_per_wind=0.7,
                upwind_distances_m=[60, 150, 300, 600, 1000, 1600])      # configs/atmosphere.json → lee (06.10.2026)
LIT = {  # литература (docs/plan/air_model_progress.md, AM-08, 01.10.2026; источники — section.md)
    "ridge2d_s063_L_over_h": 3.5, "hill3d_s063_L_over_h": 1.6, "perdigao_L_over_h": 2.8,
    "sep_onset_slope_2d": 0.27, "sep_onset_slope_3d": 0.36, "urev_over_U": [-0.2, -0.1],
    "mixing_layer_S": [0.06, 0.11],   # Pope 2000 §5.4: S = (U_c/U_s)·dδ/dx, δ = y_0,9 − y_0,1
    "bfs_L_over_h": [6.0, 8.0],       # обратный уступ, Eaton & Johnston 1981 (обзор), Driver & Seegmiller 1985: 6,26
}


def wind_e(wdir):
    p = math.radians(wdir)
    return (-math.sin(p), -math.cos(p))


# ============================================================================== индекс
def build_index(plan_dir, res_dir):
    P = json.loads((Path(plan_dir) / "plan.json").read_text())
    rel = {r["relief_id"]: r for r in P["reliefs"]}
    lines = {l["line_id"]: l for l in P["lines"]}
    rows = []
    for p in sorted(Path(res_dir).glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
            sel = np.nonzero(np.isin(c["series"], list(SER.values())))[0]
            if sel.size == 0:
                continue
            wid = list(h["window/case_id"][:]) if "window" in h else []
            for j in sel:
                r = c[j]
                L = lines[int(r["line_id"])]
                R = rel[int(r["relief_id"])]
                d = {k: (r[k].item() if hasattr(r[k], "item") else r[k]) for k in c.dtype.names}
                d.update(part=str(p), row=int(j), win=(wid.index(r["case_id"]) if r["case_id"] in wid else -1),
                         variant=L.get("variant", ""), shape=R["shape"], slope=float(R["slope"]), h_m=float(R["h_m"]),
                         ref_line_id=int(L["ref_line_id"]), relief_name=R["name"],
                         angle=float(L["numerics"]["envelope_angle_deg"]), wall=L["numerics"]["envelope_wall"])
                rows.append(d)
    return P, rows


# ============================================================================== сечение
def sec_data(f, agl, x0, y0, dx, ground, e, center):
    s, px, py = B.section(f.shape[-2], f.shape[-1], x0, y0, dx, e, center)
    al = B.bilinear(f[0], x0, y0, dx, px, py) * e[0] + B.bilinear(f[1], x0, y0, dx, px, py) * e[1]
    w = B.bilinear(f[2], x0, y0, dx, px, py)
    zs = B.bilinear(np.asarray(ground, float), x0, y0, dx, px, py)
    return s, zs, al, w


def brink_index(s, zs):
    d1 = np.gradient(zs, s)
    d2 = np.gradient(d1, s)
    il = int(np.argmin(d1))
    return int(np.argmin(d2[: il + 1])), d1


def game_lee(s, zs, agl, p, wr, shear, dmax=15000.0):
    """Модель игры на сечении: сила зоны lee (K, n) и ядро ротора; линия тени — max_d (z(s−d) − d·tanθ), гребень —
    max_d z(s−d) (непрерывные d ≤ dmax; в игре — список upwind_distances_m)."""
    th, D, R, rr, fh = p
    t = math.tan(math.radians(th))
    n = s.size
    ds = s[1] - s[0]
    nd = int(dmax / ds)
    shadow = np.full(n, -1e9)
    crest = zs.copy()
    for k in range(1, min(nd, n)):
        shadow[k:] = np.maximum(shadow[k:], zs[:-k] - k * ds * t)
        crest[k:] = np.maximum(crest[k:], zs[:-k])
    relief = np.maximum(crest - zs, 0.0)
    zabs = zs[None] + agl[:, None]
    depth = shadow[None] - zabs
    lee = np.clip((depth + shear) / (D + shear), 0, 1) * np.clip(relief / max(R, 1e-3), 0, 1)[None]
    core = lee * np.exp(-agl[:, None] / np.maximum(fh * relief[None], 1.0))
    return lee, core, shadow, relief


def fit_game(s, zs, al, w, agl, u_ref, U, theta, s_hi):
    """Подгонка (D, R, rr, f, слой сдвига) модели игры к u·e сечения (в долях U_sat) внутри зоны: от бровки до
    присоединения (s ≤ s_hi), до 200 м над гребнем; угол тени θ — геометрия пузыря (бровка → присоединение).
    wind_reduction = 0,6 как в игре (с rotor_reverse вырождены: при большом f у земли важна лишь сумма wr + rr).
    Затем коэффициент опускания k: w ≈ −k·u(agl)·lee. → dict или None."""
    wr = GAME_LEE["wind_reduction"]
    ib, _ = brink_index(s, zs)
    m = (s >= s[ib]) & (s <= s_hi)
    kk = agl <= 1100
    S, Z = s[m], zs[m]
    obs = al[kk][:, m] / U
    ur = u_ref[kk][:, None] / U
    a = agl[kk]
    top = (Z[None] + a[:, None]) <= Z[0] + 200.0
    if top.sum() < 20:
        return None

    def model(p):
        lee, core, _, _ = game_lee(S, Z, a, [theta, p[0], p[1], p[2], p[3]], wr, p[4])
        return ur * (1 - lee * wr - p[2] * core), lee

    def res(p):
        return (model(p)[0] - obs)[top]

    best = None
    for D0 in (20.0, 80.0, 250.0):
        for f0, sh0 in ((0.2, 60.0), (0.6, 200.0)):
            try:
                r = least_squares(res, [D0, 60.0, 0.9, f0, sh0],
                                  bounds=([1.0, 1.0, 0.0, 0.02, 0.0], [1000.0, 500.0, 3.0, 5.0, 1000.0]),
                                  diff_step=[0.05, 0.05, 0.02, 0.05, 0.05], max_nfev=400)
            except Exception:
                continue
            if best is None or r.cost < best.cost:
                best = r
    if best is None:
        return None
    p = best.x
    _, lee = model(p)
    q = lee * ur
    wobs = w[kk][:, m] / U
    kq = float(-(wobs[top] * q[top]).sum() / max((q[top] ** 2).sum(), 1e-9))
    g0 = [GAME_LEE["shadow_angle_deg"], GAME_LEE["depth_scale_m"], GAME_LEE["relief_scale_m"], GAME_LEE["rotor_reverse"],
          GAME_LEE["rotor_height_fraction"]]
    lee0, core0, _, _ = game_lee(S, Z, a, g0, GAME_LEE["wind_reduction"], GAME_LEE["shear_layer_m"])
    r0 = ur * (1 - lee0 * GAME_LEE["wind_reduction"] - g0[3] * core0)
    q0 = lee0 * ur
    return dict(theta_deg=float(theta), depth_m=float(p[0]), relief_m=float(p[1]), rotor_reverse=float(p[2]),
                rotor_height_fraction=float(p[3]), wind_reduction=wr, shear_layer_m=float(p[4]), sink_per_wind=kq,
                rms_fit=float(np.sqrt(np.mean(best.fun ** 2))), rms_game_now=float(np.sqrt(np.mean((r0 - obs)[top] ** 2))),
                rms_no_zone=float(np.sqrt(np.mean((ur - obs)[top] ** 2))),
                w_rms_game_now=float(np.sqrt(np.mean((wobs + GAME_LEE["danger_sink_per_wind"] * q0)[top] ** 2))),
                w_rms_fit=float(np.sqrt(np.mean((wobs + kq * q)[top] ** 2))), n_pts=int(top.sum()))


def lee_direct(s, zs, al, w, agl, h, U, u_ref, theta, L):
    """Параметры `lee` игры по их смыслу прямо из сечения (зона — от бровки до присоединения):
    rotor_reverse = 1 − wr − r₀ (r₀ = u·e/u(25 м) у земли: пик и среднее по обратной зоне; в игре у земли
    u·(1 − wr) − rr·u); rotor_height_fraction = H_col/(rel·ln(rr/(1 − wr))) — высота нуля u·e в колонне пика
    (rel — превышение бровки над землёй там); depth_scale_m — медиана (линия тени − верх обратного слоя) по колонкам
    обратной зоны; shear_layer_m — медиана (высота, где u·e/u(agl) = 0,9 − линия тени) по колонкам зоны;
    danger_sink_per_wind = −⟨w⟩/⟨u(agl)⟩ под линией тени (agl ≥ 50 м), sink_band_per_wind — то же в полосе 200 м над ней."""
    wr = GAME_LEE["wind_reduction"]
    ib, _ = brink_index(s, zs)
    sb, zb = s[ib], zs[ib]
    t = math.tan(math.radians(theta))
    m = (s > sb) & (s < sb + L)
    a0 = al[0]
    rev = m & (a0 < 0)
    if not rev.any():
        return {}
    out = {}
    r0 = a0[rev] / u_ref[0]
    out["r0_peak"] = float(r0.min())
    out["r0_mean"] = float(r0.mean())
    out["rotor_reverse"] = float(1 - wr - r0.min())
    out["rotor_reverse_mean"] = float(1 - wr - r0.mean())
    jp = int(np.nonzero(rev)[0][np.argmin(a0[rev])])
    col = al[:, jp]
    k = int(np.argmax(col >= 0))
    htop = B._zero_cross(agl[k - 1], agl[k], col[k - 1], col[k]) if k > 0 else agl[0]
    rel = max(zb - zs[jp], 1.0)
    rr = out["rotor_reverse"]
    out["rotor_height_fraction"] = float(htop / (rel * math.log(rr / (1 - wr)))) if rr > (1 - wr) * 1.05 else float("nan")
    zsh = zb - (s - sb) * t
    dd, sh, wz, uz, wb, ub = [], [], [], [], [], []
    for j in np.nonzero(m)[0]:
        c = al[:, j]
        za = zs[j] + agl
        if a0[j] < 0:
            kk = int(np.argmax(c >= 0))
            ht = B._zero_cross(agl[kk - 1], agl[kk], c[kk - 1], c[kk]) if kk > 0 else agl[0]
            dd.append(zsh[j] - (zs[j] + ht))
        z9 = iso_up(c / u_ref, za, 0.9)
        if np.isfinite(z9):
            sh.append(z9 - zsh[j])
        below = (za < zsh[j]) & (agl >= 50)
        wz += list(w[below, j]); uz += list(u_ref[below])
        band = (za >= zsh[j]) & (za < zsh[j] + 200.0)
        wb += list(w[band, j]); ub += list(u_ref[band])
    out["depth_scale_m"] = float(np.median(dd)) if dd else float("nan")
    out["shear_layer_m"] = float(np.median(sh)) if sh else float("nan")
    out["danger_sink_per_wind"] = float(-np.mean(wz) / np.mean(uz)) if wz else float("nan")
    out["sink_band_per_wind"] = float(-np.mean(wb) / np.mean(ub)) if wb else float("nan")
    return out


def iso_up(col, z, v):
    for k in range(1, col.size):
        if col[k - 1] < v <= col[k]:
            return z[k - 1] + (z[k] - z[k - 1]) * (v - col[k - 1]) / (col[k] - col[k - 1])
    return np.nan


def bubble_diag(s, zs, al, w, agl, h, U):
    """Определения длины, слой смешения, w — на сечении по ветру через бровку."""
    out = {}
    ib, d1 = brink_index(s, zs)
    sb, zb = s[ib], zs[ib]
    a0 = al[0]
    rv = np.nonzero(a0[ib:] < 0)[0]
    zmin = zs[ib:].min()
    foot = ib + int(np.argmax(zs[ib:] - zmin < 0.05 * h))
    out["foot_over_h"] = float((s[foot] - sb) / h)
    if rv.size == 0:
        return out
    j1 = ib + int(rv[0])
    jr = j1
    while jr < s.size and a0[jr] < 0:
        jr += 1
    sr = B._zero_cross(s[jr - 1], s[jr], a0[jr - 1], a0[jr]) if jr < s.size else s[-1]
    out["sep_over_h"] = float((s[j1] - sb) / h)
    out["reatt_over_h"] = float((sr - sb) / h)
    out["L_sep_over_h"] = float((sr - s[j1]) / h)
    out["L_past_foot_over_h"] = float((sr - s[foot]) / h)
    out["reatt_at_edge"] = int(jr >= s.size)
    strong = np.nonzero(a0[ib:] < -0.05 * U)[0]
    out["L_strong_over_h"] = float((s[ib + strong[-1]] - sb) / h) if strong.size else 0.0
    # 2-я зона обратного течения дальше по ветру (волна/ротор)
    rest = a0[jr:] < 0 if jr < s.size else np.zeros(0, bool)
    out["second_reverse"] = int(rest.any())
    # слой смешения: δ = z(0,9 U_top) − z(0,1 U_top) в абсолютной высоте, станции от отрыва до присоединения
    st, dl, us_l = [], [], []
    for jj in range(j1, min(jr, s.size)):
        za = zs[jj] + agl
        col = al[:, jj]
        ut = col[agl <= 1100].max()
        umin = col[agl <= 400].min()
        z1, z9 = iso_up(col, za, umin + 0.1 * (ut - umin)), iso_up(col, za, umin + 0.9 * (ut - umin))
        if np.isfinite(z1) and np.isfinite(z9):
            st.append(s[jj]); dl.append(z9 - z1); us_l.append((ut, umin))
    if len(st) >= 4:
        st, dl = np.array(st), np.array(dl)
        k = np.polyfit(st, dl, 1)[0]
        ut = float(np.mean([u[0] for u in us_l])); um = float(np.mean([u[1] for u in us_l]))
        Us, Uc = ut - um, 0.5 * (ut + um)
        out.update(shear_ddelta_ds=float(k), shear_delta0_m=float(dl[0]), shear_delta1_m=float(dl[-1]),
                   shear_Us=Us, shear_Uc=Uc, shear_S_pope=float(k * Uc / max(Us, 1e-6)))
    m = (s > sb) & (s < sr)
    k3 = (agl >= 50) & (agl <= 300)
    out["w_lee_mean_over_U"] = float(w[k3][:, m].mean() / U) if m.any() else 0.0
    out["w_lee_min_over_U"] = float(w[k3][:, (s > sb) & (s < sr + 3 * h)].min() / U)
    return out


# ============================================================================== часть 1: SEPARATION
def sep_case(arg):
    row, ctx = arg
    e = wind_e(row["wdir_from_deg"])
    h, U, N = row["h_m"], row["u_sat"], row["n_bv"]
    inflow = (ctx["alpha"], ctx["max_profile"])
    u_ref = B.inflow_speed(AGL, U, *inflow)
    out = dict(case_id=row["case_id"], dx_m=row["dx_m"])
    with h5py.File(row["part"], "r") as hf:
        old = hf["bubble"][row["row"]]
        out.update({f"old_{k}": float(old[k]) for k in old.dtype.names})
        if row["dx_m"] == 100:
            q = row["win"]
            ny, nx = hf["window/shape"][q][-2:]
            f = hf["window/fields"][q][:, :, :ny, :nx].astype(np.float32)
            g = hf["window/hc"][q][:ny, :nx].astype(float)
            x0, y0 = float(hf["window/x0_m"][q]), float(hf["window/y0_m"][q])
            c = (float(hf["window/brink_x_m"][q]), float(hf["window/brink_y_m"][q]))
            dx = 100.0
            out["win_status"] = int(hf["window/status"][q])
            out["win_iters"] = int(hf["window/iters"][q])
            edge = 0
        else:
            f = hf["fields/f"][row["row"]].astype(np.float32)
            g = hf["inputs/hc"][row["row"]].astype(float)
            x0 = y0 = X0
            c = (0.0, 0.0)
            dx = DXD
            edge = EDGE
    b = B.bubble(f, AGL, x0, y0, dx, g, e, h, U, N, center=c, edge=edge, inflow=inflow)
    out.update({k: float(b[k]) for k in b.dtype.names})
    if row["wdir_from_deg"] != 270.0:          # составляющая поперёк хребта (нормаль — +x)
        bn = B.bubble(f, AGL, x0, y0, dx, g, (1.0, 0.0), h, U, N, center=c, edge=edge, inflow=inflow)
        out.update({f"n_{k}": float(bn[k]) for k in ("has_reverse", "L_over_h", "H_over_h", "urev_over_U", "shadow_angle_deg")})
    s, zs, al, w = sec_data(f, AGL, x0, y0, dx, g, e, c)
    out.update(bubble_diag(s, zs, al, w, AGL, h, U))
    if b["has_reverse"]:
        ib, _ = brink_index(s, zs)
        fg = fit_game(s, zs, al, w, AGL, u_ref, U, float(b["shadow_angle_deg"]), s[ib] + b["L_over_h"] * h)
        if fg:
            out.update({f"fit_{k}": v for k, v in fg.items()})
        out.update({f"lee_{k}": v for k, v in lee_direct(s, zs, al, w, AGL, h, U, u_ref, float(b["shadow_angle_deg"]),
                                                        b["L_over_h"] * h).items()})
    if row["dx_m"] == 100:
        out["sec"] = dict(s=s.astype(np.float32), zs=zs.astype(np.float32), al=al.astype(np.float16), w=w.astype(np.float16))
    return out


# ============================================================================== часть 3: ENVELOPE
def col_at(f, agl, z_agl):
    """f (C, K, n) колонны; z_agl (n,) → (C, n) линейно по высоте; ниже 1-го уровня — значение 1-го уровня, < 0 — NaN."""
    C, K, n = f.shape
    out = np.full((C, n), np.nan, np.float32)
    for i in range(n):
        if z_agl[i] < 0 or z_agl[i] > agl[-1]:
            continue
        for c in range(C):
            out[c, i] = np.interp(z_agl[i], agl, f[c, :, i])
    return out


def ref_on_400(wf, hw, x0w, y0w, nxw, nyw, z_abs_400, cells):
    """Эталон окна 100 м на клетках 400 м: среднее по 4×4 колонкам окна на абсолютной высоте z_abs (клетки, где
    ≥ 12 из 16 колонок над землёй). cells — (j, i) клеток 400 м внутри окна. → (3, n) u, v, w."""
    out = np.full((3, len(cells)), np.nan, np.float32)
    for q, (j, i) in enumerate(cells):
        xc0 = X0 + DXD * i
        yc0 = X0 + DXD * j
        ii = int(round((xc0 - x0w) / 100.0)); jj = int(round((yc0 - y0w) / 100.0))
        sub = wf[:3, :, jj:jj + 4, ii:ii + 4].reshape(3, AGL.size, 16)
        gz = hw[jj:jj + 4, ii:ii + 4].reshape(16)
        za = z_abs_400[q] - gz
        ok = za >= 0
        if ok.sum() < 12:
            continue
        v = col_at(sub[:, :, ok], AGL, za[ok])
        out[:, q] = np.nanmean(v, axis=1)
    return out


def env_case(arg):
    env, ref, base = arg
    e = wind_e(env["wdir_from_deg"])
    U = env["u_sat"]
    with h5py.File(env["part"], "r") as hf:
        fe = hf["fields/f"][env["row"]].astype(np.float32)
        he = hf["inputs/h_eff"][env["row"]].astype(float)
        hc = hf["inputs/hc"][env["row"]].astype(float)
    with h5py.File(ref["part"], "r") as hf:
        q = ref["win"]
        nyw, nxw = hf["window/shape"][q][-2:]
        wf = hf["window/fields"][q][:, :, :nyw, :nxw].astype(np.float32)
        hw = hf["window/hc"][q][:nyw, :nxw].astype(float)
        x0w, y0w = float(hf["window/x0_m"][q]), float(hf["window/y0_m"][q])
        bx, by = float(hf["window/brink_x_m"][q]), float(hf["window/brink_y_m"][q])
        rb = hf["bubble"][ref["row"]]
    with h5py.File(base["part"], "r") as hf:
        fb = hf["fields/f"][base["row"]].astype(np.float32)
    sp = 4 * 100.0                                        # губка окна
    xs = X0 + DXD / 2 + DXD * np.arange(96)
    cells = [(j, i) for j in range(96) for i in range(96)
             if xs[i] - 200 >= x0w + sp and xs[i] + 200 <= x0w + 100 * nxw - sp
             and xs[j] - 200 >= y0w + sp and xs[j] + 200 <= y0w + 100 * nyw - sp]
    J = np.array([c[0] for c in cells]); I = np.array([c[1] for c in cells])
    sx = (xs[I] - bx) * e[0] + (xs[J] - by) * e[1]          # по ветру от бровки
    shadow = (he[J, I] - hc[J, I]) > 1.0
    zones = {"shadow": shadow, "behind": (~shadow) & (sx > 0), "upwind": sx < -400}
    res = dict(case_id=env["case_id"], ref_case_id=ref["case_id"], base_case_id=base["case_id"], angle=env["angle"],
               wall=env["wall"], status=env["status"], iters=env["iters"], spread=env["late_spread60_p90"],
               base_status=base["status"], base_iters=base["iters"], base_spread=base["late_spread60_p90"],
               shape=env["shape"], slope=env["slope"], fr=env["fr"], heat=env["heat_flux_wm2"], wdir=env["wdir_from_deg"],
               variant=env["variant"], ref_has_reverse=int(rb["has_reverse"]), n_shadow=int(shadow.sum()))
    for d in (50.0, 100.0, 200.0, 300.0):
        zabs = he[J, I] + d
        ke = int(np.nonzero(AGL == d)[0][0])
        ve = fe[:3, ke][:, J, I]
        vb = col_at(fb[:3][:, :, J, I], AGL, zabs - hc[J, I])
        vr = ref_on_400(wf, hw, x0w, y0w, nxw, nyw, zabs, cells)
        for zn, m in zones.items():
            ok = m & np.isfinite(vr[0]) & np.isfinite(vb[0])
            if ok.sum() < 3:
                continue
            spr = np.hypot(vr[0, ok], vr[1, ok])
            for tag, v in (("env", ve), ("base", vb)):
                spm = np.hypot(v[0, ok], v[1, ok])
                res[f"{tag}_{zn}_{int(d)}_sp_rmse"] = float(np.sqrt(np.mean((spm - spr) ** 2)) / U)
                res[f"{tag}_{zn}_{int(d)}_sp_bias"] = float(np.mean(spm - spr) / U)
                res[f"{tag}_{zn}_{int(d)}_w_rmse"] = float(np.sqrt(np.mean((v[2, ok] - vr[2, ok]) ** 2)) / U)
                res[f"{tag}_{zn}_{int(d)}_w_bias"] = float(np.mean(v[2, ok] - vr[2, ok]) / U)
            res[f"ref_{zn}_{int(d)}_w_mean"] = float(np.mean(vr[2, ok]) / U)
            res[f"env_{zn}_{int(d)}_w_mean"] = float(np.mean(ve[2, ok]) / U)
            res[f"base_{zn}_{int(d)}_w_mean"] = float(np.mean(vb[2, ok]) / U)
    # простые метрики подветренной зоны (на высотах h_eff + 50…300 м, клетки по ветру от бровки)
    lee = sx > 0
    for tag, get in (("env", lambda d: fe[:3, int(np.nonzero(AGL == d)[0][0])][:, J, I]),
                     ("base", lambda d: col_at(fb[:3][:, :, J, I], AGL, he[J, I] + d - hc[J, I])),
                     ("ref", lambda d: ref_on_400(wf, hw, x0w, y0w, nxw, nyw, he[J, I] + d, cells))):
        ws, sps = [], []
        for d in (50.0, 100.0, 200.0, 300.0):
            v = get(d)
            ok = lee & np.isfinite(v[0])
            ws.append(v[2, ok]); sps.append(np.hypot(v[0, ok], v[1, ok]))
        wsa, spa = np.concatenate(ws), np.concatenate(sps)
        res[f"lee_w_mean_{tag}"] = float(wsa.mean() / U)
        res[f"lee_w_p05_{tag}"] = float(np.percentile(wsa, 5) / U)
        res[f"lee_desc_frac_{tag}"] = float((wsa < -0.05 * U).mean())
        res[f"lee_speed_mean_{tag}"] = float(spa.mean() / U)
    return res


def envreal_case(arg):
    env, base = arg
    U = max(env["u_sat"], 0.5)
    with h5py.File(env["part"], "r") as hf:
        fe = hf["fields/f"][env["row"]].astype(np.float32)
        he = hf["inputs/h_eff"][env["row"]].astype(float) if "inputs/h_eff" in hf else hf["inputs/hc"][env["row"]].astype(float)
        hc = hf["inputs/hc"][env["row"]].astype(float)
        it = hf["trace/iter"][env["row"]]; du = hf["trace/du_max"][env["row"]]
    with h5py.File(base["part"], "r") as hf:
        fb = hf["fields/f"][base["row"]].astype(np.float32)
    sl = np.s_[EDGE:-EDGE, EDGE:-EDGE]
    sh = (he - hc)[sl] > 1.0
    res = dict(case_id=env["case_id"], base_case_id=base["case_id"], variant=env["variant"], angle=env["angle"],
               wall=env["wall"], status=env["status"], iters=env["iters"], spread=env["late_spread60_p90"],
               du_last=float(du[it >= 0][-1]) if (it >= 0).any() else 0.0, u_sat=env["u_sat"], fr=env["fr"],
               base_status=base["status"], shadow_frac=float(sh.mean()))
    if env["angle"] == 0:
        return res
    for d in (50.0, 100.0, 200.0, 300.0):
        k = int(np.nonzero(AGL == d)[0][0])
        ve = fe[:3, k][:, EDGE:-EDGE, EDGE:-EDGE]
        vb = fb[:3, k][:, EDGE:-EDGE, EDGE:-EDGE]          # вне тени h_eff = hc: та же высота над землёй
        m = ~sh
        dsp = np.hypot(ve[0], ve[1]) - np.hypot(vb[0], vb[1])
        res[f"out_{int(d)}_sp_rmse"] = float(np.sqrt(np.mean(dsp[m] ** 2)) / U)
        res[f"out_{int(d)}_w_rmse"] = float(np.sqrt(np.mean((ve[2] - vb[2])[m] ** 2)) / U)
        if sh.any():
            Jj, Ii = np.nonzero(sh)
            zb = (he - hc)[sl][Jj, Ii] + d
            vbi = col_at(fb[:3][:, :, EDGE:-EDGE, EDGE:-EDGE][:, :, Jj, Ii], AGL, zb)
            dd = np.hypot(ve[0][Jj, Ii], ve[1][Jj, Ii]) - np.hypot(vbi[0], vbi[1])
            ok = np.isfinite(dd)
            res[f"in_{int(d)}_sp_rmse"] = float(np.sqrt(np.mean(dd[ok] ** 2)) / U)
            res[f"in_{int(d)}_w_rmse"] = float(np.sqrt(np.mean((ve[2][Jj, Ii] - vbi[2])[ok] ** 2)) / U)
    return res


# ============================================================================== сводки
def sigmoid_fit(x, y, log=False):
    """Простая сигмоида y = y0 + dy·σ((x − xc)/w) (x или log10 x); → dict(xc, w, y0, dy)."""
    x = np.asarray(x, float); y = np.asarray(y, float)
    t = np.log10(x) if log else x

    def r(p):
        return p[0] + p[1] / (1 + np.exp(-(t - p[2]) / p[3])) - y
    best = None
    for c0 in np.linspace(t.min(), t.max(), 7):
        try:
            q = least_squares(r, [y.min(), y.max() - y.min(), c0, 0.05 * (t.max() - t.min()) + 1e-3],
                              bounds=([-10, -10, t.min() - 1, 1e-3], [10, 10, t.max() + 1, 10]))
        except Exception:
            continue
        if best is None or q.cost < best.cost:
            best = q
    p = best.x
    xc = 10 ** p[2] if log else p[2]
    return dict(xc=float(xc), w=float(p[3]), y0=float(p[0]), dy=float(p[1]), rms=float(np.sqrt(np.mean(best.fun ** 2))))


def stat(v):
    v = np.asarray([x for x in v if x is not None and np.isfinite(x)], float)
    if v.size == 0:
        return None
    return dict(median=float(np.median(v)), p25=float(np.percentile(v, 25)), p75=float(np.percentile(v, 75)),
                min=float(v.min()), max=float(v.max()), n=int(v.size))


def main():
    ap = argparse.ArgumentParser()
    root = os.environ.get("AIR_SYNTH_DATA", str(Path.home() / "air_synth_data"))
    ap.add_argument("--plan", default=f"{root}/phase/ap_v1")
    ap.add_argument("--results", default=f"{root}/phase/ap_v1__s1-74644c4")
    ap.add_argument("--jobs", type=int, default=16)
    a = ap.parse_args()
    P, rows = build_index(a.plan, a.results)
    ctx = dict(alpha=float(P["context"]["alpha"]), max_profile=float(P["context"]["max_profile"]))
    sep = [r for r in rows if r["series"] == SER["SEPARATION"]]
    env = [r for r in rows if r["series"] == SER["ENVELOPE"]]
    envr = [r for r in rows if r["series"] == SER["ENVELOPE_REAL"]]
    print(f"SEPARATION {len(sep)}, ENVELOPE {len(env)}, ENVELOPE_REAL {len(envr)}", flush=True)
    with ProcessPoolExecutor(a.jobs) as ex:
        sres = list(ex.map(sep_case, [(r, ctx) for r in sep], chunksize=2))
    print("SEPARATION готово", flush=True)
    # пары ENVELOPE: эталон — SEPARATION dx 100 той же конфигурации, база — SEPARATION dx 400
    key = lambda r: (r["relief_id"], round(r["fr"], 4), r["heat_flux_wm2"], r["wdir_from_deg"])  # noqa: E731
    s100 = {key(r): r for r in sep if r["dx_m"] == 100}
    s400 = {key(r): r for r in sep if r["dx_m"] == 400}
    pairs = [(r, s100[key(r)], s400[key(r)]) for r in env if key(r) in s100 and key(r) in s400]
    by_line = {}
    for r in envr:
        by_line.setdefault((r["relief_id"], r["cond_id"], r["heat_flux_wm2"], r["variant"]), []).append(r)
    rpairs = []
    for k, grp in by_line.items():
        b = [r for r in grp if r["angle"] == 0]
        if b:
            rpairs += [(r, b[0]) for r in grp]
    with ProcessPoolExecutor(a.jobs) as ex:
        eres = list(ex.map(env_case, pairs, chunksize=2))
        print("ENVELOPE готово", flush=True)
        rres = list(ex.map(envreal_case, rpairs, chunksize=4))
    print("ENVELOPE_REAL готово", flush=True)
    meta = {r["case_id"]: r for r in rows}
    summary = summarize(sres, eres, rres, meta, ctx, a)
    (HERE / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    write_bubble_csv(sres, meta)
    import figs
    figs.make(HERE, sres, eres, rres, meta, summary)
    print(json.dumps(summary["lee"], ensure_ascii=False, indent=1))


def write_bubble_csv(sres, meta):
    (HERE / "out").mkdir(exist_ok=True)
    keys = sorted({k for r in sres for k in r if k != "sec"})
    lead = ["case_id", "dx_m"]
    keys = lead + [k for k in keys if k not in lead]
    with open(HERE / "out" / "bubble_v2.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["shape", "slope", "fr", "heat", "wdir", "variant", "status"] + keys)
        for r in sorted(sres, key=lambda r: (r["case_id"])):
            m = meta[r["case_id"]]
            w.writerow([m["shape"], m["slope"], round(m["fr"], 3), m["heat_flux_wm2"], m["wdir_from_deg"], m["variant"],
                        m["status"]] + [("" if r.get(k) is None else (round(r[k], 4) if isinstance(r[k], float) else r[k]))
                                        for k in keys])


def summarize(sres, eres, rres, meta, ctx, a):
    S = {"contract": "P7 v1", "task": "AP-10", "plan": a.plan, "results": a.results,
         "inflow_profile": ctx, "game_lee_now": GAME_LEE, "literature": LIT}
    tab = []
    for r in sres:
        m = meta[r["case_id"]]
        t = dict(r); t.pop("sec", None)
        t.update(shape=m["shape"], slope=m["slope"], fr=m["fr"], heat=m["heat_flux_wm2"], wdir=m["wdir_from_deg"],
                 variant=m["variant"], status=m["status"])
        tab.append(t)
    W = [t for t in tab if t["dx_m"] == 100]
    C = [t for t in tab if t["dx_m"] == 400]
    pick = lambda T, **kw: [t for t in T if all((t[k] == v) if not callable(v) else v(t[k]) for k, v in kw.items())]  # noqa: E731
    # --- (а) крутизна: Fr 3, H 0, 270°
    slope = {}
    for shp in ("RIDGE", "HILL", "STEP_DOWN"):
        for dx, T in ((100, W), (400, C)):
            rr = sorted(pick(T, shape=shp, variant="slope"), key=lambda t: t["slope"])
            xs = [t["slope"] for t in rr]
            hr = [t["has_reverse"] for t in rr]
            on = [x for x, y in zip(xs, hr) if y]
            off = [x for x, y in zip(xs, hr) if not y and (not on or x < min(on))]
            d = dict(s=xs, has_reverse=hr, L_over_h=[t["L_over_h"] for t in rr], H_over_h=[t["H_over_h"] for t in rr],
                     urev_over_U=[t["urev_over_U"] for t in rr], shadow_angle_deg=[t["shadow_angle_deg"] for t in rr],
                     xc_over_h=[t["xc_over_h"] for t in rr], zc_over_h=[t["zc_over_h"] for t in rr],
                     area_rev_frac=[t["area_rev_frac"] for t in rr], slope_lee=[t["slope_lee"] for t in rr],
                     onset_bracket=[max(off) if off else None, min(on) if on else None])
            if dx == 100:
                d["L_sep_over_h"] = [t.get("L_sep_over_h", 0.0) for t in rr]
                d["sep_over_h"] = [t.get("sep_over_h", 0.0) for t in rr]
                d["foot_over_h"] = [t.get("foot_over_h", 0.0) for t in rr]
                d["L_past_foot_over_h"] = [t.get("L_past_foot_over_h", 0.0) for t in rr]
                d["shear_S_pope"] = [t.get("shear_S_pope") for t in rr]
                d["shear_ddelta_ds"] = [t.get("shear_ddelta_ds") for t in rr]
                d["w_lee_min_over_U"] = [t.get("w_lee_min_over_U") for t in rr]
            try:
                d["sigmoid_urev"] = sigmoid_fit(xs, [-u for u in d["urev_over_U"]])
            except Exception:
                d["sigmoid_urev"] = None
            slope[f"{shp}_dx{dx}"] = d
    S["slope_series"] = slope
    # --- (б) Fr, (в) нагрев, (г) косой ветер
    frs = {}
    for sl in (0.3, 0.5):
        for dx, T in ((100, W), (400, C)):
            rr = sorted(pick(T, shape="RIDGE", variant="fr", slope=sl), key=lambda t: t["fr"])
            rr += pick(T, shape="RIDGE", variant="slope", slope=sl) if not any(abs(t["fr"] - 3) < 1e-3 for t in rr) else []
            rr = sorted(rr, key=lambda t: t["fr"])
            frs[f"RIDGE_s{sl}_dx{dx}"] = dict(fr=[t["fr"] for t in rr], fr_local=[t["fr_local"] for t in rr],
                                             old_fr_local=[t["old_fr_local"] for t in rr], status=[t["status"] for t in rr],
                                             win_status=[t.get("win_status") for t in rr],
                                             has_reverse=[t["has_reverse"] for t in rr], L_over_h=[t["L_over_h"] for t in rr],
                                             H_over_h=[t["H_over_h"] for t in rr], urev_over_U=[t["urev_over_U"] for t in rr],
                                             shadow_angle_deg=[t["shadow_angle_deg"] for t in rr],
                                             second_reverse=[t.get("second_reverse") for t in rr])
    S["fr_series"] = frs
    heat = {}
    for sl in (0.3, 0.5):
        for dx, T in ((100, W), (400, C)):
            rr = pick(T, shape="RIDGE", slope=sl, wdir=270.0, fr=lambda f: abs(f - 3) < 1e-3)
            rr = sorted({t["heat"]: t for t in rr}.values(), key=lambda t: t["heat"])
            heat[f"RIDGE_s{sl}_dx{dx}"] = dict(heat_wm2=[t["heat"] for t in rr], has_reverse=[t["has_reverse"] for t in rr],
                                              L_over_h=[t["L_over_h"] for t in rr], urev_over_U=[t["urev_over_U"] for t in rr],
                                              H_over_h=[t["H_over_h"] for t in rr])
    S["heat_series"] = heat
    obl = {}
    for t in pick(W, variant="oblique") + pick(C, variant="oblique"):
        obl[f"RIDGE_s{t['slope']}_wdir{int(t['wdir'])}_dx{int(t['dx_m'])}"] = {
            k: t.get(k) for k in ("has_reverse", "L_over_h", "H_over_h", "urev_over_U", "shadow_angle_deg", "slope_lee",
                                  "old_has_reverse", "old_slope_lee", "n_has_reverse", "n_L_over_h", "n_urev_over_U",
                                  "n_shadow_angle_deg")}
    S["oblique"] = obl
    S["oblique_note"] = ("окно 100 м при 300°/330° поставлено window_geometry у конца хребта (бровка y ≈ −8,7…−9,2 км, "
                         "конец плато хребта — 8,6 км): трёхмерный конец, не середина хребта; старый bubble сечения через "
                         "(0, 0) окно не пересекал")
    # --- fr_local: старое и новое определение
    S["fr_local_check"] = {f"{t['shape']}_s{t['slope']}_fr{t['fr']:.2f}_dx{int(t['dx_m'])}": dict(
        new=t["fr_local"], old=t["old_fr_local"], status=t["status"])
        for t in tab if t["variant"] == "fr" and t["fr"] <= 1.0}
    # --- 100 против 400 м
    pairs = []
    k = lambda t: (t["shape"], t["slope"], round(t["fr"], 3), t["heat"], t["wdir"])  # noqa: E731
    c4 = {k(t): t for t in C}
    for t in W:
        if k(t) in c4:
            pairs.append((t, c4[k(t)]))
    both = [(p, q) for p, q in pairs if p["has_reverse"] and q["has_reverse"] and p["wdir"] == 270]
    S["grid400_vs_100"] = dict(
        n_pairs=len(pairs),
        presence_agree=float(np.mean([p["has_reverse"] == q["has_reverse"] for p, q in pairs])),
        reverse_100_only=int(sum(p["has_reverse"] and not q["has_reverse"] for p, q in pairs)),
        reverse_400_only=int(sum(q["has_reverse"] and not p["has_reverse"] for p, q in pairs)),
        L_ratio_400_100=stat([q["L_over_h"] / p["L_over_h"] for p, q in both]),
        urev_ratio_400_100=stat([q["urev_over_U"] / p["urev_over_U"] for p, q in both if p["urev_over_U"] < 0]),
        H_ratio_400_100=stat([q["H_over_h"] / p["H_over_h"] for p, q in both if p["H_over_h"] > 0]),
        shadow_400=stat([q["shadow_angle_deg"] for p, q in both]), shadow_100=stat([p["shadow_angle_deg"] for p, q in both]),
        fit_depth_400=stat([q.get("fit_depth_m") for p, q in both]), fit_depth_100=stat([p.get("fit_depth_m") for p, q in both]),
        fit_rr_400=stat([q.get("fit_rotor_reverse") for p, q in both]), fit_rr_100=stat([p.get("fit_rotor_reverse") for p, q in both]))
    # --- таблица lee: окно 100 м, 270°, H = 0, Fr ≥ 2 (опасность игры = 1), есть пузырь
    cal = [t for t in W if t["has_reverse"] and t["wdir"] == 270 and t["heat"] == 0 and t["fr"] >= 2 - 1e-6]
    lee = {}
    for shp in ("ALL", "RIDGE", "STEP_DOWN", "HILL"):
        T = cal if shp == "ALL" else [t for t in cal if t["shape"] == shp]
        lee[shp] = dict(n=len(T),
                        shadow_angle_deg=stat([t["shadow_angle_deg"] for t in T]),
                        depth_scale_m=stat([t.get("lee_depth_scale_m") for t in T]),
                        relief_scale_m=None,
                        rotor_reverse=stat([t.get("lee_rotor_reverse") for t in T]),
                        rotor_reverse_mean=stat([t.get("lee_rotor_reverse_mean") for t in T]),
                        rotor_height_fraction=stat([t.get("lee_rotor_height_fraction") for t in T]),
                        danger_sink_per_wind=stat([t.get("lee_danger_sink_per_wind") for t in T]),
                        sink_band_per_wind=stat([t.get("lee_sink_band_per_wind") for t in T]),
                        shear_layer_m=stat([t.get("lee_shear_layer_m") for t in T]),
                        r0_peak=stat([t.get("lee_r0_peak") for t in T]),
                        fit_shear_layer_m=stat([t.get("fit_shear_layer_m") for t in T]),
                        fit_relief_m=stat([t.get("fit_relief_m") for t in T]),
                        fit_rotor_height_fraction=stat([t.get("fit_rotor_height_fraction") for t in T]),
                        rms_fit=stat([t.get("fit_rms_fit") for t in T]), rms_game_now=stat([t.get("fit_rms_game_now") for t in T]),
                        rms_no_zone=stat([t.get("fit_rms_no_zone") for t in T]),
                        w_rms_game_now=stat([t.get("fit_w_rms_game_now") for t in T]),
                        w_rms_fit=stat([t.get("fit_w_rms_fit") for t in T]),
                        L_over_h=stat([t["L_over_h"] for t in T]), H_over_h=stat([t["H_over_h"] for t in T]),
                        urev_over_U=stat([t["urev_over_U"] for t in T]))
    al = lee["ALL"]
    # поправка на завышенную длину пузыря решателем (2D хребет; часть 2): угол из литературы
    lit_theta = {"ridge2d_s063": math.degrees(math.atan(1 / LIT["ridge2d_s063_L_over_h"])),
                 "perdigao": math.degrees(math.atan(1 / LIT["perdigao_L_over_h"])),
                 "hill3d_s063": math.degrees(math.atan(1 / LIT["hill3d_s063_L_over_h"]))}
    S["lee_by_shape"] = lee
    S["lee"] = {
        "_doc": ("параметр configs/atmosphere.json → lee: значение из опыта (окно 100 м, ветер поперёк, H = 0, Fr 2–5, "
                 "случаи с обратным течением; медиана, *_iqr — [p25, p75]); shadow_angle_deg — atan(Δz/L) от бровки до "
                 "присоединения (P3 bubble); остальные — по смыслу параметра в _lee_flow прямо из сечения поля (lee_direct, "
                 "wind_reduction = 0,6 как в игре); *_lit — угол по литературе (решатель завышает длину пузыря 2D-хребта, "
                 "часть 2); подгонка всей модели игры к полю вырождена — только в lee_by_shape как проверка"),
        "shadow_angle_deg": al["shadow_angle_deg"]["median"] if al["shadow_angle_deg"] else -1,
        "shadow_angle_deg_iqr": [al["shadow_angle_deg"]["p25"], al["shadow_angle_deg"]["p75"]] if al["shadow_angle_deg"] else None,
        "shadow_angle_deg_lit": lit_theta,
        "rotor_reverse": al["rotor_reverse"]["median"] if al["rotor_reverse"] else None,
        "rotor_reverse_iqr": [al["rotor_reverse"]["p25"], al["rotor_reverse"]["p75"]] if al["rotor_reverse"] else None,
        "rotor_height_fraction": al["rotor_height_fraction"]["median"] if al["rotor_height_fraction"] else None,
        "rotor_height_fraction_iqr": [al["rotor_height_fraction"]["p25"], al["rotor_height_fraction"]["p75"]]
        if al["rotor_height_fraction"] else None,
        "depth_scale_m": al["depth_scale_m"]["median"] if al["depth_scale_m"] else None,
        "depth_scale_m_iqr": [al["depth_scale_m"]["p25"], al["depth_scale_m"]["p75"]] if al["depth_scale_m"] else None,
        "relief_scale_m": None,
        "relief_scale_m_note": "серией не определяется: одна высота формы h = 500 м (подгонка модели игры даёт 40–240 м, вырождена)",
        "shear_layer_m": al["shear_layer_m"]["median"] if al["shear_layer_m"] else None,
        "shear_layer_m_iqr": [al["shear_layer_m"]["p25"], al["shear_layer_m"]["p75"]] if al["shear_layer_m"] else None,
        "danger_sink_per_wind": al["danger_sink_per_wind"]["median"] if al["danger_sink_per_wind"] else None,
        "danger_sink_per_wind_iqr": [al["danger_sink_per_wind"]["p25"], al["danger_sink_per_wind"]["p75"]]
        if al["danger_sink_per_wind"] else None,
        "sink_band_per_wind": al["sink_band_per_wind"]["median"] if al["sink_band_per_wind"] else None,
        "rotor_reverse_mean": al["rotor_reverse_mean"]["median"] if al["rotor_reverse_mean"] else None,
        "onset_slope": {k: v["onset_bracket"] for k, v in slope.items()},
        "fr_threshold": "нет в 0,3–5 (обратное течение при всех Fr; Fr ≤ 0,5 — несошедшиеся окна)",
        "n_cases": al["n"],
    }
    # --- часть 2: диагностика длины
    rid = [t for t in W if t["shape"] == "RIDGE" and t["variant"] == "slope" and t["has_reverse"]]
    S["length_diag"] = dict(
        ridge=[{k: t.get(k) for k in ("slope", "L_over_h", "sep_over_h", "reatt_over_h", "L_sep_over_h", "foot_over_h",
                                       "L_past_foot_over_h", "L_strong_over_h", "urev_over_U", "H_over_h", "shear_ddelta_ds",
                                       "shear_S_pope", "shear_Us", "shear_Uc", "shear_delta0_m", "shear_delta1_m",
                                       "second_reverse", "win_status")} for t in sorted(rid, key=lambda t: t["slope"])],
        step=[{k: t.get(k) for k in ("slope", "L_over_h", "sep_over_h", "L_sep_over_h", "L_past_foot_over_h", "urev_over_U",
                                      "shear_ddelta_ds", "shear_S_pope")}
              for t in sorted(pick(W, shape="STEP_DOWN", variant="slope", has_reverse=1), key=lambda t: t["slope"])],
        hill=[{k: t.get(k) for k in ("slope", "L_over_h", "sep_over_h", "L_sep_over_h", "L_past_foot_over_h", "urev_over_U",
                                      "shear_ddelta_ds", "shear_S_pope")}
              for t in sorted(pick(W, shape="HILL", variant="slope", has_reverse=1), key=lambda t: t["slope"])],
        shear_S_pope_ridge=stat([t.get("shear_S_pope") for t in rid]),
        K_estimate=k_estimate(ctx))
    # --- ENVELOPE
    S["envelope"] = env_summary(eres)
    S["envelope_real"] = envreal_summary(rres)
    return S


def k_estimate(ctx):
    """Порядок K замыкания решателя в слое смешения за гребнем (Fr 3: U10 6,41 м/с) против нужного по росту слоя."""
    u10 = 3.0 * 0.01 * 500 / ctx["max_profile"]
    ustar = 0.4 * u10 / math.log(10 / 0.1)
    h_bl = 0.3 * ustar / 1.13e-4
    z = 400.0
    k_hb = 0.4 * ustar * z * (1 - z / h_bl) ** 2
    return dict(u10=u10, ustar=ustar, h_bl_m=h_bl, K_hb_at_400m=k_hb, lam_m=40.0,
                note="K = max(K_HB, l²|S|·F(Ri)), l = 1/(1/(κz) + 1/λ) ≤ λ = 40 м (air.py kloc); нужное ν_T = δ·S·U_s/(2π) — section.md")


def env_summary(E):
    out = {"n": len(E)}
    cfgs = sorted({(e["angle"], e["wall"]) for e in E})
    zones = ("shadow", "behind", "upwind")
    tab = {}
    for c in cfgs:
        T = [e for e in E if (e["angle"], e["wall"]) == c]
        d = dict(n=len(T), converged=float(np.mean([e["status"] == 0 for e in T])),
                 base_converged=float(np.mean([e["base_status"] == 0 for e in T])))
        for zn in zones:
            for q in ("sp_rmse", "w_rmse", "sp_bias", "w_bias"):
                for tag in ("env", "base"):
                    v = [e.get(f"{tag}_{zn}_{dd}_{q}") for e in T for dd in (50, 100, 200, 300)]
                    v = [x for x in v if x is not None]
                    d[f"{tag}_{zn}_{q}"] = float(np.median(v)) if v else None
        for m in ("lee_w_mean", "lee_w_p05", "lee_desc_frac", "lee_speed_mean"):
            de = [e[f"{m}_env"] - e[f"{m}_ref"] for e in T]
            db = [e[f"{m}_base"] - e[f"{m}_ref"] for e in T]
            d[f"{m}_err_env"] = float(np.median(np.abs(de)))
            d[f"{m}_err_base"] = float(np.median(np.abs(db)))
            d[f"{m}_bias_env"] = float(np.median(de))
            d[f"{m}_bias_base"] = float(np.median(db))
        # только формы с обратным течением в эталоне (s ≥ 0,3)
        Tr = [e for e in T if e["ref_has_reverse"]]
        for zn in ("shadow", "behind"):
            for q in ("sp_rmse", "w_rmse"):
                for tag in ("env", "base"):
                    v = [e.get(f"{tag}_{zn}_{dd}_{q}") for e in Tr for dd in (50, 100, 200, 300)]
                    v = [x for x in v if x is not None]
                    d[f"rev_{tag}_{zn}_{q}"] = float(np.median(v)) if v else None
        # по высоте над огибающей (тень), все случаи
        for dd in (50, 100, 200, 300):
            for tag in ("env", "base"):
                v = [e.get(f"{tag}_shadow_{dd}_sp_rmse") for e in T]
                v = [x for x in v if x is not None]
                d[f"{tag}_shadow_{dd}_sp_rmse"] = float(np.median(v)) if v else None
        tab[f"{int(c[0])}_{c[1]}"] = d
    out["by_config"] = tab
    # лучший: наименьшая сумма медиан ошибки скорости и w в тени и за пузырём (случаи с обратным течением); база —
    # то же поле 400 м без огибающей в тех же клетках (зона тени своя у каждого угла)
    sc = lambda v, t: ((v[f"rev_{t}_shadow_sp_rmse"] or 9) + (v[f"rev_{t}_behind_sp_rmse"] or 9)  # noqa: E731
                       + 2 * ((v[f"rev_{t}_shadow_w_rmse"] or 9) + (v[f"rev_{t}_behind_w_rmse"] or 9)))
    out["score"] = {k: sc(v, "env") for k, v in tab.items()}
    out["score_base_same_cells"] = {k: sc(v, "base") for k, v in tab.items()}
    out["best"] = min(out["score"], key=out["score"].get)
    out["score_minus_base"] = {k: out["score"][k] - out["score_base_same_cells"][k] for k in tab}
    return out


def envreal_summary(R):
    out = {}
    var = sorted({r["variant"] for r in R})
    cfgs = sorted({(r["angle"], r["wall"]) for r in R})
    for v in var:
        d = {}
        for c in cfgs:
            T = [r for r in R if r["variant"] == v and (r["angle"], r["wall"]) == c]
            if not T:
                continue
            e = dict(n=len(T), converged=float(np.mean([r["status"] == 0 for r in T])),
                     spread_median=float(np.median([r["spread"] for r in T])),
                     du_last_median=float(np.median([r["du_last"] for r in T])),
                     iters_median=float(np.median([r["iters"] for r in T])),
                     shadow_frac_median=float(np.median([r["shadow_frac"] for r in T])))
            # пары с базой: сошлось ли там, где база не сошлась
            e["fixed"] = int(sum(r["status"] == 0 and r["base_status"] != 0 for r in T))
            e["broken"] = int(sum(r["status"] != 0 and r["base_status"] == 0 for r in T))
            if c[0] > 0:
                for k in ("out_100_sp_rmse", "out_100_w_rmse", "in_100_sp_rmse", "in_100_w_rmse", "out_300_sp_rmse",
                          "in_300_sp_rmse"):
                    vv = [r[k] for r in T if k in r]
                    e[k] = float(np.median(vv)) if vv else None
            d[f"{int(c[0])}_{c[1]}"] = e
        out[v] = d
    return out


if __name__ == "__main__":
    main()
