class_name SurfaceHeat
extends RefCounted
## Явный поток тепла с поверхности H, Вт/м² (> 0 вверх) по классу покрова и воде. Контракты SH1/SH2
## (docs/contracts/surface-heat.md), физика — docs/plan/surface-heat.md §1. Только статические чистые функции:
## без состояния и случайности, одинаковые входы дают побитно одинаковый результат.
##
## Суша: K↓ (Stull) → Rn = (1 − α)K↓ − L* → G = g_frac·Rn → H = (Rn − G)·β/(1 + β).
## Вода: H = ρ·c_p·C_H·max(U, U_min)·(T_воды − T_воздуха).

const CONFIG := "surface_heat"
const NONE_CLASS := 0
const WATER_CLASS := 6
const SNOW_CLASS := 8


static func config() -> Dictionary:
	return Config.get_config(CONFIG)


## K↓ на поверхность, Вт/м². Stull (1988, §7.3): на горизонталь K = S₀·T_K·sinψ, T_K = (a + b·sinψ)·sky_heat;
## доля рассеянной diffuse_frac — по sinψ, прямая (1 − diffuse_frac) — по max(cos_inc, 0).
## Облака: sky_heat (доля прогрева из погоды игры) заменяет множитель (1 − 0,7·cover) Stull (иначе облачность
## считалась бы дважды); cover здесь не используется (идёт в L*).
## cos_inc — скалярное произведение нормали на направление НА солнце (нормаль без нормировки — поток на
## горизонтальную площадь; единичная — на площадь склона). sin_el ≤ 0 → 0.
static func shortwave(
	cos_inc: float, sin_el: float, cover: float, sky_heat: float, cfg: Dictionary
) -> float:
	if sin_el <= 0.0:
		return 0.0
	var r: Dictionary = cfg.get("radiation", {})
	var t_k := (float(r.get("tk_a", 0.6)) + float(r.get("tk_b", 0.2)) * sin_el) * sky_heat
	var s := float(r.get("s0_wm2", 1370.0)) * t_k
	var f := float(r.get("diffuse_frac", 0.15))
	return s * ((1.0 - f) * maxf(cos_inc, 0.0) + f * sin_el)


## Длинноволновое выхолаживание L*, Вт/м² (> 0): l_star_wm2·(1 − l_cloud_k·cover).
static func long_wave(cover: float, cfg: Dictionary) -> float:
	var r: Dictionary = cfg.get("radiation", {})
	return float(r.get("l_star_wm2", 98.0)) * (1.0 - float(r.get("l_cloud_k", 0.6)) * cover)


## β по влажности рельефа m ∈ [0, 1] (план §1.4): m ≤ m_dry → bowen_max; m_norm → bowen; m ≥ m_wet → bowen_min;
## между узлами — линейно по ln β.
static func bowen(cls: int, m: float, cfg: Dictionary) -> float:
	var k := _class_cfg(cls, cfg)
	var b := float(k.bowen)
	var lo := float(k.bowen_min)
	var hi := float(k.bowen_max)
	var mo: Dictionary = cfg.get("moisture", {})
	var m_dry := float(mo.get("m_dry", 0.35))
	var m_norm := float(mo.get("m_norm", 0.5))
	var m_wet := float(mo.get("m_wet", 0.85))
	if m <= m_dry:
		return hi
	if m >= m_wet:
		return lo
	if m <= m_norm:
		return exp(lerpf(log(hi), log(b), (m - m_dry) / maxf(m_norm - m_dry, 1e-9)))
	return exp(lerpf(log(b), log(lo), (m - m_norm) / maxf(m_wet - m_norm, 1e-9)))


## H суши, Вт/м². cls = WATER — ошибка (вода идёт через water_flux).
static func land_flux(cls: int, k_down: float, cover: float, m: float, cfg: Dictionary) -> float:
	if cls == WATER_CLASS:
		push_error("SurfaceHeat.land_flux: класс WATER — используйте water_flux")
		return 0.0
	var k := _class_cfg(cls, cfg)
	var rn := (1.0 - float(k.albedo)) * k_down - long_wave(cover, cfg)
	var avail := rn - float(k.g_frac) * rn
	var b := bowen(cls, m, cfg)
	return avail * b / (1.0 + b)


## Температура воды, °C: max(0, T̄_air(дата − lag_days, высота z_m)). T̄_air — среднее суточное:
## 24 часовых отсчёта WeatherModel.diurnal_state при typical_max_c сдвинутой даты. Дата сдвигается
## на lag_days назад по году (с переходом через границу года). Высота — air_temp_c (градиент lapse_k_per_km).
static func water_temp_c(month: int, day: int, z_m: float, ctx: Dictionary, wcfg: Dictionary) -> float:
	var wm := WeatherModel.config()
	var doy := SunClock.day_of_year(month, day) - int(round(float(wcfg.get("lag_days", 30.0))))
	if doy < 1:
		doy += 365
	var md := _month_day(doy)
	var c2 := ctx.duplicate()
	c2["month"] = md.x
	c2["day"] = md.y
	var t_max := WeatherModel.typical_max_c(md.x, md.y, wm)
	var sum := 0.0
	for i in 24:
		sum += float(WeatherModel.diurnal_state(t_max, i + 0.5, c2, wm).temperature_c)
	var t := sum / 24.0 - _lapse(z_m, ctx, wcfg)
	return maxf(0.0, t)


## Температура воздуха у поверхности на высоте z_m, °C: WeatherModel.diurnal_state (долина ctx.valley_msl_m)
## минус lapse_k_per_km (6,5 К/км, стандартная атмосфера: в модели погоды градиента у земли нет — только
## upper_air.lapse_k_per_km выше перемешанного слоя) на разность z_m − долина.
static func air_temp_c(
	hour: float, t_max: float, z_m: float, ctx: Dictionary, wcfg: Dictionary
) -> float:
	var st := WeatherModel.diurnal_state(t_max, hour, ctx, WeatherModel.config())
	return float(st.temperature_c) - _lapse(z_m, ctx, wcfg)


## H воды, Вт/м²: ρ·c_p·C_H·max(U, u_min)·(T_w − T_a).
static func water_flux(t_water_c: float, t_air_c: float, u_ms: float, cfg: Dictionary) -> float:
	var w: Dictionary = cfg.get("water", {})
	var rcp := float(w.get("rho_cp", 1231.0))
	return rcp * float(w.get("c_h", 1.3e-3)) * maxf(u_ms, float(w.get("u_min_ms", 1.0))) * (t_water_c - t_air_c)


## H клетки/точки: Σ f_c·H_c, веса fracs[off + c] (нормируются; сумма 0 → весь вес NONE).
## class_sun[c] — единичный вектор НА солнце класса (нулевой — солнце под горизонтом, K↓ = 0).
## sky = {cover, sky_heat}; water = {t_water_c, t_air_c, u_ms} (пусто → H воды 0); T_воды ≤ ice_c → вода как SNOW.
static func mix_flux(
	fracs: PackedFloat32Array,
	off: int,
	normal: Vector3,
	class_sun: PackedVector3Array,
	m: float,
	sky: Dictionary,
	water: Dictionary,
	cfg: Dictionary
) -> float:
	var cover := float(sky.get("cover", 0.0))
	var sky_heat := float(sky.get("sky_heat", 1.0))
	var total := 0.0
	for c in SurfaceLayer.CLASS_COUNT:
		total += maxf(fracs[off + c], 0.0)
	var h := 0.0
	for c in SurfaceLayer.CLASS_COUNT:
		var f := maxf(fracs[off + c], 0.0) if total > 0.0 else (1.0 if c == NONE_CLASS else 0.0)
		if f <= 0.0:
			continue
		f = f / total if total > 0.0 else f
		var cls := c
		var hc := 0.0
		if c == WATER_CLASS:
			if water.is_empty():
				continue
			var tw := float(water.get("t_water_c", 0.0))
			if tw <= float(cfg.get("water", {}).get("ice_c", 0.0)):
				cls = SNOW_CLASS
			else:
				h += f * water_flux(tw, float(water.get("t_air_c", tw)), float(water.get("u_ms", 0.0)), cfg)
				continue
		var sun := class_sun[cls] if cls < class_sun.size() else Vector3.ZERO
		var k := 0.0
		if sun != Vector3.ZERO:
			k = shortwave(normal.dot(sun), sun.y, cover, sky_heat, cfg)
		hc = land_flux(cls, k, cover, m, cfg)
		h += f * hc
	return h


static func _class_cfg(cls: int, cfg: Dictionary) -> Dictionary:
	return cfg.classes[SurfaceLayer.CLASS_NAMES[clampi(cls, 0, SurfaceLayer.CLASS_COUNT - 1)]]


static func _lapse(z_m: float, ctx: Dictionary, wcfg: Dictionary) -> float:
	var z0 := float(ctx.get("valley_msl_m", z_m))
	return float(wcfg.get("lapse_k_per_km", 6.5)) * (z_m - z0) / 1000.0


static func _month_day(doy: int) -> Vector2i:
	var d := doy
	for m in range(1, 13):
		var dim := SunClock.days_in_month(m)
		if d <= dim:
			return Vector2i(m, d)
		d -= dim
	return Vector2i(12, 31)
