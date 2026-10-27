class_name CalmAir
extends Node3D
## Запасная модель воздуха, если основная атмосфера (scripts/atmosphere) не загрузилась.
## Тот же фасад W2 (docs/contracts/rust-wind.md), что у Atmosphere: configure, load_place,
## set_conditions, set_static_thermals, set_focuses, start_at, advance_to, sample_many. Постоянный
## ветер условий, фоновое опускание и несколько статичных термиков вокруг первого старта места
## (configs/game.json → calm_air). Облаков не рисует, READY сразу. Замена на настоящую атмосферу —
## строка game.json → air.script.

signal weather_changed
signal weather_updated
signal state_changed(state: int)

# Фасад W2 (docs/contracts/rust-wind.md): те же константы, что у Atmosphere (копия — запасной
# воздух не должен зависеть от основной атмосферы).
const WIND_API_VERSION := 3
const STATE_EMPTY := 0
const STATE_LOADING := 1
const STATE_READY := 2
const STATE_FAILED := 3
const OK := 0
const BAD_INPUT := 1
const NO_PLACE := 2
const NOT_READY := 3
const SAMPLE_FULL := 0
const SAMPLE_MEAN := 1
const CORE_STRIDE := 15
const CLOUD_STRIDE := 10
const CREST_STRIDE := 4

var weather: Dictionary = {}
var time_s: float = 0.0

var _cfg: Dictionary = {}
var _wind := Vector3.ZERO
var _height_fn: Callable = Callable()
var _thermals: Array[Dictionary] = []  # {x, z, w, r}
var _top_agl: float = 1800.0
var _f_err := ""
var _f_place: AirPlaceData


func _ready() -> void:
	add_to_group("atmosphere")
	if weather.is_empty():
		set_weather(String(Config.value("atmosphere", "default_weather")))


func _physics_process(dt: float) -> void:
	step(dt)


## blend_s — как у Atmosphere (мягкое обновление); здесь всегда сразу.
func set_weather(preset: Variant, _blend_s: float = -1.0) -> void:
	_cfg = Config.get_config("game").get("calm_air", {})
	weather = (Config.get_config(String(preset)) if preset is String else preset).duplicate(true)
	_top_agl = float(weather.get("cloudbase_agl_m", _cfg.get("thermal_top_agl_m", 1800.0)))
	set_wind(float(weather.get("wind_speed_kmh", 0.0)), float(weather.get("wind_from_deg", 0.0)))
	weather_changed.emit()


## Ветер: скорость, км/ч, и направление «откуда», ° (0 — с севера). ref_msl — как у Atmosphere
## (здесь ветер от высоты не зависит).
func set_wind(speed_kmh: float, from_deg: float, _ref_msl: float = NAN) -> void:
	weather.wind_speed_kmh = speed_kmh
	weather.wind_from_deg = from_deg
	var a := deg_to_rad(from_deg)
	# Дует ОТКУДА from_deg → вектор движения воздуха противоположен.
	var from_dir := Vector3(sin(a), 0.0, -cos(a))
	_wind = -from_dir * Units.kmh(speed_kmh)


func set_ground(height_fn: Callable, _sun_fn: Callable) -> void:
	_height_fn = height_fn


## Статичные термики относительно старта: вперёд по курсу / вправо (game.json → calm_air).
func place_thermals_near(start: Vector3, heading_deg: float) -> void:
	_thermals.clear()
	var h := deg_to_rad(heading_deg)
	var fwd := Vector2(sin(h), -cos(h))
	var right := Vector2(cos(h), sin(h))
	for t: Dictionary in _cfg.get("thermals_from_site", []):
		var p := Vector2(start.x, start.z) + fwd * float(t.forward_m) + right * float(t.right_m)
		add_static_thermal(p.x, p.y, float(t.strength_ms), float(t.radius_m))


func add_static_thermal(x: float, z: float, strength_ms: float, radius_m: float) -> int:
	_thermals.append({"x": x, "z": z, "w": strength_ms, "r": radius_m})
	return _thermals.size() - 1


func clear_static_thermals() -> void:
	_thermals.clear()


func step(dt: float) -> void:
	time_s += dt


## Скорость воздуха в точке, м/с: ветер + опускание + термики (колокол с кольцом опускания).
func air_velocity_at(pos: Vector3) -> Vector3:
	var ground := float(_height_fn.call(pos.x, pos.z)) if _height_fn.is_valid() else 0.0
	var agl := maxf(pos.y - ground, 0.0)
	var fade := minf(agl / maxf(float(_cfg.get("ground_fade_m", 60.0)), 1.0), 1.0)
	var w := float(_cfg.get("background_sink_ms", -0.5))
	if agl < _top_agl:
		var ring := float(_cfg.get("sink_ring_factor", 0.3))
		for t in _thermals:
			# Термик сносится ветром с высотой: ядро смещено по ветру.
			var drift := _wind * (agl / 2.0) / maxf(float(t.w), 0.5)
			var d := Vector2(pos.x - t.x - drift.x, pos.z - t.z - drift.z).length() / float(t.r)
			if d < 2.5:
				var core := exp(-d * d)
				w += float(t.w) * core - float(t.w) * ring * exp(-pow(d - 1.6, 2.0) * 4.0)
	return Vector3(_wind.x, w * fade, _wind.z)


func mean_wind_at(_pos: Vector3) -> Vector3:
	return _wind


# ================================================================ фасад W2
# Ветер 0, состояние READY сразу (без места тоже): опросы дают нули нужной длины, команды
# проверяют вход и возвращают коды W1. Прежние методы выше — переходные (до RW-3).


func last_error() -> String:
	return _f_err


func _f_fail(msg: String) -> int:
	_f_err = msg
	return BAD_INPUT


func configure(_seed: int) -> int:
	return OK


func load_place(place: AirPlaceData) -> int:
	if place == null:
		return _f_fail("load_place: место null")
	var why := place.validate()
	if why != "":
		return _f_fail("load_place: " + why)
	_f_place = place
	time_s = 0.0
	_height_fn = Callable(place, "height_at")
	_thermals.clear()
	var sites: Array = place.header.start_sites
	if not sites.is_empty():
		var st: Dictionary = sites[0]
		place_thermals_near(Vector3(float(st.x), float(st.h_msl), float(st.z)), 0.0)
	return OK


func unload_place() -> void:
	_f_place = null
	_height_fn = Callable()
	time_s = 0.0
	_thermals.clear()


func set_conditions(cond: Dictionary) -> int:
	if cond.has("forecast") == cond.has("preset"):
		return _f_fail("set_conditions: нужен ровно один из ключей forecast / preset")
	var allowed: Array[String] = [
		"start_hour", "speed", "blend_s", "rebuild", "inflow_mode", "forecast", "quantum_h",
		"wind_ref", "overrides", "preset",
	]
	for k: Variant in cond:
		if not allowed.has(String(k)):
			return _f_fail("set_conditions: посторонний ключ %s" % str(k))
	_cfg = Config.get_config("game").get("calm_air", {})
	var w: Dictionary
	if cond.has("preset"):
		var p: Variant = cond.preset
		w = (Config.get_config(String(p)) if p is String else p).duplicate(true)
	else:
		var fc: Dictionary = cond.forecast
		w = Config.get_config(String(Config.value("atmosphere", "default_weather"))).duplicate(true)
		w.wind_speed_kmh = float(fc.get("wind_speed_kmh", 0.0))
		w.wind_from_deg = float(fc.get("wind_from_deg", 0.0))
		for key: Variant in cond.get("overrides", {}):
			w[key] = cond.overrides[key]
	weather = w
	_top_agl = float(weather.get("cloudbase_agl_m", _cfg.get("thermal_top_agl_m", 1800.0)))
	set_wind(float(weather.get("wind_speed_kmh", 0.0)), float(weather.get("wind_from_deg", 0.0)))
	weather_changed.emit()
	return OK


func set_sun_direction(_to_sun: Vector3) -> void:
	pass


func set_static_thermals(list: PackedFloat32Array, mode: int) -> int:
	if list.size() % 4 != 0 or mode < 0 or mode > 2:
		return _f_fail("set_static_thermals: длина кратна 4, mode 0..2")
	if mode > 0:
		for i in range(0, list.size(), 4):
			add_static_thermal(list[i], list[i + 1], list[i + 2], list[i + 3])
	return OK


func set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int:
	if points.size() != weights.size():
		return _f_fail("set_focuses: размеры различаются")
	for w in weights:
		if not (is_finite(w) and w > 0.0):
			return _f_fail("set_focuses: вес ≤ 0")
	return OK


func advance_to(t: float) -> int:
	if not is_finite(t) or t < 0.0 or t < time_s:
		return _f_fail("advance_to: t < 0, не конечно или меньше текущего")
	time_s = t
	return OK


func start_at(t: float) -> int:
	if not is_finite(t) or t < 0.0:
		return _f_fail("start_at: t < 0 или не конечно")
	time_s = t
	return OK


func pump(_budget_us: int) -> void:
	pass


func status() -> Dictionary:
	return {"state": STATE_READY, "progress": 1.0, "time_s": time_s, "reason": ""}


func is_ready() -> bool:
	return true


func sample_many(points: PackedVector3Array, _mode: int = SAMPLE_FULL) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size() * 4)
	for i in points.size():
		var p := points[i]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			continue
		var v := air_velocity_at(p)
		out[4 * i] = v.x
		out[4 * i + 1] = v.y
		out[4 * i + 2] = v.z
	return out


func sample(pos: Vector3, mode: int = SAMPLE_FULL) -> Vector4:
	var r := sample_many(PackedVector3Array([pos]), mode)
	return Vector4(r[0], r[1], r[2], r[3])


func cloud_density_many(points: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size())
	return out


func cloudbase_msl() -> float:
	return 0.0


func get_cloudbase_msl() -> float:
	return cloudbase_msl()


func turbulence_intensity_at(_pos: Vector3) -> float:
	return 0.0


func thermals_near(_pos: Vector3, _radius: float) -> Array[Dictionary]:
	return []


func cloud_density_at(_pos: Vector3) -> float:
	return 0.0


func background_wind(heights_msl: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(heights_msl.size() * 2)
	return out


func get_weather() -> Dictionary:
	return weather.duplicate(true)


func sun_state() -> Vector4:
	return Vector4(0.0, 1.0, 0.0, 1.0)


func cores(_center: Vector3, _radius: float) -> PackedFloat32Array:
	return PackedFloat32Array()


func clouds(_center: Vector3, _radius: float) -> PackedFloat32Array:
	return PackedFloat32Array()


func cloud_raster() -> Dictionary:
	return {"version": 0}


func cloud_raster_version() -> int:
	return 0


func wave_crests(
	_center: Vector2, _radius: float, _min_eta: float, _spacing: float = 5000.0
) -> PackedFloat32Array:
	return PackedFloat32Array()


func decompose(_pos: Vector3) -> Dictionary:
	return {
		"names": PackedStringArray(),
		"vel": PackedVector3Array(),
		"sigma": PackedFloat32Array(),
		"total": Vector4(),
	}


func debug_raster_names() -> PackedStringArray:
	return PackedStringArray()


func debug_raster(_raster_name: String) -> Dictionary:
	return {}
