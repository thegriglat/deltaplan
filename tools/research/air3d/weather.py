"""Погода игры для эталона масштаба 1: фон θ̄(z), верх слоя перемешивания z_i, поток тепла от часа.

Повторяет `scripts/atmosphere/weather_model.gd` (derive + diurnal_state, только нужное полю) и
`configs/weather_model.json`: суточный ход температуры (Партон–Логан), утренняя инверсия и её
пробой, сухой потолок термиков z_dry, кромка z_lcl, доля прогрева (солнце с запаздыванием,
облачность). Из этого строится **профиль потенциальной температуры фона** θ̄(z):

  * свободная атмосфера: T(z) = T_700 + γ·(z_700 − z), γ = upper_air.lapse_k_per_km (4 К/км) →
    dθ/dz = Γd − γ = 5,8 К/км;
  * ночная инверсия (до пика прогрева): от T_min у дна долины линейно с градиентом
    (T_full − T_min)/inversion_depth (как cap в diurnal_state), до остаточного слоя T_res =
    T_max − residual_cooling; выше — остаточный (вчерашний перемешанный) слой, нейтральный, до
    встречи со свободной атмосферой;
  * текущий слой перемешивания: θ = θ_s = T(час) + parcel_excess (частица игры) — нейтрально
    от земли до z_i, где θ_s встречает профиль над ним (это ровно z_dry игры: и в ясный полдень, и
    при утренней крышке cap; в окне пробоя «break» игра плавно ведёт z от cap к z_dry за 3 К, здесь
    — физически: слой пробивает инверсию, когда θ_s > θ остаточного слоя).

θ здесь — в «Буссинеск-виде» θ = T + Γd·z (К, Γd = 9,8 К/км, z в км над морем); решателю нужен
только градиент dθ̄/dz(z) и z_i.

Поток явного тепла с земли (Вт/м²): H = H0·sky.heat·[max(0, cos угла солнца к склону) +
diffuse·sin(высоты)] − H_lw·(1 − 0,7·облачность). H0 = 330 Вт/м² при нормальном падении (прикидка:
~0,35 поглощённой коротковолновой — «луг» летом), H_lw = 40 Вт/м² — выхолаживание земли длинноволновым
излучением, переданное воздуху (типичный ночной/вечерний явный поток −20…−50 Вт/м², Stull 1988,
гл. 7), облака его уменьшают. Солнце — с запаздыванием прогрева heating.lag_h.none (0,3 ч).
"""
from __future__ import annotations

import gzip
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
CFG = json.loads((ROOT / "configs/weather_model.json").read_text())
GAMMA_D = 9.8          # К/км
TAU = 2 * math.pi

H0_WM2 = 330.0         # явный поток при нормальном падении солнца, Вт/м²
DIFFUSE = 0.10         # рассеянная доля (× sin высоты солнца)
H_LW_WM2 = 40.0        # выхолаживание длинноволновым излучением (явный поток к земле), Вт/м²
LW_CLOUD_K = 0.7       # облачность гасит выхолаживание: × (1 − 0,7·cover)


# ---------------------------------------------------------------- как SunClock / WeatherModel
DIM = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def day_of_year(m, d):
    return sum(DIM[:max(1, min(m, 12)) - 1]) + d


def solar_position(lat, lon, doy, clock_h, utc=None):
    """(азимут от севера по часовой, высота), градусы — как SunClock.solar_position."""
    g = TAU / 365.0 * (doy - 1 + (clock_h - 12.0) / 24.0)
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) - 0.006758 * math.cos(2 * g)
            + 0.000907 * math.sin(2 * g) - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    solar_h = clock_h
    if utc is not None:
        eot = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                        - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
        solar_h = clock_h + (4.0 * lon - 60.0 * utc + eot) / 60.0
    ha = math.radians(15.0 * (solar_h - 12.0))
    la = math.radians(lat)
    s = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha)
    el = math.asin(max(-1.0, min(1.0, s)))
    az = math.atan2(math.sin(ha), math.cos(ha) * math.sin(la) - math.tan(decl) * math.cos(la)) + math.pi
    return math.degrees(az) % 360.0, math.degrees(el)


def monthly(arr, month, day=15):
    if len(arr) < 12:
        return float(arr[0])
    m = max(1, min(month, 12)) - 1
    f = (day - 15.0) / DIM[m]
    j = (m + (1 if f >= 0 else -1)) % 12
    return arr[m] + (arr[j] - arr[m]) * abs(f)


def typical_max_c(month, day=15):
    r = CFG["ui"]["temperature_c"]
    return min(max(monthly(CFG["typical_max_c"], month, day), r[0]), r[1])


def diurnal_state(t_max, hour, ctx):
    d = CFG["diurnal"]
    month, day = ctx["month"], ctx["day"]
    lat, lon, utc = ctx["lat"], ctx["lon"], ctx.get("utc_offset_h")
    doy = day_of_year(month, day)
    noon = 12.0 if utc is None else 12.0 - (4.0 * lon - 60.0 * utc) / 60.0
    decl = math.radians(23.44) * math.sin(TAU * (284.0 + doy) / 365.0)
    cos_h0 = max(-1.0, min(1.0, -math.tan(math.radians(lat)) * math.tan(decl)))
    half = math.degrees(math.acos(cos_h0)) / 15.0
    sunrise, sunset = noon - half, noon + half
    peak = min(noon + d["peak_after_noon_h"], sunset - 0.5)
    fs = d["sunset_fraction"]
    if hour <= sunrise:
        f = 0.0
    elif hour <= peak:
        f = math.sin(math.pi * 0.5 * (hour - sunrise) / max(peak - sunrise, 0.1))
    elif hour <= sunset:
        f = fs + (1 - fs) * math.cos(math.pi * 0.5 * (hour - peak) / max(sunset - peak, 0.1))
    else:
        f = fs * math.exp(-(hour - sunset) / d["night_tau_h"])
    amp = monthly(d["range_k"], month, day)
    t = t_max - amp * (1 - f)
    excess = CFG["parcel_excess_k"]
    t_res = t_max - d["residual_cooling_k"]
    t_min = t_max - amp
    window = d["break_window_k"]
    cap, brk = math.inf, 1.0
    if hour < peak and t + excess < t_res:
        t_full = t_res - window
        cap = d["inversion_depth_m"] * min(max((t + excess - t_min) / max(t_full - t_min, 0.5), 0), 1)
        brk = min(max((t + excess - t_full) / max(window, 0.1), 0), 1)
    lag = d["heat_lag_h"]
    el = solar_position(lat, lon, doy, hour - lag, utc)[1]
    el_noon = solar_position(lat, lon, doy, noon, utc)[1]
    heat = min(max(max(math.sin(math.radians(el)), 0) / max(math.sin(math.radians(el_noon)), 0.05), 0), 1)
    return dict(temperature_c=t, cap_agl_m=cap, brk=brk, heat=heat, sunrise_h=sunrise, sunset_h=sunset,
                peak_h=peak, t_min=t_min, t_res=t_res, t_full=t_res - window, amp=amp)


# ---------------------------------------------------------------- место
def ground_context(h_fn, radius=10000.0, samples=15, low_pct=0.1):
    """Как WeatherModel.ground_context: высоты в круге radius вокруг (0, 0)."""
    hs = []
    n = max(samples, 2)
    for j in range(n):
        for i in range(n):
            u = i / (n - 1) * 2 - 1
            v = j / (n - 1) * 2 - 1
            if u * u + v * v > 1:
                continue
            hs.append(h_fn(u * radius, v * radius))
    hs = sorted(hs)
    k = max(0, min(int(math.floor(low_pct * (len(hs) - 1))), len(hs) - 1))
    return dict(valley_msl_m=float(hs[k]), mean_msl_m=float(np.mean(hs)))


@dataclass
class Day:
    """Погода дня в час: всё, что нужно полю."""
    hour: float
    t_max: float
    sky: str
    ctx: dict
    st: dict = field(default_factory=dict)

    def __post_init__(self):
        self.st = diurnal_state(self.t_max, self.hour, self.ctx)
        c = CFG
        m, d = self.ctx["month"], self.ctx["day"]
        self.t = self.st["temperature_c"]
        self.h_v = self.ctx["valley_msl_m"] / 1000.0
        self.t_u = monthly(c["upper_air"]["temp_c"], m, d)
        self.z_u = c["upper_air"]["z_msl_m"] / 1000.0
        self.gam = c["upper_air"]["lapse_k_per_km"]
        excess = c["parcel_excess_k"]
        # как derive: сухой потолок и кромка (км над морем)
        z_dry = self.h_v + (self.t + excess - self.t_u - self.gam * (self.z_u - self.h_v)) / (GAMMA_D - self.gam)
        cap = self.st["cap_agl_m"]
        if math.isfinite(cap):
            z_cap = min(z_dry, self.h_v + cap / 1000.0)
            z_dry = z_cap + (z_dry - z_cap) * self.st["brk"]
        td = monthly(c["dew_point_c"], m, d) + c.get("td_follow_heat", 0.0) * max(self.t_max - typical_max_c(m, d), 0)
        td = min(td, self.t)
        self.z_dry_game = z_dry * 1000.0
        self.z_lcl = (self.h_v + c["lcl_m_per_k"] / 1000.0 * (self.t - td)) * 1000.0
        sky = c["sky"].get(self.sky, c["sky"]["clear"])
        self.sky_heat = sky.get("heat", 1.0)
        self.cover = sky.get("cover", 0.0)
        self.heat = self.st["heat"] * self.sky_heat
        # профиль θ (Буссинеск-вид), км → К
        self.theta_s = self.t + excess + GAMMA_D * self.h_v
        self.z_i = self._z_i() * 1000.0

    # θ свободной атмосферы
    def theta_fa(self, zk):
        return self.t_u + self.gam * (self.z_u - zk) + GAMMA_D * zk

    def theta_upper(self, zk):
        """Профиль над текущим слоем перемешивания: ночная инверсия → остаточный слой →
        свободная атмосфера (до пика прогрева); после пика — только свободная атмосфера
        (остаточный слой днём съеден слоем перемешивания)."""
        zk = np.asarray(zk, float)
        fa = self.theta_fa(zk)
        st = self.st
        if not math.isfinite(st["cap_agl_m"]):
            return fa
        dep = CFG["diurnal"]["inversion_depth_m"] / 1000.0
        th_min = st["t_min"] + GAMMA_D * self.h_v
        th_res = st["t_res"] + GAMMA_D * self.h_v
        slope = (st["t_full"] - st["t_min"]) / dep            # К/км
        night = np.minimum(th_min + slope * np.maximum(zk - self.h_v, 0), th_res)
        return np.maximum(night, fa)

    def _z_i(self):
        z = np.linspace(self.h_v, 12.0, 23001)
        up = self.theta_upper(z)
        k = np.argmax(up > self.theta_s)
        return z[k] if up[k] > self.theta_s else 12.0

    def theta(self, z_m):
        """θ̄(z) над морем (м), К."""
        zk = np.asarray(z_m, float) / 1000.0
        return np.maximum(self.theta_upper(zk), self.theta_s)

    def gamma(self, z_m):
        """dθ̄/dz, К/м — разностью по профилю (для центров клеток)."""
        z = np.asarray(z_m, float)
        return (self.theta(z + 5.0) - self.theta(z - 5.0)) / 10.0

    def heat_flux(self, cos_inc, sin_el):
        """Явный поток тепла, Вт/м² на горизонтальную площадь (cos_inc — косинус угла солнца к
        нормали склона, приведённый к горизонтальной площади; sin_el — синус высоты солнца)."""
        sun = H0_WM2 * self.sky_heat * (np.clip(cos_inc, 0, None) + DIFFUSE * max(sin_el, 0.0))
        return sun - H_LW_WM2 * (1 - LW_CLOUD_K * self.cover)

    def summary(self):
        return dict(hour=self.hour, t_max=self.t_max, sky=self.sky, t=round(self.t, 2),
                    z_i_msl=round(self.z_i), z_dry_game_msl=round(self.z_dry_game), z_lcl_msl=round(self.z_lcl),
                    valley_msl=round(self.h_v * 1000), heat=round(self.heat, 3), cap_agl=self.st["cap_agl_m"],
                    brk=round(self.st["brk"], 2))


def location_ctx(loc_id, h_fn):
    loc = json.loads((ROOT / f"configs/locations/{loc_id}.json").read_text())
    rc = CFG["reference_context"]
    ctx = dict(month=rc["month"], day=rc["day"], lat=loc["center_lat"], lon=loc["center_lon"],
               utc_offset_h=loc.get("utc_offset_h", round(loc["center_lon"] / 15.0)))
    ctx.update(ground_context(h_fn))
    return ctx


if __name__ == "__main__":
    import terrain as T
    for loc in ("ongudai", "aushkul"):
        L = T.Location(loc)
        ctx = location_ctx(loc, L.height_at)
        print(loc, ctx)
        tm = typical_max_c(ctx["month"], ctx["day"])
        for sky in ("clear", "partly", "overcast"):
            for dt in (-8, 0, 8):
                for h in (9, 12, 15, 20):
                    D = Day(h, tm + dt, sky, ctx)
                    print(" ", D.summary())
