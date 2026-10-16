"""Правила стартов и посадок — те же, что tests/terrain/test_locations.gd, на массивах места
(повтор Terrain.height_at / normal_at / surface_at: билинейная высота detail, нормаль центральными разностями с шагом
сетки, класс — ближайший узел карты 25 м, поверх — маски 10 м: вода A ≥ 0,5, лес L ≥ 0,5; луг/поле/кустарник круче
terrain_look.rock_slope_deg — скалы). Геодезия — scripts/terrain/geo.gd (равнопромежуточная вокруг центра).
"""
import math

import numpy as np

EARTH_R = 6371008.8
FOREST, GRASS, CROP, SHRUB, BARE, WATER = 1, 2, 3, 4, 5, 6


def m_per_deg_lat():
    return EARTH_R * math.pi / 180.0


def local_to_latlon(x, z, lat0, lon0):
    return lat0 - z / m_per_deg_lat(), lon0 + x / (m_per_deg_lat() * math.cos(math.radians(lat0)))


def latlon_to_local(lat, lon, lat0, lon0):
    return (lon - lon0) * m_per_deg_lat() * math.cos(math.radians(lat0)), -(lat - lat0) * m_per_deg_lat()


def heading_vec(hdg):
    h = math.radians(hdg)
    return math.sin(h), -math.cos(h)


class Place:
    """Высоты detail (+ по желанию классы 25 м и маски 10 м) с запросами как у Terrain."""

    def __init__(self, h, origin, dx, classes=None, forest10=None, water10=None, m_origin=None, m_dx=10.0,
                 rock_slope_deg=38.0):
        self.h, self.o, self.dx = h, origin, dx
        self.n = h.shape[0]
        self.cl, self.f10, self.w10 = classes, forest10, water10
        self.mo, self.mdx = m_origin, m_dx
        self.rock_cos = math.cos(math.radians(rock_slope_deg))

    def height(self, x, z):
        fx = min(max((x - self.o) / self.dx, 0.0), self.n - 1.0)
        fz = min(max((z - self.o) / self.dx, 0.0), self.n - 1.0)
        i, j = min(int(fx), self.n - 2), min(int(fz), self.n - 2)
        tx, tz = fx - i, fz - j
        a, b = self.h[j, i], self.h[j, i + 1]
        c, d = self.h[j + 1, i], self.h[j + 1, i + 1]
        return float((a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz)

    def normal(self, x, z):
        e = self.dx
        dx = self.height(x + e, z) - self.height(x - e, z)
        dz = self.height(x, z + e) - self.height(x, z - e)
        v = np.array([-dx, 2 * e, -dz])
        return v / np.linalg.norm(v)

    def slope_deg(self, x, z):
        return math.degrees(math.acos(min(1.0, self.normal(x, z)[1])))

    def _mask(self, a, x, z):
        n = a.shape[0]
        fx = min(max((x - self.mo) / self.mdx, 0.0), n - 1.0)
        fz = min(max((z - self.mo) / self.mdx, 0.0), n - 1.0)
        i, j = min(int(fx), n - 2), min(int(fz), n - 2)
        tx, tz = fx - i, fz - j
        top = a[j, i] * (1 - tx) + a[j, i + 1] * tx
        bot = a[j + 1, i] * (1 - tx) + a[j + 1, i + 1] * tx
        return float(top * (1 - tz) + bot * tz) / 255.0

    def surface(self, x, z):
        i = min(max(int(round((x - self.o) / self.dx)), 0), self.n - 1)
        j = min(max(int(round((z - self.o) / self.dx)), 0), self.n - 1)
        c = int(self.cl[j, i])
        if self.f10 is not None:
            if self._mask(self.w10, x, z) >= 0.5:
                return WATER
            if self._mask(self.f10, x, z) >= 0.5:
                return FOREST
            if c == FOREST:
                c = self._open_near(i, j)
        if self.normal(x, z)[1] < self.rock_cos and c in (GRASS, CROP, SHRUB, 0):
            return BARE
        return c

    def _open_near(self, i0, j0):
        counts = np.zeros(9, int)
        for dj in (-1, 0, 1):
            for di in (-1, 0, 1):
                c = int(self.cl[min(max(j0 + dj, 0), self.n - 1), min(max(i0 + di, 0), self.n - 1)])
                if c not in (FOREST, 0) and c < 9:
                    counts[c] += 1
        return int(np.argmax(counts)) if counts.max() > 0 else GRASS

    # --- правила test_locations.gd ---
    def start_checks(self, x, z, hdg, with_surface=True):
        p_h = self.height(x, z)
        fx, fz = heading_vec(hdg)
        ahead = self.height(x + fx * 60.0, z + fz * 60.0)
        slope = self.slope_deg(x, z)
        out = {"slope_deg": round(slope, 2), "h_m": round(p_h, 2), "ahead60_m": round(ahead, 2),
               "ok_slope": 8.0 < slope < 35.0, "ok_down": ahead < p_h - 5.0}
        if with_surface:
            c = self.surface(x, z)
            out["class"] = c
            out["ok_forest"] = c != FOREST
        out["ok"] = all(v for k, v in out.items() if k.startswith("ok_"))
        return out

    def landing_checks(self, x, z, with_surface=True):
        slope = self.slope_deg(x, z)
        out = {"slope_deg": round(slope, 2), "h_m": round(self.height(x, z), 2), "ok_slope": slope < 10.0}
        if with_surface:
            c = self.surface(x, z)
            out["class"] = c
            out["ok_class"] = c not in (WATER, FOREST)
        out["ok"] = all(v for k, v in out.items() if k.startswith("ok_"))
        return out


def find_start(pl, box, heading=None, slope=(12.0, 26.0), heading_range=None, aspect_tol=25.0, step=10.0,
               target_h=None, forbid=None):
    """Старт в прямоугольнике box = (x0, x1, z0, z1) м: уклон в пределах slope, по курсу вниз ≥ 8 м за 60 м,
    экспозиция (направление падения) в пределах aspect_tol от курса. heading=None — курс = экспозиция, округлённая до 5°
    (в пределах heading_range). Из подходящих — самый высокий (или ближайший по высоте к target_h).
    forbid(x, z) → True — точка не годится (вода, берег). Перебор узлов с шагом step — детерминирован."""
    best = None
    for z in np.arange(box[2], box[3] + 1e-6, step):
        for x in np.arange(box[0], box[1] + 1e-6, step):
            x, z = float(x), float(z)
            if forbid is not None and forbid(x, z):
                continue
            n = pl.normal(x, z)
            s = math.degrees(math.acos(min(1.0, n[1])))
            if not slope[0] <= s <= slope[1]:
                continue
            aspect = (math.degrees(math.atan2(n[0], -n[2])) + 360.0) % 360.0     # куда падает склон
            hdg = heading
            if hdg is None:
                hdg = (round(aspect / 5.0) * 5.0) % 360.0
                if heading_range and not heading_range[0] <= hdg <= heading_range[1]:
                    continue
            if abs((aspect - hdg + 180.0) % 360.0 - 180.0) > aspect_tol:
                continue
            c = pl.start_checks(x, z, hdg, with_surface=False)
            if not c["ok"] or c["ahead60_m"] > c["h_m"] - 8.0:
                continue
            score = c["h_m"] if target_h is None else -abs(c["h_m"] - target_h)
            if best is None or score > best[0]:
                best = (score, x, z, hdg)
    if best is None:
        return None
    return {"x": best[1], "z": best[2], "heading_deg": best[3]}


def find_landing(pl, center, r_min, r_max, prefer_bearing=None, step=25.0, half=(100.0, 60.0), forbid=None):
    """Посадка: узел в кольце r_min..r_max от center, где наибольший уклон на прямоугольнике half (± по X, ± по Z)
    вокруг точки минимален (поле ровное, а не точка); при равенстве — ближе к prefer_bearing (откуда от center)."""
    cx, cz = center
    best = None
    for z in np.arange(cz - r_max, cz + r_max + 1e-6, step):
        for x in np.arange(cx - r_max, cx + r_max + 1e-6, step):
            x, z = float(x), float(z)
            r = math.hypot(x - cx, z - cz)
            if not r_min <= r <= r_max:
                continue
            if forbid is not None and forbid(x, z):
                continue
            worst = 0.0
            for dz in (-half[1], 0.0, half[1]):
                for dx in (-half[0], 0.0, half[0]):
                    worst = max(worst, pl.slope_deg(x + dx, z + dz))
            pen = 0.0
            if prefer_bearing is not None:
                b = (math.degrees(math.atan2(x - cx, -(z - cz))) + 360.0) % 360.0
                pen = 3.0 * abs((b - prefer_bearing + 180.0) % 360.0 - 180.0) / 90.0     # 3° уклона за 90° от направления
            score = worst + pen
            if best is None or score < best[0]:
                best = (score, x, z, worst)
    if best is None:
        return None
    return {"x": best[1], "z": best[2], "max_slope_deg": round(best[3], 2)}
