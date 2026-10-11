"""PD-19: статические кривые крыла с пилотом по углу атаки киля (прототип GameSim и варианты срыва).

Для каждого α — установившееся планирование (trim.glide_balance: V, γ), момент около подвески
«руки без усилия» M_free и «руки держат нейтраль» M_held (пилот в точке нейтрали в осях крыла,
вес пилота даёт момент около подвески) и усилие рук вдоль киля, Н (предел 300).
Устойчивое равновесие — M = 0 при dM/dα < 0. Вечный срыв — второй такой нуль за срывным углом.

  python tools/research/pendulum/pd19_static.py [крыло ...] [--variant base,nocp,...]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as X  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import E3  # noqa: E402
from pendulum.params import G  # noqa: E402

D = math.degrees


class VarSim(X.GameSim):
    """Варианты срыва полосы: cp — "fj" (PD-18) / "none"; lift — "plate4" (PD-18) / "viterna";
    dcm0_fade — Cm0 паруса × (1 − доля сорванной площади)."""
    cp = "fj"
    lift = "plate4"
    dcm0_fade = False
    cd_max = None  # Viterna: C_D max = 1,11 + 0,018·λ

    def _strip_cl_ge(self, a_eff):
        cl, cd_x, blend = super()._strip_cl_ge(a_eff)
        if self.lift == "viterna":
            p = self.p
            lam = p.span * p.span / p.area
            cdm = self.cd_max or (1.11 + 0.018 * lam)
            a_rel = a_eff - self.alpha0_root
            a_st = self.cl_max_strip / p.lift_slope
            cls = self.cl_max_strip
            cds = 0.0  # прибавка к поляре на срыве — 0 (поляра даёт своё)
            A1 = cdm / 2
            A2 = (cls - cdm * math.sin(a_st) * math.cos(a_st)) * math.sin(a_st) / math.cos(a_st) ** 2
            B2 = (cds - cdm * math.sin(a_st) ** 2) / math.cos(a_st)
            sa = np.sin(np.maximum(a_rel, a_st))
            ca = np.cos(np.maximum(a_rel, a_st))
            clv = A1 * 2 * sa * ca + A2 * ca * ca / sa
            cdv = cdm * sa * sa + B2 * ca
            post = a_rel > a_st
            cl = np.where(post, clv, cl)
            cd_x = np.where(post, np.maximum(cdv, 0.0), cd_x)
        return cl, cd_x, blend

    def strip_cl(self, a_eff):
        if self.cp == "none":
            return self._strip_cl_ge(a_eff)
        return super().strip_cl(a_eff)

    def wing_aero(self, pos, vel, R, w):
        F, M, info = super().wing_aero(pos, vel, R, w)
        if self.dcm0_fade:
            sc = self.sc
            fs = float((info["blend"] * sc).sum() / sc.sum())
            v_c = vel - self.air_fn(pos[None])[0]
            V = float(np.linalg.norm(v_c))
            dm = -0.5 * self.p.rho * V * V * self.p.area * self.p.chord_mean * self.p.dcm0 * fs
            M = M + R @ np.array([0.0, dm, 0.0])
        return F, M, info


def make_var(w, blk, **kw):
    p = X.params(w)
    p = p.with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    cls = type("V", (VarSim,), kw)
    s = cls(p, yaw_mode="free", dt=1 / 120, substeps=X.substeps_for(1 / 120))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


def curves(s, alphas):
    p = s.p
    st0 = s.trim_state
    n_rel = np.array(st0["pilot_dir_b"]) * p.hang_len
    out = []
    V0 = st0["V"]
    for a in alphas:
        V, gam, M_free, st = trim.glide_balance(s, a, V0)
        R = np.array(st["R"])
        W = p.m_pilot * G * E3
        M_held = M_free + float((R.T @ np.cross(R @ n_rel, W))[1])
        # усилие рук вдоль киля: вес пилота в осях B, разложить на стропу (вдоль n_rel) и x_B
        wb = R.T @ W
        d = n_rel / np.linalg.norm(n_rel)
        # wb = T·d + F·x  → решаем в плоскости x-z
        A = np.array([[d[0], 1.0], [d[2], 0.0]])
        T, F = np.linalg.solve(A, np.array([wb[0], wb[2]]))
        out.append((D(a), V * 3.6, D(gam), M_free, M_held, F))
        V0 = V
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wings", nargs="*", default=["training", "laminar", "sport", "bautek_kite"])
    ap.add_argument("--var", default="{}", help='json: {"cp": "none", "lift": "viterna", "dcm0_fade": true}')
    ap.add_argument("--step", type=float, default=2.0)
    a = ap.parse_args()
    ref = json.loads((X.ROOT / "tests/flight/pendulum/reference.json").read_text())
    alphas = np.radians(np.arange(4.0, 91.0, a.step))
    for w in a.wings:
        blk = X.wing_cfg(w)["pendulum"]
        s = make_var(w, blk, **json.loads(a.var))
        c = curves(s, alphas)
        print(f"{w} {a.var}: трим α {D(s.trim_state['alpha']):.1f}°, V {s.trim_state['V']*3.6:.1f}, cl_max полос {s.cl_max_strip:.3f}")
        for r in c:
            print(f"  α {r[0]:4.0f} V {r[1]:5.1f} γ {r[2]:6.1f}  M_free {r[3]:+8.1f}  M_held {r[4]:+8.1f}  F_рук {r[5]:+7.0f}")


if __name__ == "__main__":
    main()
