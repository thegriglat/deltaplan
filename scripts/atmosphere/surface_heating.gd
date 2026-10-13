class_name SurfaceHeating
extends RefCounted
## Инерция прогрева поверхности (фаза 2 погоды, docs/archive/plan/weather-by-temperature.md §7.3 п. 2):
## для каждого класса поверхности — направление на солнце с запаздыванием класса (≈ 0,6 τ).
## Без состояния: направление — чистая функция часа (перемотка и ускорение времени не ломают).
## Terrain.thermal_source_strength_at берёт солнце своего класса (Terrain.set_class_sun).
## Параметры — configs/weather_model.json → heating.
##
##   var h := SurfaceHeating.new()
##   h.setup(lat, lon, month, day, utc_offset_h)
##   terrain.set_class_sun(h.directions(clock.hour))

var enabled: bool = true
var lat_deg: float = 52.0
var lon_deg: float = 85.0
var utc_offset_h: float = NAN
var doy: int = 196
var lags_h := PackedFloat32Array()
## Закат по часам места (ψ = 0), ч; NAN — полярный день/ночь.
var sunset_h: float = NAN


func setup(lat: float, lon: float, month: int, day: int, utc: float, cfg: Dictionary = {}) -> void:
	var c: Dictionary = (cfg if not cfg.is_empty() else WeatherModel.config()).get("heating", {})
	enabled = bool(c.get("enabled", true))
	lat_deg = lat
	lon_deg = lon
	utc_offset_h = utc
	doy = SunClock.day_of_year(month, day)
	var lags: Dictionary = c.get("lag_h", {})
	lags_h.resize(SurfaceLayer.CLASS_COUNT)
	for k in SurfaceLayer.CLASS_COUNT:
		lags_h[k] = float(lags.get(SurfaceLayer.CLASS_NAMES[k], 0.0))
	sunset_h = _sunset()


## Направления на солнце по классам на час hour (часы места). Солнце (запаздывающее или текущее) под
## горизонтом — нулевой вектор (класс не греется): после заката притока тепла нет ни у одного класса
## (FBW-К2), запаздывание сдвигает только дневной ход. Выключено — пустой массив (Terrain берёт
## текущее солнце).
func directions(hour: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not enabled:
		return out
	out.resize(lags_h.size())
	if sun_at(hour) == Vector3.ZERO:
		return out  # нулевые векторы
	for k in lags_h.size():
		out[k] = sun_at(hour - lags_h[k])
	return out


## Направление на солнце в час hour; под горизонтом — Vector3.ZERO.
func sun_at(hour: float) -> Vector3:
	var p := SunClock.solar_position(lat_deg, lon_deg, doy, hour, utc_offset_h)
	if p.y <= 0.0:
		return Vector3.ZERO
	return TerrainGeo.sun_direction(p.x, p.y)


## Застройка после заката (FBW-К2 v3): {} — солнце над горизонтом или закат не найден; иначе
## {sin_s — sin высоты солнца застройки (с её запаздыванием) в момент заката, dt_h — часов после
## заката}. Передаётся в SurfaceHeat.mix_flux через sky.night: H застройки = нижний предел +
## (H на закате − предел)·exp(−dt/τ).
func built_night(hour: float) -> Dictionary:
	if is_nan(sunset_h) or sun_at(hour) != Vector3.ZERO or hour < sunset_h:
		return {}
	var p := SunClock.solar_position(
		lat_deg, lon_deg, doy, sunset_h - lags_h[SurfaceLayer.BUILT], utc_offset_h
	)
	return {"sin_s": maxf(sin(deg_to_rad(p.y)), 0.0), "dt_h": hour - sunset_h}


## Закат по часам места: от истинного полудня вперёд, где ψ впервые ≤ 0 (бисекция); NAN — нет.
func _sunset() -> float:
	var lo := 12.0
	var hi := 24.0
	if SunClock.solar_position(lat_deg, lon_deg, doy, hi, utc_offset_h).y > 0.0:
		return NAN
	# полдень по часам места может быть не в 12:00 (пояс) — начать с самого высокого солнца
	var best := lo
	var best_el := -INF
	for i in 25:
		var h := 6.0 + i * 0.5
		var el := SunClock.solar_position(lat_deg, lon_deg, doy, h, utc_offset_h).y
		if el > best_el:
			best_el = el
			best = h
	if best_el <= 0.0:
		return NAN
	lo = best
	for i in 40:
		var mid := 0.5 * (lo + hi)
		if SunClock.solar_position(lat_deg, lon_deg, doy, mid, utc_offset_h).y > 0.0:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)
