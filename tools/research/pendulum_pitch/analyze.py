"""Разбор замеров тангажа «Маятника» (out/game.json) против эталона — точечной массы с полярой игры.

Эталон: планер — точка, L = ½ρV²S·CL, D = ½ρV²S·CD(CL) по поляре крыла (configs/wings/<id>.json →
polar, вся система с пилотом). Уравнения: V' = −D/m − g·sinγ, γ' = (L/m − g·cosγ)/V.
Это классическая задача Ланкастера о фугоиде (Lanchester 1908; Etkin & Reid, Dynamics of Flight,
§ 6.2): если угол атаки (CL) задан, траектория определяется только им — тангаж θ = γ + α.

Сценарии эталона:
  (1) CL(t) из игры: α(t) игры → CL через установившуюся связь α→CL самой игры (качание по ходу
      трапеции) — проверка, что провал траектории в игре — следствие закона CL(t), а не ошибка;
  (2) ступенька CL трим → CL(1,6·V_трим) — верхняя граница провала при мгновенном переходе;
  (3) линейная рампа CL за 3 и 6 с.
Фугоида при постоянном CL: период и затухание за период — Ланкастер T = π√2·V/g, ζ ≈ 1/(√2·K).

Запуск: python analyze.py  (нужны numpy, matplotlib; venv tools/research/heat_ca/.venv подходит)
Выход: out/summary.json, out/tables.md, fig/*.png
"""
import json
import math
import pathlib

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
G = 9.81
RHO = 1.225


def wing_cfg(w):
    return json.loads((ROOT / "configs" / "wings" / f"{w}.json").read_text())


class Polar:
    """CL → CD по точкам поляры (линейно в координатах CL→CD, как WingPolar игры)."""

    def __init__(self, cfg):
        self.m = cfg["pilot_mass_ref_kg"] + cfg["wing_mass_kg"]
        self.S = cfg["area_m2"]
        W = self.m * G
        cl, cd = [], []
        for v_kmh, sink in cfg["polar"]["points_kmh_ms"]:
            V = v_kmh / 3.6
            gam = math.asin(sink / V)
            c_l = 2 * W * math.cos(gam) / (RHO * self.S * V * V)
            cl.append(c_l)
            cd.append(c_l * math.tan(gam))
        o = np.argsort(cl)
        self.cl = np.array(cl)[o]
        self.cd = np.array(cd)[o]

    def CD(self, c_l):
        if c_l <= self.cl[0]:  # экстраполяция по двум первым точкам (большие скорости)
            k = (self.cd[1] - self.cd[0]) / (self.cl[1] - self.cl[0])
            return max(self.cd[0] + k * (c_l - self.cl[0]), 0.02)
        return float(np.interp(c_l, self.cl, self.cd))

    def steady(self, c_l):
        """Установившееся планирование при CL: (V, γ)."""
        gam = -math.atan(self.CD(c_l) / c_l)
        V = math.sqrt(2 * self.m * G * math.cos(gam) / (RHO * self.S * c_l))
        return V, gam


def simulate(pol, cl_of_t, V0, g0, T=60.0, dt=0.005):
    V, gam = V0, g0
    out = []
    t = 0.0
    while t <= T + 1e-9:
        c_l = cl_of_t(t)
        q = 0.5 * RHO * V * V * pol.S
        L, D = q * c_l, q * pol.CD(c_l)

        def f(V_, g_):
            q_ = 0.5 * RHO * V_ * V_ * pol.S
            return (-q_ * pol.CD(c_l) / pol.m - G * math.sin(g_),
                    (q_ * c_l / pol.m - G * math.cos(g_)) / V_)

        out.append((t, V, gam, c_l, L / (pol.m * G)))
        k1 = f(V, gam)
        k2 = f(V + 0.5 * dt * k1[0], gam + 0.5 * dt * k1[1])
        k3 = f(V + 0.5 * dt * k2[0], gam + 0.5 * dt * k2[1])
        k4 = f(V + dt * k3[0], gam + dt * k3[1])
        V += dt / 6 * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0])
        gam += dt / 6 * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1])
        t += dt
    return np.array(out)


def phugoid_decay(arr, g_eq):
    """Период и отношение амплитуд γ за период по экстремумам γ − γ_eq."""
    t, gam = arr[:, 0], arr[:, 2] - g_eq
    ext = [i for i in range(1, len(gam) - 1) if (gam[i] - gam[i - 1]) * (gam[i + 1] - gam[i]) < 0]
    ext = [i for i in ext if abs(gam[i]) > 1e-3]
    if len(ext) < 3:
        return None, None, [math.degrees(gam[i]) for i in ext]
    T = 2 * np.mean(np.diff(t[ext]))
    r = [abs(gam[ext[i + 2]] / gam[ext[i]]) for i in range(len(ext) - 2)]
    return float(T), float(np.median(r)), [round(math.degrees(gam[i]) + math.degrees(g_eq), 2) for i in ext[:6]]


def game_cl_alpha(r, pol):
    """Связь α_киля → CL по установившимся режимам игры."""
    a, c = [], []
    for s in r["sweep"]:
        V = s["V_kmh"] / 3.6
        a.append(s["alpha_deg"])
        c.append(2 * pol.m * G * math.cos(math.radians(s["gamma_deg"])) / (RHO * pol.S * V * V))
    o = np.argsort(a)
    return np.array(a)[o], np.array(c)[o]


def extrema(series, col):
    x = np.array([row[col] for row in series])
    ext = [i for i in range(1, len(x) - 1) if (x[i] - x[i - 1]) * (x[i + 1] - x[i]) < 0]
    return [(series[i][0], x[i]) for i in ext]


def main():
    game = json.loads((HERE / "out" / "game.json").read_text())
    summary = {"source": "out/game.json + configs/wings/*.json polar", "wings": {}}
    lines = []
    figs = {}
    for w, r in game["wings"].items():
        cfg = wing_cfg(w)
        pol = Polar(cfg)
        a_tab, cl_tab = game_cl_alpha(r, pol)
        slope = np.polyfit(np.radians(a_tab[(a_tab > -1) & (a_tab < 12)]), cl_tab[(a_tab > -1) & (a_tab < 12)], 1)[0]
        tr = r["trim"]
        Vt = tr["V_kmh"] / 3.6
        cl_t = 2 * pol.m * G * math.cos(math.radians(tr["gamma_deg"])) / (RHO * pol.S * Vt * Vt)
        # эталон 1,6·V_трим в установившемся планировании
        V16 = 1.6 * Vt
        cl16 = cl_t / 2.56
        for _ in range(20):  # уточнить с cosγ
            _, g16 = pol.steady(cl16)
            cl16 = 2 * pol.m * G * math.cos(g16) / (RHO * pol.S * V16 * V16)
        _, g16 = pol.steady(cl16)
        a16 = float(np.interp(cl16, cl_tab, a_tab))
        ref16 = {"V_kmh": V16 * 3.6, "CL": cl16, "gamma_deg": math.degrees(g16), "L_D": 1 / math.tan(-g16),
                 "alpha_deg_game_CLalpha": a16, "theta_deg": a16 + math.degrees(g16),
                 "dtheta_from_trim_deg": a16 + math.degrees(g16) - tr["theta_deg"],
                 "dalpha_from_trim_deg": a16 - tr["alpha_deg"]}
        # установившиеся режимы игры против эталона по той же CL
        sweep_cmp = []
        for s in r["sweep"]:
            V = s["V_kmh"] / 3.6
            c_l = 2 * pol.m * G * math.cos(math.radians(s["gamma_deg"])) / (RHO * pol.S * V * V)
            _, gref = pol.steady(c_l)
            sweep_cmp.append({"pitch": s["pitch"], "V_kmh": s["V_kmh"], "V_ratio": s["V_kmh"] / tr["V_kmh"],
                              "theta_deg": s["theta_deg"], "gamma_deg": s["gamma_deg"], "alpha_deg": s["alpha_deg"],
                              "gamma_polar_deg": math.degrees(gref), "CL": c_l, "bar_n": s["bar_n"],
                              "theta_p2p_deg": s["theta_p2p_deg"]})
        # переходы: игра против точечной массы с CL(t) игры
        trans = {}
        for name, x in r["transients"].items():
            ser = x["series"]
            ts = np.array([row[0] for row in ser])
            al = np.array([row[3] for row in ser])
            cl_t_series = np.interp(al, a_tab, cl_tab)

            def cl_fun(t, ts=ts, c=cl_t_series):
                return float(np.interp(t, ts, c))

            g0 = math.radians(ser[0][2])
            pm = simulate(pol, cl_fun, ser[0][4] / 3.6, g0, T=ts[-1])
            g_pm = np.degrees(pm[:, 2])
            g_game = np.array([row[2] for row in ser])
            gx = extrema(ser, 2)
            trans[name] = {
                "theta_min_deg": x["theta_min_deg"], "gamma_min_deg": x["gamma_min_deg"],
                "alpha_min_deg": x["alpha_min_deg"], "alpha_end_deg": x["end"]["alpha_deg"],
                "t_theta_min_s": x["at_theta_min"]["t"], "V_max_kmh": x["V_max_kmh"],
                "n_max": x["n_max"],
                "at_1.6Vtrim": {k: x["at_1.6Vtrim"][k] for k in ("t", "theta_deg", "gamma_deg", "alpha_deg")}
                if x["at_1.6Vtrim"] else None,
                "pointmass_same_CL_gamma_min_deg": float(g_pm.min()),
                "pointmass_same_CL_t_gamma_min_s": float(pm[np.argmin(g_pm), 0]),
                "game_gamma_extrema": [(round(a, 2), round(b, 2)) for a, b in gx[:6]],
            }
            if name == "step":
                figs[w] = (ts, np.array([row[1] for row in ser]), g_game, al, pm[:, 0], g_pm)
        # эталон: ступенька и рампы CL трим → CL(1,6·V_трим)
        ref_steps = {}
        for name, tr_s in (("step", 0.0), ("ramp1", 1.0), ("ramp3", 3.0), ("ramp6", 6.0)):
            def cl_fun(t, tr_s=tr_s):
                if tr_s <= 0:
                    return cl16
                return cl_t + (cl16 - cl_t) * min(t / tr_s, 1.0)
            pm = simulate(pol, cl_fun, Vt, math.radians(tr["gamma_deg"]), T=60)
            gdeg = np.degrees(pm[:, 2])
            i16 = np.argmax(pm[:, 1] >= V16)
            T_ph, ratio, ext = phugoid_decay(pm[pm[:, 0] > tr_s], g16)
            ref_steps[name] = {
                "gamma_min_deg": float(gdeg.min()), "t_gamma_min_s": float(pm[np.argmin(gdeg), 0]),
                "theta_min_deg_est": float(gdeg.min() + a16),
                "gamma_at_first_1.6V_deg": float(gdeg[i16]) if pm[i16, 1] >= V16 else None,
                "V_max_kmh": float(pm[:, 1].max() * 3.6), "n_min": float(pm[:, 4].min()),
                "phugoid_T_s": T_ph, "phugoid_ratio_per_period": ratio, "gamma_extrema_deg": ext,
            }
        K16 = 1 / math.tan(-g16)
        lanchester = {"T_s": math.pi * math.sqrt(2) * V16 / G, "zeta": 1 / (math.sqrt(2) * K16),
                      "ratio_per_period": math.exp(-2 * math.pi / (math.sqrt(2) * K16) /
                                                   math.sqrt(1 - 1 / (2 * K16 * K16)))}
        # затухание фугоиды игры после ступеньки «на себя» (по экстремумам γ)
        gx = extrema(r["transients"]["step"]["series"], 2)
        g_end = r["sweep"][-1]["gamma_deg"]
        amp = [abs(b - g_end) for _, b in gx]
        game_ratio = [amp[i + 2] / amp[i] for i in range(len(amp) - 2)]
        game_T = 2 * float(np.mean(np.diff([a for a, _ in gx]))) if len(gx) > 2 else None
        imp = r["pitch_impulse"]["extrema"]
        sp_T = 2 * float(np.mean(np.diff([e[0] for e in imp[:4]]))) if len(imp) >= 4 else None
        summary["wings"][w] = {
            "trim": tr, "iyy_wing_kgm2": r["iyy"], "CL_trim": cl_t, "CL_alpha_per_rad_game": float(slope),
            "ref_1.6Vtrim_steady": ref16, "sweep": sweep_cmp,
            "full_pull_steady": sweep_cmp[-1],
            "transients_game": trans, "ref_pointmass_CL_step_to_1.6V": ref_steps,
            "lanchester_at_1.6V": lanchester,
            "game_phugoid_after_step": {"T_s": game_T, "ratio_per_period": game_ratio,
                                        "gamma_extrema": gx[:8], "gamma_eq_deg": g_end},
            "short_period_alpha_impulse": {"extrema": imp[:6], "T_s": sp_T},
        }
        s = summary["wings"][w]
        lines.append(f"### {w}\n")
        lines.append(f"Трим {tr['V_kmh']:.1f} км/ч: θ {tr['theta_deg']:.2f}°, γ {tr['gamma_deg']:.2f}°, "
                     f"α {tr['alpha_deg']:.2f}°, CL {cl_t:.3f}; CLα игры {slope:.2f} 1/рад; Iyy крыла {r['iyy']:.1f} кг·м².\n")
        lines.append("| ход | V, км/ч | V/V_трим | θ, ° | γ игры, ° | γ поляры, ° | α, ° | штанга, Н | размах θ 60–90 с, ° |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for c in sweep_cmp:
            lines.append(f"| {c['pitch']:+.2f} | {c['V_kmh']:.1f} | {c['V_ratio']:.2f} | {c['theta_deg']:.1f} | "
                         f"{c['gamma_deg']:.1f} | {c['gamma_polar_deg']:.1f} | {c['alpha_deg']:.1f} | {c['bar_n']:.0f} | "
                         f"{c['theta_p2p_deg']:.1f} |")
        lines.append(f"\nЭталон 1,6·V_трим ({ref16['V_kmh']:.1f} км/ч, установившийся): CL {cl16:.3f}, K {ref16['L_D']:.1f}, "
                     f"γ {ref16['gamma_deg']:.1f}°, α {a16:.1f}°, θ {ref16['theta_deg']:.1f}° (Δθ {ref16['dtheta_from_trim_deg']:.1f}°).\n")
        lines.append("| переход | θ min, ° | γ min, ° | α min, ° | t θmin, с | V max | θ/γ/α на 1,6·V_трим | γ min точечной массы с CL(t) игры, ° |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for name, x in trans.items():
            a = x["at_1.6Vtrim"]
            a_s = f"{a['theta_deg']:.1f} / {a['gamma_deg']:.1f} / {a['alpha_deg']:.1f}" if a else "не достигнута"
            lines.append(f"| {name} | {x['theta_min_deg']:.1f} | {x['gamma_min_deg']:.1f} | {x['alpha_min_deg']:.1f} | "
                         f"{x['t_theta_min_s']:.2f} | {x['V_max_kmh']:.1f} | {a_s} | {x['pointmass_same_CL_gamma_min_deg']:.1f} |")
        lines.append("\nЭталон «точечная масса, CL трим → CL(1,6·V_трим)»:\n")
        lines.append("| закон CL | γ min, ° | θ min ≈ γ + α, ° | V max, км/ч | n min | фугоида T, с | ×за период |")
        lines.append("|---|---|---|---|---|---|---|")
        for name, x in ref_steps.items():
            lines.append(f"| {name} | {x['gamma_min_deg']:.1f} | {x['theta_min_deg_est']:.1f} | {x['V_max_kmh']:.1f} | "
                         f"{x['n_min']:.2f} | {x['phugoid_T_s'] or float('nan'):.2f} | {x['phugoid_ratio_per_period'] or float('nan'):.2f} |")
        lines.append(f"\nЛанкастер на 1,6·V_трим: T {lanchester['T_s']:.2f} с, ζ {lanchester['zeta']:.3f}, "
                     f"×{lanchester['ratio_per_period']:.2f} за период. Игра после ступеньки (полный ход): T "
                     f"{game_T or float('nan'):.2f} с, ×за период {', '.join(f'{v:.2f}' for v in game_ratio[:4])}.")
        lines.append(f"Короткопериодическое (толчок q −20 °/с, руки держат): экстремумы Δα {imp[:4]}, T ≈ {sp_T:.2f} с.\n")
    (HERE / "out" / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float))
    (HERE / "out" / "tables.md").write_text("\n".join(lines) + "\n")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        (HERE / "fig").mkdir(exist_ok=True)
        fig, axs = plt.subplots(1, len(figs), figsize=(5 * len(figs), 4), sharey=True)
        for ax, (w, (ts, th, gg, al, tp, gp)) in zip(np.atleast_1d(axs), figs.items()):
            ax.plot(ts, th, label="θ игры")
            ax.plot(ts, gg, label="γ игры")
            ax.plot(ts, al, label="α игры")
            ax.plot(tp, gp, "--", label="γ точечной массы, CL(t) игры")
            ax.set_title(f"{w}: ступенька «на себя» 100 %")
            ax.set_xlabel("t, с")
            ax.grid(alpha=0.3)
        np.atleast_1d(axs)[0].set_ylabel("угол, °")
        np.atleast_1d(axs)[0].legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(HERE / "fig" / "step_pull.png", dpi=120)
    except ImportError:
        pass
    print((HERE / "out" / "tables.md").read_text())


if __name__ == "__main__":
    main()
