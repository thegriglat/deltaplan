"""Модель буксировщика-дельталёта (TT-1): двигатель, винт, крыло. Только stdlib."""
import math

RHO = 1.225
G = 9.81

def interp(x, xs, ys):
    if x <= xs[0]: return ys[0]
    if x >= xs[-1]: return ys[-1]
    for i in range(1, len(xs)):
        if x <= xs[i]:
            t = (x - xs[i-1]) / (xs[i] - xs[i-1])
            return ys[i-1] + t * (ys[i] - ys[i-1])

# --- двигатели: мощность (кВт) по оборотам двигателя ---
# Rotax 582 UL DCDI 48 кВт: паспорт даёт 48 кВт @6500, макс. момент 75 Нм @6000 (=47 кВт), 6800 макс.
# (rotax-owner.com, OM 582 UL). Остальные точки — оценка по почти плоскому моменту ~69-72 Нм.
R582 = dict(
    name="Rotax 582 UL DCDI", gear=3.47, rpm_idle_e=2000.0, rpm_max_e=6800.0,
    rpm=[2000, 3000, 4000, 5000, 5500, 6000, 6500, 6800],
    kw=[3.0, 10.0, 24.0, 36.0, 41.0, 47.0, 48.0, 47.0],
    D=1.8, static_rpm_e=5600.0, fm=0.60, eta_peak=0.72, k=0.35)
# Rotax 912 ULS (Tanarg/iXess 15): 73.5 кВт @5800; момент ~128 Нм ровный до 4600 (wings.json); редуктор 2.43
R912 = dict(
    name="Rotax 912 ULS", gear=2.43, rpm_idle_e=1400.0, rpm_max_e=5800.0,
    rpm=[1400, 2500, 3500, 4600, 5000, 5500, 5800],
    kw=[6.0, 33.0, 46.0, 61.7, 66.0, 71.0, 73.5],
    D=1.7, static_rpm_e=4600.0, fm=0.65, eta_peak=0.72, k=0.35)

class Prop:
    """Винт фиксированного шага: Ct=Ct0(1-J/J0), Cp=Cp0(1-k J/J0). Cp0 — по статическим оборотам,
    Ct0 — по статической тяге (FM), J0 — по пику КПД. Всё это калибровка, не паспорт."""
    def __init__(self, e):
        self.e = e
        self.D = e["D"]; self.k = e["k"]
        n = e["static_rpm_e"] / e["gear"] / 60.0
        P = self.p_eng(e["static_rpm_e"]) * 1000.0
        A = math.pi * self.D**2 / 4
        Tst = (2 * RHO * A) ** (1/3) * (e["fm"] * P) ** (2/3)
        self.T_static_design = Tst
        self.Ct0 = Tst / (RHO * n**2 * self.D**4)
        self.Cp0 = P / (RHO * n**3 * self.D**5)
        # J0 из пика КПД: eta(x)=J0*x*Ct0(1-x)/(Cp0(1-kx)), max по x
        best = 0
        for i in range(1, 1000):
            x = i / 1000
            f = x * (1 - x) / (1 - self.k * x)
            best = max(best, f)
        self.J0 = e["eta_peak"] * self.Cp0 / (self.Ct0 * best)
    def p_eng(self, rpm_e):
        return interp(rpm_e, self.e["rpm"], self.e["kw"])
    def coefs(self, J):
        x = J / self.J0
        return self.Ct0 * (1 - x), self.Cp0 * (1 - self.k * x)
    def thrust_at(self, V, n):
        J = V / (n * self.D)
        ct, _ = self.coefs(J)
        return ct * RHO * n**2 * self.D**4
    def full(self, V):
        """Полный газ: обороты винта (об/мин), тяга Н, КПД. Равновесие P_eng = P_prop."""
        e = self.e; g = e["gear"]
        lo, hi = e["rpm_idle_e"], e["rpm_max_e"]
        def resid(re):
            n = re / g / 60
            J = V / (n * self.D)
            _, cp = self.coefs(J)
            return self.p_eng(re) * 1000 - cp * RHO * n**3 * self.D**5
        if resid(hi) > 0: re = hi  # винт не нагружает до красной черты: ограничение оборотов
        else:
            for _ in range(80):
                mid = (lo + hi) / 2
                if resid(mid) > 0: lo = mid
                else: hi = mid
            re = (lo + hi) / 2
        n = re / g / 60
        T = max(0.0, self.thrust_at(V, n))
        eta = T * V / (self.p_eng(re) * 1000) if V > 0 else 0.0
        return re / g, T, eta
    def idle(self, V):
        n = self.e["rpm_idle_e"] / self.e["gear"] / 60
        return max(0.0, self.thrust_at(V, n))

# --- крыло iXess 15 (параболическая поляра, калибровка по HADS HM16) ---
class Wing:
    S = 15.0; AR = 6.66; e = 0.75
    MTOW = 450.0; VS_MTOW = 59.3 / 3.6; V_GLIDE = 74.1 / 3.6; LD_SYS = 6.6
    def __init__(self, cda_cart):
        self.k = 1 / (math.pi * self.e * self.AR)
        W = self.MTOW * G
        q = 0.5 * RHO * self.V_GLIDE**2
        d_sys = W / self.LD_SYS
        d_wing = d_sys - q * cda_cart
        CL = W / (q * self.S)
        CD = d_wing / (q * self.S)
        self.CD0 = CD - self.k * CL**2
        self.CLmax = W / (0.5 * RHO * self.VS_MTOW**2 * self.S)
    def cd(self, cl): return self.CD0 + self.k * cl**2
    def drag(self, V, L):
        cl = L / (0.5 * RHO * V**2 * self.S)
        return cl, self.cd(cl) * 0.5 * RHO * V**2 * self.S
    def vstall(self, mass):
        return math.sqrt(mass * G / (0.5 * RHO * self.S * self.CLmax))
    def best_ld(self):
        cl = math.sqrt(self.CD0 / self.k); return cl, cl / self.cd(cl)
