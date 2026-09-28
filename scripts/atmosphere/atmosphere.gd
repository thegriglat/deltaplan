# gdlint: disable=max-public-methods
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
##
## Детерминизм (сеть, NET-00): состояние — чистая функция (настройки, погода, day, сид, time_s).
##   atmo.seed_value = zone_seed                 # до set_weather/configure
##   atmo.set_weather(w); atmo.set_ground(…); atmo.set_wind(…); atmo.set_day(day)
##   atmo.start_at(zone_t)                       # сразу в момент t — то же, что прогон от 0

signal weather_changed
## Погода мягко обновлена (update_weather: ход дня) — термики и облака не пересоздаются.
signal weather_updated

## Нода, вокруг которой живут термики и облака (обычно планер). Если не задана — активная камера.
@export var focus_node: Node3D
## Рисовать облака и птиц (в тестах без окна — выключено автоматически).
@export var visuals_enabled: bool = true

var weather: Dictionary = {}
var cfg: Dictionary = {}

var wind: WindModel
var ground: GroundField
var field: ThermalField
## Облака в физике: подсос, поток в облаке, «в облаке ли» (FR-14b).
var cloud_phys: CloudPhysics
## Грозовые ячейки (Cb): нисходящий поток и фронт порывов (VR-26).
var storm: StormField
## Подветренные волны и роторы (VR-27).
var wave: WaveField

## Время атмосферы, с. Термики — чистые функции времени и координат.
var time_s: float = 0.0
## Пульсации (турбулентность) — можно выключить для тестов.
var turbulence_enabled: bool = true
## Сид мира (≥ 0) вместо atmosphere.json → seed — задать до configure/set_weather (сеть: сид зоны).
var seed_value: int = -1
## Ход дня (погода, солнце, источники — функции времени, AtmoDay); null — погода постоянна
## (или мягкие обновления set_weather(w, blend_s)).
var day: AtmoDay

var _focus: Vector3 = Vector3.ZERO
var _configured: bool = false
var _refresh_acc: float = 1.0e9
var _refresh_interval: float = 0.5
## Обновления — по сетке времени атмосферы (номер интервала), а не по накопленному dt: набор
## термиков в момент t не зависит от шага и от того, с какого момента атмосферу начали.
var _refresh_slot: int = -(1 << 62)
var _state_slot: int = -(1 << 62)
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
var _lee_shear: float = 40.0
var _lee_danger_min: float = 2.0
var _lee_danger_full: float = 5.0
var _lee_danger_sink: float = 0.7
var _lee_danger_turb: float = 0.8
var _lee_burst: float = 1.0
var _lee_burst_k: float = 0.375
var _lee_burst_thr: float = 0.8
var _lee_burst_width: float = 1.0
var _lee_reverse: float = 0.9
var _lee_rotor_h: float = 0.4
var _lee_rotor_max: float = 7.0
var _mech_k: float = 0.14
var _mech_boost: float = 1.0
var _mech_h: float = 150.0
var _conv_amp: float = 0.8
var _conv_norm: float = 1.0
var _vert_ratio: float = 0.7
var _turb_max: float = 6.0
var _advect: float = 0.0
var _wave_ref_agl: float = 1000.0
var _in_cloud_turb: float = 1.5
var _in_cloud_eject: float = 3.0
var _in_cloud_scale_k: float = 3.0
var _last_sigma: float = 0.0
## Базовые коэффициенты болтанки (без поправок хода дня).
var _mech_k_base: float = 0.14
var _edge_factor_base: float = 0.35
var _edge_width: float = 0.45
## Мягкое обновление погоды (ход дня): к чему плавно ведём и за сколько, с.
var _blend_tau: float = 0.0
var _target: Dictionary = {}
var _day_w: Dictionary = {}  ## погода шага дня, выставленная в weather

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


## Погодный пресет: имя конфига ("weather/strong") или словарь (WeatherModel.derive).
## blend_s ≥ 0 — мягкое обновление (ход дня, _update_weather): поле не пересоздаётся.
func set_weather(preset: Variant, blend_s: float = -1.0) -> void:
	var w: Dictionary = Config.get_config(String(preset)) if preset is String else preset
	if blend_s >= 0.0 and _configured:
		_update_weather(w, blend_s)
	else:
		configure(Config.get_config("atmosphere"), w)


## Полная настройка (для тестов можно передать свои словари).
func configure(atmo_cfg: Dictionary, weather_cfg: Dictionary) -> void:
	cfg = atmo_cfg
	weather = weather_cfg.duplicate(true)
	var seed_used := seed_value if seed_value >= 0 else int(cfg.seed)
	var old_ground := ground
	wind = WindModel.new()
	wind.setup(cfg.wind, cfg.turbulence, seed_used)
	wind.set_wind(Units.kmh(float(weather.wind_speed_kmh)), float(weather.wind_from_deg))
	ground = GroundField.new()
	ground.setup(cfg.ground, cfg.lee)
	if old_ground != null and old_ground.has_ground:
		ground.set_functions(old_ground.height_fn, old_ground.sun_fn)
		ground.surface_fn = old_ground.surface_fn
	ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	field = ThermalField.new()
	field.setup(cfg.thermal, weather, seed_used, ground, wind)
	field.day = day
	field.cirrus_block = float(cfg.cirrus.sun_block)
	field.cloud_width_per_ms_base = float(cfg.clouds.width_per_ms_m)
	var tb: Dictionary = cfg.turbulence
	_edge_factor_base = float(tb.edge_factor)
	_edge_width = float(tb.edge_width)
	field.set_turbulence_params(
		_edge_factor_base * float(weather.get("thermal_edge_k", 1.0)), _edge_width
	)
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
	# Перистая пелена (VR-28) ослабляет прогрев земли — термики реже и слабее.
	field.insolation = get_insolation()
	cloud_phys = CloudPhysics.new()
	cloud_phys.setup(cfg.clouds, cfg.thermal, float(weather.get("cloud_size_factor", 1.0)))
	field.cloud_phys = cloud_phys
	storm = StormField.new()
	storm.setup(cfg.storm, field.cloud_width_per_ms)
	wave = WaveField.new()
	wave.setup(cfg.wave, weather, ground)
	_update_wave_wind()
	_refresh_interval = float(cfg.thermal.refresh_interval_s)
	_state_interval = float(cfg.thermal.state_update_interval_s)
	_cache_coefficients()
	_cloudbase_agl = float(weather.cloudbase_agl_m)
	_update_cloudbase()
	for st: Dictionary in weather.get("static_thermals", []):
		add_static_thermal(float(st.x_m), float(st.z_m), float(st.strength_ms), float(st.radius_m))
	_configured = true
	_refresh_acc = 1.0e9
	_target.clear()
	_day_w = {}
	if _day_active():
		_apply_day(time_s)
	weather_changed.emit()


## Мягко перейти к новой погоде (set_weather(w, blend_s); ход дня — WeatherModel.derive с часом):
## новые термики рождаются с новыми числами, живые доживают со старыми; кромка, фон, болтанка
## и прогрев плавно идут к новым значениям за ~blend_s. Сетка источников (thermal_spacing_m),
## ветер и статичные термики не меняются — поле не пересоздаётся.
func _update_weather(w: Dictionary, blend_s: float) -> void:
	var nw := w.duplicate(true)
	for k in ["wind_speed_kmh", "wind_from_deg", "thermal_spacing_m", "static_thermals"]:
		if weather.has(k):
			nw[k] = weather[k]
	weather = nw
	field.set_weather_soft(weather)
	field.cloud_width_per_ms = (
		float(cfg.clouds.width_per_ms_m) * float(weather.get("cloud_size_factor", 1.0))
	)
	_target = {
		"bg_sink": float(weather.background_sink_ms),
		"conv_amp": float(weather.convective_turbulence_ms),
		"cloudbase_agl": float(weather.cloudbase_agl_m),
		"insolation": get_insolation(),
		"edge": _edge_factor_base * float(weather.get("thermal_edge_k", 1.0)),
		"mech": _mech_k_base * float(weather.get("mech_turbulence_k", 1.0)),
	}
	_blend_tau = maxf(blend_s, 0.0) / 3.0
	if _blend_tau <= 0.0:
		_blend(1.0)
	weather_updated.emit()


## Сдвинуть текущие коэффициенты к цели (доля k 0..1).
func _blend(k: float) -> void:
	if _target.is_empty():
		return
	_bg_sink = lerpf(_bg_sink, float(_target.bg_sink), k)
	_conv_amp = lerpf(_conv_amp, float(_target.conv_amp), k)
	field.insolation = lerpf(field.insolation, float(_target.insolation), k)
	_mech_k = lerpf(_mech_k, float(_target.mech), k)
	field.set_turbulence_params(lerpf(field.get_edge_factor(), float(_target.edge), k), _edge_width)
	var old_cb := _cloudbase_agl
	_cloudbase_agl = lerpf(_cloudbase_agl, float(_target.cloudbase_agl), k)
	if not _cloudbase_override and absf(_cloudbase_agl - old_cb) > 0.01:
		field.set_cloudbase_soft(_ground_ref + _cloudbase_agl)
	if k >= 1.0 or absf(_cloudbase_agl - float(_target.cloudbase_agl)) < 0.5:
		if absf(_bg_sink - float(_target.bg_sink)) < 1.0e-3:
			_target.clear()


## Ход дня: погода шага для рождения термиков и потребителей (weather), плавные величины —
## линейно между шагами. Чистая функция времени t (вместо _blend по кадрам).
func _apply_day(t: float) -> void:
	var b := day.bracket(t)
	var w0: Dictionary = b[0]
	var w1: Dictionary = b[1]
	var f: float = b[2]
	if not is_same(w0, _day_w):
		_day_w = w0
		var nw := w0.duplicate(true)
		for k in ["wind_speed_kmh", "wind_from_deg", "thermal_spacing_m", "static_thermals"]:
			if weather.has(k):
				nw[k] = weather[k]
		weather = nw
		field.set_weather_soft(weather)
		field.cloud_width_per_ms = (
			float(cfg.clouds.width_per_ms_m) * float(weather.get("cloud_size_factor", 1.0))
		)
		weather_updated.emit()
	_bg_sink = _lerp_key(w0, w1, f, "background_sink_ms", _bg_sink)
	_conv_amp = _lerp_key(w0, w1, f, "convective_turbulence_ms", _conv_amp)
	_mech_k = _mech_k_base * _lerp_key(w0, w1, f, "mech_turbulence_k", 1.0)
	field.set_turbulence_params(
		_edge_factor_base * _lerp_key(w0, w1, f, "thermal_edge_k", 1.0), _edge_width
	)
	var sb := float(cfg.cirrus.sun_block)
	field.insolation = (
		1.0 - clampf(_lerp_key(w0, w1, f, "cirrus_cover", 0.0), 0.0, 1.0) * sb
	)
	var cb := _lerp_key(w0, w1, f, "cloudbase_agl_m", _cloudbase_agl)
	if absf(cb - _cloudbase_agl) > 1.0e-6:
		_cloudbase_agl = cb
		if not _cloudbase_override:
			field.set_cloudbase_soft(_ground_ref + _cloudbase_agl)


static func _lerp_key(w0: Dictionary, w1: Dictionary, f: float, key: String, def: float) -> float:
	return lerpf(float(w0.get(key, def)), float(w1.get(key, def)), f)


## Задать ход дня (AtmoDay): погода, солнце и источники термиков — функции времени атмосферы.
func set_day(d: AtmoDay) -> void:
	day = d
	_day_w = {}
	if field != null:
		field.day = d
		if d != null and d.has_weather():
			_apply_day(time_s)
		_refresh_acc = 1.0e9


## Начать сразу с момента t (время атмосферы/зоны, с): то же состояние, что при прогоне от 0
## до t с любым шагом (сеть: догнать время зоны, NET-40). Статичные термики остаются.
func start_at(t: float) -> void:
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	time_s = t
	_target.clear()
	field.reset_dynamic()
	refresh_now()


## Обновить набор термиков, облака и сетку поиска на текущий time_s сразу (не ждать интервала).
func refresh_now() -> void:
	_update_focus()
	_refresh_slot = floori(time_s / _refresh_interval)
	_state_slot = floori(time_s / _state_interval)
	_refresh_acc = 0.0
	# Ход дня — на начало интервала (чистая функция времени, не шага).
	if _day_active():
		_apply_day(_state_slot * _state_interval)
	field.refresh(time_s, _focus, _refresh_interval)
	storm.refresh(field.thermals)
	cloud_phys.refresh(field.thermals, time_s, _focus, float(cfg.thermal.physics_radius_m))


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
	# Новые ключи — через get: старые/пользовательские конфиги без них продолжают работать.
	_lee_shear = float(l.get("shear_layer_m", 0.0))
	_lee_danger_min = float(l.get("danger_min_wind_ms", 2.0))
	_lee_danger_full = float(l.get("danger_full_wind_ms", 5.0))
	_lee_danger_sink = float(l.get("danger_sink_per_wind", _lee_sink))
	_lee_danger_turb = float(l.get("danger_turbulence_per_wind", _lee_turb))
	_lee_burst = float(l.get("burst_per_wind", 0.0))
	_lee_burst_k = float(cfg.turbulence.scale_m) / float(l.get("burst_scale_m", 120.0))
	_lee_burst_thr = float(l.get("burst_threshold", 0.8))
	_lee_burst_width = float(l.get("burst_width", 1.0))
	_lee_reverse = float(l.get("rotor_reverse", 0.0))
	_lee_rotor_h = float(l.get("rotor_height_fraction", 0.4))
	_lee_rotor_max = float(l.get("rotor_max_amplitude_ms", 0.0))
	var t: Dictionary = cfg.turbulence
	_mech_k_base = float(t.mech_per_wind)
	_mech_k = _mech_k_base * float(weather.get("mech_turbulence_k", 1.0))
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
	_wave_ref_agl = float(cfg.wave.wind_reference_agl_m)
	_in_cloud_turb = float(t.in_cloud_ms)
	_in_cloud_eject = float(t.in_cloud_eject_ms)
	_in_cloud_scale_k = float(t.scale_m) / float(t.in_cloud_scale_m)


static func _lenschow(xi: float) -> float:
	var a := 1.0 - 0.8 * xi
	return sqrt(1.8 * pow(xi, 2.0 / 3.0) * a * a)


## Функции рельефа: height_fn(x, z) -> высота над уровнем моря, sun_fn(x, z) -> 0..1.
## surface_fn(x, z) -> int — класс поверхности (terrain.surface_at), необязательно: для пылевых
## вихрей над сухими полями (VR-18).
func set_ground(height_fn: Callable, sun_fn: Callable, surface_fn := Callable()) -> void:
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	ground.set_functions(height_fn, sun_fn)
	ground.surface_fn = surface_fn
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
## ref_msl — высота над морем, где задан ветер прогноза (старт): выше неё ветер сильнее, ниже —
## слабее (atmosphere.json → wind.altitude_*); NAN — только профиль над рельефом.
func set_wind(speed_kmh: float, from_deg: float, ref_msl: float = NAN) -> void:
	wind.ref_msl = ref_msl
	weather.wind_speed_kmh = speed_kmh
	weather.wind_from_deg = from_deg
	var old := wind.from_deg
	wind.set_wind(Units.kmh(speed_kmh), from_deg)
	_advect = wind.speed_at(float(cfg.turbulence.advection_height_m))
	var tol := float(cfg.ground.wind_dir_tolerance_deg)
	if absf(angle_difference(deg_to_rad(old), deg_to_rad(from_deg))) > deg_to_rad(tol):
		ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	field.update_wind_frame()
	_update_wave_wind()
	_refresh_acc = 1.0e9


## Направление на солнце (единичный вектор, мир) — для теней облаков на источниках термиков.
## Главная сцена передаёт солнце мира; по умолчанию — из конфига (clouds.sun_*).
func set_sun_direction(to_sun: Vector3) -> void:
	field.sun_dir = to_sun.normalized()


## Нижняя кромка облаков над уровнем моря, м. По умолчанию — средняя высота земли + пресет.
func set_cloudbase_msl(msl: float) -> void:
	_cloudbase_override = true
	field.cloudbase_fixed = true
	field.set_cloudbase(msl)
	_refresh_acc = 1.0e9


func get_cloudbase_msl() -> float:
	return field.cloudbase_msl


func _update_cloudbase() -> void:
	var g: Dictionary = cfg.ground
	_ground_ref = ground.mean_height(
		0.0, 0.0, float(g.reference_radius_m), int(g.reference_samples)
	)
	field.cloudbase_ref = _ground_ref
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
	if not _day_active() and not _target.is_empty():
		_blend(1.0 - exp(-dt / _blend_tau) if _blend_tau > 0.0 else 1.0)
	_update_focus()
	_refresh_acc += dt
	if _refresh_acc >= 1.0e8 or floori(time_s / _refresh_interval) != _refresh_slot:
		refresh_now()
	else:
		var slot := floori(time_s / _state_interval)
		if slot != _state_slot:
			_state_slot = slot
			if _day_active():
				_apply_day(slot * _state_interval)
			field.update_time(time_s)
	ground.prefetch(_focus)


func _day_active() -> bool:
	return day != null and day.has_weather()


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
	var u := wind.speed_at_pos(agl, pos.y)
	var wd := wind.dir
	# Подветренная зона: ниже линии тени от гребня против ветра (и в слое сдвига над ней).
	var lee := 0.0
	var danger := 0.0
	var relief := 0.0
	var depth := gs.w - pos.y
	if depth > -_lee_shear and u > 0.0:
		relief = ground.relief_at(pos.x, pos.z)
		lee = (
			clampf((depth + _lee_shear) / (_lee_depth + _lee_shear), 0.0, 1.0)
			* clampf(relief / _lee_relief, 0.0, 1.0)
		)
		if lee > 0.0:
			danger = _lee_danger(wind.speed_ref * wind.altitude_factor(pos.y))
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
	var w := fade * (_bg_sink * (1.0 - th.y) + th.x) + w_ridge
	var h := u * (1.0 - lee * _lee_wind_red)
	if lee > 0.0:
		var ld := _lee_flow(pos, agl, u, lee, danger, relief)
		w += ld.y
		h += ld.x
	var v := Vector3(wd.x * h, w, wd.z * h)
	# Грозы: нисходящий поток, растекание и фронт порывов.
	var storm_turb := 0.0
	if not storm.cells.is_empty():
		var sf := storm.sample(pos, agl, time_s)
		v += Vector3(sf.x, sf.y, sf.z)
		storm_turb = sf.w
	# Подветренные волны и роторы.
	var rotor_turb := 0.0
	if wave.enabled:
		var wv := wave.sample(pos, agl, wind.speed_at(_wave_ref_agl))
		v.y += wv.x
		rotor_turb = wv.y
	# В облаке: поток «выкидывает» к краю, упорядоченного подъёма почти нет (FR-14b).
	var cin := Vector3.ZERO
	if cloud_phys.cloud_count() > 0:
		cin = cloud_phys.sample(pos)
		v += Vector3(cin.y, 0.0, cin.z) * _in_cloud_eject * cin.x
	_last_sigma = 0.0
	if not turbulence_enabled:
		return v
	# Турбулентность: механическая + конвективная (Lenschow) + край термика + ротор.
	var mech := _mech_k * u * (1.0 + _mech_boost * exp(-agl / _mech_h))
	var conv := 0.0
	if not above_base:
		var cb_agl := maxf(field.cloudbase_msl - gs.x, 1.0)
		conv = _conv_amp * _conv_norm * _lenschow(clampf(agl / cb_agl, 0.0, 1.0))
	var rot := lerpf(_lee_turb, _lee_danger_turb, danger) * u * lee
	var amp2 := mech * mech + conv * conv + th.z * th.z + rot * rot
	amp2 += storm_turb * storm_turb + rotor_turb * rotor_turb
	# У ротора свой предел: за гребнем в сильный ветер болтает сильнее общего ограничения.
	var amp := minf(sqrt(amp2), maxf(_turb_max, minf(rot, _lee_rotor_max)))
	# В облаке — бурление: большие пульсации мелкого масштаба во всех направлениях.
	var chaos := _in_cloud_turb * cin.x
	_last_sigma = sqrt(amp * amp + chaos * chaos)
	if chaos > 1.0e-3:
		var nc := wind.gust_unit(pos * _in_cloud_scale_k, time_s * 3.0, _advect, 0.0)
		v += nc * chaos
	if amp < 1.0e-3:
		return v
	# Крупные вихри растут с высотой (у земли масштаб вихрей ~ высоты): на разбеге и посадке —
	# мелкая болтанка, как раньше.
	var n := wind.gust_unit(pos, time_s, _advect, agl / wind.large_fade_agl)
	return v + Vector3(n.x * amp, n.y * amp * _vert_ratio * fade, n.z * amp)


## Опасность подветренной зоны 0..1 от ветра прогноза (нелинейно: слабый ветер — мягко).
func _lee_danger(u_ref: float) -> float:
	return smoothstep(_lee_danger_min, _lee_danger_full, u_ref)


## Подветренный поток: (добавка к горизонтали вдоль ветра, вертикаль), м/с. Нисходящий поток,
## рывки сверху (детерминированный шум, редкие сильные удары вниз) и ротор у склона — обратный
## поток у земли в глубине зоны.
func _lee_flow(
	pos: Vector3, agl: float, u: float, lee: float, danger: float, relief: float
) -> Vector2:
	var w := -lerpf(_lee_sink, _lee_danger_sink, danger) * u * lee
	var hard := lee * danger
	if hard < 1.0e-3:
		return Vector2(0.0, w)
	var nb := wind.gust_unit(pos * _lee_burst_k, time_s, u * _lee_burst_k, 0.0).x
	w -= _lee_burst * u * hard * clampf((nb - _lee_burst_thr) / _lee_burst_width, 0.0, 1.0)
	var core := hard * exp(-agl / maxf(_lee_rotor_h * relief, 1.0))
	return Vector2(-_lee_reverse * u * core, w)


## Интенсивность болтанки в точке — СКО пульсаций скорости воздуха, м/с (для оценки перегрузки,
## FR-14c; саму перегрузку flight считает по air_velocity_at на крыле).
func turbulence_intensity_at(pos: Vector3) -> float:
	var was := turbulence_enabled
	turbulence_enabled = true
	air_velocity_at(pos)
	turbulence_enabled = was
	return _last_sigma


## Плотность облака в точке 0..1 (0 — ясно): для «белой мглы» у камеры и оценки «в облаке».
func cloud_density_at(pos: Vector3) -> float:
	return cloud_phys.density_at(pos)


## Доля солнечного прогрева земли под перистой пеленой 0..1 (1 — ясно). Интегратор может
## ослабить по ней и солнце мира (VR-28).
func get_insolation() -> float:
	var cover := clampf(float(weather.get("cirrus_cover", 0.0)), 0.0, 1.0)
	return 1.0 - cover * float(cfg.cirrus.sun_block)


func _update_wave_wind() -> void:
	if wave != null:
		var u := wind.speed_at(float(cfg.wave.wind_reference_agl_m))
		wave.set_wind(u, Vector2(wind.dir.x, wind.dir.z))


## Средний ветер без пульсаций и вертикальных потоков (для колдуна на старте и т. п.), м/с.
func mean_wind_at(pos: Vector3) -> Vector3:
	var gs := ground.sample(pos.x, pos.z)
	var s := wind.speed_at_pos(maxf(pos.y - gs.x, 0.0), pos.y)
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
	var cirrus := CirrusLayer.new()
	cirrus.name = "Cirrus"
	add_child(cirrus)
	cirrus.setup(self)
	var dust := DustDevils.new()
	dust.name = "DustDevils"
	add_child(dust)
	dust.setup(self)
	if bool(cfg.birds.enabled):
		var bird_script: Script = load("res://scripts/atmosphere/bird_flock.gd")
		if bird_script != null:
			_birds = bird_script.new()
			_birds.name = "Birds"
			add_child(_birds)
			_birds.call("setup", self)
