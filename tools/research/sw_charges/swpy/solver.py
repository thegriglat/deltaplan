"""Явный конечнообъёмный решатель модели Рипа (SW1) на NumPy.

Схема: MUSCL (minmod по η, u, v, b) + SSP-RK2; HLL (скорости Дэвиса, у мокро/сухо — Toro), нормальный импульс и
поток массы из HLL, v и b переносятся против потока массы; well-balanced реконструкция Одюсса со вторым порядком
(покой при однородном b — точно; у мокро/сухо и в крайних клетках — первый порядок); трение — неявно; сила F,
Кориолис (поворот), нагрев и губка — после переноса (расщепление). Границы — через фиктивные клетки.
Состояние: Q = (h, hu, hv, hb), массив (4, ny+2, nx+2) с одной фиктивной клеткой вокруг.
"""
import json
import math
import os
import time

import numpy as np

from . import io as swio

H_, HU_, HV_, HB_ = 0, 1, 2, 3


def _hll(hL, uL, vL, bL, hR, uR, vR, bR):
    """Потоки через грань (нормаль +): (F_h, F_нормальный импульс, F_hv, F_hb). Состояния — реконструированные."""
    cL = np.sqrt(bL * hL)
    cR = np.sqrt(bR * hR)
    dL = hL <= 0
    dR = hR <= 0
    sL = np.minimum(uL - cL, uR - cR)
    sR = np.maximum(uL + cL, uR + cR)
    m = dR & ~dL
    sL = np.where(m, uL - cL, sL)
    sR = np.where(m, uL + 2 * cL, sR)
    m = dL & ~dR
    sL = np.where(m, uR - 2 * cR, sL)
    sR = np.where(m, uR + cR, sR)
    FhL = hL * uL
    FhR = hR * uR
    FmL = hL * uL * uL + 0.5 * bL * hL * hL
    FmR = hR * uR * uR + 0.5 * bR * hR * hR
    den = sR - sL
    ok = den > 0
    den = np.where(ok, den, 1.0)
    Fh = (sR * FhL - sL * FhR + sL * sR * (hR - hL)) / den
    Fm = (sR * FmL - sL * FmR + sL * sR * (hR * uR - hL * uL)) / den
    Fh = np.where(sL >= 0, FhL, np.where(sR <= 0, FhR, Fh))
    Fm = np.where(sL >= 0, FmL, np.where(sR <= 0, FmR, Fm))
    Fh = np.where(ok | (sL >= 0) | (sR <= 0), Fh, 0.0)
    Fm = np.where(ok | (sL >= 0) | (sR <= 0), Fm, 0.0)
    up = Fh > 0
    return Fh, Fm, Fh * np.where(up, vL, vR), Fh * np.where(up, bL, bR)


class Solver:
    def __init__(self, meta, arrays):
        self.meta = meta
        g = meta["grid"]
        self.nx, self.ny = g["nx"], g["ny"]
        self.dx = g["dx"]
        self.dim = meta["dim"]
        self.dy = g["dy"] if self.dim == 2 else None
        self.ref = meta["ref"]
        p = meta["physics"]
        self.p = p
        self.h_min, self.b_min = p["h_min"], p["b_min"]
        self.bc = meta["bc"]
        self.sponge = meta["sponge"]
        self.run = meta["run"]
        nx, ny = self.nx, self.ny
        sh = (ny + 2, nx + 2)
        self.zb = np.zeros(sh)
        zb = arrays["zb"].astype(np.float64)
        self.zb[1:-1, 1:-1] = zb
        self._fill_scalar(self.zb)
        self.zref = float(zb[:, 0].min())
        r = self.ref
        self.U0 = np.array([r["U0"], r["V0"] if self.dim == 2 else 0.0])
        # невозмущённое состояние на локальной земле (для границ и губки)
        self.h_ref = np.maximum(0.0, r["h0"] + self.zref - self.zb)
        Q = np.zeros((4, ny + 2, nx + 2))
        Q[H_, 1:-1, 1:-1] = self.h_ref[1:-1, 1:-1]
        Q[HU_] = self.h_ref * self.U0[0]
        Q[HV_] = self.h_ref * self.U0[1]
        Q[HB_] = self.h_ref * r["b0"]
        inner = (slice(1, -1), slice(1, -1))
        if "h_init" in arrays:
            Q[H_][inner] = arrays["h_init"]
        for k, key in ((HU_, "hu_init"), (HV_, "hv_init"), (HB_, "b_init")):
            if key in arrays:
                Q[k][inner] = arrays[key] * (Q[H_][inner] if key == "b_init" else 1.0)
        if self.dim == 1:
            Q[HV_] = 0.0
        self.Q = Q
        self.q_heat = arrays.get("q_heat")
        self.t = 0.0
        self.steps = 0
        self._dry_fix()
        # губка: вес 0..1 (×1/tau) к краю
        self.sp_w = None
        if self.sponge is not None:
            w = np.zeros((ny, nx))
            wd = self.sponge["width_m"]
            xc = (np.arange(nx) + 0.5) * self.dx
            dist_x = np.minimum(xc, nx * self.dx - xc)
            if self.bc["west"] != "periodic":
                w = np.maximum(w, np.clip(1 - (xc / wd), 0, 1)[None, :] ** 2)
            if self.bc["east"] != "periodic":
                w = np.maximum(w, np.clip(1 - ((nx * self.dx - xc) / wd), 0, 1)[None, :] ** 2)
            if self.dim == 2:
                yc = (np.arange(ny) + 0.5) * self.dy
                if self.bc["south"] != "periodic":
                    w = np.maximum(w, np.clip(1 - (yc / wd), 0, 1)[:, None] ** 2)
                if self.bc["north"] != "periodic":
                    w = np.maximum(w, np.clip(1 - ((ny * self.dy - yc) / wd), 0, 1)[:, None] ** 2)
            self.sp_w = w
        self.mass0 = self.mass()
        self.net_in = 0.0   # накопленный приток массы через края и губку (площадь·м)

    # --- служебное ---
    def _fill_scalar(self, a):
        a[:, 0], a[:, -1] = a[:, 1], a[:, -2]
        a[0, :], a[-1, :] = a[1, :], a[-2, :]
        if self.bc["west"] == "periodic" or self.bc["east"] == "periodic":
            a[:, 0], a[:, -1] = a[:, -2], a[:, 1]
        if self.dim == 2 and (self.bc["south"] == "periodic" or self.bc["north"] == "periodic"):
            a[0, :], a[-1, :] = a[-2, :], a[1, :]

    def cell_area(self):
        return self.dx * (self.dy if self.dim == 2 else 1.0)

    def mass(self):
        return float(self.Q[H_, 1:-1, 1:-1].sum()) * self.cell_area()

    def _dry_fix(self):
        Q = self.Q
        dry = Q[H_] < self.h_min
        Q[HU_][dry] = 0.0
        Q[HV_][dry] = 0.0
        # b в сухих клетках — ref (hb согласован с h)
        Q[HB_][dry] = Q[H_][dry] * self.ref["b0"]

    def _prim(self, Q):
        h = Q[H_]
        wet = h >= self.h_min
        hs = np.where(wet, h, 1.0)
        u = np.where(wet, Q[HU_] / hs, 0.0)
        v = np.where(wet, Q[HV_] / hs, 0.0)
        b = np.where(wet, Q[HB_] / hs, self.ref["b0"])
        return h, u, v, b, wet

    # --- границы ---
    def _bc_side(self, side):
        """Заполняет фиктивный слой стороны side."""
        Q, kind = self.Q, self.bc[side]
        if side == "west":
            gs, ins = (slice(None), 0), (slice(None), 1)
        elif side == "east":
            gs, ins = (slice(None), -1), (slice(None), -2)
        elif side == "south":
            gs, ins = (0, slice(None)), (1, slice(None))
        else:
            gs, ins = (-1, slice(None)), (-2, slice(None))
        horiz = side in ("west", "east")
        nrm = HU_ if horiz else HV_
        tan = HV_ if horiz else HU_
        # для east/north нормаль наружу = +; внутрь по нормали: sg = +1 у west/south, −1 у east/north
        sg = 1.0 if side in ("west", "south") else -1.0
        Qi = Q[(slice(None),) + ins]
        if kind == "transmissive":
            Q[(slice(None),) + gs] = Qi
        elif kind == "wall":
            Q[(slice(None),) + gs] = Qi
            Q[(nrm,) + gs] = -Qi[nrm]
        elif kind == "periodic":
            pass  # заполняется в _bc_periodic
        elif kind == "farfield":
            hi = Qi[H_]
            wet = hi >= self.h_min
            hs = np.where(wet, hi, 1.0)
            un_i = sg * np.where(wet, Qi[nrm] / hs, 0.0)
            ut_i = np.where(wet, Qi[tan] / hs, 0.0)
            b_i = np.where(wet, Qi[HB_] / hs, self.ref["b0"])
            c_i = np.sqrt(b_i * hi)
            hr = self.h_ref[gs]
            b_r = self.ref["b0"]
            un_r = sg * (self.U0[0] if horiz else self.U0[1])
            ut_r = self.U0[1] if horiz else self.U0[0]
            c_r = np.sqrt(b_r * hr)
            Rp = un_r + 2 * c_r
            Rm = un_i - 2 * c_i
            ub = 0.5 * (Rp + Rm)
            cb = np.maximum(0.25 * (Rp - Rm), 0.0)
            inflow = ub > 0
            bb = np.where(inflow, b_r, b_i)
            hb_ = np.where(bb > 0, cb ** 2 / np.where(bb > 0, bb, 1.0), 0.0)
            utb = np.where(inflow, ut_r, ut_i)
            # сверхзвуковой вход / выход
            sup_in = wet & (un_i >= c_i)
            sup_out = wet & (un_i <= -c_i)
            hb_ = np.where(sup_in, hr, np.where(sup_out, hi, hb_))
            ub = np.where(sup_in, un_r, np.where(sup_out, un_i, ub))
            utb = np.where(sup_in, ut_r, np.where(sup_out, ut_i, utb))
            bb = np.where(sup_in, b_r, np.where(sup_out, b_i, bb))
            # сухие: ref сухой или внутри сухо -> копия
            copy = (hr < self.h_min) | ~wet
            G = np.empty_like(Qi)
            G[H_] = np.where(copy, hi, hb_)
            G[nrm] = np.where(copy, Qi[nrm], sg * hb_ * ub)
            G[tan] = np.where(copy, Qi[tan], hb_ * utb)
            G[HB_] = np.where(copy, Qi[HB_], hb_ * bb)
            Q[(slice(None),) + gs] = G
        else:
            raise ValueError(f"bc {kind!r}")

    def _apply_bc(self):
        Q = self.Q
        for side in ("west", "east") + (("south", "north") if self.dim == 2 else ()):
            self._bc_side(side)
        if self.bc["west"] == "periodic" or self.bc["east"] == "periodic":
            Q[:, :, 0], Q[:, :, -1] = Q[:, :, -2], Q[:, :, 1]
        if self.dim == 1:
            Q[:, 0, :], Q[:, -1, :] = Q[:, 1, :], Q[:, 1, :]
            Q[HV_] = 0.0
        elif self.bc["south"] == "periodic" or self.bc["north"] == "periodic":
            Q[:, 0, :], Q[:, -1, :] = Q[:, -2, :], Q[:, 1, :]

    # --- шаг ---
    def max_rate(self):
        """dt = cfl/min(...): по каждой оси λ_x = max(|u|+c)/dx, λ_y = max(|v|+c)/dy; сумма — страховка для 2D."""
        h, u, v, b, wet = self._prim(self.Q)
        sl = (slice(1, -1), slice(1, -1))
        c = np.sqrt(b * h)[sl]
        lx = float(((np.abs(u[sl]) + c) / self.dx).max())
        if self.dim == 2:
            ly = float(((np.abs(v[sl]) + c) / self.dy).max())
            return max(lx, ly, (lx + ly) / 0.9 * self.run["cfl"])
        return lx

    @staticmethod
    def _minmod(a, b):
        """Ограничитель наклона minmod (на экстремумах — ноль)."""
        return np.where(a * b > 0, np.where(np.abs(a) < np.abs(b), a, b), 0.0)

    def _sweep(self, h, un, ut, b, zb, wet, d):
        """Одна ось (нормаль — последний индекс; массивы с фиктивным слоем). Второй порядок (MUSCL minmod по η, u, v, b),
        Одюсс-реконструкция на гранях; у мокро/сухо и при h_edge ≤ 0 — первый порядок.
        Возвращает приращения-скорости (dh, d_normal_momentum, d_tangential_momentum, d_hb) во внутренних клетках
        и поток массы через крайние грани (по строкам)."""
        eta = h + zb
        ok = wet.copy()
        ok[:, 1:-1] &= wet[:, :-2] & wet[:, 2:]
        ok[:, 0] = ok[:, -1] = ok[:, 1] = ok[:, -2] = False  # у краёв — первый порядок (стена без утечки)

        def slope(a):
            sl = np.zeros_like(a)
            sl[:, 1:-1] = self._minmod(a[:, 1:-1] - a[:, :-2], a[:, 2:] - a[:, 1:-1])
            return np.where(ok, sl, 0.0)

        sz = np.zeros_like(zb)
        sz[:, 1:-1] = 0.5 * (zb[:, 2:] - zb[:, :-2])
        sz = np.where(ok, sz, 0.0)
        se, su, sv, sb = slope(eta), slope(un), slope(ut), slope(b)
        hr = eta + 0.5 * se - (zb + 0.5 * sz)
        hl = eta - 0.5 * se - (zb - 0.5 * sz)
        bad = (hr <= 0) | (hl <= 0) | ~ok
        se, su, sv, sb, sz = (np.where(bad, 0.0, q) for q in (se, su, sv, sb, sz))
        zr, zl = zb + 0.5 * sz, zb - 0.5 * sz
        hr = eta + 0.5 * se - zr
        hl = eta - 0.5 * se - zl
        # состояния слева/справа каждой грани k (между клетками k и k+1)
        zm = np.maximum(zr[:, :-1], zl[:, 1:])
        hsL = np.maximum(0.0, hr[:, :-1] + zr[:, :-1] - zm)
        hsR = np.maximum(0.0, hl[:, 1:] + zl[:, 1:] - zm)
        Fh, Fn, Ft, Fb = _hll(hsL, (un + 0.5 * su)[:, :-1], (ut + 0.5 * sv)[:, :-1], (b + 0.5 * sb)[:, :-1],
                              hsR, (un - 0.5 * su)[:, 1:], (ut - 0.5 * sv)[:, 1:], (b - 0.5 * sb)[:, 1:])
        r = slice(1, -1)
        bi = b[r, 1:-1]
        hri, hli, hci = hr[r, 1:-1], hl[r, 1:-1], h[r, 1:-1]
        zri, zli = zr[r, 1:-1], zl[r, 1:-1]
        # давление: поток + поправки Одюсса + центральный источник
        PR = Fn[r, 1:] + 0.5 * bi * (hri ** 2 - hsL[r, 1:] ** 2)
        PL = Fn[r, :-1] + 0.5 * bi * (hli ** 2 - hsR[r, :-1] ** 2)
        dn = -(PR - PL) / d - bi * 0.5 * (hri + hli) * (zri - zli) / d
        dh = -(Fh[r, 1:] - Fh[r, :-1]) / d
        dt_ = -(Ft[r, 1:] - Ft[r, :-1]) / d
        db = -(Fb[r, 1:] - Fb[r, :-1]) / d
        return dh, dn, dt_, db, Fh[r, 0], Fh[r, -1]

    def _rhs(self):
        """Правая часть переноса (без трения/нагрева/губки) и приток массы через края за единицу времени."""
        self._apply_bc()
        Q = self.Q
        h, u, v, b, wet = self._prim(Q)
        zb = self.zb
        dh, dhu, dhv, dhb, w, e = self._sweep(h, u, v, b, zb, wet, self.dx)
        dQ = np.stack([dh, dhu, dhv, dhb])
        inflow = float((w - e).sum()) * (self.dy if self.dim == 2 else 1.0)
        if self.dim == 2:
            dh2, dhv2, dhu2, dhb2, s_, n_ = self._sweep(h.T, v.T, u.T, b.T, zb.T, wet.T, self.dy)
            dQ[H_] += dh2.T
            dQ[HV_] += dhv2.T
            dQ[HU_] += dhu2.T
            dQ[HB_] += dhb2.T
            inflow += float((s_ - n_).sum()) * self.dx
        return dQ, inflow

    def step(self, dt):
        """SSP-RK2 по переносу, затем источники (сила, трение, Кориолис, нагрев, губка) за dt."""
        p = self.p
        inner = (slice(None), slice(1, -1), slice(1, -1))
        Q0 = self.Q[inner].copy()
        L0, in0 = self._rhs()
        self.Q[inner] = Q0 + dt * L0
        self.post()
        L1, in1 = self._rhs()
        self.Q[inner] = 0.5 * Q0 + 0.5 * (self.Q[inner] + dt * L1)
        bnd = 0.5 * (in0 + in1) * dt
        Qn = self.Q[inner].copy()
        hN = Qn[H_]
        wetN = hN >= self.h_min
        hs = np.where(wetN, hN, 1.0)
        uN = np.where(wetN, Qn[HU_] / hs, 0.0)
        vN = np.where(wetN, Qn[HV_] / hs, 0.0)
        cd = p["cd"]
        if p["forcing"] == "balance":
            sp0 = math.hypot(*self.U0)
            Qn[HU_] += dt * hN * cd * sp0 * self.U0[0] / self.ref["h0"]
            Qn[HV_] += dt * hN * cd * sp0 * self.U0[1] / self.ref["h0"]
        if cd > 0:
            fac = 1.0 / (1.0 + dt * cd * np.hypot(uN, vN) / hs)
            Qn[HU_] *= fac
            Qn[HV_] *= fac
        if p["f_cor"] != 0.0 and self.dim == 2:
            th = p["f_cor"] * dt
            ct, st = math.cos(th), math.sin(th)
            mu, mv = Qn[HU_].copy(), Qn[HV_].copy()
            Qn[HU_] = ct * mu - st * mv
            Qn[HV_] = st * mu + ct * mv
        if self.q_heat is not None:
            Qn[HB_] -= dt * (p["g"] / p["theta0"]) * self.q_heat / p["rho_cp"]
        mass_sp = 0.0
        if self.sp_w is not None:
            a = dt * self.sp_w / self.sponge["tau_s"]
            ri = (slice(1, -1), slice(1, -1))
            ref = np.stack([self.h_ref[ri], self.h_ref[ri] * self.U0[0], self.h_ref[ri] * self.U0[1],
                            self.h_ref[ri] * self.ref["b0"]])
            h_before = Qn[H_].copy()
            Qn = (Qn + a * ref) / (1.0 + a)
            mass_sp = float((Qn[H_] - h_before).sum()) * self.cell_area()
        self.Q[inner] = Qn
        if self.dim == 1:
            self.Q[HV_] = 0.0
        self.net_in += bnd + mass_sp
        self.t += dt
        self.steps += 1

    def finite_ok(self):
        Qi = self.Q[:, 1:-1, 1:-1]
        return bool(np.isfinite(Qi).all()) and float(Qi[H_].min()) > -1e-9 * self.ref["h0"]

    def post(self):
        """Обрезка мелких отрицательных h, нижний предел b, сухие клетки."""
        Q = self.Q
        h = Q[H_]
        h[h < 0] = 0.0
        self._dry_fix()
        wet = h >= self.h_min
        lo = self.b_min * h
        clip = wet & (Q[HB_] < lo)
        Q[HB_][clip] = lo[clip]


def _field_arrays(S, mean):
    inner = (slice(1, -1), slice(1, -1))
    h = S.Q[H_][inner]
    wet = (h >= S.h_min)
    a = {"zb": S.zb[inner], "h": h, "hu": np.where(wet, S.Q[HU_][inner], 0.0),
         "hv": np.where(wet, S.Q[HV_][inner], 0.0), "hb": S.Q[HB_][inner], "wet": wet.astype(float)}
    if mean is not None:
        sh, shu, shv, shb, w = mean["sums"]
        ok = (sh / w) >= S.h_min
        den = np.where(ok, sh, 1.0)
        a["h_mean"] = sh / w
        a["u_mean"] = np.where(ok, shu / den, 0.0)
        a["v_mean"] = np.where(ok, shv / den, 0.0)
        a["b_mean"] = np.where(ok, shb / den, 0.0)
    return a


def _write_field(S, case_name, out_dir, mean, suffix=""):
    meta = {"format": "sw-field", "version": 1, "case": case_name, "t": S.t, "steps": S.steps,
            "grid": S.meta["grid"], "ref": S.meta["ref"],
            "mean": None if mean is None else {"t_from": mean["t_from"], "t_to": S.t, "n": mean["n"]},
            "git": swio.git_rev(), "created": swio.now_iso()}
    path = os.path.join(out_dir, f"{case_name}{suffix}.field.json")
    swio.write_pair(path, meta, _field_arrays(S, mean))
    return path


def run(case, out_dir, t_end=None, log=None):
    """Прогон случая SW1 (путь к json или пара (meta, arrays)) -> (поле, запись SW3).
    Поле — словарь float64 (ny, nx) тех же имён, что в SW2 (до округления до float32); файлы SW2/SW3 пишутся в out_dir."""
    rec = run_case(case, out_dir, t_end=t_end, log=log)
    return rec.pop("_arrays"), rec


def run_case(case_path, out_dir, t_end=None, log=None):
    """Прогон случая SW1 -> SW2 (итог и промежуточные) и SW3. Возвращает словарь SW3 (+ служебный _arrays)."""
    if isinstance(case_path, (tuple, list)):
        meta, arrays = case_path
        meta = json.loads(json.dumps(meta))
        arrays = {k: np.asarray(v, dtype=np.float64) for k, v in arrays.items()}
    else:
        meta, arrays = swio.read_pair(case_path)
    if t_end is not None:
        meta["run"]["t_end"] = t_end
    os.makedirs(out_dir, exist_ok=True)
    name = meta["name"]
    S = Solver(meta, arrays)
    run = meta["run"]
    cfl = run["cfl"]
    r = meta["ref"]
    cwave = math.sqrt(r["b0"] * r["h0"])
    spd = math.hypot(r["U0"], r["V0"]) + cwave
    Tc = S.nx * S.dx / (abs(r["U0"]) + cwave)
    tau = 0.05 * Tc
    ref_scale = r["h0"] * spd
    t_end = run["t_end"]
    out_every = run["out_every"]
    avg_from = run["avg_from"]
    mean = None
    next_check, prev_snap, ok_count, resid = tau, None, 0, None
    next_out = out_every if out_every else None
    dts = []
    status = None
    t0 = time.time()
    S._dry_fix()
    notes = []
    while S.t < t_end - 1e-9:
        lam = S.max_rate()
        dt_nat = cfl / lam if lam > 0 else t_end - S.t
        dts.append(dt_nat)
        dt = min(dt_nat, t_end - S.t, next_check - S.t)
        if next_out is not None:
            dt = min(dt, next_out - S.t)
        if avg_from is not None and S.t < avg_from < S.t + dt:
            dt = avg_from - S.t
        in_avg = avg_from is not None and S.t >= avg_from - 1e-9
        if in_avg:
            inner = (slice(1, -1), slice(1, -1))
            if mean is None:
                mean = {"t_from": S.t, "n": 0, "sums": [np.zeros((S.ny, S.nx)) for _ in range(4)] + [0.0]}
            sm = mean["sums"]
            for k in range(4):
                sm[k] += S.Q[k][inner] * dt
            sm[4] += dt
            mean["n"] += 1
        S.step(dt)
        S.post()
        if not S.finite_ok():
            status = "diverged"
            break
        if out_every and next_out is not None and S.t >= next_out - 1e-9:
            _write_field(S, name, out_dir, mean, f".t{int(round(S.t))}")
            next_out += out_every
        if S.t >= next_check - 1e-9:
            inner = (slice(1, -1), slice(1, -1))
            snap = (S.Q[HU_][inner].copy(), S.Q[HV_][inner].copy(), S.Q[H_][inner] >= S.h_min)
            if prev_snap is not None:
                w = snap[2]
                if w.any():
                    d = max(np.abs(snap[0] - prev_snap[0])[w].max(), np.abs(snap[1] - prev_snap[1])[w].max())
                    resid = float(d / ref_scale)
                    ok_count = ok_count + 1 if resid < run["steady_tol"] else 0
            prev_snap = snap
            next_check += tau
            if ok_count >= 2:
                status = "steady"
                break
        if log and S.steps % 2000 == 0:
            log(f"t={S.t:.0f}/{t_end:.0f} steps={S.steps} dt={dts[-1]:.3g}")
    if status is None:
        status = "averaged" if mean is not None else "max_time"
    if status == "diverged":
        notes.append("расчёт разошёлся (NaN/Inf или h<0); поле — состояние в момент обнаружения, может быть нефизичным")
    if status == "steady" and avg_from is not None and mean is None:
        notes.append("steady достигнут раньше avg_from — среднего нет")
    if S.sp_w is not None:
        notes.append("в mass_rel_err учтён обмен массой с губкой")
    notes.append("2-й порядок (MUSCL minmod по η,u,v,b; SSP-RK2), у сухих фронтов и краёв — 1-й; HLL с реконструкцией Одюсса")
    fpath = _write_field(S, name, out_dir, mean)
    inner = (slice(1, -1), slice(1, -1))
    h = S.Q[H_][inner]
    wet = h >= S.h_min
    expected = S.mass0 + S.net_in
    m_err = abs(S.mass() - expected) / S.mass0 if S.mass0 > 0 and np.isfinite(S.mass()) else None
    bb = np.where(wet, S.Q[HB_][inner] / np.where(wet, h, 1.0), 1.0)
    rec = {"format": "sw-run", "version": 1, "case": name, "field": fpath, "status": status, "t": S.t,
           "steps": S.steps, "wall_s": time.time() - t0, "threads": 1,
           "dt_min": float(min(dts)) if dts else None, "dt_mean": float(np.mean(dts)) if dts else None,
           "cfl": cfl, "mass_rel_err": m_err, "steady_residual": resid,
           "dry_cells": int((~wet).sum()),
           "b_clipped": int((wet & (bb <= S.b_min * (1 + 1e-9))).sum()),
           "notes": "; ".join(notes), "git": swio.git_rev(), "created": swio.now_iso()}
    swio.write_json(os.path.join(out_dir, f"{name}.run.json"), rec)
    rec = dict(rec, _arrays=_field_arrays(S, mean))
    return rec
