class_name Atmosphere
extends Node3D
## Атмосфера: ветер с профилем и порывами, термики, фоновое опускание, склоновый подъём,
## подветренные зоны и роторы; рисует облака и птиц (дочерние ноды).
## Контракт — docs/ARCHITECTURE.md, модель — docs/research/thermals.md,
## описание — docs/atmosphere.md.
##
## Использование:
##   atmo.set_weather("weather/medium")          # или словарь пресета
##   atmo.set_ground(terrain.height_at, terrain.sun_exposure_at)
##   atmo.focus_node = glider                    # вокруг кого генерировать термики
##   var v := atmo.air_velocity_at(pos)          # скорость воздуха, м/с (мир)

signal weather_changed

## Нода, вокруг которой живут термики и облака (обычно планер). Если не задана — активная камера.
@export var focus_node: Node3D
## Рисовать облака и птиц (в тестах без окна — выключено автоматически).
@export var visuals_enabled: bool = true

var weather: Dictionary = {}
var cfg: Dictionary = {}

var wind: WindModel
var ground: GroundField
var field: ThermalField

## Время атмосферы, с. Термики — чистые функции времени и координат.
var time_s: float = 0.0
## Пульсации (турбулентность) — можно выключить для тестов.
var turbulence_enabled: bool = true

var _focus: Vector3 = Vector3.ZERO
var _configured: bool = false
var _refresh_acc: float = 1.0e9
var _refresh_interval: float = 0.5
var _state_acc: float = 0.0
var _state_interval: float = 0.1
var _cloudbase_agl: float = 1500.0
var _ground_ref: float = 0.0
var _cloudbase_override: bool = false

# Кешированные коэффициенты (чтобы air_velocity_at не лазил в словари).
var _bg_sink: float = -0.5
var _ground_fade: float = 60.0
var _ridge_eff: float = 0.7
var _ridge_decay: float = 250.0
var _ridge_shift_k: float = 0.8
var _ridge_shift_max: float = 400.0
var _ridge_max: float = 6.0
var _lee_depth: float = 120.0
var _lee_relief: float = 150.0
var _lee_sink: float = 0.25
var _lee_turb: float = 0.5
var _lee_wind_red: float = 0.6
var _mech_k: float = 0.14
var _mech_boost: float = 1.0
var _mech_h: float = 150.0
var _conv_amp: float = 0.8
var _conv_norm: float = 1.0
var _vert_ratio: float = 0.7
var _turb_max: float = 6.0
var _advect: float = 0.0

var _clouds: Node3D
var _birds: Node3D


func _ready() -> void:
	add_to_group("atmosphere")
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	if visuals_enabled and DisplayServer.get_name() != "headless":
		_create_visuals()


func _physics_process(delta: float) -> void:
	step(delta)


# ================================================================ настройка


## Погодный пресет: имя конфига ("weather/strong") или словарь.
func set_weather(preset: Variant) -> void:
	var w: Dictionary = Config.get_config(String(preset)) if preset is String else preset
	configure(Config.get_config("atmosphere"), w)


## Полная настройка (для тестов можно передать свои словари).
func configure(atmo_cfg: Dictionary, weather_cfg: Dictionary) -> void:
	cfg = atmo_cfg
	weather = weather_cfg.duplicate(true)
	var seed_value := int(cfg.seed)
	var old_ground := ground
	wind = WindModel.new()
	wind.setup(cfg.wind, cfg.turbulence, seed_value)
	wind.set_wind(Units.kmh(float(weather.wind_speed_kmh)), float(weather.wind_from_deg))
	ground = GroundField.new()
	ground.setup(cfg.ground, cfg.lee)
	if old_ground != null and old_ground.has_ground:
		ground.set_functions(old_ground.height_fn, old_ground.sun_fn)
	ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	field = ThermalField.new()
	field.setup(cfg.thermal, weather, seed_value, ground, wind)
	var tb: Dictionary = cfg.turbulence
	field.set_turbulence_params(float(tb.edge_factor), float(tb.edge_width))
	var cc: Dictionary = cfg.clouds
	field.cloud_linger_s = float(cc.linger_s)
	field.cloud_width_per_ms = (
		float(cc.width_per_ms_m) * float(weather.get("cloud_size_factor", 1.0))
	)
	field.cloud_width_min = float(cc.width_min_m)
	field.cloud_width_max = float(cc.width_max_m)
	var el := deg_to_rad(float(cc.sun_elevation_deg))
	var az := deg_to_rad(float(cc.sun_azimuth_deg))
	field.sun_dir = Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	_refresh_interval = float(cfg.thermal.refresh_interval_s)
	_state_interval = float(cfg.thermal.state_update_interval_s)
	_cache_coefficients()
	_cloudbase_agl = float(weather.cloudbase_agl_m)
	_update_cloudbase()
	for st: Dictionary in weather.get("static_thermals", []):
		add_static_thermal(float(st.x_m), float(st.z_m), float(st.strength_ms), float(st.radius_m))
	_configured = true
	_refresh_acc = 1.0e9
	weather_changed.emit()


func _cache_coefficients() -> void:
	_bg_sink = float(weather.background_sink_ms)
	_ground_fade = float(cfg.ground_fade_m)
	var r: Dictionary = cfg.ridge
	_ridge_eff = float(r.efficiency)
	_ridge_decay = float(r.decay_height_m)
	_ridge_shift_k = float(r.forward_shift_factor)
	_ridge_shift_max = float(r.forward_shift_max_m)
	_ridge_max = float(r.max_lift_ms)
	var l: Dictionary = cfg.lee
	_lee_depth = float(l.depth_scale_m)
	_lee_relief = float(l.relief_scale_m)
	_lee_sink = float(l.sink_per_wind)
	_lee_turb = float(l.turbulence_per_wind)
	_lee_wind_red = float(l.wind_reduction)
	var t: Dictionary = cfg.turbulence
	_mech_k = float(t.mech_per_wind)
	_mech_boost = float(t.mech_ground_boost)
	_mech_h = float(t.mech_ground_height_m)
	_vert_ratio = float(t.vertical_ratio)
	_turb_max = float(t.max_amplitude_ms)
	_conv_amp = float(weather.convective_turbulence_ms)
	# Профиль Lenschow σw ∝ √(1,8 ξ^(2/3) (1 − 0,8ξ)²) нормируем на максимум.
	var peak := 0.0
	for i in 101:
		peak = maxf(peak, _lenschow(i / 100.0))
	_conv_norm = 1.0 / maxf(peak, 1.0e-4)
	_advect = wind.speed_at(float(t.advection_height_m))


static func _lenschow(xi: float) -> float:
	var a := 1.0 - 0.8 * xi
	return sqrt(1.8 * pow(xi, 2.0 / 3.0) * a * a)


## Функции рельефа: height_fn(x, z) -> высота над уровнем моря, sun_fn(x, z) -> 0..1.
func set_ground(height_fn: Callable, sun_fn: Callable) -> void:
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	ground.set_functions(height_fn, sun_fn)
	ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	_update_cloudbase()
	# Статичные термики — пересадить на новую землю.
	var statics: Array = []
	for id in field.thermals:
		var th: AtmoThermal = field.thermals[id]
		if th.is_static:
			statics.append([th.src.x, th.src.z, th.strength, th.radius])
	field.clear_static()
	for s in statics:
		field.add_static(s[0], s[1], s[2], s[3])
	_refresh_acc = 1.0e9


## Ветер: скорость на опорной высоте (км/ч) и направление «откуда» (0 — с севера), FR-16.
func set_wind(speed_kmh: float, from_deg: float) -> void:
	weather.wind_speed_kmh = speed_kmh
	weather.wind_from_deg = from_deg
	var old := wind.from_deg
	wind.set_wind(Units.kmh(speed_kmh), from_deg)
	_advect = wind.speed_at(float(cfg.turbulence.advection_height_m))
	var tol := float(cfg.ground.wind_dir_tolerance_deg)
	if absf(angle_difference(deg_to_rad(old), deg_to_rad(from_deg))) > deg_to_rad(tol):
		ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	field.update_wind_frame()
	_refresh_acc = 1.0e9


## Направление на солнце (единичный вектор, мир) — для теней облаков на источниках термиков.
## Главная сцена передаёт солнце мира; по умолчанию — из конфига (clouds.sun_*).
func set_sun_direction(to_sun: Vector3) -> void:
	field.sun_dir = to_sun.normalized()


## Нижняя кромка облаков над уровнем моря, м. По умолчанию — средняя высота земли + пресет.
func set_cloudbase_msl(msl: float) -> void:
	_cloudbase_override = true
	field.set_cloudbase(msl)
	_refresh_acc = 1.0e9


func get_cloudbase_msl() -> float:
	return field.cloudbase_msl


func _update_cloudbase() -> void:
	var g: Dictionary = cfg.ground
	_ground_ref = ground.mean_height(
		0.0, 0.0, float(g.reference_radius_m), int(g.reference_samples)
	)
	if not _cloudbase_override:
		field.set_cloudbase(_ground_ref + _cloudbase_agl)


## Режим термиков: "dynamic" (по рельефу), "static" (только статичные — MVP), "both".
func set_thermal_mode(mode: String) -> void:
	field.mode = mode
	if mode == "static":
		field.update_wind_frame()  # убрать динамические
	_refresh_acc = 1.0e9


## Статичный термик (MVP): источник в (x, z), всегда на пике. Возвращает id.
func add_static_thermal(x: float, z: float, strength_ms: float, radius_m: float) -> int:
	var th := field.add_static(x, z, strength_ms, radius_m)
	_refresh_acc = 1.0e9
	return th.id


## Статичные термики из массива словарей {x_m, z_m, strength_ms, radius_m}
## (например, из конфига локации).
func load_static_thermals(list: Array) -> void:
	for st: Dictionary in list:
		add_static_thermal(float(st.x_m), float(st.z_m), float(st.strength_ms), float(st.radius_m))


func clear_static_thermals() -> void:
	field.clear_static()
	_refresh_acc = 1.0e9


func set_focus(pos: Vector3) -> void:
	_focus = pos


func get_focus() -> Vector3:
	return _focus


# ================================================================ время


## Продвинуть атмосферу на dt секунд (жизнь термиков, кеш рельефа).
func step(dt: float) -> void:
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	time_s += dt
	_update_focus()
	_refresh_acc += dt
	if _refresh_acc >= _refresh_interval:
		_refresh_acc = 0.0
		_state_acc = 0.0
		field.refresh(time_s, _focus, _refresh_interval)
	else:
		_state_acc += dt
		if _state_acc >= _state_interval:
			_state_acc = 0.0
			field.update_time(time_s)
	ground.prefetch(_focus)


func _update_focus() -> void:
	if focus_node != null and is_instance_valid(focus_node) and focus_node.is_inside_tree():
		_focus = focus_node.global_position
	elif is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			_focus = cam.global_position


# ================================================================ поле скоростей


## Скорость воздуха в точке (ветер + вертикальные потоки + пульсации), м/с, мир.
func air_velocity_at(pos: Vector3) -> Vector3:
	var gs := ground.sample(pos.x, pos.z)
	var agl := maxf(pos.y - gs.x, 0.0)
	var u := wind.speed_at(agl)
	var wd := wind.dir
	# Подветренная зона: ниже линии тени от гребня против ветра.
	var lee := 0.0
	var depth := gs.w - pos.y
	if depth > 0.0 and u > 0.0:
		lee = clampf(depth / _lee_depth, 0.0, 1.0) * clampf((gs.w - gs.x) / _lee_relief, 0.0, 1.0)
	# Склоновый подъём: V·∇h впереди по ветру, затухает с высотой над склоном.
	var w_ridge := 0.0
	if u > 0.0 and ground.has_ground:
		var shift := minf(agl * _ridge_shift_k, _ridge_shift_max)
		var gr := ground.sample(pos.x + wd.x * shift, pos.z + wd.z * shift)
		var slope := wd.x * gr.y + wd.z * gr.z
		var agl_s := maxf(pos.y - gr.x, 0.0)
		w_ridge = (
			clampf(_ridge_eff * u * slope * exp(-agl_s / _ridge_decay), -_ridge_max, _ridge_max)
			* (1.0 - lee)
		)
	# Термики и фоновое опускание (у земли плавно гаснут).
	var th := field.sample(pos)
	var fade := minf(agl / _ground_fade, 1.0)
	var above_base := pos.y >= field.cloudbase_msl
	var w := fade * (_bg_sink * (1.0 - th.y) + th.x) + w_ridge - _lee_sink * u * lee
	var h := u * (1.0 - lee * _lee_wind_red)
	var v := Vector3(wd.x * h, w, wd.z * h)
	if not turbulence_enabled:
		return v
	# Турбулентность: механическая + конвективная (Lenschow) + край термика + ротор.
	var mech := _mech_k * u * (1.0 + _mech_boost * exp(-agl / _mech_h))
	var conv := 0.0
	if not above_base:
		var cb_agl := maxf(field.cloudbase_msl - gs.x, 1.0)
		conv = _conv_amp * _conv_norm * _lenschow(clampf(agl / cb_agl, 0.0, 1.0))
	var rot := _lee_turb * u * lee
	var amp := minf(sqrt(mech * mech + conv * conv + th.z * th.z + rot * rot), _turb_max)
	if amp < 1.0e-3:
		return v
	var n := wind.gust_unit(pos, time_s, _advect)
	return v + Vector3(n.x * amp, n.y * amp * _vert_ratio * fade, n.z * amp)


## Средний ветер без пульсаций и вертикальных потоков (для колдуна на старте и т. п.), м/с.
func mean_wind_at(pos: Vector3) -> Vector3:
	var gs := ground.sample(pos.x, pos.z)
	var s := wind.speed_at(maxf(pos.y - gs.x, 0.0))
	return Vector3(wind.dir.x * s, 0.0, wind.dir.z * s)


## Термики рядом (для тестов, птиц и отладки; НЕ показывать пилоту — FR-22).
func thermals_near(pos: Vector3, radius: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for th in field.near(pos, radius):
		out.append(th.to_dict())
	return out


# ================================================================ визуал


func _create_visuals() -> void:
	if bool(cfg.clouds.enabled):
		var cloud_script: Script = load("res://scripts/atmosphere/cloud_layer.gd")
		if cloud_script != null:
			_clouds = cloud_script.new()
			_clouds.name = "Clouds"
			add_child(_clouds)
			_clouds.call("setup", self)
	if bool(cfg.birds.enabled):
		var bird_script: Script = load("res://scripts/atmosphere/bird_flock.gd")
		if bird_script != null:
			_birds = bird_script.new()
			_birds.name = "Birds"
			add_child(_birds)
			_birds.call("setup", self)
