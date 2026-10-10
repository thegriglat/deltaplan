"""Эталонные числа прототипа маятника для тестов порта (PD-2): tests/flight/pendulum/reference.json.

Прототип (pendulum/*.py) не меняется — здесь только постановка сценариев приёмки PD-2 для
крыльев training / laminar / sport при эталонной массе, вариант B (рыскание свободно), гибкость паруса
и эффективное поперечное V — умолчания крыла (configs/wings → pendulum.apparatus_defaults, PD-К1 v3),
экранный эффект и C_L max полос по поляре — как в игре (GameSim, PD-14), dt 1/120 с, 4 подшага, 3 звена.

Постановка как в игре: блок `pendulum` крыла (PD-К2) считается при эталонной массе один раз
(dcm0, cd_scale — под паспортный трим), сценарии с другой массой (опыт Ochi) берут его как есть.
В reference.json пишется и сам блок (`blocks.<крыло>`): тесты берут блок из configs/wings, а если
его там ещё нет (PD-1 не влит) — отсюда.

Болтанка — детерминированная сумма синусоид (моды в reference.json → `turbulence`), одинаковая
здесь и в тесте GDScript (оси игры: X — восток, Y — вверх, −Z — север).

Земля (PD-3): разбег со склона 15° в штиль и при встречном 3 и 6 м/с вдоль склона (`ground_run*`); `--ground` —
только эти сценарии, дописываются в готовый reference.json с его блоками.

Запуск (≈ 5–10 мин на 8 процессах; --ground — ≈ 1 мин):
  /home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python \
      tools/research/pendulum/export_reference.py [--jobs 8] [--ground]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pendulum import air, trim  # noqa: E402
from pendulum.model import Control, Ground, R_from_euler, Sim  # noqa: E402
from pendulum.params import G, load_params  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run, settle  # noqa: E402

ROOT = HERE.parents[2]
OUT = ROOT / "tests/flight/pendulum/reference.json"
WINGS = ["training", "laminar", "sport"]
D = math.degrees
RAD = math.radians
SUBSTEPS_PER_S = 480
SUBSTEPS_MIN = 4
MIN_AIRSPEED = 0.5  # flight.json → min_airspeed_ms


def substeps_for(dt: float) -> int:
    return max(SUBSTEPS_MIN, math.ceil(dt * SUBSTEPS_PER_S - 1e-9))


# ----------------------------------------------------------------------------- болтанка
def turbulence_modes(sigma=1.0, n=24, seed=7):
    """Сумма синусоид, оси игры: u(p) = Σ a_i·cos(k_i·p + φ_i); a_i ⊥ k_i; длины волн 4…200 м
    (лог.), спектр ~ фон Карман L 40 м; каждая составляющая — СКО ≈ sigma."""
    rng = np.random.default_rng(seed)
    lam = np.exp(np.linspace(math.log(200.0), math.log(4.0), n))
    ks = 2 * math.pi / lam
    L = 40.0
    dk = np.gradient(ks) * -1.0
    E = (ks * L) ** 4 / (1 + (ks * L) ** 2) ** (17.0 / 6.0)
    amp = np.sqrt(np.abs(E * dk))
    dirs = rng.normal(size=(n, 3))
    dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
    a = rng.normal(size=(n, 3))
    a -= (a * dirs).sum(1, keepdims=True) * dirs
    a /= np.linalg.norm(a, axis=1, keepdims=True)
    A = a * amp[:, None]
    var = (A ** 2).sum(0) / 2.0
    A *= sigma / math.sqrt(var.mean())
    ph = rng.uniform(0, 2 * math.pi, n)
    K = dirs * ks[:, None]
    return {"k": K.tolist(), "a": A.tolist(), "phase": ph.tolist(), "sigma": sigma, "seed": seed}


def ned_to_game(p):
    return np.stack([p[:, 1], -p[:, 2], -p[:, 0]], 1)


def game_to_ned(v):
    return np.stack([-v[:, 2], v[:, 0], -v[:, 1]], 1)


def turbulence_fn(modes, offset_game=(0.0, 0.0, 0.0)):
    K = np.array(modes["k"])
    A = np.array(modes["a"])
    ph = np.array(modes["phase"])
    off = np.array(offset_game)

    def f(points_ned):
        g = ned_to_game(points_ned) - off[None]
        u = np.cos(g @ K.T + ph[None]) @ A
        return game_to_ned(u)

    return f


# ----------------------------------------------------------------------------- постановка
def wing_cfg(wing: str) -> dict:
    return json.loads((ROOT / f"configs/wings/{wing}.json").read_text())


def params(wing: str, m_pilot=None):
    """Параметры прототипа при умолчаниях «Аппарата» крыла (класса; PD-К1 v3, PD-К2 v3:
    wing.pendulum.apparatus_defaults) и крутке из блока крыла (pendulum_params.py её уменьшает,
    если по геометрии полосы срываются раньше трима)."""
    blk = wing_cfg(wing)["pendulum"]
    ad = blk["apparatus_defaults"]
    return load_params(wing, m_pilot).with_(
        dihedral=math.radians(ad["dihedral_eff_deg"]), flex_relief=ad["sail_flex"],
        washout=math.radians(blk["washout_deg"]))


def block(wing: str) -> dict:
    """Блок pendulum (PD-К2) при эталонной массе — как его посчитает PD-1."""
    p = params(wing)
    xh = p.x_hang_game
    d = trim.solve_dcm0(p.with_(x_hang=xh), xh)
    p = p.with_(x_hang=xh, dcm0=d)
    s = GameSim(p, yaw_mode="free")
    a, st = trim.solve_trim(s)
    cd_scale = trim.calibrate_cd(s, a)
    a, st = trim.solve_trim(s)
    kn = trim.static_margin(s, st["alpha"], st["V"])
    I = s.mm.inertia_b
    zb = 0.06 + p.upright_len * math.cos(p.upright_tilt)
    xb = xh - p.upright_len * math.sin(p.upright_tilt)
    return {
        "contract": "PD-К2 v1",
        "_doc": "эталон прототипа (tools/research/pendulum/export_reference.py)",
        "sweep_deg": D(p.sweep),
        "root_chord_m": p.root_chord,
        "tip_chord_m": p.tip_chord,
        "washout_deg": D(p.washout),
        "keel_len_m": p.keel_len,
        "crossbar_from_nose_m": p.crossbar_from_nose,
        "hang_from_nose_m": xh,
        "bar_x_from_nose_m": xb,
        "bar_z_m": -zb,
        "cg_x_from_nose_m": float(s.mm.cg_n[0]),
        "cg_z_m": float(-s.mm.cg_n[2]),
        "inertia_kgm2": {"ixx": float(I[0, 0]), "iyy": float(I[1, 1]), "izz": float(I[2, 2]),
                         "ixz": float(I[0, 2])},
        "dcm0": d,
        "cd_scale": cd_scale,
        "apparatus_defaults": wing_cfg(wing)["pendulum"]["apparatus_defaults"],
        "ref": {"trim_kmh": st["V"] * 3.6, "sink_ms": st["V"] * math.sin(st["gamma"]),
                "alpha_trim_deg": D(st["alpha"]), "static_margin": kn},
    }


def make(wing: str, blk: dict, m_pilot=None, dt=1 / 120):
    """Sim с параметрами из блока (dcm0, cd_scale не пересчитываются), трим, пилот в равновесии."""
    p = params(wing, m_pilot)
    p = p.with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    s = GameSim(p, yaw_mode="free", dt=dt, substeps=substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


# ----------------------------------------------------------------------------- сценарии
def sc_trim(wing, blk):
    s = make(wing, blk)
    st = s.trim_state
    r = run(s, lambda t, o: Control(), 30.0)
    m = r["t"] > 15
    return {"reset_V_kmh": st["V"] * 3.6, "reset_sink_ms": st["V"] * math.sin(st["gamma"]),
            "reset_alpha_deg": D(st["alpha"]), "reset_theta_deg": D(st["theta"]),
            "V_kmh": float(r["V"][m].mean() * 3.6), "sink_ms": float(-r["vz"][m].mean()),
            "alpha_deg": float(D(r["alpha"][m].mean())), "theta_deg": float(D(r["theta"][m].mean())),
            "pilot_rel_x": float(r["rel_x"][m].mean()), "pilot_rel_z": float(r["rel_z"][m].mean()),
            "tension_N": float(r["tension"][m].mean())}


def sc_phugoid(wing, blk, dv=3.0):
    s = make(wing, blk)
    s.vel = s.vel * (1 + dv / np.linalg.norm(s.vel))
    s.vn = s.vn + (s.vel - s.vn[-1])
    r = run(s, lambda t, o: Control(), 60.0, every=1)
    t, V = r["t"], r["V"]
    pk = [i for i in range(1, len(V) - 1) if V[i] > V[i - 1] and V[i] >= V[i + 1]]
    per = float(np.median(np.diff(t[pk]))) if len(pk) >= 2 else float("nan")
    Vm = float(np.median(V[-600:]))
    amps = [V[i] - Vm for i in pk]
    ratio = float(amps[1] / amps[0]) if len(amps) >= 2 and amps[0] != 0 else float("nan")
    return {"dv_ms": dv, "period_s": per, "amp_ratio_per_period": ratio, "V_end_kmh": float(V[-1] * 3.6)}


def sc_reversal(wing, blk, bank=45.0):
    s = make(wing, blk)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 14.0)
    phi0 = D(r0["phi"][-1])
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=1)
    t = r["t"]
    return {"bank_deg": bank, "hold_s": 14.0, "phi_start": phi0, "t_to_minus": first_cross(t, r["phi"], RAD(-bank)),
            "t_to_zero": first_cross(t, r["phi"], 0.0), "phi_t2": float(D(np.interp(2.0, t, r["phi"]))),
            "beta_max": float(D(np.abs(r["beta"]).max()))}


def sc_pendulum(wing, blk):
    out = {}
    for axis, key in ((1, "lat"), (0, "lon")):
        s = make(wing, blk)
        settle(s, 3.0)
        dv = np.zeros(3)
        dv[axis] = 0.5
        s.vn[-1] = s.vn[-1] + s.R @ dv
        r = run(s, lambda t, o: Control(arms_relaxed=True), 20.0, every=1)
        x = r["rel_y" if axis == 1 else "rel_x"]
        x = x - np.median(x[-240:])
        t = r["t"]
        zc = [t[i] for i in range(1, len(x)) if x[i - 1] < 0 <= x[i]]
        pk = [abs(x[i]) for i in range(1, len(x) - 1) if abs(x[i]) >= abs(x[i - 1]) and abs(x[i]) > abs(x[i + 1])]
        out[f"{key}_period_s"] = float(np.median(np.diff(zc))) if len(zc) >= 3 else float("nan")
        out[f"{key}_ratio_per_period"] = float(pk[2] / pk[0]) if len(pk) >= 3 and pk[0] > 0 else float("nan")
        out[f"{key}_amp0_m"] = float(pk[0]) if pk else float("nan")
    return out


def sc_ochi(wing, blk, force=30.0, t_on=8.5, m_pilot=72.6):
    s = make(wing, blk, m_pilot=m_pilot)
    settle(s, 2.0)
    r = run(s, lambda t, o: Control(force_y=force if t < t_on else None), 12.0, every=1)
    t = r["t"]
    return {"m_pilot": m_pilot, "force_n": force, "t_on_s": t_on, "settle_s": 2.0,
            "phi_7s": float(D(np.interp(7.0, t, r["phi"]))), "phi_max": float(D(r["phi"].max()))}


def sc_turbulence(wing, blk, modes, dt=1 / 120, T=40.0):
    s = make(wing, blk, dt=dt)
    s.air_fn = turbulence_fn(modes)
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    n = int(round(T / dt))
    phi, rel_y, th, V = [], [], [], []
    o = s.observe()
    blow = False
    for i in range(n):
        s.step(hold(0.0, o))
        o = s.observe()
        if not np.isfinite(o["phi"]) or o["V"] > 80:
            blow = True
            break
        if o["t"] > 10.0:
            phi.append(o["phi"]); rel_y.append(o["rel_y"]); th.append(o["theta"]); V.append(o["V"])
    return {"dt": dt, "T_s": T, "blowup": blow, "std_phi_deg": float(D(np.std(phi))),
            "std_theta_deg": float(D(np.std(th))), "std_rel_y_m": float(np.std(rel_y)),
            "max_abs_phi_deg": float(D(np.max(np.abs(phi)))), "V_mean_kmh": float(np.mean(V) * 3.6),
            "max_stretch_m": float(s.max_stretch)}


GE_SPAN_EFFICIENCY = 0.9  # configs/pendulum.json → ground_effect.span_efficiency


def ground_sigma(h, b):
    """Экранный эффект Wieselsberger (как PendulumWingStrips.ground_sigma): σ ≥ 0, h/b ≥ 0,033."""
    hb = np.maximum(h / b, 0.033)
    return np.maximum((1.0 - 1.32 * hb) / (1.05 + 7.4 * hb), 0.0)


TURB_DTS = (1 / 120, 1 / 100, 1 / 60, 1 / 30)


def sc_turbulence_mean(wing, blk, modes):
    """Эталон болтанки (PD-14, решение координатора): отклик хаотичен — у прототипа СКО крена на
    одном поле меняется в ≈ 2 раза от шага (training: 4,7–9,2°), поэтому эталон — среднее прототипа
    по шагам TURB_DTS на том же поле; по шагам — в by_dt. dt эталона-среднего — 1/120 (как тест)."""
    runs = [sc_turbulence(wing, blk, modes, dt=dt) for dt in TURB_DTS]
    out = {"dt": 1 / 120, "T_s": runs[0]["T_s"], "blowup": any(r["blowup"] for r in runs),
           "dts": list(TURB_DTS), "by_dt": runs}
    for k in ("std_phi_deg", "std_theta_deg", "std_rel_y_m", "max_abs_phi_deg", "V_mean_kmh", "max_stretch_m"):
        out[k] = float(np.mean([r[k] for r in runs]))
    return out


class GameSim(Sim):
    """Прототип с правками, как в игре (PD-3, PD-14).

    1. Ноги (как PendulumGround): сила бега — сцепление, не больше μ·N (μ = 0,8 — как боковое
       трение прототипа). В Sim._legs бег толкал полной силой при любом касании — и при опоре в
       доли ньютона (в сильный ветер это держало пилота «на цыпочках» у склона, отрыва не было).
    2. Экранный эффект полос (PD-14, configs/pendulum.json → ground_effect): индуктивный скос у
       полосы × (1 − σ), σ — Wieselsberger по высоте полосы над склоном; наклон подъёмной силы
       a₀/(1 + (1 − σ)·a₀/(π·e·λ)), индуктивное сопротивление C_L²/(π·e·λ) × (1 − σ), C_L max прежний.
    3. C_L max полос подобран так, что C_L max всего крыла (статика, симметрично) = поляры
       (configs/pendulum.json → strip_cl_max_match_polar; PendulumWingStrips.match_polar_cl_max):
       скорость сваливания — паспортная.
    """

    _ge = None  # σ по полосам на текущем вызове wing_aero

    def __post_init__(self):
        super().__post_init__()
        self.cl_max_wing0 = self.wing_cl_max()
        target = self.p.polar.cl_max
        lo, hi = target, 1.6 * target
        for _ in range(24):
            mid = 0.5 * (lo + hi)
            self.cl_max_strip = mid
            if self.wing_cl_max() < target:
                lo = mid
            else:
                hi = mid
        self.cl_max_strip = 0.5 * (lo + hi)

    def wing_cl_max(self):
        """C_L max крыла: поток вдоль x мира, киль под углом a; перебор 1°, потом 0,05° у максимума."""
        def cl(a):
            R = R_from_euler(0.0, a, 0.0)
            F, _, _ = Sim.wing_aero(self, np.zeros(3), np.array([1.0, 0.0, 0.0]), R, np.zeros(3))
            return -F[2] / (0.5 * self.p.rho * self.p.area)
        grid = [(cl(math.radians(d)), d) for d in range(5, 46)]
        best, d0 = max(grid)
        for j in range(41):
            best = max(best, cl(math.radians(d0 - 1.0 + j * 0.05)))
        return best

    def strip_cl(self, a_eff):
        if self._ge is None:
            return super().strip_cl(a_eff)
        p = self.p
        ind = 1.0 / (math.pi * GE_SPAN_EFFICIENCY * p.span * p.span / p.area)
        a0 = p.lift_slope / max(1.0 - p.lift_slope * ind, 0.2)
        sl = a0 / (1.0 + (1.0 - self._ge) * a0 * ind)
        a_rel = a_eff - self.alpha0_root
        a_st = self.cl_max_strip / sl
        cl_plate = 2.0 * np.sin(a_rel) * np.cos(a_rel)
        blend = np.clip((a_rel - a_st) / math.radians(4.0), 0.0, 1.0)
        cl_att = np.minimum(sl * a_rel, self.cl_max_strip)
        cl_att = np.where(a_rel < -a_st, -self.cl_max_strip, cl_att)
        cl = (1 - blend) * cl_att + blend * cl_plate
        cd_extra = blend * np.maximum(2.0 * np.sin(a_rel) ** 2, 0.0)
        # индуктивная часть обтекаемой доли × (1 − σ): вычитается здесь же (cd_extra идёт в сумму CD)
        cd_extra = cd_extra - self._ge * (1 - blend) * self.cd_scale * ind * cl * cl
        return cl, cd_extra, blend

    def wing_aero(self, pos, vel, R, w):
        self._ge = None
        if self.ground is not None:
            pts = pos[None] + self.r_strip_b @ R.T
            h = -pts[:, 2] - self.ground.height(pts[:, 0], pts[:, 1])
            ge = ground_sigma(h, self.p.span)
            if ge.max() > 0.0:
                self._ge = ge
        try:
            return super().wing_aero(pos, vel, R, w)
        finally:
            self._ge = None

    def _legs(self):
        F = super()._legs()
        if self.on_ground and self.control.run:
            fz = -F[2]
            lim = 0.8 * fz
            if abs(F[0]) > lim:
                F[0] = math.copysign(lim, F[0])
        return F


def make_ground(wing: str, blk: dict, dt=1 / 120):
    p = params(wing)
    p = p.with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    s = GameSim(p, yaw_mode="free", dt=dt, substeps=substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    return s


def sc_ground_run(wing, blk, wind=0.0, slope_deg=15.0):
    """Разбег (PD-3): постановка scenarios.sc_ground_run прототипа, но с блоком крыла (dcm0,
    cd_scale) и носом крыла как в игре (PendulumGround, GroundRun): wing.launch.alpha_neutral_deg
    к потоку на бегущего пилота (ветер в ЦМ крыла; пока потока меньше min_airspeed_ms — вдоль склона), а не 14°
    к склону для всех — иначе в сильный встречный ветер угол атаки на склоне мал; сила бега ≤ μ·N
    (GameSim). Пилот стоит 1 с, потом бежит (run);
    отрыв — ступни (ЦМ − 1 м) выше земли на 5 см без опоры, после 1,5 с; руки на штангу — через
    1 с после отрыва. Время — от начала (стоя), путь — по горизонтали вдоль склона."""
    s = make_ground(wing, blk)
    p = s.p
    gnd = Ground(slope_tan=math.tan(RAD(slope_deg)), h0=0.0)
    s.ground = gnd
    # встречный ветер вдоль склона (у земли поток обтекает склон): на юг и вверх по склону;
    # горизонтальный ветер на склоне 15° наклоняет подъёмную силу назад вдоль склона — в 6 м/с
    # крыло «висит» у склона, а разгружённые ноги не разгоняют (отрыва нет)
    a = RAD(slope_deg)
    s.air_fn = air.uniform([-wind * math.cos(a), 0.0, -wind * math.sin(a)])
    la = float(json.loads((ROOT / f"configs/wings/{wing}.json").read_text())["launch"]["alpha_neutral_deg"])
    p.extra["launch_theta_deg"] = la - slope_deg  # тангаж к горизонту: угол атаки к склону
    xp = np.array([0.0, 0.0, -1.0])
    s.xn = np.stack([xp for _ in range(s.n_links)])
    s.vn = np.zeros((s.n_links, 3))
    s.R = R_from_euler(0.0, RAD(la - slope_deg), 0.0)
    s.pos = xp + np.array([0.35, 0.0, -0.45]) - s.R @ s.r_grip_b
    s.vel = np.zeros(3)
    s.w = np.zeros(3)
    s.neutral_rel = None
    H = s.hang_world()
    for i in range(s.n_links):
        s.xn[i] = H + (xp - H) * (i + 1) / s.n_links
    liftoff = None
    t_half = None
    hands = "uprights"
    n = int(25.0 / s.dt)
    W_p = p.m_pilot * G
    feet_max = 0.0
    for i in range(n):
        tt = i * s.dt
        if liftoff is not None and tt - liftoff > 1.0 and hands == "uprights":
            hands = "bar"
            s.neutral_rel = s.pilot_rel_b()
        va = s.vn[-1] - s.air_fn(s.pos[None])[0]  # поток на бегущего пилота, ветер — у крыла
        d3 = np.array([math.cos(RAD(slope_deg)), 0.0, math.sin(RAD(slope_deg))])
        u = va + d3 * max(MIN_AIRSPEED - float(np.linalg.norm(va)), 0.0)
        u = u / np.linalg.norm(u) if np.linalg.norm(u) > 1e-3 else d3
        p.extra["launch_theta_deg"] = math.degrees(math.asin(max(-1.0, min(1.0, -u[2])))) + la
        s.step(Control(run=tt > 1.0, hands=hands))
        o = s.observe()
        h_feet = o["hp"] - 1.0 - gnd.height(o["xp"], o["yp"])
        if t_half is None and o["tension"] > 0.5 * W_p:
            t_half = tt + s.dt
        if liftoff is None and h_feet > 0.05 and o["feet"] == 0.0 and tt > 1.5:
            liftoff = tt + s.dt
            out = {"t_liftoff": liftoff, "x_liftoff": float(o["xp"]), "v_liftoff_kmh": o["V"] * 3.6,
                   "vxp_liftoff": float(o["vxp"])}
        if liftoff is not None:
            feet_max = max(feet_max, h_feet)
            if tt - liftoff > 5.0:
                break
    if liftoff is None:
        return {"wind_ms": wind, "slope_deg": slope_deg, "alpha_launch_deg": la, "t_liftoff": float("nan")}
    out.update({"wind_ms": wind, "slope_deg": slope_deg, "alpha_launch_deg": la,
                "t_strap_half_load": t_half if t_half is not None else float("nan"),
                "max_h_feet_5s": float(feet_max)})
    return out


def job(args):
    name, wing, blk, extra = args
    if name == "trim":
        return name, wing, sc_trim(wing, blk)
    if name == "phugoid":
        return name, wing, sc_phugoid(wing, blk)
    if name == "reversal":
        return name, wing, sc_reversal(wing, blk)
    if name == "pendulum":
        return name, wing, sc_pendulum(wing, blk)
    if name == "ochi":
        return name, wing, sc_ochi(wing, blk)
    if name.startswith("ground_run"):
        return name, wing, sc_ground_run(wing, blk, wind=extra["wind"])
    if name == "turbulence":
        return name, wing, sc_turbulence_mean(wing, blk, extra["modes"])
    if name.startswith("turbulence"):
        return name, wing, sc_turbulence(wing, blk, extra["modes"], dt=extra["dt"])
    raise ValueError(name)


GROUND_PLAN = (("ground_run", 0.0), ("ground_run_wind3", 3.0), ("ground_run_wind6", 6.0))


def main_ground(jobs: int):
    ref = json.loads(OUT.read_text())
    blocks = ref["blocks"]
    plan = [(nm, w, blocks[w], {"wind": wind}) for nm, wind in GROUND_PLAN for w in WINGS]
    with ProcessPoolExecutor(jobs) as ex:
        for name, wing, r in ex.map(job, plan):
            ref["scenarios"].setdefault(name, {})[wing] = r
            print(name, wing, json.dumps(r, ensure_ascii=False), flush=True)
    OUT.write_text(json.dumps(ref, ensure_ascii=False, indent=1) + "\n")
    print("→", OUT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--ground", action="store_true",
                    help="только сценарии земли (PD-3): дописать в готовый reference.json, блоки — из него")
    args = ap.parse_args()
    if args.ground:
        main_ground(args.jobs)
        return
    with ProcessPoolExecutor(args.jobs) as ex:
        blocks = dict(zip(WINGS, ex.map(block, WINGS)))
    modes = turbulence_modes()
    plan = []
    for w in WINGS:
        for sc in ("trim", "phugoid", "reversal", "pendulum"):
            plan.append((sc, w, blocks[w], {}))
        plan.append(("turbulence", w, blocks[w], {"modes": modes, "dt": 1 / 120}))
    plan.append(("ochi", "laminar", blocks["laminar"], {}))
    for dt, nm in ((1 / 60, "turbulence_dt60"), (1 / 30, "turbulence_dt30")):
        plan.append((nm, "sport", blocks["sport"], {"modes": modes, "dt": dt}))
    for nm, wind in GROUND_PLAN:
        for w in WINGS:
            plan.append((nm, w, blocks[w], {"wind": wind}))
    res = {}
    with ProcessPoolExecutor(args.jobs) as ex:
        for name, wing, r in ex.map(job, plan):
            res.setdefault(name, {})[wing] = r
            print(name, wing, json.dumps(r, ensure_ascii=False), flush=True)
    out = {
        "_doc": "Эталон прототипа маятника для тестов PD-2; генерирует tools/research/pendulum/export_reference.py, руками не править",
        "variant": {"yaw_mode": "free",
                    "apparatus_defaults": {w: wing_cfg(w)["pendulum"]["apparatus_defaults"] for w in WINGS},
                    "ground_effect": {"span_efficiency": GE_SPAN_EFFICIENCY}, "strip_cl_max_match_polar": True,
                    "dt": 1 / 120, "substeps_per_s": SUBSTEPS_PER_S, "substeps_min": SUBSTEPS_MIN,
                    "n_links": 3, "n_strips": 16, "rho": 1.225, "hang_length_m": 1.2, "g": G},
        "blocks": blocks,
        "turbulence": modes,
        "scenarios": res,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print("→", OUT)


if __name__ == "__main__":
    main()
