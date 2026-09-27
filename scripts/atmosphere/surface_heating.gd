class_name SurfaceHeating
extends RefCounted
## Инерция прогрева поверхности (фаза 2 погоды, docs/plan/weather_by_temperature.md §7.3 п. 2):
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


## Направления на солнце по классам на час hour (часы места). Солнце под горизонтом — нулевой
## вектор (класс не греется). Выключено — пустой массив (Terrain берёт текущее солнце).
func directions(hour: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not enabled:
		return out
	out.resize(lags_h.size())
	for k in lags_h.size():
		out[k] = sun_at(hour - lags_h[k])
	return out


## Направление на солнце в час hour; под горизонтом — Vector3.ZERO.
func sun_at(hour: float) -> Vector3:
	var p := SunClock.solar_position(lat_deg, lon_deg, doy, hour, utc_offset_h)
	if p.y <= 0.0:
		return Vector3.ZERO
	return TerrainGeo.sun_direction(p.x, p.y)
