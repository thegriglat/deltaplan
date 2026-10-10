"""Порт нынешней модели игры (scripts/flight/flight_model.gd) для тех же сценариев: крен
«смещение веса» и «как раньше» (rate), продольный канал с phugoid_damping. Только то, что нужно
для сравнения; значения параметров — из configs/wings/<id>.json и configs/flight.json."""

from __future__ import annotations

import json
import math

import numpy as np

from .params import G, ROOT, Polar


class GameModel:
    def __init__(self, wing_id: str):
        w = json.loads((ROOT / f"configs/wings/{wing_id}.json").read_text())
        fl = json.loads((ROOT / "configs/flight.json").read_text())
        self.w, self.fl = w, fl
        self.m = float(w["pilot_mass_ref_kg"]) + float(w["wing_mass_kg"])
        self.S = float(w["area_m2"])
        self.b = float(w["span_m"])
        self.polar = Polar(w["polar"]["points_kmh_ms"], self.m, 1.225, self.S)
        self.vt = float(w["trim_speed_kmh"]) / 3.6
        ws = w["weight_shift"]
        self.ws = ws
        self.tau_ws = float(ws["roll_time_constant_s"])
        self.rr_ws = math.radians(float(ws["roll_rate_max_dps"]))
        self.k0 = float(ws["roll_stability_per_s"])
        self.k1 = float(ws["roll_stability_steep_per_s"])
        self.ob = math.radians(float(ws["roll_overbank_deg"]))
        self.tau_rate = float(w["roll_time_constant_s"])
        self.rr = math.radians(float(w["roll_rate_max_dps"]))
        self.a = float(w["lift_slope_per_rad"])
        self.a0 = math.radians(float(w["zero_lift_alpha_deg"]))
        self.tau_pitch = float(w["pitch_time_constant_s"])

    def authority(self, v):
        vr = max(v, 0.5) / self.vt
        sf = vr ** float(self.w["roll_speed_exponent"])
        if vr > 1:
            sf = vr ** (-float(self.ws["roll_heavy_exponent"]))
        return min(max(sf, float(self.w["roll_speed_factor_min"])), float(self.w["roll_speed_factor_max"]))

    def stability(self, phi):
        a = abs(phi)
        ob = min(a, self.ob)
        r = ob / (0.25 * math.pi)
        k = self.k0 + self.k1 * r * r
        if a > self.ob:
            k *= ob / a * max(0.0, 1 - (a - ob) / math.radians(10))
        return k

    def roll_run(self, u_fn, phi0=0.0, p0=0.0, T=20.0, dt=1 / 120, mode="weight_shift", dw_fn=None):
        """u_fn(t, phi, p) → ввод; V = V_трим·√n (угол атаки держится). → массивы t, phi, p."""
        phi, p = phi0, p0
        ts, ph, ps = [], [], []
        for i in range(int(T / dt)):
            t = i * dt
            v = self.vt * math.sqrt(1 / max(math.cos(phi), 0.2))
            u = max(-1.0, min(1.0, u_fn(t, phi, p)))
            p_air = 0.0
            if dw_fn is not None:
                p_air = float(self.w["air_roll_gain"]) * dw_fn(t, phi) / self.b
            if mode == "weight_shift":
                pc = u * self.rr_ws * self.authority(v)
                ps_ = -self.stability(phi) * phi
                p += (pc + ps_ + p_air - p) * (1 - math.exp(-dt / self.tau_ws))
            else:
                sf = (max(v, 0.5) / self.vt) ** float(self.w["roll_speed_exponent"])
                sf = min(max(sf, float(self.w["roll_speed_factor_min"])), float(self.w["roll_speed_factor_max"]))
                pc = u * self.rr * sf
                p += (pc + p_air - p) * (1 - math.exp(-dt / self.tau_rate))
            phi += p * dt
            mb = math.radians(float(self.w["max_bank_deg"]))
            if abs(phi) > mb:
                phi = math.copysign(mb, phi)
                p = 0.0
            ts.append(t); ph.append(phi); ps.append(p)
        return np.array(ts), np.array(ph), np.array(ps)

    def phugoid_run(self, dv=3.0, T=60.0, dt=1 / 120, gain=None):
        """Продольный канал игры: θ → γ + α_цель (+ демпфирование ∝ dV/dt) с τ_тангажа."""
        pd = self.fl["phugoid_damping"]
        g = float(pd["gain"]) if gain is None else gain
        lim = math.radians(float(pd["max_alpha_deg"]))
        cl_t = 2 * self.m * G / (1.225 * self.S * self.vt ** 2)
        a_cmd = cl_t / self.a + self.a0
        # установившееся планирование
        cd = float(self.polar.cd_at(cl_t))
        gam = -math.atan(cd / cl_t)
        V = self.vt + dv
        alpha = a_cmd
        theta = gam + alpha
        acc = 0.0
        out = []
        for i in range(int(T / dt)):
            q = 0.5 * 1.225 * V * V * self.S
            a_t = a_cmd
            if q > 0:
                a_t += max(-lim, min(lim, g * self.m * acc / (q * self.a)))
            theta += (gam + a_t - theta) * (1 - math.exp(-dt / self.tau_pitch))
            alpha = theta - gam
            cl = self.a * (alpha - self.a0)
            cd = float(self.polar.cd_at(min(cl, self.polar.cl_max)))
            L, D = q * cl, q * cd
            dV = (-D - self.m * G * math.sin(gam)) / self.m
            dg = (L - self.m * G * math.cos(gam)) / (self.m * V)
            acc = dV
            V += dV * dt
            gam += dg * dt
            out.append((i * dt, V, gam))
        return np.array(out)
