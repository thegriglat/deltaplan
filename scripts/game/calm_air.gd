class_name CalmAir
extends Node3D
## Запасная модель воздуха, если основная атмосфера (scripts/atmosphere) не загрузилась.
## Тот же интерфейс, что у Atmosphere (docs/ARCHITECTURE.md): set_weather, set_wind,
## set_ground, air_velocity_at, step, focus_node. Постоянный ветер из пресета погоды,
## фоновое опускание и несколько статичных термиков вокруг старта (configs/game.json → calm_air).
## Облаков не рисует. Замена на настоящую атмосферу — строка game.json → air.script.

signal weather_changed

@export var focus_node: Node3D

var weather: Dictionary = {}
var time_s: float = 0.0

var _cfg: Dictionary = {}
var _wind := Vector3.ZERO
var _height_fn: Callable = Callable()
var _thermals: Array[Dictionary] = []  # {x, z, w, r}
var _top_agl: float = 1800.0


func _ready() -> void:
	add_to_group("atmosphere")
	if weather.is_empty():
		set_weather(String(Config.value("game", "default_weather")))


func _physics_process(dt: float) -> void:
	step(dt)


func set_weather(preset: Variant) -> void:
	_cfg = Config.get_config("game").get("calm_air", {})
	weather = (Config.get_config(String(preset)) if preset is String else preset).duplicate(true)
	_top_agl = float(weather.get("cloudbase_agl_m", _cfg.get("thermal_top_agl_m", 1800.0)))
	set_wind(float(weather.get("wind_speed_kmh", 0.0)), float(weather.get("wind_from_deg", 0.0)))
	weather_changed.emit()


## Ветер: скорость, км/ч, и направление «откуда», ° (0 — с севера).
func set_wind(speed_kmh: float, from_deg: float) -> void:
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
