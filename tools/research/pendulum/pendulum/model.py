"""Прототип «честного маятника»: крыло — твёрдое тело, пилот — точка на цепи из N звеньев.

Мир — NED (x север, y восток, z вниз), высота = −z. Крыло: ЦМ p, скорость v, матрица R (B→мир),
угловая скорость w (мир). Цепь: узлы 1..N (узел N — пилот), звено 0 — от точки подвески H на крыле.
Интегратор — XPBD с подшагами («Small Steps», Macklin et al. 2019): силы → скорости → позиции →
связи (стропа — только растяжение, податливость стропы) → скорости из позиций.

Аэродинамика крыла — полосы (strip theory, простая теория стреловидности): у каждой полосы
местная скорость v + ω×r − air_fn(точка полосы); подъёмная сила ⊥ нормальной к кромке скорости,
сопротивление — поляра игры CD(CL) за вычетом доли пилота. Пилот — лобовое сопротивление (CD·A)_p.
Руки — сила с насыщением между пилотом и серединой базовой штанги (цель — положение пилота
относительно трапеции); на земле — хват за стойки, ноги — опора и разбег.

Рыскание (yaw_mode):
- "noslip" — этап A: курс крыла кинематически по воздушной скорости (β = 0), как сейчас в игре;
- "free"  — минимальный этап B: рыскание — степень свободы, флюгерная устойчивость — от
  стреловидных полос (сопротивление) и килевого кармана (fin_*), скольжение даёт Clβ от
  стреловидности само (простая теория стреловидности по полосам).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from . import geometry
from .params import G, Params

E3 = np.array([0.0, 0.0, 1.0])


def skew(a):
    return np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])


def expm_so3(phi):
    th = float(np.linalg.norm(phi))
    if th < 1e-12:
        return np.eye(3) + skew(phi)
    k = skew(phi / th)
    return np.eye(3) + math.sin(th) * k + (1 - math.cos(th)) * (k @ k)


def logm_so3(Rm):
    c = max(-1.0, min(1.0, 0.5 * (np.trace(Rm) - 1.0)))
    th = math.acos(c)
    v = np.array([Rm[2, 1] - Rm[1, 2], Rm[0, 2] - Rm[2, 0], Rm[1, 0] - Rm[0, 1]])
    if th < 1e-9:
        return 0.5 * v
    return th / (2 * math.sin(th)) * v


def orthonormalize(Rm):
    u, _, vt = np.linalg.svd(Rm)
    return u @ vt


def euler_from_R(Rm):
    """(ψ, θ, φ) — курс, тангаж, крен (ZYX), R: B→NED."""
    th = -math.asin(max(-1.0, min(1.0, Rm[2, 0])))
    ph = math.atan2(Rm[2, 1], Rm[2, 2])
    ps = math.atan2(Rm[1, 0], Rm[0, 0])
    return ps, th, ph


def R_from_euler(ps, th, ph):
    cps, sps, cth, sth, cph, sph = (math.cos(ps), math.sin(ps), math.cos(th), math.sin(th),
                                    math.cos(ph), math.sin(ph))
    return np.array([
        [cth * cps, sph * sth * cps - cph * sps, cph * sth * cps + sph * sps],
        [cth * sps, sph * sth * sps + cph * cps, cph * sth * sps - sph * cps],
        [-sth, sph * cth, cph * cth],
    ])


def calm(points):
    return np.zeros_like(points)


@dataclass
class Control:
    """Ввод пилота. roll/pitch — как ControlInput в режиме weight_shift: roll — положение пилота
    поперёк трапеции (−1..1, + вправо), pitch — трапеция (+1 от себя). На земле: run, ground_roll,
    ground_pitch (руки держат стойки), hands — 'bar' (полёт) или 'uprights' (земля)."""

    roll: float = 0.0
    pitch: float = 0.0
    run: bool = False
    hands: str = "bar"
    arms_relaxed: bool = False  # руки отпущены (свободный маятник)
    force_y: float | None = None  # задать поперечное усилие рук, Н (+ — пилот вправо), вместо положения


@dataclass
class Ground:
    """Плоский склон: высота h(x,y) = h0 − slope·x (x — по склону вниз, на север)."""

    slope_tan: float = 0.0
    h0: float = 0.0

    def height(self, x, y):
        return self.h0 - self.slope_tan * x


@dataclass
class Sim:
    p: Params
    n_links: int = 3
    substeps: int = 4
    dt: float = 1.0 / 120.0
    yaw_mode: str = "noslip"
    air_fn: object = calm
    ground: Ground | None = None
    log_every: int = 1
    # состояние (заполняется reset_*)
    t: float = 0.0
    pos: np.ndarray = field(default=None)
    vel: np.ndarray = field(default=None)
    R: np.ndarray = field(default=None)
    w: np.ndarray = field(default=None)
    xn: np.ndarray = field(default=None)  # (N,3) узлы цепи
    vn: np.ndarray = field(default=None)
    neutral_rel: np.ndarray = field(default=None)  # положение пилота отн. H в B при нейтрали
    feet_load: float = 0.0
    on_ground: bool = False
    hands_force_b: np.ndarray = field(default=None)
    strap_tension: float = 0.0
    max_stretch: float = 0.0

    def __post_init__(self):
        p = self.p
        self.strips = geometry.make_strips(p)
        if math.isnan(p.x_hang):
            raise ValueError("x_hang не задан: сначала trim.solve_hang")
        self.mm = geometry.mass_model(p, p.x_hang)
        I = self.mm.inertia_b.copy()
        self.I_struct = I.copy()
        if p.apparent_roll:
            I[0, 0] += geometry.apparent_roll_inertia(p)
        self.I_b = I
        self.I_b_inv = np.linalg.inv(I)
        cg = self.mm.cg_n
        self.cg_n = cg
        to_b = lambda r: np.array([cg[0] - r[0], r[1], r[2] - cg[2]])
        self.to_b = to_b
        self.r_strip_b = np.stack([to_b(r) for r in self.strips.r_n])
        self.r_hang_b = to_b(np.array([p.x_hang, 0.0, 0.0]))
        zb = 0.06 + p.upright_len * math.cos(p.upright_tilt)
        xb = p.x_hang - p.upright_len * math.sin(p.upright_tilt)
        self.r_bar_b = to_b(np.array([xb, 0.0, zb]))
        # хват за стойки на земле: на уровне плеч ≈ 0,9 м ниже киля по стойке
        gu = 0.7
        self.r_grip_b = to_b(np.array([p.x_hang - gu * math.sin(p.upright_tilt), 0.0,
                                       0.06 + gu * math.cos(p.upright_tilt)]))
        self.r_fin_b = np.array([-p.fin_arm, 0.0, 0.0])
        # массы узлов цепи
        n = self.n_links
        self.m_nodes = np.full(n, p.strap_mass / max(n - 1, 1))
        self.m_nodes[-1] = p.m_pilot
        if n == 1:
            self.m_nodes[-1] = p.m_pilot
        self.link_len = p.hang_len / n
        self.cd_pilot_share = p.pilot_cda / p.area
        # стрип: доля хорды/ширины
        self.sc = self.strips.chord * self.strips.width
        cs = math.cos(p.sweep)
        self.cos_sweep = cs
        # потолок CL полосы: на сваливании всё крыло даёт cl_max поляры (см. strip_cl)
        self.cl_max_strip = p.polar.cl_max
        self.alpha0_root = p.alpha0 + float((self.strips.twist * self.sc).sum() / self.sc.sum())
        self.log = []
        self.cd_scale = 1.0  # калибровка: сумма полос в прямом полёте = поляра (trim.calibrate_cd)
        self.control = Control()
        self.hands_force_b = np.zeros(3)
        self.arm_int = np.zeros(3)
        self._h = self.dt / self.substeps

    # ------------------------------------------------------------------ аэродинамика
    def strip_cl(self, a_eff):
        """CL полосы: линейно до cl_max, дальше пластина CN=2 (как aero_coefs игры), без гистерезиса."""
        p = self.p
        a_rel = a_eff - self.alpha0_root
        cl_lin = p.lift_slope * a_rel
        a_st = self.cl_max_strip / p.lift_slope
        cl_plate = 2.0 * np.sin(a_rel) * np.cos(a_rel)
        # смешивание за 4° после критического
        blend = np.clip((a_rel - a_st) / math.radians(4.0), 0.0, 1.0)
        cl_att = np.minimum(cl_lin, self.cl_max_strip)
        neg = a_rel < -a_st
        cl_att = np.where(neg, -self.cl_max_strip, cl_att)
        cl = (1 - blend) * cl_att + blend * cl_plate
        cd_extra = blend * np.maximum(2.0 * np.sin(a_rel) ** 2, 0.0)
        return cl, cd_extra, blend

    def wing_aero(self, pos, vel, R, w):
        """Сила (мир) и момент около ЦМ (мир) от полос; плюс данные для журнала."""
        p = self.p
        st = self.strips
        r_w = self.r_strip_b @ R.T  # (n,3) мир
        pts = pos[None] + r_w
        air = self.air_fn(pts)
        u_w = vel[None] + np.cross(w[None], r_w) - air  # скорость полосы отн. воздуха, мир
        u = u_w @ R  # B
        uc = (u * st.c_b).sum(1)  # нормальная к кромке хордовая составляющая
        uz = (u * st.n_b).sum(1)  # по нормали панели (поперечное V даёт эффект скольжения)
        cs = self.cos_sweep
        a_geo = np.arctan2(uz, uc) * cs  # потоковый эквивалент угла атаки
        a_eff = a_geo + st.twist
        half = 0.5 * p.span
        yabs = np.abs(self.strips.r_n[:, 1]) / half
        if p.billow_shift_deg != 0.0 and self.xn is not None:
            # «перекос пузыря» (billow shift, Kroo 1981: киль-карман, плавающий киль): боковая
            # нагрузка стропы сдвигает киль относительно паруса — на стороне пилота крутка растёт
            d_b = R.T @ (self.xn[0] - (pos + R @ self.r_hang_b))
            lam = d_b[1] / max(d_b[2], 1e-3)
            a_eff = a_eff - st.side * math.radians(p.billow_shift_deg) * lam * yabs
        cl, cd_x, blend = self.strip_cl(a_eff)
        qn = 0.5 * p.rho * (uc * uc + uz * uz) / (cs * cs)
        if p.flex_relief < 1.0:
            # гибкий парус: разница нагрузок левой и правой консоли частично снимается круткой
            # (антисимметричная часть нагрузки × flex_relief; симметричная уже в поляре)
            n2 = len(cl) // 2
            lR, lL = qn[:n2] * cl[:n2], qn[n2:] * cl[n2:]
            m_, d_ = 0.5 * (lR + lL), 0.5 * (lR - lL) * p.flex_relief
            cl = np.concatenate([(m_ + d_) / np.maximum(qn[:n2], 1e-6), (m_ - d_) / np.maximum(qn[n2:], 1e-6)])
        cd = self.cd_scale * (p.polar.cd_at(np.clip(cl, -2, p.polar.cl_max)) - self.cd_pilot_share) + cd_x
        # направления в B
        un = st.c_b * uc[:, None] + st.n_b * uz[:, None]
        lift_dir = np.cross(st.s_b, un)
        lift_dir *= np.where(lift_dir[:, 2] > 0, -1.0, 1.0)[:, None]
        nrm = np.linalg.norm(lift_dir, axis=1, keepdims=True)
        lift_dir = lift_dir / np.maximum(nrm, 1e-9)
        umag = np.linalg.norm(u, axis=1, keepdims=True)
        drag_dir = -u / np.maximum(umag, 1e-9)
        f_b = (qn * self.sc)[:, None] * (cl[:, None] * lift_dir + cd[:, None] * drag_dir)
        F_b = f_b.sum(0)
        M_b = np.cross(self.r_strip_b, f_b).sum(0)
        # добавка Cm0 (если задана) — по скоростному напору в ЦМ
        v_c = vel - self.air_fn(pos[None])[0]
        V = float(np.linalg.norm(v_c))
        M_b[1] += 0.5 * p.rho * V * V * p.area * p.chord_mean * p.dcm0
        if self.yaw_mode == "free":
            vf = (v_c + np.cross(w, R @ self.r_fin_b)) @ R
            beta_f = math.atan2(vf[1], max(vf[0], 0.1))
            fy = -0.5 * p.rho * (vf[0] ** 2 + vf[1] ** 2) * p.fin_area * p.fin_slope * beta_f
            ff = np.array([0.0, fy, 0.0])
            F_b += ff
            M_b += np.cross(self.r_fin_b, ff)
        info = {"cl": cl, "a": a_eff, "blend": blend, "V": V, "lift": float(-F_b[2])}
        return R @ F_b, R @ M_b, info

    # ------------------------------------------------------------------ состояние
    def hang_world(self, pos=None, R=None):
        pos = self.pos if pos is None else pos
        R = self.R if R is None else R
        return pos + R @ self.r_hang_b

    def pilot_rel_b(self):
        """Положение пилота относительно H в осях крыла."""
        return self.R.T @ (self.xn[-1] - self.hang_world())

    def reset_air(self, state):
        """state: dict из trim.steady_state (pos, vel, R, pilot_dir_b, ...)."""
        self.t = 0.0
        self.pos = np.array(state["pos"], float)
        self.vel = np.array(state["vel"], float)
        self.R = np.array(state["R"], float)
        self.w = np.zeros(3)
        d_b = np.array(state["pilot_dir_b"], float)
        H = self.hang_world()
        d_w = self.R @ d_b
        self.xn = np.stack([H + d_w * self.link_len * (i + 1) for i in range(self.n_links)])
        self.vn = np.tile(self.vel, (self.n_links, 1))
        self.neutral_rel = d_b * self.p.hang_len
        self.on_ground = False

    # ------------------------------------------------------------------ шаг
    def step(self, control: Control):
        self.control = control
        h = self.dt / self.substeps
        for _ in range(self.substeps):
            self._substep(h)
        self.t += self.dt

    def _hands_force(self, H, v_wing_pt_bar):
        """Сила рук на пилота (мир). Цель — положение пилота отн. H в осях крыла (x, y)."""
        p = self.p
        c = self.control
        if c.arms_relaxed:
            self.hands_force_b = np.zeros(3)
            self.arm_int = np.zeros(3)
            return np.zeros(3)
        R = self.R
        rel = R.T @ (self.xn[-1] - H)
        # относительная скорость в осях крыла (во вращающейся системе)
        vH = self.vel + np.cross(self.w, R @ self.r_hang_b)
        vrel_w = self.vn[-1] - vH - np.cross(self.w, self.xn[-1] - H)
        vrel = R.T @ vrel_w
        tgt = self.neutral_rel.copy()
        ry = max(-1.0, min(1.0, c.roll))
        px = max(-1.0, min(1.0, c.pitch))
        tgt[1] += ry * p.shift_y_max
        tgt[0] += -px * (p.shift_x_push if px > 0 else p.shift_x_pull)
        k = p.m_pilot / p.arm_tau ** 2
        d = 2.0 * p.m_pilot / p.arm_tau
        e = tgt - rel
        e[2] = 0.0
        # руки — пружина-демпфер плюс прямая подача силы маятника m·g/L·(цель − нейтраль): пилот,
        # сдвинутый от нейтрали на Δ, тянется стропой назад силой ≈ m·g·Δ/L — руки держат её сразу
        # (PD-19). Интеграл (arm_ti > 0) — только для сравнения: ПИ-удержание с 0,6 с раскачивало
        # фугоиду (затухание sport 0,95 за период вместо 0,80), большие размахи — срыв и петля.
        if p.arm_ti > 0:
            self.arm_int = self.arm_int + e * self._h / p.arm_ti
        f = k * (e + self.arm_int) - d * vrel
        L = float(np.linalg.norm(self.neutral_rel))
        if L > 0.1:
            off = tgt - self.neutral_rel
            off[2] = 0.0
            f = f + off * (p.m_pilot * G / L)
        f[2] = 0.0  # вертикально — стропа, не руки
        n = math.hypot(f[0], f[1])
        if n > p.arm_force_max:
            f *= p.arm_force_max / n
            # антинасыщение: интеграл не копится сверх того, что руки могут дать
            if p.arm_ti > 0:
                self.arm_int = self.arm_int - e * self._h / p.arm_ti
        if c.force_y is not None:
            f[1] = c.force_y
            n = math.hypot(f[0], f[1])
            if n > p.arm_force_max:
                f *= p.arm_force_max / n
        self.hands_force_b = f
        return R @ f

    def _ground_hands(self, H):
        """Земля: руки держат стойки у плеч. Сила между точкой хвата и плечами пилота (выше ЦМ на
        0,45 м), PD с насыщением; вниз руки крыло почти не тянут (крыло «лежит» на руках)."""
        p = self.p
        R = self.R
        grip = self.pos + R @ self.r_grip_b
        shoulder = self.xn[-1] + np.array([0.6, 0.0, -0.45]) @ np.eye(3)  # пилот лицом на север
        shoulder = self.xn[-1] + np.array([0.35, 0.0, -0.45])
        vg = self.vel + np.cross(self.w, R @ self.r_grip_b)
        k = 3000.0
        d = 2 * math.sqrt(k * p.m_wing)
        f_w = k * (shoulder - grip) + d * (self.vn[-1] - vg)  # на крыло
        # вниз (z+) на крыло руки дают не больше 100 Н: подъёмную силу не держат
        f_w[2] = min(f_w[2], 100.0)
        n = float(np.linalg.norm(f_w))
        lim = 600.0
        if n > lim:
            f_w *= lim / n
        return f_w

    def _ground_torque(self):
        """Руки на стойках задают тангаж и крен крыла (как GroundRun: предел ∝ доле веса на ногах)."""
        p = self.p
        c = self.control
        ps, th, ph = euler_from_R(self.R)
        th_cmd = math.radians(float(self.p.extra.get("launch_theta_deg", 14.0))) + c.pitch * math.radians(10)
        ph_cmd = c.roll * math.radians(15)
        wb = self.R.T @ self.w
        Ixx, Iyy = self.I_b[0, 0], self.I_b[1, 1]
        tau = 0.3
        # тангаж: руки держат нос жёстко (300 Н·м на 10°, EST), и в подвеске тоже — пока руки на стойках
        k_th = 300.0 / math.radians(10.0)
        m_th = k_th * (th_cmd - th) - 2 * math.sqrt(k_th * Iyy) * wb[1]
        m_ph = Ixx / tau ** 2 * (ph_cmd - ph) - 2 * Ixx / tau * wb[0]
        lim_th = 300.0
        lim_ph = 200.0 * self.feet_load
        return self.R @ np.array([np.clip(m_ph, -lim_ph, lim_ph), np.clip(m_th, -lim_th, lim_th), 0.0])

    def _legs(self):
        """Ноги: опора (пружина-демпфер, только толкает) и бег (сила F(1−v/v_max)·N/W вдоль склона)."""
        p = self.p
        gnd = self.ground
        x = self.xn[-1]
        hgt = gnd.height(x[0], x[1])
        cg_h = 1.0  # м, ЦМ стоящего пилота над ступнями
        pen = (-x[2]) - (hgt + cg_h)  # >0 — выше роста (ноги не достают)
        F = np.zeros(3)
        if pen < 0.0:
            # нога — пружина-демпфер (критическое демпфирование для массы пилота), только толкает
            k = 3.0e4
            d = 2.0 * math.sqrt(k * self.p.m_pilot)
            vz_gnd = gnd.slope_tan * self.vn[-1][0]  # склон уходит вниз под бегущим (NED: + вниз)
            Fz = max(k * (-pen) + d * (self.vn[-1][2] - vz_gnd), 0.0)  # вверх (−z в NED)
            F[2] = -Fz
            self.feet_load = min(Fz / (self.p.m_total * G), 1.0)
            self.on_ground = True
            if self.control.run:
                vx = self.vn[-1][0]
                v_cap = 6.5 * (1 + 0.3 * (1 - self.feet_load))
                fr = 420.0 * (1 - vx / v_cap)
                if fr < 0:
                    fr *= self.feet_load
                F[0] += fr
            # боковое трение ног
            F[1] += -min(abs(self.vn[-1][1]) * 2000.0, 0.8 * Fz) * np.sign(self.vn[-1][1])
            if not self.control.run:
                F[0] += -min(abs(self.vn[-1][0]) * 2000.0, 0.8 * Fz) * np.sign(self.vn[-1][0])
        else:
            self.feet_load = 0.0
            self.on_ground = False
        return F

    def _substep(self, h):
        p = self.p
        R = self.R
        H = self.hang_world()
        # силы
        Fa, Ma, info = self.wing_aero(self.pos, self.vel, R, self.w)
        self._last_info = info
        F_w = Fa + self.p.m_wing * G * E3
        M_w = Ma.copy()
        F_n = self.m_nodes[:, None] * G * E3[None].repeat(self.n_links, 0)
        # сопротивление пилота
        xp, vp = self.xn[-1], self.vn[-1]
        va = vp - self.air_fn(xp[None])[0]
        F_n[-1] += -0.5 * p.rho * p.pilot_cda * np.linalg.norm(va) * va
        if self.control.hands == "bar":
            fh = self._hands_force(H, None)
            F_n[-1] += fh
            # продольная сила рук — в середине штанги (момент по тангажу); поперечная — на высоте
            # штанги, но на продольной координате ЦМ пилота: пилот держит тело перпендикулярно штанге
            # разнонаправленными усилиями рук (Takamatsu & Ochi 2022, Tdx), поэтому пара «боковая
            # сила на штанге — боковая сила стропы» по рысканию на крыло не передаётся.
            fb = self.hands_force_b
            rb_x = R @ self.r_bar_b
            r_pil_b = R.T @ (self.xn[-1] - self.pos)
            rb_y = R @ np.array([r_pil_b[0], 0.0, self.r_bar_b[2]])
            fx_w = R @ np.array([fb[0], 0.0, 0.0])
            fy_w = R @ np.array([0.0, fb[1], 0.0])
            F_w += -fh
            M_w += np.cross(rb_x, -fx_w) + np.cross(rb_y, -fy_w)
        else:
            fw = self._ground_hands(H)
            # крыло лежит на плечах и руках: вертикальная опора — под ЦМ крыла (пилот несёт
            # крыло уравновешенным), горизонтальная — в хвате за стойки; тангаж и крен держат руки
            rg = R @ self.r_grip_b
            r_sup = R @ np.array([0.0, 0.0, self.r_grip_b[2]])
            fv = np.array([0.0, 0.0, fw[2]])
            fhz = fw - fv
            F_w += fw
            M_w += np.cross(rg, fhz) + np.cross(r_sup, fv)
            F_n[-1] += -fw
            M_w += self._ground_torque()
        if self.ground is not None:
            F_n[-1] += self._legs()
        # интегрирование скоростей и позиций
        pos_prev, R_prev, xn_prev = self.pos.copy(), R.copy(), self.xn.copy()
        self.vel = self.vel + h * F_w / p.m_wing
        wb = R.T @ self.w
        tb = R.T @ M_w
        # гироскопический член — только по инерции конструкции: присоединённая масса воздуха
        # (крен) — не твёрдое тело, она добавляет инерцию, но не даёт ω×Iω
        wb = wb + h * self.I_b_inv @ (tb - np.cross(wb, self.I_struct @ wb))
        self.w = R @ wb
        self.pos = self.pos + h * self.vel
        self.R = orthonormalize(expm_so3(h * self.w) @ R)
        self.vn = self.vn + h * F_n / self.m_nodes[:, None]
        self.xn = self.xn + h * self.vn
        if self.yaw_mode == "noslip":
            self._project_noslip()
        # связи: звенья цепи (только растяжение)
        alpha_t = p.strap_compliance / self.n_links / (h * h)
        Iw_inv = self.R @ self.I_b_inv @ self.R.T
        tension = 0.0
        for i in range(self.n_links):
            b = self.xn[i]
            if i == 0:
                a = self.hang_world()
            else:
                a = self.xn[i - 1]
            d = b - a
            L = float(np.linalg.norm(d))
            C = L - self.link_len
            if C <= 0.0 or L < 1e-9:
                continue
            n = d / L
            wb_ = 1.0 / self.m_nodes[i]
            if i == 0:
                r = a - self.pos
                rn = np.cross(r, n)
                wa = 1.0 / p.m_wing + float(rn @ Iw_inv @ rn)
            else:
                wa = 1.0 / self.m_nodes[i - 1]
            dl = -C / (wa + wb_ + alpha_t)
            self.xn[i] = b + wb_ * dl * n
            if i == 0:
                self.pos = self.pos - dl * n / p.m_wing
                dth = Iw_inv @ np.cross(r, -dl * n)
                self.R = orthonormalize(expm_so3(dth) @ self.R)
                tension = -dl / (h * h)
            else:
                self.xn[i - 1] = a - wa * dl * n
            self.max_stretch = max(self.max_stretch, C)
        self.strap_tension = tension
        # скорости из позиций
        self.vel = (self.pos - pos_prev) / h
        self.w = logm_so3(self.R @ R_prev.T) / h
        self.vn = (self.xn - xn_prev) / h

    def _project_noslip(self):
        """Этап A: курс крыла — так, чтобы боковая составляющая воздушной скорости ЦМ была 0."""
        v = self.vel - self.air_fn(self.pos[None])[0]
        ps, th, ph = euler_from_R(self.R)
        sth, cth, sph, cph = math.sin(th), math.cos(th), math.sin(ph), math.cos(ph)
        A = v[0] * sth * sph + v[1] * cph
        B = -v[0] * cph + v[1] * sth * sph
        C = v[2] * cth * sph
        Rr = math.hypot(A, B)
        if Rr < 1e-6:
            return
        d = math.atan2(B, A)
        x = max(-1.0, min(1.0, -C / Rr))
        c1 = d + math.acos(x)
        c2 = d - math.acos(x)
        pick = c1 if abs(math.remainder(c1 - ps, 2 * math.pi)) < abs(math.remainder(c2 - ps, 2 * math.pi)) else c2
        R_new = R_from_euler(pick, th, ph)
        # поворот вокруг ЦМ крыла (пилот — отдельное тело, догоняет через стропу)
        self.R = R_new

    # ------------------------------------------------------------------ наблюдаемые
    def observe(self):
        ps, th, ph = euler_from_R(self.R)
        v_air = self.vel - self.air_fn(self.pos[None])[0]
        V = float(np.linalg.norm(v_air))
        vb = self.R.T @ v_air
        alpha = math.atan2(vb[2], vb[0])
        beta = math.asin(max(-1, min(1, vb[1] / max(V, 1e-6))))
        rel = self.pilot_rel_b()
        wb = self.R.T @ self.w
        # крен пилота: наклон звена к вертикали в плоскости, поперечной курсу крыла
        d = self.xn[-1] - self.hang_world()
        right = np.array([-math.sin(ps), math.cos(ps), 0.0])
        pilot_roll = math.atan2(float(d @ right), float(d[2]))
        info = getattr(self, "_last_info", None)
        stall_frac = float(np.mean(info["blend"] > 0.01)) if info is not None else 0.0
        return {
            "t": self.t, "x": self.pos[0], "y": self.pos[1], "h": -self.pos[2],
            "psi": ps, "theta": th, "phi": ph, "V": V, "alpha": alpha, "beta": beta,
            "p": wb[0], "q": wb[1], "r": wb[2],
            "vz": -self.vel[2], "rel_x": rel[0], "rel_y": rel[1], "rel_z": rel[2],
            "fh_x": self.hands_force_b[0], "fh_y": self.hands_force_b[1],
            "tension": self.strap_tension, "pilot_roll": pilot_roll,
            "xp": self.xn[-1][0], "yp": self.xn[-1][1], "hp": -self.xn[-1][2],
            "vxp": self.vn[-1][0], "vyp": self.vn[-1][1], "vzp": -self.vn[-1][2],
            "feet": self.feet_load, "stall_frac": stall_frac,
        }
