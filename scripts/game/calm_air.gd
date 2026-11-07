# gdlint: disable=max-public-methods
class_name CalmAir
extends Node3D
## Запасная модель воздуха, если основная атмосфера (scripts/atmosphere) не загрузилась.
## Тот же фасад W2 (docs/contracts/rust-wind.md), что у Atmosphere, и поведение `Calm` из W4:
## ветер, вертикаль и σ — нули, описаний нет, облаков нет, READY сразу. Замена на настоящую
## атмосферу — строка game.json → air.script.

signal weather_changed
signal weather_updated
signal state_changed(state: int)

# Фасад W2 (docs/contracts/rust-wind.md): те же константы, что у Atmosphere (копия — запасной
# воздух не должен зависеть от основной атмосферы).
const WIND_API_VERSION := 6
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
const OBJ_STRIDE := 22
const WAVE_INFO_ENABLED := 0
const WAVE_INFO_LENGTH := 1

var time_s: float = 0.0

var _weather: Dictionary = {}
var _f_err := ""
var _f_place: AirPlaceData


func _ready() -> void:
	add_to_group("atmosphere")


# ================================================================ фасад W2
# Ветер 0, состояние READY сразу (без места тоже): опросы дают нули нужной длины, команды
# проверяют вход и возвращают коды W1.


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
	return OK


func unload_place() -> void:
	_f_place = null
	time_s = 0.0


func set_conditions(cond: Dictionary) -> int:
	if cond.has("forecast") == cond.has("preset"):
		return _f_fail("set_conditions: нужен ровно один из ключей forecast / preset")
	var allowed: Array[String] = [
		"start_hour",
		"speed",
		"blend_s",
		"rebuild",
		"forecast",
		"quantum_h",
		"wind_ref",
		"overrides",
		"preset",
	]
	for k: Variant in cond:
		if not allowed.has(String(k)):
			return _f_fail("set_conditions: посторонний ключ %s" % str(k))
	var w: Dictionary
	if cond.has("preset"):
		var p: Variant = cond.preset
		w = (Config.get_config(String(p)) if p is String else p).duplicate(true)
	else:
		var fc: Dictionary = cond.forecast
		w = (
			Config
			. get_config(String(Config.get_config("atmosphere").get("default_weather", "")))
			. duplicate(true)
		)
		w.wind_speed_kmh = float(fc.get("wind_speed_kmh", 0.0))
		w.wind_from_deg = float(fc.get("wind_from_deg", 0.0))
		for key: Variant in cond.get("overrides", {}):
			w[key] = cond.overrides[key]
	_weather = w
	weather_changed.emit()
	return OK


func set_sun_direction(_to_sun: Vector3) -> void:
	pass


func set_static_thermals(list: PackedFloat32Array, mode: int) -> int:
	if list.size() % 4 != 0 or mode < 0 or mode > 2:
		return _f_fail("set_static_thermals: длина кратна 4, mode 0..2")
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
	return {
		"state": STATE_READY,
		"progress": 1.0,
		"time_s": time_s,
		"reason": "",
		"stage": "",
		"field_on": false,
		"iters": 0,
		"run": 0,
		"runs": 0,
	}


func is_ready() -> bool:
	return true


func sample_many(points: PackedVector3Array, _mode: int = SAMPLE_FULL) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size() * 4)
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


func air_velocity_at(_pos: Vector3) -> Vector3:
	return Vector3.ZERO


func mean_wind_at(_pos: Vector3) -> Vector3:
	return Vector3.ZERO


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


func weather() -> Dictionary:
	return _weather.duplicate(true)


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


func cloud_objects(_center: Vector3, _radius: float, _t: float) -> PackedFloat32Array:
	return PackedFloat32Array()


func wave_info() -> PackedFloat32Array:
	return PackedFloat32Array([0.0, 0.0])


func surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(mini(xz.size(), t.size()))
	return out
