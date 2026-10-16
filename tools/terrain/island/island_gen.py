"""Учебный остров: рельеф fs1 (поднятие из форм × маска острова, речная эрозия fastscapelib + диффузия + тепловая
эрозия, θ — docs/research/terrain_tuning.md §5–6), детализация до 25 м и карта классов 25 м + маски 10 м — процедурно.

Координаты — как в игре (scripts/terrain/geo.gd): X — восток, Z — юг (−Z — север), начало — центр места, метры.
Массивы — [j, i]: строка j растёт на юг (+Z), столбец i — на восток (+X).
Детерминизм: все случайные выборы — из SeedSequence([SEED, k]); fastscapelib и numba — однопоточно
(OMP_NUM_THREADS=1, NUMBA_NUM_THREADS=1 ставит build_island.py до импорта).
"""
import numpy as np
from numba import njit
from scipy import ndimage
import fastscapelib as fs

# --- параметры (все попадают в params.json) ---------------------------------------------------------------
P = {
    "seed": 20261016,
    # расчёт fs1
    "fs_n": 201, "fs_dx_m": 100.0,                     # 201 × 100 м = ±10 км, узел 100 — точка (0, 0)
    "t_total_yr": 8.0e6, "dt_yr": 1.0e5,
    # θ: Онгудай (uplift, k0) + пул (diffusion, m, tan_crit), terrain_tuning.md §5; fourier — малая (формы задаёт план)
    "uplift_max_m_per_yr": 1.6e-4, "k0": 1.3e-6, "k_logsd": 0.5, "k_beta": 1.6,
    "m_exp": 0.42, "n_exp": 1.0, "diffusion_m2_per_yr": 0.01, "tan_crit": 0.9, "thermal_passes": 5,
    "fourier_amp": 0.12, "fourier_beta": 1.9, "noise_m": 2.0,
    "uplift_floor": 0.05,                               # доля поднятия равнины (внутри острова)
    "uplift_mask_km": 0.9,                              # поднятие нарастает от берега на этом расстоянии
    # остров: суперэллипс (полуоси на запад/восток/север/юг, км) + шум берега
    "isl_west_km": 6.4, "isl_east_km": 7.4, "isl_north_km": 5.0, "isl_south_km": 5.0, "isl_p": 2.4,
    "coast_noise_km": 0.35,
    # подгонка после fs1
    "crest_target_m": 500.0,                            # вершина главного хребта
    "plain_max_m": 75.0,                                # равнина: мягкий потолок высот
    "detail_noise_m": 1.2,                              # мелкий шум 25 м на суше
    "beach_min_m": 0.4,                                 # высота суши у самой воды
    # озеро на равнине
    "lake_x_km": 1.6, "lake_z_km": 2.6, "lake_r_km": 0.38,
}

# Формы поднятия (км; θ — от +X к +Z, т.е. 90° — вдоль С–Ю). ridge: (x, z, θ°, высота, σ_запад/«левый», σ_правый, L/2, край)
RIDGES = {
    "main_ridge":   (-4.8, -0.9, 90.0, 1.00, 0.95, 0.55, 3.0, 0.8),   # хребет С–Ю на западе, наветренный склон к морю
    "south_spur":   (-4.1, 2.7, 55.0, 0.42, 0.45, 0.55, 1.3, 0.6),    # южный отрог над равниной — старт «термики»
    "bowl_rim":     (-3.1, -1.4, 90.0, 0.38, 0.30, 0.6, 1.2, 0.5),    # восточный борт чаши — старт «ротор»
    "north_spur":   (-3.6, -3.1, 0.0, 0.30, 0.40, 0.40, 1.0, 0.5),    # северная перемычка чаши
}
# blob: (x, z, θ°, высота, σ_u, σ_v)
BLOBS = {
    "landing_hill": (3.6, -1.8, 90.0, 0.22, 0.9, 0.35),               # холм посадки 80–150 м
}


def rng_for(k):
    return np.random.default_rng(np.random.SeedSequence([P["seed"], k]))


def fs_axes():
    n, dx = P["fs_n"], P["fs_dx_m"]
    c = (n - 1) // 2
    return (np.arange(n) - c) * dx


@njit(cache=True)
def _thermal(z, dx, Sc, npass, fixed):
    """Тепловая эрозия (копия fs1 corpus/generator.py, + маска неподвижных узлов — море)."""
    n, m = z.shape
    for _ in range(npass):
        for i in range(n):
            for j in range(m):
                for di in (-1, 0, 1):
                    for dj in (-1, 0, 1):
                        if di == 0 and dj == 0:
                            continue
                        ii = i + di
                        jj = j + dj
                        if ii < 0 or jj < 0 or ii >= n or jj >= m:
                            continue
                        d = dx * (1.41421356 if (di != 0 and dj != 0) else 1.0)
                        ex = z[i, j] - z[ii, jj] - Sc * d
                        if ex > 0:
                            t = 0.125 * ex
                            if not fixed[i, j]:
                                z[i, j] -= t
                            if not fixed[ii, jj]:
                                z[ii, jj] += t


def gauss_field(shape, beta, rng):
    """Изотропное гауссово поле, спектр профиля ~ k^-beta, std 1 (как _field fs1 без вытянутости)."""
    ny, nx = shape
    ky = np.fft.fftfreq(ny)[:, None]
    kx = np.fft.fftfreq(nx)[None, :]
    K = np.sqrt(kx ** 2 + ky ** 2)
    K[0, 0] = 1
    amp = K ** (-(beta + 1) / 2.0)
    amp[0, 0] = 0
    f = np.fft.ifft2(amp * np.fft.fft2(rng.standard_normal(shape))).real
    return (f - f.mean()) / f.std()


def _ridge(f, X, Z):
    x0, z0, th, h, s1, s2, L, w = f
    c, s = np.cos(np.radians(th)), np.sin(np.radians(th))
    u = (X - x0) * c + (Z - z0) * s
    v = -(X - x0) * s + (Z - z0) * c
    sg = np.where(v > 0, s1, s2)
    S = 0.5 * (np.tanh((u + L) / w) - np.tanh((u - L) / w))
    return h * np.exp(-0.5 * (v / sg) ** 2) * S


def _blob(f, X, Z):
    x0, z0, th, h, su, sv = f
    c, s = np.cos(np.radians(th)), np.sin(np.radians(th))
    u = (X - x0) * c + (Z - z0) * s
    v = -(X - x0) * s + (Z - z0) * c
    return h * np.exp(-0.5 * ((u / su) ** 2 + (v / sv) ** 2))


def _coast_noise():
    """Шум радиуса берега по азимуту: сумма гармоник 2..12 с убывающей амплитудой (детерминированно)."""
    rng = rng_for(11)
    ks = np.arange(2, 13)
    amp = rng.standard_normal(len(ks)) / ks ** 1.2
    ph = rng.uniform(0, 2 * np.pi, len(ks))
    norm = P["coast_noise_km"] / np.sqrt(0.5 * np.sum(amp ** 2))

    def f(ang):
        out = np.zeros_like(ang)
        for k, a, p in zip(ks, amp, ph):
            out += a * np.cos(k * ang + p)
        return out * norm
    return f


_COAST = None


def island_r(Xkm, Zkm):
    """Нормированный «радиус» суперэллипса с шумом: < 1 — суша, > 1 — море."""
    global _COAST
    if _COAST is None:
        _COAST = _coast_noise()
    a = np.where(Xkm < 0, P["isl_west_km"], P["isl_east_km"])
    b = np.where(Zkm < 0, P["isl_north_km"], P["isl_south_km"])
    p = P["isl_p"]
    r = (np.abs(Xkm / a) ** p + np.abs(Zkm / b) ** p) ** (1 / p)
    ang = np.arctan2(Zkm, Xkm)
    rad = np.sqrt(Xkm ** 2 + Zkm ** 2) + 1e-9
    # шум радиуса в км → в долях нормированного радиуса
    return r * (1.0 - _COAST(ang) / np.maximum(rad / np.maximum(r, 1e-9), 1e-3))


def lake_r(Xkm, Zkm):
    rng = rng_for(12)
    ks = np.arange(2, 7)
    amp = rng.standard_normal(len(ks)) * 0.06 / ks
    ph = rng.uniform(0, 2 * np.pi, len(ks))
    dx, dz = Xkm - P["lake_x_km"], (Zkm - P["lake_z_km"]) / 0.7
    ang = np.arctan2(dz, dx)
    w = 1.0 + sum(a * np.cos(k * ang + p) for k, a, p in zip(ks, amp, ph))
    return np.sqrt(dx ** 2 + dz ** 2) / (P["lake_r_km"] * w)


def forms(X, Z):
    """Сумма форм поднятия (без поля Фурье), X, Z в км."""
    u = np.zeros_like(X)
    for f in RIDGES.values():
        u += _ridge(f, X, Z)
    for f in BLOBS.values():
        u += _blob(f, X, Z)
    return u


def uplift_field(X, Z, land):
    """Безразмерное поднятие 0..1 на сетке fs1 (формы + слабое поле Фурье) × маска острова."""
    u = forms(X, Z)
    u = u + P["fourier_amp"] * np.clip(gauss_field(X.shape, P["fourier_beta"], rng_for(1)), -2.5, 2.5)
    u = np.clip(u, 0, None)
    dist_km = ndimage.distance_transform_edt(land) * P["fs_dx_m"] / 1000.0
    m = np.clip(dist_km / P["uplift_mask_km"], 0, 1)
    m = m * m * (3 - 2 * m)
    return (P["uplift_floor"] + (1 - P["uplift_floor"]) * u) * m


def run_fs1():
    """fs1 на 100 м: возвращает (оси x, z в м, z100 [j, i] м, uplift, land)."""
    ax = fs_axes()
    X, Z = np.meshgrid(ax / 1000.0, ax / 1000.0)
    land = island_r(X, Z) < 1.0
    n = P["fs_n"]
    u = uplift_field(X, Z, land)
    U = P["uplift_max_m_per_yr"] * u
    rng = rng_for(2)
    z = rng.uniform(0, P["noise_m"], (n, n)) * land
    K = P["k0"] * np.exp(P["k_logsd"] * gauss_field((n, n), P["k_beta"], rng_for(3)))
    grid = fs.RasterGrid([n, n], [P["fs_dx_m"]] * 2, fs.NodeStatus.FIXED_VALUE)
    graph = fs.FlowGraph(grid, [fs.SingleFlowRouter(), fs.MSTSinkResolver()])
    spl = fs.SPLEroder(graph, K, P["m_exp"], P["n_exp"], 1e-5)
    diff = fs.DiffusionADIEroder(grid, P["diffusion_m2_per_yr"])
    sea = ~land
    fixed = sea.copy()
    fixed[0, :] = fixed[-1, :] = fixed[:, 0] = fixed[:, -1] = True
    dt = P["dt_yr"]
    for _ in range(int(round(P["t_total_yr"] / dt))):
        graph.update_routes(z)
        A = graph.accumulate(1.0)
        er = spl.erode(z, A, dt)
        zn = z + U * dt - er
        zn -= diff.erode(zn, dt)
        zn[fixed] = 0.0                     # море — базис эрозии, 0 м
        z = np.ascontiguousarray(zn)
        _thermal(z, P["fs_dx_m"], P["tan_crit"], int(P["thermal_passes"]), fixed)
    return ax, z, u, land


# --- детализация до 25 м ------------------------------------------------------------------------------------
D_N, D_DX, D_O = 1601, 25.0, -20000.0         # detail: 40 км × 25 м
M_N, M_DX, M_O = 4001, 10.0, -20000.0         # маски 10 м
F_N, F_DX, F_O = 1601, 100.0, -80000.0        # far: 160 км × 100 м
H_STEP = 0.03125


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def detail_axes():
    return D_O + D_DX * np.arange(D_N)


def detail_heights(z100):
    """Высоты detail [j, i] (м, float64): бикубика fs1 × масштаб под вершину хребта, мелкий шум, потолок равнины,
    пологий берег, озеро. Вне расчёта fs1 и в море — 0. Возвращает (h, info)."""
    ax = detail_axes()
    lo = int(round((-(P["fs_n"] - 1) / 2 * P["fs_dx_m"] - D_O) / D_DX))
    hi = D_N - 1 - lo
    sub = ax[lo:hi + 1]
    k = (sub + (P["fs_n"] - 1) / 2 * P["fs_dx_m"]) / P["fs_dx_m"]
    KJ, KI = np.meshgrid(k, k, indexing="ij")
    scale = P["crest_target_m"] / float(z100.max())
    zs = ndimage.map_coordinates(z100 * scale, [KJ, KI], order=3, mode="nearest")
    X, Z = np.meshgrid(sub / 1000.0, sub / 1000.0)
    land = island_r(X, Z) < 1.0
    dist = ndimage.distance_transform_edt(land) * D_DX
    # мелкий шум на суше (нарастает от берега на 200 м)
    zs = zs + P["detail_noise_m"] * gauss_field(zs.shape, 2.2, rng_for(4)) * smoothstep(0, 200, dist)
    zs = np.clip(zs, 0, None)
    # равнина: мягкий потолок высот там, где нет форм
    w = 1.0 - smoothstep(0.08, 0.3, forms(X, Z))
    cap = P["plain_max_m"]
    zs = zs + (cap * np.tanh(zs / cap) - zs) * w
    # берег: пологий пляж (профиль от воды), у хребта — круче по профилю
    beach = P["beach_min_m"] + 0.04 * dist + 0.002 * dist ** 2
    zs = np.where(land, np.maximum(np.minimum(zs, beach), P["beach_min_m"]), 0.0)
    # озеро: ровное зеркало и пологие берега
    lr = lake_r(X, Z)
    lake = (lr < 1.0) & land
    level = float(np.percentile(zs[lake], 20)) - 0.5
    bank = smoothstep(1.0, 1.0 + 0.12 / P["lake_r_km"], lr)          # ~120 м берега
    zs = np.where(lake, level, np.maximum(level + 0.3 + (zs - level) * bank, np.minimum(zs, level + 0.3)))
    zs = np.where(land, zs, 0.0)
    h = np.zeros((D_N, D_N))
    h[lo:hi + 1, lo:hi + 1] = zs
    h = np.round(h / H_STEP) * H_STEP
    land_full = np.zeros((D_N, D_N), bool)
    land_full[lo:hi + 1, lo:hi + 1] = land
    lake_full = np.zeros((D_N, D_N), bool)
    lake_full[lo:hi + 1, lo:hi + 1] = lake
    return h, {"scale": scale, "lake_level_m": level, "land": land_full, "lake": lake_full, "lo": lo, "hi": hi}


# --- карта классов 25 м и маски 10 м --------------------------------------------------------------------------
NONE, FOREST, GRASS, CROP, SHRUB, BARE, WATER = 0, 1, 2, 3, 4, 5, 6
C = {
    "parcel_angle_deg": 14.0, "parcel_u_m": (180.0, 420.0), "parcel_v_m": (120.0, 300.0),
    "p_crop": 0.28, "p_bare": 0.30, "p_grove": 0.10,            # доли участков равнины: пашня, голый грунт, роща
    "plain_forms_max": 0.2, "plain_slope_max_deg": 6.0, "plain_coast_m": 80.0,
    "forest_forms_min": 0.12, "rock_slope_deg": 34.0, "beach_m": 50.0, "beach_h_m": 5.0,
    "start_clear_m": 180.0, "landing_clear_m": 220.0,
}


def _parcels(X, Z):
    """Тип участка равнины по повёрнутой неравномерной сетке: 0..1 (равномерно) на участок, детерминированно."""
    a = np.radians(C["parcel_angle_deg"])
    u = X * np.cos(a) + Z * np.sin(a)
    v = -X * np.sin(a) + Z * np.cos(a)
    rng = rng_for(20)
    cu = -13000.0 + np.cumsum(rng.uniform(*C["parcel_u_m"], 200))
    cv = -13000.0 + np.cumsum(rng.uniform(*C["parcel_v_m"], 250))
    T = rng_for(21).uniform(size=(len(cu) + 1, len(cv) + 1))
    return T[np.searchsorted(cu, u), np.searchsorted(cv, v)]


def surface_maps(h, info, keep):
    """Карта классов detail 25 м (uint8 [j, i]) и маска 10 м: L — доля леса, A — вода (uint8, 4001²).
    keep — [(x, z, радиус_м, вид)]: «start» — без леса в круге; «landing» — луг без леса в круге."""
    lo25, hi25 = info["lo"], info["hi"]
    x0 = D_O + D_DX * lo25                                       # окно расчёта fs1 (−10 км)
    lo10 = int(round((x0 - M_O) / M_DX))
    hi10 = M_N - 1 - lo10
    ax10 = M_O + M_DX * np.arange(lo10, hi10 + 1)
    X, Z = np.meshgrid(ax10, ax10)
    Xk, Zk = X / 1000.0, Z / 1000.0
    sea = island_r(Xk, Zk) >= 1.0
    lake = (lake_r(Xk, Zk) < 1.0) & ~sea
    # высота и уклон 25 м → узлы 10 м (билинейно)
    f = (ax10 - D_O) / D_DX
    FJ, FI = np.meshgrid(f, f, indexing="ij")
    gz, gx = np.gradient(h, D_DX)                                 # dh/dz (юг), dh/dx (восток)
    h10 = ndimage.map_coordinates(h, [FJ, FI], order=1)
    gx10 = ndimage.map_coordinates(gx, [FJ, FI], order=1)
    gz10 = ndimage.map_coordinates(gz, [FJ, FI], order=1)
    slope10 = np.degrees(np.arctan(np.hypot(gx10, gz10)))
    fm = forms(Xk, Zk)
    dcoast = ndimage.distance_transform_edt(~sea) * M_DX
    dlake = ndimage.distance_transform_edt(~lake) * M_DX
    n1 = gauss_field(X.shape, 2.4, rng_for(30))
    cls = np.full(X.shape, GRASS, np.uint8)
    # равнина: участки пашни, голого грунта, луга и рощ
    plain = ~sea & ~lake & (fm < C["plain_forms_max"]) & (slope10 < C["plain_slope_max_deg"]) & (dcoast > C["plain_coast_m"])
    T = _parcels(X, Z)
    cls[plain & (T < C["p_crop"])] = CROP
    cls[plain & (T >= C["p_crop"]) & (T < C["p_crop"] + C["p_bare"])] = BARE
    forest = plain & (T >= 1.0 - C["p_grove"])
    # лес на подветренных (восточных) и северных склонах форм, не на наветренном склоне
    lee = (gx10 < -0.03) | (gz10 > 0.05)
    forest |= ~sea & ~lake & (fm >= C["forest_forms_min"]) & lee & (n1 > -0.2) & (slope10 < 32.0)
    # пляж, береговая полоса озера, скалы
    cls[~sea & (dcoast < C["beach_m"]) & (h10 < C["beach_h_m"])] = BARE
    forest &= (dcoast > 60.0) & (dlake > 30.0)
    cls[(dlake > 0) & (dlake <= 30.0)] = GRASS
    cls[slope10 > C["rock_slope_deg"]] = BARE
    # площадки: без леса, у посадок — луг
    for (kx, kz, r, kind) in keep:
        circ = (X - kx) ** 2 + (Z - kz) ** 2 <= r * r
        forest &= ~circ
        if kind == "landing":
            cls[circ & ~sea & ~lake] = GRASS
    forest &= ~sea & ~lake
    cls[forest] = FOREST
    cls[sea | lake] = WATER
    L = np.clip(np.round(ndimage.gaussian_filter(forest.astype(np.float64), 0.8) * 255.0), 0, 255).astype(np.uint8)
    L[sea | lake] = 0
    A = ((sea | lake) * 255).astype(np.uint8)
    L10 = np.zeros((M_N, M_N), np.uint8)
    A10 = np.full((M_N, M_N), 255, np.uint8)
    L10[lo10:hi10 + 1, lo10:hi10 + 1] = L
    A10[lo10:hi10 + 1, lo10:hi10 + 1] = A
    # 25 м: класс ближайшего узла 10 м; лес — маска L ≥ 0,5 билинейно; вода — как у высот (море 0 м, озеро)
    c25 = np.full((D_N, D_N), WATER, np.uint8)
    ax25 = detail_axes()[lo25:hi25 + 1]
    k10 = np.clip(np.round((ax25 - ax10[0]) / M_DX).astype(int), 0, len(ax10) - 1)
    sub = cls[np.ix_(k10, k10)].copy()
    f10 = (ax25 - ax10[0]) / M_DX
    J, I = np.meshgrid(f10, f10, indexing="ij")
    Lb = ndimage.map_coordinates(L.astype(np.float64), [J, I], order=1)
    sub[sub == FOREST] = GRASS
    sub[Lb >= 127.5] = FOREST
    land25 = info["land"][lo25:hi25 + 1, lo25:hi25 + 1]
    lake25 = info["lake"][lo25:hi25 + 1, lo25:hi25 + 1]
    sub[(sub == WATER) & land25 & ~lake25] = GRASS
    sub[~land25 | lake25] = WATER
    c25[lo25:hi25 + 1, lo25:hi25 + 1] = sub
    return c25, L10, A10
