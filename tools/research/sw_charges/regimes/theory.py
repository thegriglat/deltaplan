"""Теория literature.md §2 (M_c, M_s, бор, лее-сторона, прыжок на склоне) и правило R1 (§7)."""
from math import sqrt, log, atanh


def Mc(F):
    return 1 + F * F / 2 - 1.5 * F ** (2 / 3)



def conj_q(h, q):
    Fr = q / h ** 1.5
    return h * (sqrt(1 + 8 * Fr * Fr) - 1) / 2


def Ms(F):
    h1 = (sqrt(1 + 8 * F * F) - 1) / 2
    return h1 + F * F / (2 * h1 * h1) - 1.5 * F ** (2 / 3), h1


def bore(F, M):
    """(h1, s, U1) за бором; None — нет решения (литература §10, скрипт без изменений по смыслу)."""
    def st(h):
        return (sqrt(h * (h + 1) / 2) - F, sqrt(h * (h + 1) / 2) / h - (sqrt(h * (h + 1) / 2) - F))

    def g(h):
        s, U = st(h)
        return None if U <= 0 else h + U * U / 2 - M - 1.5 * (h * U) ** (2 / 3)
    prev = None
    for i in range(1, 8000):
        h = 1 + i * 0.0005
        v = g(h)
        if v is None:
            return None
        if prev is not None and prev[1] < 0 <= v:
            a, b = prev[0], h
            for _ in range(80):
                m = (a + b) / 2
                if g(m) < 0:
                    a = m
                else:
                    b = m
            return (a,) + st(a)
        prev = (h, v)
    return None


def regime_theory(F0, M):
    if M >= 1:
        return "R6"
    if F0 < 1:
        return "R1" if M < Mc(F0) else "R3"
    ms, mc = Ms(F0)[0], Mc(F0)
    if M < ms:
        return "R2"
    if M < mc:
        return "R2|R4j"
    return "R5"


def root_super(E, q):
    """Сверхкритический корень h + q²/(2h²) = E (h ≤ q^(2/3))."""
    hc = q ** (2 / 3)
    if E <= 1.5 * hc:
        return hc
    a, b = 1e-9, hc
    for _ in range(100):
        m = (a + b) / 2
        if m + q * q / (2 * m * m) > E:
            a = m
        else:
            b = m
    return (a + b) / 2


def root_sub(E, q):
    hc = q ** (2 / 3)
    if E <= 1.5 * hc:
        return hc
    a, b = hc, E
    for _ in range(100):
        m = (a + b) / 2
        if m + q * q / (2 * m * m) > E:
            b = m
        else:
            a = m
    return (a + b) / 2


def jump_branch(zb_over_h0, x_over_a, F0, M, xmin_a=-4.0):
    """Теоретическая ветвь с прыжком на наветренном склоне (literature §2.2–2.3, R4j) в единицах h0, c.
    zb_over_h0, x_over_a — 1D массивы (x в единицах a). Возвращает (h, x_j/a, z_j, clipped) в единицах h0."""
    import numpy as np
    q = F0
    E0 = 1 + F0 * F0 / 2
    target = M + 1.5 * q ** (2 / 3)

    def E2(zj):
        hu = root_super(E0 - zj, q)
        h2 = conj_q(hu, q)
        return zj + h2 + q * q / (2 * h2 * h2)
    lo, hi = 0.0, M
    for _ in range(100):
        m = (lo + hi) / 2
        if E2(m) < target:
            lo = m
        else:
            hi = m
    zj = (lo + hi) / 2
    zb = np.asarray(zb_over_h0, float)
    x = np.asarray(x_over_a, float)
    icrest = int(np.argmax(zb))
    clipped = False
    # первый индекс на склоне (x ≥ xmin_a), где земля ≥ z_j
    idx = np.where((x >= xmin_a) & (zb >= zj) & (np.arange(len(x)) <= icrest))[0]
    ij = int(idx[0]) if len(idx) else icrest
    if x[ij] > 0 and ij > 0:
        ij = icrest
    if zb[ij] > zj * 1.0 + 1e-12 and x[max(ij - 1, 0)] < xmin_a + 1e-9 and ij == int(np.argmax(x >= xmin_a)):
        clipped = True
        zj = float(zb[ij])
    E_head = E2(zj)
    h = np.empty_like(zb)
    for i in range(len(x)):
        if i < ij:
            h[i] = root_super(E0 - zb[i], q)
        elif i <= icrest:
            h[i] = root_sub(E_head - zb[i], q)
        else:
            h[i] = root_super(E_head - zb[i], q)
    return h, float(x[ij]), zj, clipped


def u10_from_usat(U_sat, alpha=0.24, f=1.1e-4, z0=0.1, kappa=0.4):
    """U10 из U_sat = U10·(z_sat/10)^α, z_sat = 0,3·h, h = 0,3·u*/f, u* = κ·U10/ln(10/z0) (limits.md Б2; нейтральная D).
    Возвращает (U10, z_sat)."""
    def usat(U10):
        ustar = kappa * U10 / log(10 / z0)
        zs = 0.3 * 0.3 * ustar / f
        return U10 * (zs / 10) ** alpha, zs
    lo, hi = 1e-3, 100.0
    for _ in range(100):
        m = (lo + hi) / 2
        if usat(m)[0] < U_sat:
            lo = m
        else:
            hi = m
    U10 = (lo + hi) / 2
    return U10, usat(U10)[1]


def u0_layer(U10, z_sat, h0, alpha=0.24):
    """R1 п. 2: U0 = ⟨U⟩ по слою 0…h0 профиля U10·(z/10)^α до z_sat, дальше константа."""
    U_sat = U10 * (z_sat / 10) ** alpha
    if h0 <= z_sat:
        return U10 * 10 ** (-alpha) * h0 ** alpha / (1 + alpha)
    integ = U10 * 10 ** (-alpha) * z_sat ** (1 + alpha) / (1 + alpha)
    return (integ + U_sat * (h0 - z_sat)) / h0


def cd_r1(h0, z0=0.1, kappa=0.4):
    """R1 п. 4: c_d = [κ/ln(0,37·h0/z0)]²."""
    return (kappa / log(0.37 * h0 / z0)) ** 2
