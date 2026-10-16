class_name GoalEstimator
extends RefCounted
## Оценка погоды → значения целей окна «Полёт…» (GL-К2, docs/contracts/goals.md).
## До старта, без рельефа: погода на час старта (WeatherModel.derive) → сила термиков, база
## облаков, ветер, часы до заката → числа лёгкой / средней / трудной цели. Детерминированно;
## формулы и коэффициенты — configs/goals/estimate.json (обоснование — в _doc).
##
##   var wx := GoalEstimator.weather_for(settings)
##   var all := GoalEstimator.suggest_all(wx, route_m)   # {kind: {easy, medium, hard}}

const CONFIG := "goals/estimate"
## Виды целей с числом из погоды — порядок GoalSpec.KINDS без route.
const KINDS := ["height", "duration", "distance", "return", "triangle", "speed", "landing"]
const LEVELS := ["easy", "medium", "hard"]


static func config() -> Dictionary:
	return Config.get_config(CONFIG)


## Погода до старта для места и часа FlightSettings: {cloudbase_agl_m, thermal_ms, wind_ms,
## wind_from_deg, sky, hours_left, start_hour}.
static func weather_for(s: FlightSettings) -> Dictionary:
	var wc := WeatherModel.config()
	var ctx := _context(s, wc)
	var w := WeatherModel.derive(s.forecast(), ctx, wc, s.start_hour)
	var ts: Array = w.get("thermal_strength_ms", [0.0, 0.0])
	var day := WeatherModel.diurnal_state(s.temperature_c, s.start_hour, ctx, wc)
	var max_hour := float(Config.value("world", "time.max_hour", 24.0))
	var end_h := minf(float(day.sunset_h), max_hour)
	return {
		"cloudbase_agl_m": float(w.cloudbase_agl_m),
		"thermal_ms": 0.5 * (float(ts[0]) + float(ts[1])),
		"wind_ms": float(w.wind_speed_kmh) / 3.6,
		"wind_from_deg": float(w.wind_from_deg),
		"sky": s.sky,
		"hours_left": maxf(0.0, end_h - s.start_hour),
		"start_hour": s.start_hour,
	}


## Место погоды как у Game._weather_context, но высоты — опорные (рельефа ещё нет).
static func _context(s: FlightSettings, wc: Dictionary) -> Dictionary:
	var ctx := WeatherModel.reference_context(wc)
	ctx.month = s.month
	ctx.day = s.day
	var loc := Locations.config(s.location_id)
	var lat := NAN
	var lon := NAN
	var zone := NAN
	if Locations.is_builtin(s.location_id) and loc.has("center_lat"):
		lat = float(loc.center_lat)
		lon = float(loc.center_lon)
		zone = float(loc.get("utc_offset_h", NAN))
	elif s.has_pick():
		lat = s.pick_lat
		lon = s.pick_lon
	elif loc.has("center_lat"):
		lat = float(loc.center_lat)
		lon = float(loc.center_lon)
		zone = float(loc.get("utc_offset_h", NAN))
	if is_finite(lat) and is_finite(lon):
		ctx.lat = lat
		ctx.lon = lon
		ctx.utc_offset_h = zone if is_finite(zone) else roundf(lon / 15.0)
	# Пояс часов — как у SunClock/Game: world.json → time.utc_offset_h ("solar" — солнечное).
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		ctx.utc_offset_h = NAN
	elif v != null and not v is String:
		ctx.utc_offset_h = float(v)
	return ctx


## Значение цели kind уровня level в единицах GL-К1; route → 0, speed без маршрута → 0,
## custom — как medium.
static func suggest(kind: String, level: String, wx: Dictionary, route_m := 0.0) -> float:
	var lv := "medium" if level == "custom" else level
	var vals := _levels(kind, wx, route_m)
	return float(vals.get(lv, 0.0))


## {kind: {easy, medium, hard}} для всех KINDS (без route).
static func suggest_all(wx: Dictionary, route_m := 0.0) -> Dictionary:
	var out := {}
	for k in KINDS:
		out[k] = _levels(k, wx, route_m)
	return out


static func _levels(kind: String, wx: Dictionary, route_m: float) -> Dictionary:
	var c := config()
	var zero := {"easy": 0.0, "medium": 0.0, "hard": 0.0}
	if not c.has(kind):
		return zero
	var kc: Dictionary = c[kind]
	var d: Dictionary = c.get("defaults", {})
	var b := _in(wx, d, "cloudbase_agl_m")
	var climb := _climb(_in(wx, d, "thermal_ms"), c)
	var wind := maxf(_in(wx, d, "wind_ms"), 0.0)
	var t_h := _window_h(_in(wx, d, "hours_left"), c)
	var v_air := _xc_speed(climb, c)
	# Маршрут — пока держишься: в слабых термиках большую часть окна не набрать (и снос ветром
	# без набора — только скольжение вниз).
	var stay := minf(climb / float(c.climb.stay_full_ms), 1.0)
	var xc_s := t_h * 3600.0 * stay
	match kind:
		"height":
			return _ladder(kc, b - float(kc.start_above_mean_m), kc.round_m, kc.floor_m)
		"duration":
			var q_min := float(kc.q_min)
			var q := q_min + (1.0 - q_min) * minf(climb / float(kc.full_climb_ms), 1.0)
			return _ladder(kc, t_h * 3600.0 * q, kc.round_s, kc.floor_s)
		"distance":
			var a := minf((v_air + wind) * xc_s, float(kc.max_m))
			return _ladder(kc, a, kc.round_m, kc.floor_m)
		"return":
			var a := minf(_closed_speed(v_air, wind, kc) * xc_s * 0.5, float(kc.max_m))
			return _ladder(kc, a, kc.round_m, kc.floor_m)
		"triangle":
			var a := minf(_closed_speed(v_air, wind, kc) * xc_s, float(kc.max_m))
			return _ladder(kc, a, kc.round_m, kc.floor_m)
		"speed":
			if route_m <= 0.0:
				return zero
			var v := maxf(_closed_speed(v_air, wind, kc), float(kc.min_speed_ms))
			return _speed_limits(kc, route_m, v)
		"landing":
			var out := {}
			var step := float(kc.round_m)
			for lv in LEVELS:
				out[lv] = maxf(_round(float(kc.radius_m[lv]), step), step)
			out.medium = minf(out.medium, out.easy - step)
			out.hard = maxf(minf(out.hard, out.medium - step), step)
			return out
	return zero


static func _in(wx: Dictionary, d: Dictionary, key: String) -> float:
	var v := float(wx.get(key, d.get(key, 0.0)))
	return v if is_finite(v) else float(d.get(key, 0.0))


## Скороподъёмность дельтаплана в термике, м/с.
static func _climb(thermal_ms: float, c: Dictionary) -> float:
	var cl: Dictionary = c.climb
	return maxf(float(cl.core_k) * thermal_ms - float(cl.circling_sink_ms), float(cl.min_ms))


## Рабочее окно термиков, ч.
static func _window_h(hours_left: float, c: Dictionary) -> float:
	var w: Dictionary = c.window
	return clampf(hours_left - float(w.evening_off_h), 0.0, float(w.max_h))


## Средняя скорость маршрута в воздухе по МакКриди, м/с.
static func _xc_speed(climb: float, c: Dictionary) -> float:
	var g: Dictionary = c.glide
	return float(g.speed_ms) * climb / (climb + float(g.sink_ms))


## Средняя путевая скорость замкнутого маршрута с ветром, м/с.
static func _closed_speed(v: float, wind: float, kc: Dictionary) -> float:
	if v <= 0.0:
		return 0.0
	var r := wind / v
	return v * maxf(1.0 - r * r, float(kc.wind_floor))


static func _round(x: float, step: float) -> float:
	return roundf(x / step) * step


## Уровни frac × a, округление, нижние пороги уровней, строго easy < medium < hard (шаг).
static func _ladder(kc: Dictionary, a: float, step_v: Variant, mins: Dictionary) -> Dictionary:
	var step := float(step_v)
	var out := {}
	for lv in LEVELS:
		var x := float(kc.frac[lv]) * maxf(a, 0.0)
		out[lv] = maxf(_round(x, step), float(mins[lv]))
	out.medium = maxf(out.medium, out.easy + step)
	out.hard = maxf(out.hard, out.medium + step)
	return out


## Пределы времени маршрута: строже — меньше, строго easy > medium > hard (шаг), > 0.
static func _speed_limits(kc: Dictionary, route_m: float, v: float) -> Dictionary:
	var step := float(kc.round_s)
	var out := {}
	for lv in LEVELS:
		var vl := float(kc.frac[lv]) * v
		var t := route_m / vl if vl > 0.0 else 1.0e9
		out[lv] = maxf(_round(t, step), step)
	out.medium = maxf(out.medium, out.hard + step)
	out.easy = maxf(out.easy, out.medium + step)
	return out
