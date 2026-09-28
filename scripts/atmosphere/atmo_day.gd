class_name AtmoDay
extends RefCounted
## День для атмосферы: погода, солнце и сила источников термиков как чистые функции времени
## атмосферы t (docs/atmosphere.md → «Детерминизм»). Нужен, чтобы мир был одинаков у всех
## клиентов сетевой зоны и чтобы атмосферу можно было начать сразу с момента t (Atmosphere.start_at)
## — без истории: термик рождается с погодой, солнцем и тенью на момент своего рождения.
##
## Ход дня по часам: час места hour(t) = start_hour + (t − t0)·speed/3600 (ограничен
## SunClock.clamp_hour). Погода считается раз на шаг quantum_h часов и между шагами
## интерполируется линейно (вместо прежнего мягкого перехода по кадрам).
##
##   var day := AtmoDay.new()
##   day.start_hour = 13.0
##   day.weather_fn = func(h: float) -> Dictionary: return WeatherModel.derive(fc, ctx, {}, h)
##   day.sun_fn = func(h: float) -> Vector3: return …  # направление НА солнце
##   day.source_fn = func(x: float, z: float, h: float) -> float: return …  # 0..1
##   atmo.set_day(day)

## Час места при t = t0.
var start_hour: float = 13.0
## Время атмосферы, с, которому соответствует start_hour.
var t0: float = 0.0
## Скорость часов: 1 — реальное время (сеть — всегда 1).
var speed: float = 1.0
## Шаг пересчёта погоды, часы (weather_model.json → diurnal.update_s / 3600).
var quantum_h: float = 60.0 / 3600.0
## hour -> Dictionary погоды (как WeatherModel.derive). Пусто — погода не меняется.
var weather_fn: Callable
## hour -> Vector3 направление НА солнце (для теней облаков на источниках). Пусто — из Atmosphere.
var sun_fn: Callable
## (x, z, hour) -> 0..1 сила источника термиков. Пусто — GroundField.sun_fn (без времени).
var source_fn: Callable

var _cache: Dictionary = {}  ## индекс шага погоды -> Dictionary
var _min_h: float = 6.0
var _max_h: float = 20.0


func _init() -> void:
	var tc: Dictionary = Config.get_config("world").get("time", {})
	_min_h = float(tc.get("min_hour", 6.0))
	_max_h = float(tc.get("max_hour", 20.0))


## Час места в момент t атмосферы (как SunClock.clamp_hour: после max_hour время стоит).
func hour_at(t: float) -> float:
	return clampf(start_hour + (t - t0) * speed / 3600.0, _min_h, _max_h)


## Погода шага, в который попадает момент t (для рождения термиков).
func weather_at(t: float) -> Dictionary:
	return _weather_q(floori(hour_at(t) / quantum_h))


## Для плавных величин: [погода шага, погода следующего шага, доля 0..1] в момент t.
func bracket(t: float) -> Array:
	var qf := hour_at(t) / quantum_h
	var q := floori(qf)
	return [_weather_q(q), _weather_q(q + 1), qf - q]


## Число из погоды, плавно по времени (линейно между шагами).
func value_at(t: float, key: String, default: float = 0.0) -> float:
	var b := bracket(t)
	return lerpf(float(b[0].get(key, default)), float(b[1].get(key, default)), float(b[2]))


func has_weather() -> bool:
	return weather_fn.is_valid()


## Направление на солнце в момент t; Vector3.ZERO — не задано.
func sun_at(t: float) -> Vector3:
	return sun_fn.call(hour_at(t)) if sun_fn.is_valid() else Vector3.ZERO


## Сила источника термиков в точке в момент t (-1 — не задано: брать GroundField.sun).
func source_at(x: float, z: float, t: float) -> float:
	if not source_fn.is_valid():
		return -1.0
	return clampf(float(source_fn.call(x, z, hour_at(t))), 0.0, 1.0)


## Часы пошли иначе (одиночная игра: «Ещё раз» вернул часы к старту, сменили скорость времени):
## с момента t атмосферы час — hour, дальше со скоростью new_speed. Кеш погоды по часам остаётся.
func rebase(t: float, hour: float, new_speed: float) -> void:
	t0 = t
	start_hour = hour
	speed = new_speed


## Направление НА солнце в месте и дате в час hour — как SunClock (высота не ниже
## time.min_light_elevation_deg). utc_offset_h = NAN — солнечное время.
## Первым — час: удобно для bind (AtmoDay.sun_direction.bind(lat, lon, month, day, utc)).
static func sun_direction(
	hour: float, lat: float, lon: float, month: int, p_day: int, utc_offset_h: float
) -> Vector3:
	var a := SunClock.solar_position(
		lat, lon, SunClock.day_of_year(month, p_day), hour, utc_offset_h
	)
	var el := maxf(a.y, float(Config.value("world", "time.min_light_elevation_deg", 2.0)))
	return TerrainGeo.sun_direction(a.x, el)


func _weather_q(q: int) -> Dictionary:
	var w: Variant = _cache.get(q)
	if w != null:
		return w
	if _cache.size() > 512:
		_cache.clear()
	var d: Dictionary = weather_fn.call(q * quantum_h) if weather_fn.is_valid() else {}
	_cache[q] = d
	return d
