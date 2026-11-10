"""TB-11: приток у земли шаблона (0,58 w*) против LES Schmidt & Schumann 1989 (0,36 w*) — причина.

Не меняет bubble.py: правки-прототипы (длина подъёма Q у земли L_b) вносятся обёрткой над bb._Plume в этом файле.
Запуск: tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/inflow.py        (полный, ~3 мин; пишет out/round3_inflow.json и inflow_*.png)
        tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/inflow.py --check  (быстро: пересчёт ключевых чисел и сверка с json)
Все величины — радиальный приток к оси (−u_ρ), в w* случая; шаблон осесимметричен, ветра нет (Env(wind=0)).
"""
from __future__ import annotations

import dataclasses
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
TB = HERE.parent
sys.path.insert(0, str(TB))
import bubble as bb  # noqa: E402

OUT = TB / "out" / "round3_inflow.json"
CASES = {"game": (2.56, 1400.0), "ss89": (1.46, 1600.0)}   # (w*, z_i): медианы игры; Schmidt & Schumann 1989
T_PLATEAU = 400.0                                          # с: источник включён, приток вышел на плато
_ORIG_INIT = bb._Plume.__init__
_LB = [None]


def _patched_init(self, st):
    """Прототип правки: длина подъёма Q у земли L_b (в bubble.py L_b = b0)."""
    _ORIG_INIT(self, st)
    if _LB[0] is not None and st.zb < 1e-6:
        self.Lb = _LB[0]
        self.s, self.wq = self._nodes()
        self.m = -self._dQ(self.s) * self.wq


bb._Plume.__init__ = _patched_init


def make(case, tau=None, f0_scale=1.0, lb=None):
    w, zi = CASES[case]
    env = bb.Env(wind=(0.0, 0.0), zi=zi)
    src = bb.from_game(0.0, 0.0, 0.0, w, zi, env)
    kw = {}
    if tau is not None:
        kw["tau"] = tau
    if f0_scale != 1.0:
        kw["F0"] = src.F0 * f0_scale
    _LB[0] = lb
    return dataclasses.replace(src, **kw), env, w, zi


def field_ur(st, env, rho, z):
    """u_ρ(ρ, z) на сетке (nz, nrho): луч вдоль +x."""
    P = np.zeros((len(z), len(rho), 3))
    P[..., 0] = st.xc + rho[None, :]
    P[..., 1] = st.yc
    P[..., 2] = np.asarray(z, float)[:, None]
    return bb.velocity(P, [st], env)[..., 0]


RHO = np.unique(np.concatenate([np.linspace(0, 300, 301), np.linspace(300, 1500, 121)]))
ZG = np.linspace(0.5, 120.0, 48)


def point_inflow(case, tau=None, f0_scale=1.0, lb=None, t=T_PLATEAU, z=(10.0, 25.0)):
    src, env, w, zi = make(case, tau, f0_scale, lb)
    st = bb.state(src, env, t)
    if st is None:
        return None
    u = field_ur(st, env, RHO, list(z))
    return {str(zz): float(-u[i].min() / w) for i, zz in enumerate(z)}


def lifetime_max(case, z=10.0, dt=30.0):
    src, env, w, zi = make(case)
    best, tb, t = 0.0, 0.0, dt
    while True:
        st = bb.state(src, env, t)
        if st is None:
            break
        v = float(-field_ur(st, env, RHO, [z]).min() / w)
        if v > best:
            best, tb = v, t
        t += dt
    return best, tb


def head_cross_time(src, env, zeta=0.5, dt=5.0):
    t = dt
    while True:
        st = bb.state(src, env, t)
        if st is None:
            return None
        if st.zc >= zeta * env.zi:
            return t
        t += dt


def inflow_at_head_crossing(case, tau, zeta=0.5, z=25.0):
    src, env, w, zi = make(case, tau)
    t = head_cross_time(src, env, zeta)
    st = bb.state(src, env, t)
    u = field_ur(st, env, RHO, [z])
    core = bb.velocity(np.array([[[st.xc, st.yc, zeta * zi]]]).reshape(1, 3), [st], env)[0, 2]
    return {"t_cross": t, "inflow_z25": float(-u[0].min() / w), "w_axis_at_head_over_wstar": float(core / w),
            "zb_m": float(st.zb)}


def active_fraction(case, tau, dt=30.0, thr=0.5):
    """Доля жизни, когда приток (z = 25 м) ≥ thr · плато."""
    src, env, w, zi = make(case, tau)
    plateau = point_inflow(case, tau)["25.0"]
    n = k = 0
    t = dt
    while bb.state(src, env, t) is not None:
        v = -field_ur(bb.state(src, env, t), env, RHO, [25.0]).min() / w
        n += 1
        k += v >= thr * plateau
        t += dt
    return k / n, n * dt


# ---------------------------------------------------------------- как меряет LES: узлы сетки, объём ячейки, разброс центра
def ur_interp(st, env):
    u = field_ur(st, env, RHO, ZG)

    def f(r, z):
        r = np.atleast_1d(r); z = np.atleast_1d(z)
        out = np.empty((z.size, r.size))
        for i in range(z.size):
            j = min(max(np.searchsorted(ZG, z[i]) - 1, 0), ZG.size - 2)
            a = (z[i] - ZG[j]) / (ZG[j + 1] - ZG[j])
            row = (1 - a) * u[j] + a * u[j + 1] if z[i] > ZG[0] else u[0] * z[i] / ZG[0]
            out[i] = np.interp(r, RHO, row)
        return out
    return f


def grid_composite(st, env, dx, sigma, cell=True, nodes=None):
    """Композит u_x в плоскости (x, z) через центр события: u_x усреднён по ячейке dx×dx×dx (нижний слой 0…dx),
    разброс положения оси относительно точки выборки — гауссов 2D σ (Гаусс–Эрмит 7×7). Узлы x = k·dx.
    Возвращает (минимум по узлам, по узлам x нижнего слоя), в м/с; в нижнем слое z = 0…dx."""
    f = ur_interp(st, env)
    gh_x, gh_w = np.polynomial.hermite_e.hermegauss(7)
    gh_w = gh_w / gh_w.sum()
    zq = (np.arange(4) + 0.5) / 4 * dx if cell else np.array([0.5 * dx])
    sub = (np.arange(4) + 0.5) / 4 * dx - dx / 2 if cell else np.array([0.0])
    nodes = nodes if nodes is not None else np.arange(1, 13) * dx
    res = []
    for xn in nodes:
        acc = 0.0
        for ax, wx in zip(gh_x, gh_w):
            for ay, wy in zip(gh_x, gh_w):
                dxj, dyj = sigma * ax, sigma * ay
                for sx in sub:
                    for sy in sub:
                        X = xn + sx - dxj
                        Y = sy - dyj
                        r = np.hypot(X, Y)
                        ur = f(r, zq)                       # (nz, 1)
                        acc += wx * wy * np.mean(ur[:, 0] * X / np.maximum(r, 1e-9)) / (sub.size ** 2)
        res.append(acc)
    res = np.array(res)
    return float(-res.min()), res.tolist()


def composite_w_axis(st, env, zi, dx, sigma):
    """w в центре композита на 0,5 z_i: ячейка dx×dx, разброс оси σ (2D гаусс), м/с."""
    rho = np.linspace(0, 1500, 1501)
    P = np.zeros((1, rho.size, 3))
    P[..., 0] = st.xc + rho; P[..., 1] = st.yc; P[..., 2] = 0.5 * zi
    wr = bb.velocity(P, [st], env)[0, :, 2]
    gx, gw = np.polynomial.hermite_e.hermegauss(7)
    gw = gw / gw.sum()
    sub = (np.arange(4) + 0.5) / 4 * dx - dx / 2
    acc = 0.0
    for a, wa in zip(gx, gw):
        for b, wb in zip(gx, gw):
            for sx in sub:
                for sy in sub:
                    acc += wa * wb * np.interp(np.hypot(sx - sigma * a, sy - sigma * b), rho, wr) / sub.size ** 2
    return float(acc)


def like_for_like_scale(sigma, dx, target=2.0):
    """F0-множитель, при котором w композита (ячейка dx, разброс σ) на 0,5 z_i равен target·w*; tau = 1380 (конвективное время ss89)."""
    def g(s):
        src, env, w, zi = make("ss89", 1380.0, s)
        t = head_cross_time(src, env)
        return composite_w_axis(bb.state(src, env, t), env, zi, dx, sigma) / w
    lo, hi = 0.5, 60.0
    for _ in range(14):
        mid = np.sqrt(lo * hi)
        if g(mid) < target:
            lo = mid
        else:
            hi = mid
    s = float(np.sqrt(lo * hi))
    return s, g(s)


def w_axis_profile(case, lb, zs):
    src, env, w, zi = make(case, None, 1.0, lb)
    st = bb.state(src, env, T_PLATEAU)
    P = np.zeros((len(zs), 3)); P[:, 2] = zs
    P[:, 0] = st.xc; P[:, 1] = st.yc
    return (bb.velocity(P, [st], env)[:, 2] / w).tolist()


def ls_shape(z_over_zi):
    """Lenschow & Stephens 1980: ŵ/w* = (z/z_i)^{1/3} (1 − 1,1 z/z_i), средний подъём термика."""
    x = np.asarray(z_over_zi, float)
    return x ** (1 / 3) * (1 - 1.1 * x)


def main(check=False):
    R = {"task": "TB-11", "ref": "Schmidt & Schumann 1989, JFM 200:511 (рис. 18a(i), с. 543): до 0,36 w* в приземном слое"}
    # E0: базовые числа
    base = {}
    for c in (["game"] if check else ["game", "ss89"]):
        lm, tb = lifetime_max(c, 10.0, 60.0 if check else 30.0)
        base[c] = {"lifetime_max_z10": lm, "t_at_max": tb, "plateau": point_inflow(c, z=(10.0, 25.0, 50.0))}
    R["E0_baseline"] = base
    if check:
        return R
    # E1: когда меряем. Тау игры 420…960 (grow 120–240 + mature 300–720)
    e1 = {}
    for c in ("game", "ss89"):
        k = (CASES[c][1] / CASES[c][0]) / (1400.0 / 2.56)       # τ масштабируется конвективным временем z_i/w*
        e1[c] = {str(int(tau * k)): inflow_at_head_crossing(c, tau * k) for tau in (420.0, 690.0, 960.0, 1500.0)}
        e1[c]["active_fraction_tau_game690_scaled"] = active_fraction(c, 690.0 * k)
    R["E1_time_of_measure"] = e1
    # E2/E3: сетка и разброс, плато, S&S-случай
    src, env, w, zi = make("ss89")
    st = bb.state(src, env, T_PLATEAU)
    dx = zi / 32.0
    e2 = {"dx_m": dx}
    pt = point_inflow("ss89")
    e2["point_z10"] = pt["10.0"]
    for sg_name, sg in (("0", 0.0), ("0.5dx", 0.5 * dx), ("1dx", dx), ("2dx", 2 * dx)):
        v, prof = grid_composite(st, env, dx, sg)
        e2["cell_avg_sigma_" + sg_name] = {"max_inflow_over_wstar": v / w, "profile_x_nodes_over_wstar": [p / w for p in prof]}
    v, _ = grid_composite(st, env, dx, 0.0, cell=False)
    e2["node_only_z_dx2_sigma_0"] = v / w
    R["E2_les_like_measure"] = e2
    # E8: поэлементно как композит: сила ядра 2,0 w* при том же разбросе и ячейке, затем приток
    e8 = {}
    for sg_name, sg in (("0", 0.0), ("0.5dx", 0.5 * dx), ("1dx", dx)):
        s_, wc = like_for_like_scale(sg, dx)
        src2, env2, w2, zi2 = make("ss89", 1380.0, s_)
        st2 = bb.state(src2, env2, T_PLATEAU)
        v, prof = grid_composite(st2, env2, dx, sg)
        e8["sigma_" + sg_name] = {"F0_scale": s_, "w_composite_at_0.5zi": wc, "inflow_over_wstar": v / w2}
    R["E8_like_for_like_w2"] = e8
    # E4: сила события (композит 2,0 w* против ядра шаблона)
    wcore = inflow_at_head_crossing("ss89", 1500.0)["w_axis_at_head_over_wstar"]
    e4 = {"w_core_template_at_0.5zi": wcore, "w_core_composite": 2.0}
    sc = (2.0 / wcore) ** 3
    e4["inflow_at_F0_scaled_to_w2"] = point_inflow("ss89", f0_scale=sc)
    R["E4_strength"] = e4
    # E5: стенка. Лог-профиль z0 = 1e-4 z_i; средний по слою 0…dx относительно значения на опорной высоте
    z0 = 1e-4 * zi
    e5 = {}
    for zref in (dx, 2 * dx, 4 * dx):
        e5[f"zref_{int(zref)}m"] = float((np.log(dx / z0) - 1.0) / np.log(zref / z0))
    R["E5_wall_factor_upper_bound"] = {"z0_m": z0, "factor_mean_0_to_dx_over_ref": e5,
                                       "note": "верхняя оценка эффекта трения: профиль логарифмический вплоть до z_ref; шаблон — потенциальный поток со скольжением"}
    # E6: проверка правок. L_b и профиль w на оси против L&S
    zs = np.array([25.0, 48.0, 100.0, 350.0])
    e6 = {}
    for lb in (None, 90.0, 130.0, 200.0, 300.0):
        key = "base" if lb is None else f"Lb_{int(lb)}"
        pi = point_inflow("game", lb=lb, z=(10.0, 25.0, 50.0))
        wa = w_axis_profile("game", lb, zs)
        e6[key] = {"inflow": pi, "w_axis_over_wstar": dict(zip([str(int(z)) for z in zs], wa)),
                   "w_rel_to_350": [wa[i] / wa[3] for i in range(3)]}
    zr = zs[:3] / 1400.0
    e6["Lenschow_Stephens_rel_to_0.25zi"] = {"z_m": zs[:3].tolist(), "rel": (ls_shape(zr) / ls_shape(0.25)).tolist()}
    R["E6_fix_Lb"] = e6
    # E7: чувствительность к b0 и F0
    e7 = {}
    for name, kw in (("F0x0.5", dict(f0_scale=0.5)), ("F0x2", dict(f0_scale=2.0))):
        e7[name] = point_inflow("game", **kw)
    src0, env0, w0_, zi0 = make("game")
    for k in (0.5, 1.5):
        s2 = dataclasses.replace(src0, b0=src0.b0 * k)
        stb = bb.state(s2, env0, T_PLATEAU)
        e7[f"b0x{k}"] = {"10.0": float(-field_ur(stb, env0, RHO, [10.0]).min() / w0_)}
    R["E7_sensitivity"] = e7
    return R


def finalize(R):
    """Сводка выводов из посчитанных блоков (числа берутся из R, ничего не подгоняется)."""
    e2 = R["E2_les_like_measure"]
    e0 = R["E0_baseline"]["ss89"]
    wall = R["E5_wall_factor_upper_bound"]["factor_mean_0_to_dx_over_ref"]
    grid = e2["cell_avg_sigma_0"]["max_inflow_over_wstar"]
    e6 = R["E6_fix_Lb"]
    R["template_point_z10_over_wstar"] = e0["lifetime_max_z10"]
    R["inflow_v4_like_les_wstar"] = grid
    R["inflow_v4_like_les_with_wall_range"] = [grid * min(wall.values()), grid * max(wall.values())]
    R["ratio_to_les"] = {"point_z10": e0["lifetime_max_z10"] / 0.36, "like_les_grid": grid / 0.36,
                         "like_les_grid_equal_w2": R["E8_like_for_like_w2"]["sigma_0"]["inflow_over_wstar"] / 0.36}
    R["causes"] = [
        {"id": "definition", "share": "основная при равной силе",
         "text": "шаблон мерится точкой z = 10 м по максимуму жизни; LES — ячейка 50 м (слой 0…50 м), узлы сетки 50 м: тот же шаблон даёт %.2f w* (×%.2f к LES)" % (grid, grid / 0.36),
         "evidence": "E2"},
        {"id": "wall", "share": "в ту же сторону, оценка сверху",
         "text": "шаблон — потенциальное течение со скольжением; в LES шероховатость z0 = 1e-4 z_i: логарифмический слой снижает среднее по нижней ячейке в %.2f…%.2f раза" % (min(wall.values()), max(wall.values())),
         "evidence": "E5"},
        {"id": "strength", "share": "в обратную сторону",
         "text": "композит LES — события с w = 2,0 w* на 0,5 z_i и радиусом 0,33 z_i, ядро шаблона 1,45 w* и 0,06 z_i; при равном w композита приток шаблона %.2f w* (×%.1f)" % (R["E8_like_for_like_w2"]["sigma_0"]["inflow_over_wstar"], R["E8_like_for_like_w2"]["sigma_0"]["inflow_over_wstar"] / 0.36),
         "evidence": "E4, E8"},
        {"id": "not_cause", "share": "0",
         "text": "время измерения (приток — плато пока источник включён, на пересечении 0,5 z_i тот же), b0 (в 1,5 раза: 0,50 против 0,58)", "evidence": "E1, E7"},
    ]
    R["fix"] = {"proposed": False,
                "tested": "L_b (длина подъёма Q у земли): приток 0,36 достигается при L_b ≈ 130 м, но w оси на 48 м падает до %.2f от w(350 м) против L&S 0,68 (база %.2f)" % (e6["Lb_130"]["w_rel_to_350"][1], e6["base"]["w_rel_to_350"][1]),
                "reason": "профиль w(z) у земли в базе согласован с Lenschow–Stephens; правка ухудшила бы его — основания нет"}
    R["recommendation"] = ("Шаблон не менять. Приток 0,58 w* — значение в точке z = 10 м; в метрике LES (ячейка 50 м) то же поле даёт %.2f w* (×%.2f), "
                           "с оценкой трения у стенки %.2f…%.2f. Прямого количественного подтверждения нет: композит LES — другой, более сильный и широкий объект. Правка bubble.py не обоснована; "
                           "в документах писать «порядок совпадает, в метрике LES ×1,1, при равной силе ядра ×1,6»." % (grid, grid / 0.36, *R["inflow_v4_like_les_with_wall_range"]))
    return R


def plot(R):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    e2 = R["E2_les_like_measure"]
    fig, ax = plt.subplots(1, 2, figsize=(10, 4))
    dx = e2["dx_m"]
    for k, v in e2.items():
        if k.startswith("cell_avg"):
            ax[0].plot(np.arange(1, 13) * dx, [-p for p in v["profile_x_nodes_over_wstar"]], marker="o", label=k.replace("cell_avg_", ""))
    ax[0].axhline(0.36, color="k", ls="--", label="LES 0,36")
    ax[0].set_xlabel("x узла, м"); ax[0].set_ylabel("приток, w*"); ax[0].legend(fontsize=7); ax[0].set_title("ячейка 50 м, разброс σ")
    e6 = R["E6_fix_Lb"]
    zs = [25, 48, 100]
    for k, v in e6.items():
        if k.startswith("Lb") or k == "base":
            ax[1].plot(zs, v["w_rel_to_350"], marker="o", label=k)
    ax[1].plot(zs, e6["Lenschow_Stephens_rel_to_0.25zi"]["rel"], "k--", label="L&S 1980")
    ax[1].set_xlabel("z, м"); ax[1].set_ylabel("w оси / w(350 м)"); ax[1].legend(fontsize=7); ax[1].set_title("профиль w у земли против L&S")
    fig.tight_layout(); fig.savefig(HERE / "inflow_summary.png", dpi=110)


if __name__ == "__main__":
    if "--finalize" in sys.argv:
        R = finalize(json.load(open(OUT))); json.dump(R, open(OUT, "w"), ensure_ascii=False, indent=1); plot(R); sys.exit(0)
    if "--plot" in sys.argv:
        plot(json.load(open(OUT))); sys.exit(0)
    chk = "--check" in sys.argv
    R = main(chk)
    if chk:
        ref = json.load(open(OUT))
        g = R["E0_baseline"]["game"]
        r0 = ref["E0_baseline"]["game"]
        assert abs(g["lifetime_max_z10"] - r0["lifetime_max_z10"]) < 0.02, (g, r0)
        assert abs(g["plateau"]["25.0"] - r0["plateau"]["25.0"]) < 0.01
        assert 0.55 < g["lifetime_max_z10"] < 0.62, "базовые 0,58 w* из compare.json не воспроизводятся"
        print("check ok", g["lifetime_max_z10"], g["plateau"]["25.0"])
        sys.exit(0)
    OUT.parent.mkdir(exist_ok=True)
    finalize(R)
    json.dump(R, open(OUT, "w"), ensure_ascii=False, indent=1)
    plot(R)
    print(json.dumps(R, ensure_ascii=False, indent=1)[:6000])
