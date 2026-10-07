# gdlint: disable=max-public-methods
class_name Atmosphere
extends Node3D
## Атмосфера: ветер с профилем и порывами, термики, фоновое опускание, склоновый подъём,
## подветренные зоны и роторы; рисует облака и птиц (дочерние ноды).
## Контракт — docs/guide/architecture.md, модель — docs/research/thermals.md,
## описание — docs/guide/atmosphere.md.
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

## Журнал режима поля: последняя напечатанная строка (одна строка на смену режима, не на мир).
static var _air_log_last := ""
## Поле из командной строки (--air-field=<путь>, отладка до решателя на GPU): читается один раз.
static var _cmd_field_checked := false
static var _cmd_field: WindField
static var _cmd_field_error := ""

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
## Среднее поле воздуха (масштаб 1, docs/guide/air-model.md → «Поле на CPU»): уровни и плавная подмена.
## Переживает configure() (как функции рельефа); поле подаёт set_air_field.
var air_field: AirFieldSet
## Масштаб 3 с полем (AM-08): коэффициенты, признак отрыва, σ и спектр порывов.
var field_turb: FieldTurbulence

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
## Во сколько раз реже обновлять список термиков и облака (только «Подождать час», Q-17: мир идёт
## ×60, а пересчёт — 25–45 мс — не должен падать на каждый шаг). 1 — как обычно.
var refresh_scale: float = 1.0
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
var _lee_heat_full: float = 0.0
var _lee_heat_wstar_k: float = 0.6
var _lee_heat_key: Vector2 = Vector2(-1.0, -1.0)
var _lee_heat_val: float = 1.0
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
## Промежуточные величины выборки (_extra_flow): σ гроз и роторов волн, облако в точке.
var _storm_turb: float = 0.0
var _rotor_turb: float = 0.0
var _cin := Vector3.ZERO
## Базовые коэффициенты болтанки (без поправок хода дня).
var _mech_k_base: float = 0.14
var _edge_factor_base: float = 0.35
var _edge_width: float = 0.45
## Мягкое обновление погоды (ход дня): к чему плавно ведём и за сколько, с.
var _blend_tau: float = 0.0
var _target: Dictionary = {}
var _day_w: Dictionary = {}  ## погода шага дня, выставленная в weather
## Поле воздуха используется (air_model.enabled ≠ off и поле есть).
var _air_on: bool = false
var _air_mode: String = "auto"
var _air_blend_s: float = 60.0

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
	var wc := _wind_conditions()
	wind.set_conditions(wc.x, wc.y)
	wind.set_wind(Units.kmh(float(weather.wind_speed_kmh)), float(weather.wind_from_deg))
	field_turb = FieldTurbulence.new()
	field_turb.setup(cfg.turbulence, cfg.lee, seed_used)
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
	_setup_air()
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
	_update_wind_conditions()
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
		_update_wind_conditions()
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
	_refresh_slot = floori(time_s / _refresh_dt())
	_state_slot = floori(time_s / _state_interval)
	_refresh_acc = 0.0
	# Ход дня — на начало интервала (чистая функция времени, не шага).
	if _day_active():
		_apply_day(_state_slot * _state_interval)
	field.refresh(time_s, _focus, _refresh_dt())
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
	_lee_heat_full = float(l.get("heat_kill_wm2", 0.0))
	_lee_heat_wstar_k = float(l.get("heat_sigma_per_wstar", 0.6))
	_lee_heat_key = Vector2(-1.0, -1.0)
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


## Поле воздуха по конфигу air_model: режим, край, ограничители; поле с --air-field=<путь>.
func _setup_air() -> void:
	var ac: Dictionary = cfg.get("air_model", {})
	if air_field == null:
		air_field = AirFieldSet.new()
	air_field.edge_cells = float(ac.get("edge_blend_cells", 5.0))
	air_field.max_speed = float(ac.get("max_speed_ms", 40.0))
	air_field.max_w = float(ac.get("max_w_ms", 10.0))
	for f in air_field.levels:
		f.edge_cells = air_field.edge_cells
	_air_blend_s = float(ac.get("blend_s", 60.0))
	_air_mode = String(ac.get("enabled", "auto"))
	if _air_mode != "off" and not air_field.is_active():
		var f := _cmdline_field()
		if f != null:
			air_field.set_field(f, 0.0)
	_update_air_mode()


## Подать поле воздуха: WindField, массив уровней (от мелкого к грубому) или null — без поля.
## blend_s — время плавной подмены старого поля (или аналитики) новым, с времени атмосферы;
## < 0 — air_model.blend_s. При air_model.enabled = off поле хранится, но не используется.
func set_air_field(new_field: Variant, blend_s: float = -1.0) -> void:
	if air_field == null:
		air_field = AirFieldSet.new()
	air_field.set_field(new_field, _air_blend_s if blend_s < 0.0 else blend_s)
	_update_air_mode()


## Режим поля воздуха поверх конфига: "auto" | "on" | "off" (отладка «поле/аналитика», замеры).
func set_air_mode(mode: String) -> void:
	_air_mode = mode
	_update_air_mode()


## Используется ли сейчас поле воздуха (иначе — аналитика).
func is_air_field_on() -> bool:
	return _air_on


func _update_air_mode() -> void:
	# Упрощённый ветер (off): профиль по высоте как в 0.8.0; auto/on — WindProfile (C2 v4).
	if wind != null and cfg != null and (_air_mode == "off") != wind.simple_profile:
		wind.set_simple_profile(_air_mode == "off", cfg.get("wind_profile_simple", {}))
	var reason := ""
	if _air_mode == "off":
		reason = "air_model.enabled = off"
	elif not air_field.is_active():
		reason = "нет поля" if _cmd_field_error == "" else _cmd_field_error
		if _air_mode == "on":
			reason += "; требуется поле (enabled = on)"
	_air_on = reason == ""
	if not air_field.levels.is_empty() and field_turb != null:
		field_turb.z0 = air_field.levels[0].z0
	# Термики из поля (AM-07): источники, сила, потолок, снос и «между» — ThermalField.air.
	if field != null:
		field.air = air_field if _air_on else null
	var line := "air_model: analytic (%s)" % reason
	if _air_on:
		var src := "поле"
		if not air_field.levels.is_empty():
			var m: Dictionary = air_field.levels[0].meta
			src = String(m.get("path", "массивы"))
			var cond: Dictionary = m.get("cond", {})
			if cond.has("wind"):
				src += ", ветер поля %s м/с с %s°" % [cond.wind, cond.get("wdir", "?")]
		line = "air_model: field (%s; уровней %d)" % [src, air_field.levels.size()]
	if line != _air_log_last:
		_air_log_last = line
		if _air_mode == "on" and not _air_on:
			push_warning(line)
		print(line)


static func _cmdline_field() -> WindField:
	if not _cmd_field_checked:
		_cmd_field_checked = true
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--air-field="):
				var path := a.substr(12)
				_cmd_field = WindField.load_file(path)
				if _cmd_field == null:
					_cmd_field_error = "ошибка чтения поля %s" % path
	return _cmd_field


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
	if _air_on:
		air_field.advance(dt)
	if not _day_active() and not _target.is_empty():
		_blend(1.0 - exp(-dt / _blend_tau) if _blend_tau > 0.0 else 1.0)
	_update_focus()
	_refresh_acc += dt
	if _refresh_acc >= 1.0e8 or floori(time_s / _refresh_dt()) != _refresh_slot:
		refresh_now()
	else:
		var slot := floori(time_s / _state_interval)
		if slot != _state_slot:
			_state_slot = slot
			if _day_active():
				_apply_day(slot * _state_interval)
			field.update_time(time_s)
	ground.prefetch(_focus)


func _refresh_dt() -> float:
	return _refresh_interval * maxf(refresh_scale, 1.0)


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
## С полем воздуха (доля fw.w > 0) — _air_velocity_field (масштабы 1–3 из поля); без поля и вне
## поля — аналитика ниже (побитно прежняя).
func air_velocity_at(pos: Vector3) -> Vector3:
	var gs := ground.sample(pos.x, pos.z)
	var agl := maxf(pos.y - gs.x, 0.0)
	var u := wind.speed_at_pos(agl, pos.y)
	if _air_on:
		var fw := air_field.sample(pos, gs.x)
		if fw.w > 0.0:
			return _air_velocity_field(pos, gs, agl, u, fw)
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
		w_ridge = _ridge_lift(pos, agl, u)
	w_ridge *= 1.0 - lee
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
	var v := _extra_flow(Vector3(wd.x * h, w, wd.z * h), pos, agl)
	_last_sigma = 0.0
	if not turbulence_enabled:
		return v
	var rot := lerpf(_lee_turb, _lee_danger_turb, danger) * u * lee
	var amp := _analytic_amp(pos, gs, agl, u, th, rot, above_base)
	var tv := _analytic_turb(pos, agl, amp, fade)
	# В облаке — бурление: большие пульсации мелкого масштаба во всех направлениях.
	var chaos := _in_cloud_turb * _cin.x
	_last_sigma = sqrt(amp * amp + chaos * chaos)
	if chaos > 1.0e-3:
		var nc := wind.gust_unit(pos * _in_cloud_scale_k, time_s * 3.0, _advect, 0.0)
		v += nc * chaos
	if amp < 1.0e-3:
		return v
	return v + tv


## Склоновый подъём аналитики: V·∇h впереди по ветру, затухает с высотой над склоном, м/с.
func _ridge_lift(pos: Vector3, agl: float, u: float) -> float:
	var wd := wind.dir
	var shift := minf(agl * _ridge_shift_k, _ridge_shift_max)
	var gr := ground.sample(pos.x + wd.x * shift, pos.z + wd.z * shift)
	var slope := wd.x * gr.y + wd.z * gr.z
	var agl_s := maxf(pos.y - gr.x, 0.0)
	return clampf(_ridge_eff * u * slope * exp(-agl_s / _ridge_decay), -_ridge_max, _ridge_max)


## Грозы, подветренные волны, поток в облаке — добавить к скорости v; σ болтанки гроз и роторов
## волн — в _storm_turb, _rotor_turb, облако в точке — в _cin (для бурления).
func _extra_flow(v_in: Vector3, pos: Vector3, agl: float) -> Vector3:
	var v := v_in
	# Грозы: нисходящий поток, растекание и фронт порывов.
	_storm_turb = 0.0
	if not storm.cells.is_empty():
		var sf := storm.sample(pos, agl, time_s)
		v += Vector3(sf.x, sf.y, sf.z)
		_storm_turb = sf.w
	# Подветренные волны и роторы.
	_rotor_turb = 0.0
	if wave.enabled:
		var wv := wave.sample(pos, agl, wind.speed_at(_wave_ref_agl))
		v.y += wv.x
		_rotor_turb = wv.y
	# В облаке: поток «выкидывает» к краю, упорядоченного подъёма почти нет (FR-14b).
	_cin = Vector3.ZERO
	if cloud_phys.cloud_count() > 0:
		_cin = cloud_phys.sample(pos)
		v += Vector3(_cin.y, 0.0, _cin.z) * _in_cloud_eject * _cin.x
	return v


## σ болтанки аналитики (горизонталь), м/с: механическая + конвективная (Lenschow) + край термика
## + ротор + грозы и роторы волн.
func _analytic_amp(
	_pos: Vector3, gs: Vector4, agl: float, u: float, th: Vector3, rot: float, above_base: bool
) -> float:
	var mech := _mech_k * u * (1.0 + _mech_boost * exp(-agl / _mech_h))
	var conv := 0.0
	if not above_base:
		var cb_agl := maxf(field.cloudbase_msl - gs.x, 1.0)
		conv = _conv_amp * _conv_norm * _lenschow(clampf(agl / cb_agl, 0.0, 1.0))
	var amp2 := mech * mech + conv * conv + th.z * th.z + rot * rot
	amp2 += _storm_turb * _storm_turb + _rotor_turb * _rotor_turb
	# У ротора свой предел: за гребнем в сильный ветер болтает сильнее общего ограничения.
	return minf(sqrt(amp2), maxf(_turb_max, minf(rot, _lee_rotor_max)))


## Пульсации аналитики: двухмасштабный шум WindModel.gust_unit × σ (вертикаль — доля
## vertical_ratio и гаснет у земли).
func _analytic_turb(pos: Vector3, agl: float, amp: float, fade: float) -> Vector3:
	if amp < 1.0e-3:
		return Vector3.ZERO
	# Крупные вихри растут с высотой (у земли масштаб вихрей ~ высоты): на разбеге и посадке —
	# мелкая болтанка, как раньше.
	var n := wind.gust_unit(pos, time_s, _advect, agl / wind.large_fade_agl)
	return Vector3(n.x * amp, n.y * amp * _vert_ratio * fade, n.z * amp)


## Скорость воздуха с полем (масштабы 1–3 из поля, docs/guide/air-model.md → «Масштаб 3: возмущения
## из поля»). fw — выборка поля (доля a = fw.w > 0); в полосе края (a < 1) остаток — аналитика с её
## линией тени.
## - Среднее: горизонталь и w_mech — поле; подветренного опускания и ослабления ветра поверх поля
##   нет (они уже в поле); у аналитической доли — как в аналитике.
## - Зона отрыва — признак из поля (FieldTurbulence.lee: дефицит скорости у земли против
##   лог-профиля под «внешним» ветром столба и опускание); в ней эвристика (C4 v4) даёт болтанку
##   слоя смешения по ΔU от ветра поля на уровне гребня U_H, рывки (часть этой болтанки, с нулевым
##   средним, только при turbulence_enabled) и обратный поток у земли 0,22·U_H — только там, где
##   пузырь отрыва решателем не разрешён (грубая сетка).
## - Болтанка: механическая по u* поля (в приземном слое — по ветру в точке) и местному сдвигу (с
##   поправкой на устойчивость Ri), конвективная по w* (Lenschow; сложение σ³ — Panofsky 1977),
##   слоя смешения за гребнем по ΔU; горизонталь вдоль и поперёк среднего ветра (σ_u ≠ σ_v); шум —
##   спектр фон Кармана (GustSpectrum) с масштабами MIL-HDBK-1797 от высоты и устойчивости, у земли
##   растянутыми под местный перенос, конвективная горизонталь — с масштабом 0,22 z_i (AS-2).
func _air_velocity_field(pos: Vector3, gs: Vector4, agl: float, u: float, fw: Vector4) -> Vector3:
	var wd := wind.dir
	var a := fw.w
	var tb := air_field.sample_turb(pos, gs.x)
	# аналитическая доля (полоса края поля): линия тени, склоновый подъём
	var lee_a := 0.0
	var relief := -1.0
	var w_ridge := 0.0
	if a < 1.0 and u > 0.0:
		var depth := gs.w - pos.y
		if depth > -_lee_shear:
			relief = ground.relief_at(pos.x, pos.z)
			lee_a = (
				clampf((depth + _lee_shear) / (_lee_depth + _lee_shear), 0.0, 1.0)
				* clampf(relief / _lee_relief, 0.0, 1.0)
			)
		if ground.has_ground:
			w_ridge = _ridge_lift(pos, agl, u) * (1.0 - lee_a)
	# поле: скорость (без доли), признак отрыва, скачок скорости слоя смешения ΔU от ветра поля
	# на уровне гребня U_H (та же вертикаль, высота h + max(r, agl); C4 v4)
	var uf := Vector2(fw.x, fw.z).length() / a
	var lee_f := field_turb.lee(uf, agl, tb)
	var danger := 0.0
	if lee_f > 0.0 or lee_a > 0.0:
		danger = _lee_danger(wind.speed_ref * wind.altitude_factor(pos.y))
		if relief < 0.0:
			relief = ground.relief_at(pos.x, pos.z)
	var u_h := uf
	if lee_f > 0.0 and relief > agl:
		var fh := air_field.sample(Vector3(pos.x, gs.x + relief, pos.z), gs.x)
		if fh.w > 0.0:
			u_h = Vector2(fh.x, fh.z).length() / fh.w
	var du := maxf(u_h - uf, 0.0) * lee_f
	# средняя вертикаль: w_mech поля + аналитика в доле края; термики и фон — как всегда
	var th := field.sample(pos)
	var fade := minf(agl / _ground_fade, 1.0)
	var above_base := pos.y >= field.cloudbase_msl
	var w := fade * (_bg_sink * (1.0 - th.y) + th.x) + fw.y + (1.0 - a) * w_ridge
	var h := u * (1.0 - a) * (1.0 - lee_a * _lee_wind_red)
	if lee_a > 0.0:
		w -= (1.0 - a) * lerpf(_lee_sink, _lee_danger_sink, danger) * u * lee_a
	var hard_a := (1.0 - a) * u * lee_a * danger
	if hard_a > 0.0:
		# аналитическая доля: рывки вниз в пятнах шума и ротор у земли — как в аналитике
		if hard_a > 1.0e-3:
			w -= _lee_burst * hard_a * _lee_burst_g(pos, u)
		h -= _lee_reverse * hard_a * exp(-agl / maxf(_lee_rotor_h * relief, 1.0))
	if lee_f > 0.0 and danger > 0.0:
		# обратный поток у земли — только там, где пузырь отрыва (L ≈ 2,8 r) решателем не разрешён
		# (меньше n1 клеток на длину): в окнах 50/100 м возвратное течение даёт само поле
		var unres := field_turb.reverse_unresolved(relief, air_field.sample_dx(pos, gs.x))
		if unres > 0.0:
			h -= (
				a * field_turb.reverse * u_h * lee_f * danger * unres
				* exp(-agl / maxf(_lee_rotor_h * relief, 1.0))
			)
	var v := Vector3(fw.x + wd.x * h, w, fw.z + wd.z * h)
	v = _extra_flow(v, pos, agl)
	_last_sigma = 0.0
	if not turbulence_enabled:
		return v
	# болтанка поля
	var conv_a := 0.0
	if tb[WindField.T_HMIX] <= 0.0 and not above_base:
		# в поле нет данных о нагреве — конвективная болтанка аналитики (погода)
		var cb_agl := maxf(field.cloudbase_msl - gs.x, 1.0)
		conv_a = _conv_amp * _conv_norm * _lenschow(clampf(agl / cb_agl, 0.0, 1.0))
	# средний ветер в точке (поле + доля аналитики) — u* приземного слоя и перенос вихрей у земли
	var mh := Vector2(v.x, v.z)
	var sg := field_turb.sigma(agl, tb, Vector2(conv_a, conv_a * _vert_ratio), uf)
	var s_u := sg.x
	var s_v := field_turb.last_sv
	var s_w := sg.y
	var s_sep := field_turb.sep_sigma(du)
	# рывки вниз слоя смешения (с нулевым средним — поток массы уже в w_mech поля): часть
	# пульсаций, их доля в σ_w вычитается из гауссовой, σ_w в зоне = 0,14·ΔU (Bell & Mehta 1990)
	var hard_f := du * danger
	var w_burst := 0.0
	if hard_f > 1.0e-3:
		var amp_b := field_turb.burst_per_du * hard_f
		var g_mean := field_turb.burst_mean(wind, _lee_burst_k, _lee_burst_thr, _lee_burst_width)
		var g_std := field_turb.burst_std(wind, _lee_burst_k, _lee_burst_thr, _lee_burst_width)
		w_burst = -amp_b * (_lee_burst_g(pos, u) - g_mean)
		var s_b := amp_b * g_std
		s_sep.y = sqrt(maxf(s_sep.y * s_sep.y - s_b * s_b, 0.0))
	s_u = maxf(s_u, s_sep.x)
	s_v = maxf(s_v, s_sep.x)
	s_w = maxf(s_w, s_sep.y)
	var ex2 := th.z * th.z + _storm_turb * _storm_turb + _rotor_turb * _rotor_turb
	var cap_h := maxf(_turb_max, minf(s_sep.x, _lee_rotor_max))
	s_u = minf(sqrt(s_u * s_u + ex2), cap_h)
	s_v = minf(sqrt(s_v * s_v + ex2), cap_h)
	s_w = minf(
		sqrt(s_w * s_w + ex2 * _vert_ratio * _vert_ratio),
		maxf(_turb_max, minf(s_sep.y, _lee_rotor_max))
	)
	# вихри слоя смешения за гребнем не ограничены расстоянием до стенки: масштаб — толщина слоя,
	# у места присоединения ~ высоты гребня над точкой (Castro & Haque 1987)
	var l_sep := field_turb.sep_scale * maxf(relief, 0.0) * lee_f
	# у земли вихри несёт местный ветер, а не перенос шума (FieldTurbulence.taylor_stretch)
	var stretch := FieldTurbulence.taylor_stretch(_advect, mh.length(), agl)
	var n := field_turb.gusts.sample(
		pos, time_s, _advect, wd, maxf(sg.z * stretch, l_sep), maxf(sg.w * stretch, l_sep),
		field_turb.last_l_c, field_turb.last_fu_c, field_turb.last_fv_c
	)
	# горизонталь — вдоль и поперёк среднего ветра в точке (σ_u ≠ σ_v)
	var e := mh / mh.length() if mh.length() > 0.3 else Vector2(wd.x, wd.z).normalized()
	var tv := Vector3(
		e.x * n.x * s_u - e.y * n.z * s_v, n.y * s_w + a * w_burst, e.y * n.x * s_u + e.x * n.z * s_v
	)
	var sig := s_u
	if a < 1.0:
		# полоса края: смесь с аналитикой (два независимых шума — дисперсия сохраняется)
		var rot := lerpf(_lee_turb, _lee_danger_turb, danger) * u * lee_a
		var amp := _analytic_amp(pos, gs, agl, u, th, rot, above_base)
		var ta := _analytic_turb(pos, agl, amp, fade)
		var k := 1.0 / sqrt(a * a + (1.0 - a) * (1.0 - a))
		tv = (tv * a + ta * (1.0 - a)) * k
		sig = sqrt(a * s_u * s_u + (1.0 - a) * amp * amp)
	var chaos := _in_cloud_turb * _cin.x
	_last_sigma = sqrt(sig * sig + chaos * chaos)
	if chaos > 1.0e-3:
		var nc := wind.gust_unit(pos * _in_cloud_scale_k, time_s * 3.0, _advect, 0.0)
		v += nc * chaos
	return v + tv


## Опасность подветренной зоны 0..1 от ветра прогноза (нелинейно: слабый ветер — мягко).
func _lee_danger(u_ref: float) -> float:
	return smoothstep(_lee_danger_min, _lee_danger_full, u_ref)


## Подветренный поток: (добавка к горизонтали вдоль ветра, вертикаль), м/с. Нисходящий поток,
## рывки сверху (детерминированный шум, редкие сильные удары вниз) и ротор у склона — обратный
## поток у земли в глубине зоны.
## Пятно рывка 0..1: clamp((n − порог)/ширина) детерминированного шума (burst_*), переносится
## ветром u.
func _lee_burst_g(pos: Vector3, u: float) -> float:
	var nb := wind.gust_unit(pos * _lee_burst_k, time_s, u * _lee_burst_k, 0.0).x
	return clampf((nb - _lee_burst_thr) / _lee_burst_width, 0.0, 1.0)


## Ослабление ротора нагревом земли 0..1 (1 — нет нагрева). Поток тепла по погоде дня: w* из
## σ конвективной болтанки (σ ≈ 0,6·w*, weather/*.json), H = w*³·ρc_p/(g/θ0·z_i), z_i — кромка
## (нижняя граница — ZI_MIN поля); фактор = 1 − H/heat_kill_wm2 (AP-10: нагрев убирает пузырь).
func _lee_heat_factor() -> float:
	if _lee_heat_full <= 0.0:
		return 1.0
	var key := Vector2(_conv_amp, _cloudbase_agl)
	if key != _lee_heat_key:
		_lee_heat_key = key
		var ws := _conv_amp / maxf(_lee_heat_wstar_k, 0.05)
		var zi := maxf(_cloudbase_agl, WindField.ZI_MIN)
		var h := (
			pow(ws, 3.0) * WindField.RHO_CP / (WindField.G / WindField.THETA0 * zi)
		)
		_lee_heat_val = clampf(1.0 - h / _lee_heat_full, 0.0, 1.0)
	return _lee_heat_val


## Поток тепла дня, Вт/м² (по тем же w*, z_i; для тестов).
func lee_heat_wm2() -> float:
	var ws := _conv_amp / maxf(_lee_heat_wstar_k, 0.05)
	var zi := maxf(_cloudbase_agl, WindField.ZI_MIN)
	return pow(ws, 3.0) * WindField.RHO_CP / (WindField.G / WindField.THETA0 * zi)


func _lee_flow(
	pos: Vector3, agl: float, u: float, lee: float, danger: float, relief: float
) -> Vector2:
	var w := -lerpf(_lee_sink, _lee_danger_sink, danger) * u * lee
	var hard := lee * danger * _lee_heat_factor()
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


## Условия устойчивости профиля ветра (WindProfile, C2 v4) из погоды: (высота солнца часа, °;
## облачность 0..1). Час — WeatherModel.derive → _derived.sun_elev_deg (пресет без часа —
## clouds.sun_elevation_deg), облачность — прогноз (sky_params(sky).cover; пресет — ясно).
func _wind_conditions() -> Vector2:
	var dv: Dictionary = weather.get("_derived", {})
	var sun := float(dv.get("sun_elev_deg", float(cfg.clouds.sun_elevation_deg)))
	var cover := 0.0
	if dv.has("sky"):
		cover = float(WeatherModel.sky_params(String(dv.sky)).get("cover", 0.0))
	return Vector2(sun, cover)


## Погода сменилась (шаг хода дня, мягкое обновление): профиль ветра по новым условиям.
func _update_wind_conditions() -> void:
	var wc := _wind_conditions()
	if wc.x == wind.sun_elev_deg and wc.y == wind.cover:
		return
	wind.set_conditions(wc.x, wc.y)
	_advect = wind.speed_at(float(cfg.turbulence.advection_height_m))
	_update_wave_wind()


func _update_wave_wind() -> void:
	if wave != null:
		var u := wind.speed_at(float(cfg.wave.wind_reference_agl_m))
		wave.set_wind(u, Vector2(wind.dir.x, wind.dir.z))


## Средний ветер без пульсаций и вертикальных потоков (для колдуна на старте и т. п.), м/с.
## С полем воздуха — горизонталь и механическая вертикаль поля (тот же вес края, что в
## air_velocity_at), без подветренной эвристики.
func mean_wind_at(pos: Vector3) -> Vector3:
	var gs := ground.sample(pos.x, pos.z)
	var s := wind.speed_at_pos(maxf(pos.y - gs.x, 0.0), pos.y)
	if _air_on:
		var fw := air_field.sample(pos, gs.x)
		if fw.w > 0.0:
			var a := s * (1.0 - fw.w)
			return Vector3(fw.x + wind.dir.x * a, fw.y, fw.z + wind.dir.z * a)
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
	if bool(cfg.thermal_signs.enabled):
		var signs := ThermalSigns.new()
		signs.name = "ThermalSigns"
		add_child(signs)
		signs.setup(self)
