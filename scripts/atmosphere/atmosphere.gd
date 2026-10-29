# gdlint: disable=max-public-methods
class_name Atmosphere
extends Node3D
## Атмосфера: ветер с профилем и порывами, термики, фоновое опускание, склоновый подъём,
## подветренные зоны и роторы; рисует облака и птиц (дочерние ноды).
## Контракт — docs/guide/architecture.md, модель — docs/research/thermals.md,
## описание — docs/guide/atmosphere.md.
##
## Использование (фасад W2, docs/contracts/rust-wind.md):
##   atmo.configure(seed)                         # сид мира (< 0 — из configs/atmosphere.json)
##   atmo.load_place(AirPlaceData.from_terrain(terrain, utc_offset_h, month, day))
##   atmo.set_conditions({forecast: {…}, start_hour: 12.0, speed: 1.0, …})   # погода и ход дня
##   atmo.set_focuses(points, weights)            # вокруг кого генерировать термики (0 — игрок)
##   atmo.start_at(0.0)                           # асинхронно; ждать is_ready(), звать pump(бюджет)
##   atmo.advance_to(t)                           # раз в тик; sample_many / air_velocity_at — опрос
##
## Детерминизм (сеть, NET-00): состояние — чистая функция (настройки, погода, day, сид, time_s).
## Переходные входы (set_ground, set_day, set_wind, set_weather, step, focus_node) — внутри
## реализации gd, снаружи не зовутся (W10); их держат тесты внутренностей и файлы RW-3b/RW-3c.

signal weather_changed
## Погода мягко обновлена (update_weather: ход дня) — термики и облака не пересоздаются.
signal weather_updated
## Фасад W2: состояние воздуха сменилось (STATE_*).
signal state_changed(state: int)

# ---- Фасад W2 (docs/contracts/rust-wind.md): константы ----
const WIND_API_VERSION := 4
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
## Описания W6 (docs/contracts/rust-wind/descriptions.md): смещения и шаги.
const CORE_ID := 0
const CORE_FLAGS := 1
const CORE_X := 2
const CORE_Z := 3
const CORE_Y_SRC := 4
const CORE_TOP := 5
const CORE_W := 6
const CORE_RADIUS := 7
const CORE_LEAN_X := 8
const CORE_LEAN_Z := 9
const CORE_AGE := 10
const CORE_LIFE := 11
const CORE_STAGE := 12
const CORE_VIS_SEED := 13
const CORE_STORM := 14
const CORE_STRIDE := 15
const CLOUD_ID := 0
const CLOUD_CORE_ID := 1
const CLOUD_X := 2
const CLOUD_Z := 3
const CLOUD_BASE := 4
const CLOUD_TOP := 5
const CLOUD_RADIUS := 6
const CLOUD_GROWTH := 7
const CLOUD_DECAY := 8
const CLOUD_FLAGS := 9
const CLOUD_STRIDE := 10
const CREST_X := 0
const CREST_Z := 1
const CREST_ETA := 2
const CREST_CREST := 3
const CREST_STRIDE := 4
## Объекты-облака W6 v4 (cloud_objects): смещения полей и шаг.
const OBJ_ID := 0
const OBJ_FLAGS := 1
const OBJ_CX := 2
const OBJ_CZ := 3
const OBJ_BASE := 4
const OBJ_GROWTH := 5
const OBJ_DECAY := 6
const OBJ_ACTIVITY := 7
const OBJ_RX := 8
const OBJ_RZ := 9
const OBJ_DEPTH := 10
const OBJ_SPREAD := 11
const OBJ_VIS_SEED := 12
const OBJ_LIFE_T0 := 13
const OBJ_LIFE_T1 := 14
const OBJ_SRC_X := 15
const OBJ_SRC_Z := 16
const OBJ_DRIFT_VX := 17
const OBJ_DRIFT_VZ := 18
const OBJ_DRIFT_T0 := 19
const OBJ_STORM_T0 := 20
const OBJ_STORM_K := 21
const OBJ_STRIDE := 22
## wave_info (W6 v4): [enabled, wavelength_m].
const WAVE_INFO_ENABLED := 0
const WAVE_INFO_LENGTH := 1
## Ключи set_conditions (W5): общие, прогноз, эталон.
const COND_KEYS_COMMON: Array[String] = [
	"start_hour", "speed", "blend_s", "rebuild", "inflow_mode"
]
const COND_KEYS_FORECAST: Array[String] = ["forecast", "quantum_h", "wind_ref", "overrides"]
const COND_KEYS_PRESET: Array[String] = ["preset"]

## Журнал режима поля: последняя напечатанная строка (одна строка на смену режима, не на мир).
static var _air_log_last := ""

## Нода, вокруг которой живут термики и облака (обычно планер). Если не задана — активная камера.
@export var focus_node: Node3D
## Рисовать облака и птиц (в тестах без окна — выключено автоматически).
@export var visuals_enabled: bool = true

var _weather: Dictionary = {}
var cfg: Dictionary = {}
## Переходное (только gd, до RW-13): свой конфиг атмосферы вместо configs/atmosphere.json при
## сборке места (load_place) — превью и отпечаток мира (меньший радиус термиков и т. п.).
var cfg_override: Dictionary = {}

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
## Переживает configure() (как функции рельефа); поле подаёт крейт (снимок field_export, RW-7b)
## или set_air_field (тесты и инструменты).
var air_field: AirFieldSet = AirFieldSet.new()
## Масштаб 3 с полем (AM-08): коэффициенты, признак отрыва, σ и спектр порывов.
var field_turb: FieldTurbulence

## Время атмосферы, с. Термики — чистые функции времени и координат.
var time_s: float = 0.0
## Пульсации (турбулентность) — можно выключить для тестов.
var turbulence_enabled: bool = true
## Запись слагаемых для decompose (W7): только в decompose, в горячем пути выключена. Вклады уже
## со своими весами; индексы — T_*. Физику не меняет.
var _rec_on: bool = false
var _rec: PackedVector3Array = PackedVector3Array()
var _rec_sig: PackedFloat32Array = PackedFloat32Array()
const T_NAMES := ["field", "analytic", "ridge", "thermal", "storm", "wave", "cloud", "turb", "gust"]
const T_FIELD := 0
const T_ANALYTIC := 1
const T_RIDGE := 2
const T_THERMAL := 3
const T_STORM := 4
const T_WAVE := 5
const T_CLOUD := 6
const T_TURB := 7
const T_GUST := 8
## Сид мира (≥ 0) вместо atmosphere.json → seed — задать до configure/set_weather (сеть: сид зоны).
var seed_value: int = -1
## Ход дня (погода, солнце, источники — функции времени, AtmoDay); null — погода постоянна
## (или мягкие обновления set_weather(w, blend_s)).
var day: AtmoDay

var _focus: Vector3 = Vector3.ZERO
## Фасад W2 (реализация gd): место, запомненные команды, состояние. Переходное (до RW-13).
var _f_place: AirPlaceData
var _f_seed: int = -1
var _f_cond: Dictionary = {}
var _f_cond_set := false
var _f_sun := Vector3.ZERO
var _f_sun_set := false
var _f_statics := PackedFloat32Array()
var _f_static_mode := 0
## set_static_thermals звали — режим термиков задан командой; иначе остаётся режим погоды.
var _f_statics_set := false
var _f_focus_pts := PackedVector3Array()
var _f_focus_w := PackedFloat32Array()
var _f_focus_manual := false
var _f_state := STATE_EMPTY
## Стадия загрузки в pump: 0 — собрать воздух, 1 — ждать поле Пикара (место из рельефа игры),
## 2 — начать обновление термиков, 3 — порции обновления, 4 — готово.
var _f_stage := 0
## Кеш поля Пикара на диске (FL-К1): включает игра; тесты — нет. Каталог кеша крейту отдаётся
## при загрузке места (user://air_cache).
var air_cache_enabled := false
## Детерминированный режим крейта (W1 v2, air.deterministic): фоновые подачи поля — в игровой
## момент, заданный входом; снимок поля принимается синхронно. Тесты; задать до первой загрузки.
var deterministic := false
## Поле Пикара ведёт крейт (DpAir, W3), фасад подаёт его снимок в air_field (RW-7b).
var _dp: RefCounted
## Нет расширения DpAir — ветер без поля (W9); строка в журнале одна.
var _dp_missing := false
## Подпись последнего configure крейта (сид, режим): повторный configure — только при смене.
var _dp_cfg_sig := ""
## load_place отправлен крейту и место не выгружено.
var _dp_placed := false
## Номер подачи поля (field_version), уже принятый в air_field; −1 — ещё не принимали.
var _dp_ver := -1
## Режим поля, отправленный крейту (set_field_enabled): −1 — не слали, 0/1.
var _dp_mode_sent := -1
## Поле в air_field пришло из крейта (выгрузка места его снимает).
var _dp_fed := false
## Сборка уровней снимка в фоне (WorkerThreadPool): id задачи и её задание {head, data, fs}.
var _dp_task := -1
var _dp_job: Dictionary = {}
## Последняя фокусная точка, отправленная крейту.
var _dp_focus_sent := Vector3(INF, INF, INF)
## Состояние FAILED крейта уже в журнале.
var _dp_fail_logged := false
## Растр «phase_main» (debug_raster): по какой карте весов построен, он сам и номер версии.
var _f_phase_src: Variant = null
var _f_phase_cache: Dictionary = {}
var _f_phase_ver := 0
var _f_t_req := 0.0
var _f_progress := 0.0
var _f_err := ""
## Фасадные команды уже звали: start_at без места тогда — NO_PLACE, а не прежний синхронный путь.
var _f_used := false
var _configured: bool = false
var _refresh_acc: float = 1.0e9
var _refresh_interval: float = 0.5
## Во сколько раз реже обновлять список термиков и облака (только «Подождать час», Q-17: мир идёт
## ×60, а пересчёт — 25–45 мс — не должен падать на каждый шаг). 1 — как обычно.
var refresh_scale: float = 1.0
## > 0 — обновление термиков/облаков порциями по этому бюджету за шаг, мкс (PF-8); 0 — сразу.
var refresh_budget_us: int = 0
var _ra_pending := false
var _ra_stage := 0
var _ra_t := 0.0
var _ra_focus := Vector3.ZERO
var _ra_finish_us := 3000
## Первое обновление на экране загрузки (FL-5): 0 — нет, 1 — ждём источники поля, 2 — порции.
var _ld_stage := 0
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
var _day_w: Dictionary = {}  ## погода шага дня, выставленная в _weather
## Поле воздуха используется (air_model.enabled ≠ off и поле есть).
var _air_on: bool = false
var _air_mode: String = "auto"
## Режим задан командой set_air_mode — конфиг (air_model.enabled) его не перебивает при сборке.
var _air_mode_set := false
var _air_blend_s: float = 60.0

var _clouds: Node3D
var _birds: Node3D


func _ready() -> void:
	add_to_group("atmosphere")
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	if visuals_enabled and DisplayServer.get_name() != "headless":
		_create_visuals()
		refresh_budget_us = 3000


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
		_configure_legacy(Config.get_config("atmosphere"), w)


## Полная настройка (для тестов можно передать свои словари).
## Выход из места/игры: сборка источников в рабочем потоке читает рельеф — дождаться до его освобождения.
func _exit_tree() -> void:
	if field != null:
		field.air_wait(false)
	_dp_stop_task()
	if _dp != null and _dp_placed:
		_dp.unload_place()  # фоновая работа крейта прерывается, без зависания (W3)
		_dp_placed = false


## Фасад W2: configure(seed: int) -> int — сид до первого load_place (< 0 — из конфига).
## Переходное (до RW-13, не W2): configure(atmo_cfg: Dictionary, weather_cfg: Dictionary) — полная
## настройка своими словарями, без места фасада; его зовут тесты внутренностей и инструменты
## (tools/wind_fixtures, tools/terrain/bake_air.gd, исследования), игра и превью — нет.
func configure(a: Variant, weather_cfg: Variant = null) -> int:
	if a is Dictionary:
		_configure_legacy(a, weather_cfg)
		return OK
	if (a is int or a is float) and weather_cfg == null:
		if _f_place != null:
			return _f_fail(BAD_INPUT, "configure после load_place")
		_f_used = true
		_f_seed = int(a)
		seed_value = _f_seed
		return OK
	return _f_fail(BAD_INPUT, "configure: ожидается seed (int)")


func _configure_legacy(atmo_cfg: Dictionary, weather_cfg: Dictionary) -> void:
	cfg = atmo_cfg
	_ra_pending = false
	_weather = weather_cfg.duplicate(true)
	var seed_used := seed_value if seed_value >= 0 else int(cfg.seed)
	var old_ground := ground
	wind = WindModel.new()
	wind.setup(cfg.wind, cfg.turbulence, seed_used)
	var wc := _wind_conditions()
	wind.set_conditions(wc.x, wc.y)
	wind.set_wind(Units.kmh(float(_weather.wind_speed_kmh)), float(_weather.wind_from_deg))
	field_turb = FieldTurbulence.new()
	field_turb.setup(cfg.turbulence, cfg.lee, seed_used)
	ground = GroundField.new()
	ground.setup(cfg.ground, cfg.lee)
	if old_ground != null and old_ground.has_ground:
		ground.set_functions(old_ground.height_fn, old_ground.sun_fn)
		ground.surface_fn = old_ground.surface_fn
	ground.set_wind_dir(Vector2(wind.dir.x, wind.dir.z))
	field = ThermalField.new()
	field.setup(cfg.thermal, _weather, seed_used, ground, wind)
	field.day = day
	field.cirrus_block = float(cfg.cirrus.sun_block)
	field.cloud_width_per_ms_base = float(cfg.clouds.width_per_ms_m)
	var tb: Dictionary = cfg.turbulence
	_edge_factor_base = float(tb.edge_factor)
	_edge_width = float(tb.edge_width)
	field.set_turbulence_params(
		_edge_factor_base * float(_weather.get("thermal_edge_k", 1.0)), _edge_width
	)
	var cc: Dictionary = cfg.clouds
	field.cloud_linger_s = float(cc.linger_s)
	field.cloud_width_per_ms = (
		float(cc.width_per_ms_m) * float(_weather.get("cloud_size_factor", 1.0))
	)
	field.cloud_width_min = float(cc.width_min_m)
	field.cloud_width_max = float(cc.width_max_m)
	var el := deg_to_rad(float(cc.sun_elevation_deg))
	var az := deg_to_rad(float(cc.sun_azimuth_deg))
	field.sun_dir = Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	# Перистая пелена (VR-28) ослабляет прогрев земли — термики реже и слабее.
	field.insolation = get_insolation()
	cloud_phys = CloudPhysics.new()
	cloud_phys.setup(cfg.clouds, cfg.thermal, float(_weather.get("cloud_size_factor", 1.0)))
	field.cloud_phys = cloud_phys
	storm = StormField.new()
	storm.setup(cfg.storm, field.cloud_width_per_ms)
	wave = WaveField.new()
	wave.setup(cfg.wave, _weather, ground)
	_update_wave_wind()
	_refresh_interval = float(cfg.thermal.refresh_interval_s)
	_state_interval = float(cfg.thermal.state_update_interval_s)
	_cache_coefficients()
	_setup_air()
	_cloudbase_agl = float(_weather.cloudbase_agl_m)
	_update_cloudbase()
	for st: Dictionary in _weather.get("static_thermals", []):
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
		if _weather.has(k):
			nw[k] = _weather[k]
	_weather = nw
	field.set_weather_soft(_weather)
	field.cloud_width_per_ms = (
		float(cfg.clouds.width_per_ms_m) * float(_weather.get("cloud_size_factor", 1.0))
	)
	_update_wind_conditions()
	_target = {
		"bg_sink": float(_weather.background_sink_ms),
		"conv_amp": float(_weather.convective_turbulence_ms),
		"cloudbase_agl": float(_weather.cloudbase_agl_m),
		"insolation": get_insolation(),
		"edge": _edge_factor_base * float(_weather.get("thermal_edge_k", 1.0)),
		"mech": _mech_k_base * float(_weather.get("mech_turbulence_k", 1.0)),
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


## Ход дня: погода шага для рождения термиков и потребителей (_weather), плавные величины —
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
			if _weather.has(k):
				nw[k] = _weather[k]
		_weather = nw
		field.set_weather_soft(_weather)
		field.cloud_width_per_ms = (
			float(cfg.clouds.width_per_ms_m) * float(_weather.get("cloud_size_factor", 1.0))
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
		1.0
		- lerpf(WeatherModel.sun_block_cover(w0), WeatherModel.sun_block_cover(w1), f) * sb
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
func start_at(t: float) -> int:
	if _f_place != null:
		return _f_start_at_place(t)
	if _f_used and not (ground != null and ground.has_ground):
		if not _f_time_ok(t):
			return _f_fail(BAD_INPUT, "start_at: t < 0 или не конечно")
		return NO_PLACE
	if not _configured:
		set_weather(String(Config.value("atmosphere", "default_weather")))
	time_s = t
	_target.clear()
	field.reset_dynamic()
	refresh_now()
	return OK


## Обновить набор термиков, облака и сетку поиска на текущий time_s сразу (не ждать интервала).
func refresh_now() -> void:
	field.abort_refresh()
	_ra_pending = false
	_ld_stage = 0
	_refresh_begin(false)
	field.step_refresh(-1)
	_refresh_finish()


## Общее начало обновления (синхронного и порциями): фокус, интервалы, ход дня.
func _refresh_begin(chunked: bool) -> void:
	_refresh_prepare()
	field.begin_refresh(time_s, _focus, _refresh_dt(), chunked)


func _refresh_prepare() -> void:
	_update_focus()
	_refresh_slot = floori(time_s / _refresh_dt())
	_state_slot = floori(time_s / _state_interval)
	_refresh_acc = 0.0
	# Ход дня — на начало интервала (чистая функция времени, не шага).
	if _day_active():
		_apply_day(_state_slot * _state_interval)
	_ra_t = time_s
	_ra_focus = _focus


## Загрузка места (FL-5): поле воздуха подано — начать сборку источников термиков сейчас, в
## рабочем потоке (PF-К4), не дожидаясь первого обновления.
func prefetch_air_sources() -> void:
	_refresh_prepare()  # погода и солнце на время старта — входы сборки (сверяются потом)
	field.air_prefetch()


## Первое обновление на экране загрузки (FL-5) вместо refresh_now(): тот же итог на текущий
## time_s, но без замирания — сборку источников ждёт опросом, термики и сетку поиска считает
## порциями load_refresh_step(бюджет) и подменяет целиком по готовности (PF-8).
func begin_load_refresh() -> void:
	field.abort_refresh()
	_ra_pending = false
	_ra_stage = 0
	_refresh_prepare()
	_ld_stage = 1


## Порция первого обновления не дольше budget_us мкс (плюс неделимый конец: бури и физика
## облаков — десятки мс). true — готово (или не начиналось).
func load_refresh_step(budget_us: int) -> bool:
	if _ld_stage == 1:
		if field.air_prefetch():
			return false  # источники поля ещё собираются
		field.begin_refresh(_ra_t, _ra_focus, _refresh_dt(), true)
		_ld_stage = 2
	if _ld_stage == 2:
		if not field.refresh_pending():
			# поле само бросило порцию (подмена источников): начать заново
			field.begin_refresh(_ra_t, _ra_focus, _refresh_dt(), true)
		if not field.step_refresh(budget_us):
			return false
		_refresh_finish()
		_ld_stage = 0
	return true


func _refresh_finish() -> void:
	storm.refresh(field.thermals)
	cloud_phys.refresh(field.thermals, _ra_t, _ra_focus, float(cfg.thermal.physics_radius_m))


## Порциями (PF-8): refresh_budget_us > 0 — обновление растягивается на несколько шагов, по
## бюджету за шаг; набор термиков и сетка поиска подменяются целиком по готовности, итог для
## тех же (время, фокус) тот же, что у refresh_now().
func _refresh_pump() -> void:
	var t0 := Time.get_ticks_usec()
	if _ra_stage == 0:
		if not field.refresh_pending():
			# поле само бросило порцию (смена поля воздуха, статичный термик): начать заново
			_refresh_begin(true)
		if not field.step_refresh(refresh_budget_us):
			return
		_ra_stage = 1
		# Неделимый кусок (бури, физика облаков) — в шаге, где хватает бюджета.
		if Time.get_ticks_usec() - t0 + _ra_finish_us > refresh_budget_us:
			return
	var t1 := Time.get_ticks_usec()
	_refresh_finish()
	_ra_finish_us = Time.get_ticks_usec() - t1
	_ra_stage = 0
	_ra_pending = false


func _cache_coefficients() -> void:
	_bg_sink = float(_weather.background_sink_ms)
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
	_mech_k = _mech_k_base * float(_weather.get("mech_turbulence_k", 1.0))
	_mech_boost = float(t.mech_ground_boost)
	_mech_h = float(t.mech_ground_height_m)
	_vert_ratio = float(t.vertical_ratio)
	_turb_max = float(t.max_amplitude_ms)
	_conv_amp = float(_weather.convective_turbulence_ms)
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


## Поле воздуха по конфигу air_model: режим, край, ограничители.
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
	if not _air_mode_set:
		_air_mode = String(ac.get("enabled", "auto"))
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
## Крейту уходит set_field_enabled (W2 «Режим поля»): off — false, on — true, auto — не headless.
func set_air_mode(mode: String) -> void:
	_air_mode = mode
	_air_mode_set = true
	_update_air_mode()
	_dp_sync_mode()
	_dp_feed()


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
		reason = "нет поля"
		if _air_mode == "on":
			reason += "; требуется поле (enabled = on)"
	_air_on = reason == ""
	if not air_field.levels.is_empty() and field_turb != null:
		field_turb.z0 = air_field.levels[0].z0
	# Термики из поля (AM-07): источники, сила, потолок, снос и «между» — ThermalField.air.
	if field != null:
		field.air = air_field if _air_on else null
		if not _air_on:
			field.air_src = null  # источники поля без поля читать нечем (with_between)
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
		if _air_mode == "on" and not _air_on and _f_state == STATE_READY:
			push_warning(line)
		print(line)


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
## gain_per_km — рост ветра с высотой места (ClimateGrid.place, HH6 WR); NAN — из конфига.
func set_wind(
	speed_kmh: float, from_deg: float, ref_msl: float = NAN, gain_per_km: float = NAN
) -> void:
	wind.ref_msl = ref_msl
	wind.set_altitude_gain(gain_per_km)
	_weather.wind_speed_kmh = speed_kmh
	_weather.wind_from_deg = from_deg
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
	if not (is_finite(to_sun.x) and is_finite(to_sun.y) and is_finite(to_sun.z)):
		return
	if to_sun.length_squared() < 1.0e-12:
		return
	_f_sun = to_sun.normalized()
	_f_sun_set = true
	if field != null:
		field.sun_dir = _f_sun


## Нижняя кромка облаков над уровнем моря, м. По умолчанию — средняя высота земли + пресет.
func set_cloudbase_msl(msl: float) -> void:
	_cloudbase_override = true
	field.cloudbase_fixed = true
	field.set_cloudbase(msl)
	_refresh_acc = 1.0e9


func get_cloudbase_msl() -> float:
	return field.cloudbase_msl if field != null else 0.0


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
	_dp_tick()
	_refresh_acc += dt
	if _refresh_acc >= 1.0e8:
		refresh_now()
	elif _ra_pending:
		_refresh_pump()
	elif floori(time_s / _refresh_dt()) != _refresh_slot:
		if refresh_budget_us > 0:
			_ra_pending = true
			_ra_stage = 0
			_refresh_begin(true)
			_refresh_pump()
		else:
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
	if _f_focus_manual:
		return  # точки внимания заданы фасадом (set_focuses), узел и камера не нужны
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
	if ground == null or field == null:
		return Vector3.ZERO  # воздух не собран (EMPTY/ранняя загрузка): нули, W2
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
	if _rec_on:
		var w_th := fade * (_bg_sink * (1.0 - th.y) + th.x)
		_rec[T_ANALYTIC] = Vector3(wd.x * h, w - w_th - w_ridge, wd.z * h)
		_rec[T_THERMAL] = Vector3(0.0, w_th, 0.0)
		_rec[T_RIDGE] = Vector3(0.0, w_ridge, 0.0)
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
		if _rec_on:
			_rec[T_GUST] += nc * chaos
	if _rec_on:
		_rec_sig[T_GUST] = amp
	if amp < 1.0e-3:
		return v
	if _rec_on:
		_rec[T_GUST] += tv
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
		if _rec_on:
			_rec[T_STORM] = Vector3(sf.x, sf.y, sf.z)
		_storm_turb = sf.w
	# Подветренные волны и роторы.
	_rotor_turb = 0.0
	if wave.enabled:
		var wv := wave.sample(pos, agl, wind.speed_at(_wave_ref_agl))
		v.y += wv.x
		_rotor_turb = wv.y
		if _rec_on:
			_rec[T_WAVE] = Vector3(0.0, wv.x, 0.0)
	# В облаке: поток «выкидывает» к краю, упорядоченного подъёма почти нет (FR-14b).
	_cin = Vector3.ZERO
	if cloud_phys.cloud_count() > 0:
		_cin = cloud_phys.sample(pos)
		v += Vector3(_cin.y, 0.0, _cin.z) * _in_cloud_eject * _cin.x
		if _rec_on:
			_rec[T_CLOUD] = Vector3(_cin.y, 0.0, _cin.z) * _in_cloud_eject * _cin.x
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
	if _rec_on:
		var w_th := fade * (_bg_sink * (1.0 - th.y) + th.x)
		var w_rd := (1.0 - a) * w_ridge
		_rec[T_FIELD] = Vector3(fw.x, fw.y, fw.z)
		_rec[T_ANALYTIC] = Vector3(wd.x * h, w - w_th - fw.y - w_rd, wd.z * h)
		_rec[T_RIDGE] = Vector3(0.0, w_rd, 0.0)
		_rec[T_THERMAL] = Vector3(0.0, w_th, 0.0)
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
	if _rec_on:
		_rec[T_TURB] = tv
		_rec_sig[T_TURB] = s_u
	if a < 1.0:
		# полоса края: смесь с аналитикой (два независимых шума — дисперсия сохраняется)
		var rot := lerpf(_lee_turb, _lee_danger_turb, danger) * u * lee_a
		var amp := _analytic_amp(pos, gs, agl, u, th, rot, above_base)
		var ta := _analytic_turb(pos, agl, amp, fade)
		var k := 1.0 / sqrt(a * a + (1.0 - a) * (1.0 - a))
		if _rec_on:
			_rec[T_TURB] = tv * (a * k)
			_rec[T_GUST] = ta * ((1.0 - a) * k)
			_rec_sig[T_GUST] = amp
		tv = (tv * a + ta * (1.0 - a)) * k
		sig = sqrt(a * s_u * s_u + (1.0 - a) * amp * amp)
	var chaos := _in_cloud_turb * _cin.x
	_last_sigma = sqrt(sig * sig + chaos * chaos)
	if chaos > 1.0e-3:
		var nc := wind.gust_unit(pos * _in_cloud_scale_k, time_s * 3.0, _advect, 0.0)
		v += nc * chaos
		if _rec_on:
			_rec[T_GUST] += nc * chaos
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
	if ground == null or field == null:
		return 0.0
	var was := turbulence_enabled
	turbulence_enabled = true
	air_velocity_at(pos)
	turbulence_enabled = was
	return _last_sigma


## Плотность облака в точке 0..1 (0 — ясно): для «белой мглы» у камеры и оценки «в облаке».
func cloud_density_at(pos: Vector3) -> float:
	return cloud_phys.density_at(pos) if cloud_phys != null else 0.0


## Доля солнечного прогрева земли под перистой пеленой 0..1 (1 — ясно). Интегратор может
## ослабить по ней и солнце мира (VR-28).
func get_insolation() -> float:
	return 1.0 - WeatherModel.sun_block_cover(_weather) * float(cfg.cirrus.sun_block)


## Условия устойчивости профиля ветра (WindProfile, C2 v4) из погоды: (высота солнца часа, °;
## облачность 0..1). Час — WeatherModel.derive → _derived.sun_elev_deg (пресет без часа —
## clouds.sun_elevation_deg), облачность — прогноз (sky_params(sky).cover; пресет — ясно).
func _wind_conditions() -> Vector2:
	var dv: Dictionary = _weather.get("_derived", {})
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
	if ground == null or wind == null:
		return Vector3.ZERO
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
	if field == null:
		return out
	for th in field.near(pos, radius):
		out.append(th.to_dict())
	return out


# ================================================================ фасад W2
# Фасад rust-wind (docs/contracts/rust-wind.md, W2) поверх нынешнего расчёта: физика не меняется,
# команды переводятся в прежние входы (set_ground, set_day, set_wind, start_at, step). Игра и мир
# (RW-3a) ходят только через фасад; прежние входы остаются внутри реализации gd и у файлов
# RW-3b/RW-3c.
# Переходное (до RW-13, в W3/W4 нет): configure принимает и сид, и прежние словари (atmo_cfg,
# weather_cfg) — для тестов внутренностей и генератора фикстур; start_at без места (прежние тесты и
# инструменты) синхронный, при месте — асинхронный (pump).


func _f_fail(code: int, msg: String) -> int:
	_f_err = msg
	return code


## Текст последней ошибки; пусто — не было.
func last_error() -> String:
	return _f_err


func _f_set_state(s: int) -> void:
	if s == _f_state:
		return
	_f_state = s
	state_changed.emit(s)


## Состояние для опросов: с местом фасада — его состояние; без — READY, если воздух собран
## прежним путём (set_ground), иначе EMPTY.
func _f_state_eff() -> int:
	if _f_place != null:
		return _f_state
	if _configured and ground != null and ground.has_ground:
		return STATE_READY
	return STATE_EMPTY


func _f_queryable() -> bool:
	return _configured and ground != null and ground.has_ground and field != null


## Растры места один раз (W5). Возвращает сразу; подготовка — в pump (state = LOADING).
func load_place(place: AirPlaceData) -> int:
	if place == null:
		return _f_fail(BAD_INPUT, "load_place: место null")
	var why := place.validate()
	if why != "":
		return _f_fail(BAD_INPUT, "load_place: " + why)
	_f_used = true
	if _f_place != null:
		unload_place()
	if not (place.header.loc as Dictionary).has("climate"):
		place.fill_climate()  # W5 v3: климат центра места считает фасад
	_f_place = place
	_f_err = ""
	_f_stage = 0
	_f_t_req = 0.0
	_f_progress = 0.0
	_f_set_state(STATE_LOADING)
	return OK


## Сброс всего, что связано с местом: время, термики, фокусы, статические термики.
## Конфиги, сид, условия и солнце остаются.
func unload_place() -> void:
	if field != null:
		field.abort_refresh()
		field.air_wait(false)
	_ra_pending = false
	_ld_stage = 0
	if ground != null:
		ground.set_functions(Callable(), Callable())
		ground.surface_fn = Callable()
	if field != null:
		field.clear_static()
		field.reset_dynamic()
		field.day = null
	day = null
	time_s = 0.0
	_target.clear()
	_f_place = null
	_f_statics = PackedFloat32Array()
	_f_static_mode = 0
	_f_statics_set = false
	_f_focus_pts = PackedVector3Array()
	_f_focus_w = PackedFloat32Array()
	_f_focus_manual = false
	_focus = Vector3.ZERO
	_f_stage = 0
	_f_t_req = 0.0
	_f_progress = 0.0
	_dp_unload()
	_f_set_state(STATE_EMPTY)


## Погода и ход дня (W5): ровно один вид — прогноз или эталон. Не горячий путь.
func set_conditions(cond: Dictionary) -> int:
	var why := _f_check_conditions(cond)
	if why != "":
		return _f_fail(BAD_INPUT, "set_conditions: " + why)
	_f_used = true
	var prev := _f_cond
	_f_cond = cond.duplicate(true)
	_f_cond_set = true
	if _f_place == null or _f_stage == 0:
		return OK  # место не загружено или воздух ещё не собран — применится при сборке
	# Часы пошли иначе (ещё раз, смена скорости времени), остальное то же: только перепривязка
	# хода дня к текущему моменту — без смены погоды и без пересчёта термиков (как AtmoDay.rebase).
	if day != null and not bool(cond.get("rebuild", false)) and _f_same_but_clock(prev, _f_cond):
		day.rebase(time_s, float(cond.get("start_hour", 12.0)), float(cond.get("speed", 1.0)))
		_dp_conditions()
		return OK
	if bool(cond.get("rebuild", false)):
		_f_stage = 0
		_f_t_req = time_s
		_f_progress = 0.0
		_f_set_state(STATE_LOADING)
		return OK
	_f_apply_soft(_f_cond)
	_dp_conditions()
	return OK


func _f_same_but_clock(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty():
		return false
	var x := a.duplicate()
	var y := b.duplicate()
	for k in ["start_hour", "speed", "blend_s"]:
		x.erase(k)
		y.erase(k)
	return x == y


func _f_check_conditions(cond: Dictionary) -> String:
	var has_fc := cond.has("forecast")
	var has_pr := cond.has("preset")
	if has_fc == has_pr:
		return "нужен ровно один из ключей forecast / preset"
	var allowed: Array[String] = COND_KEYS_COMMON.duplicate()
	allowed.append_array(COND_KEYS_FORECAST if has_fc else COND_KEYS_PRESET)
	for k: Variant in cond:
		if not allowed.has(String(k)):
			return "посторонний ключ %s" % str(k)
	for k in ["start_hour", "speed", "quantum_h"]:
		if cond.has(k) and not (typeof(cond[k]) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(cond[k]))):
			return "%s: не число" % k
	if cond.has("speed") and float(cond.speed) <= 0.0:
		return "speed ≤ 0"
	if cond.has("quantum_h") and float(cond.quantum_h) <= 0.0:
		return "quantum_h ≤ 0"
	if cond.get("blend_s") != null and not (
		typeof(cond.blend_s) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(cond.blend_s))
	):
		return "blend_s: не число"
	if cond.has("inflow_mode") and not (String(cond.inflow_mode) in ["start", "inflow"]):
		return "inflow_mode: start | inflow"
	if has_fc:
		var fc: Variant = cond.forecast
		if not fc is Dictionary:
			return "forecast не словарь"
		for k in ["temperature_c", "wind_speed_kmh", "wind_from_deg"]:
			if not (fc as Dictionary).has(k) or not is_finite(float(fc[k])):
				return "forecast.%s отсутствует или не число" % k
		if not (fc as Dictionary).has("sky"):
			return "forecast.sky отсутствует"
		var wr: Variant = cond.get("wind_ref")
		if wr != null and not (wr is Dictionary and wr.has("ref_msl") and wr.has("gain_per_km")):
			return "wind_ref: {ref_msl, gain_per_km} или null"
		if cond.has("overrides") and not cond.overrides is Dictionary:
			return "overrides не словарь"
	else:
		var p: Variant = cond.preset
		if p is String:
			if not FileAccess.file_exists("res://configs/%s.json" % p):
				return "preset %s не найден" % p
		elif not p is Dictionary:
			return "preset: имя или словарь"
	return ""


## Место для погоды (WeatherModel.derive): дата, координаты, пояс, высоты долины и средней земли.
func _f_weather_ctx() -> Dictionary:
	var g: Dictionary = Config.get_config("atmosphere").ground
	var ctx := WeatherModel.ground_context(
		_f_height_callable(),
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(WeatherModel.config().valley_percentile)
	)
	var loc: Dictionary = _f_place.header.loc
	ctx.merge(
		{
			"month": int(loc.get("month", 7)),
			"day": int(loc.get("day", 15)),
			"lat": float(loc.get("center_lat", 52.0)),
			"lon": float(loc.get("center_lon", 0.0)),
			"utc_offset_h": float(loc.get("utc_offset_h", NAN)),
		}
	)
	return ctx


func _f_height_callable() -> Callable:
	var t: Node = _f_place.terrain
	if t != null and is_instance_valid(t):
		return Callable(t, "height_at")
	return Callable(_f_place, "height_at")


## Погода условий: {weather, day (AtmoDay | null), ref_msl, gain}. t0 — время атмосферы, которому
## соответствует start_hour (сборка — 0, мягкая смена — текущее).
func _f_resolve(cond: Dictionary, t0: float) -> Dictionary:
	var out := {"weather": {}, "day": null, "ref_msl": NAN, "gain": NAN}
	var sites: Array = _f_place.header.start_sites
	if not sites.is_empty():
		out.ref_msl = float((sites[0] as Dictionary).get("h_msl", NAN))
	if cond.has("preset"):
		var p: Variant = cond.preset
		out.weather = (Config.get_config(p) if p is String else p).duplicate(true)
	else:
		var fc: Dictionary = cond.forecast
		var ctx := _f_weather_ctx()
		var hour0 := float(cond.get("start_hour", 12.0))
		var peak := float(WeatherModel.derive(fc, ctx).thermal_spacing_m)
		var ov: Dictionary = cond.get("overrides", {})
		var derive_fn := func(h: float) -> Dictionary:
			var dw := WeatherModel.derive(fc, ctx, {}, h)
			dw.thermal_spacing_m = peak
			for k: Variant in ov:
				dw[k] = ov[k]
			dw.erase("static_thermals")
			return dw
		out.weather = derive_fn.call(hour0)
		var d := AtmoDay.new()
		d.start_hour = hour0
		d.t0 = t0
		d.speed = float(cond.get("speed", 1.0))
		var diurnal: Dictionary = WeatherModel.config().get("diurnal", {})
		d.quantum_h = float(cond.get("quantum_h", float(diurnal.get("update_s", 60.0)) / 3600.0))
		d.weather_fn = derive_fn
		var loc: Dictionary = _f_place.header.loc
		d.sun_fn = AtmoDay.sun_direction.bind(
			float(loc.get("center_lat", 52.0)),
			float(loc.get("center_lon", 0.0)),
			int(loc.get("month", 7)),
			int(loc.get("day", 15)),
			float(loc.get("utc_offset_h", NAN))
		)
		var terr: Node = _f_place.terrain
		if terr != null and is_instance_valid(terr) and terr.has_method("thermal_source_strength_for"):
			d.source_fn = _f_source_fn(terr, ctx, fc)
		out.day = d
		var wr: Variant = cond.get("wind_ref")
		if wr is Dictionary:
			out.ref_msl = float(wr.ref_msl)
			out.gain = float(wr.gain_per_km)
	(out.weather as Dictionary).erase("static_thermals")
	return out


## Сила источника термиков (x, z, час) для хода дня: солнце с запаздыванием класса поверхности,
## вода и ночь (Terrain.thermal_source_strength_water) — как делала игра (Game._make_day). Часть
## реализации gd: в крейте это «нагрев и surface_flux» (W5).
func _f_source_fn(terr: Node, ctx: Dictionary, fc: Dictionary) -> Callable:
	var heating := SurfaceHeating.new()
	heating.setup(
		float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h)
	)
	var sun := AtmoDay.sun_direction.bind(
		float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h)
	)
	var cache := {"h": NAN, "dirs": PackedVector3Array(), "sun": Vector3.UP, "water": {}, "night": {}}
	return func(x: float, z: float, h: float) -> float:
		if h != float(cache.h):
			cache.h = h
			cache.dirs = heating.directions(h)
			cache.sun = sun.call(h)
			cache.water = _f_water_heat(h, fc, ctx)
			cache.night = heating.built_night(h)
		return terr.thermal_source_strength_water(
			x, z, cache.dirs, cache.sun, cache.water, cache.night
		)


## Контекст воды для потока тепла (SH-5) в час места hour: T воды, T воздуха суточного хода по
## прогнозу, ветер прогноза на 10 м (как Game._water_heat_at).
func _f_water_heat(hour: float, fc: Dictionary, ctx: Dictionary) -> Dictionary:
	var wcfg: Dictionary = SurfaceHeat.config().water
	var z := float(ctx.get("valley_msl_m", 0.0))
	return {
		"t_water_c": SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), z, ctx, wcfg),
		"t_air_c":
		SurfaceHeat.air_temp_c(hour, float(fc.get("temperature_c", 20.0)), z, ctx, wcfg),
		"u_ms": float(fc.get("wind_speed_kmh", 0.0)) / 3.6,
		"z_m": z,
	}


## Собрать воздух места по запомненным условиям (стадия 0 загрузки): прежние configure,
## set_ground, set_day, статические термики, set_wind.
func _f_build() -> void:
	var cond := _f_cond if _f_cond_set else {"preset": String(Config.value("atmosphere", "default_weather"))}
	var r := _f_resolve(cond, 0.0)
	var w: Dictionary = r.weather
	seed_value = _f_seed
	day = null
	_configure_legacy(cfg_override if not cfg_override.is_empty() else Config.get_config("atmosphere"), w)
	var t: Node = _f_place.terrain
	if t != null and is_instance_valid(t):
		var src := (
			Callable(t, "thermal_source_strength_at")
			if t.has_method("thermal_source_strength_at")
			else Callable(t, "sun_exposure_at")
		)
		set_ground(Callable(t, "height_at"), src, Callable(t, "surface_at"))
	else:
		set_ground(
			Callable(_f_place, "height_at"),
			Callable(_f_place, "source_at"),
			Callable(_f_place, "surface_at")
		)
	if r.day != null:
		set_day(r.day)
	if _f_sun_set:
		field.sun_dir = _f_sun
	_f_apply_statics()
	set_wind(float(w.wind_speed_kmh), float(w.wind_from_deg), float(r.ref_msl), float(r.gain))
	_f_apply_focus()


## Мягкая смена погоды (W5): подмена за blend_s, без пересоздания поля.
func _f_apply_soft(cond: Dictionary) -> void:
	var r := _f_resolve(cond, time_s)
	var w: Dictionary = r.weather
	var blend: Variant = cond.get("blend_s")
	if blend == null:
		var dc: Dictionary = WeatherModel.config().get("diurnal", {})
		blend = float(dc.get("blend_s", 300.0)) / maxf(float(cond.get("speed", 1.0)), 1.0)
	set_wind(float(w.wind_speed_kmh), float(w.wind_from_deg), float(r.ref_msl), float(r.gain))
	if r.day != null:
		set_day(r.day)
	else:
		day = null
		field.day = null
		_update_weather(w, float(blend))


func _f_apply_statics() -> void:
	if field == null:
		return
	clear_static_thermals()
	if _f_statics_set:
		set_thermal_mode(["dynamic", "static", "both"][clampi(_f_static_mode, 0, 2)])
	for i in range(0, _f_statics.size() - 3, 4):
		add_static_thermal(_f_statics[i], _f_statics[i + 1], _f_statics[i + 2], _f_statics[i + 3])


func _f_apply_focus() -> void:
	if _f_focus_manual:
		_focus = _f_focus_pts[0] if _f_focus_pts.size() > 0 else Vector3(0.0, _f_origin_height(), 0.0)


func _f_origin_height() -> float:
	return _f_place.height_at(0.0, 0.0) if _f_place != null else 0.0


## Статические термики шага 4: [x_m, z_m, strength_ms, radius_m]; mode 0 dynamic, 1 static, 2 both.
func set_static_thermals(list: PackedFloat32Array, mode: int) -> int:
	if list.size() % 4 != 0 or mode < 0 or mode > 2:
		return _f_fail(BAD_INPUT, "set_static_thermals: длина кратна 4, mode 0..2")
	for i in range(0, list.size(), 4):
		for k in 4:
			if not is_finite(list[i + k]):
				return _f_fail(BAD_INPUT, "set_static_thermals: не число")
		if list[i + 3] <= 0.0:
			return _f_fail(BAD_INPUT, "set_static_thermals: radius ≤ 0")
	_f_used = true
	_f_statics = list
	_f_static_mode = mode
	_f_statics_set = true
	if _f_place != null and _f_stage > 0:
		_f_apply_statics()
	return OK


## Точки внимания (индекс 0 — игрок), вес > 0; размеры равны. Детализацию выбирает реализация;
## gd использует точку 0 как нынешний фокус (остальные запоминает).
func set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int:
	if points.size() != weights.size():
		return _f_fail(BAD_INPUT, "set_focuses: размеры points и weights различаются")
	for i in points.size():
		var p := points[i]
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return _f_fail(BAD_INPUT, "set_focuses: точка не конечна")
		if not (is_finite(weights[i]) and weights[i] > 0.0):
			return _f_fail(BAD_INPUT, "set_focuses: вес ≤ 0")
	_f_used = true
	_f_focus_pts = points
	_f_focus_w = weights
	_f_focus_manual = true
	_f_apply_focus()
	_dp_send_focus(true)
	return OK


func _f_time_ok(t: float) -> bool:
	return is_finite(t) and t >= 0.0


## Продвинуть воздух до t. t меньше текущего — BAD_INPUT; равно — OK; идёт загрузка — NOT_READY
## (t запоминается как момент старта).
func advance_to(t: float) -> int:
	if not _f_time_ok(t):
		return _f_fail(BAD_INPUT, "advance_to: t < 0 или не конечно")
	if _f_place == null:
		if not _f_queryable():
			return NO_PLACE
	elif _f_state == STATE_LOADING:
		if t < _f_t_req:
			return _f_fail(BAD_INPUT, "advance_to: t меньше текущего")
		_f_t_req = t
		return NOT_READY
	if t < time_s:
		return _f_fail(BAD_INPUT, "advance_to: t меньше текущего")
	if t == time_s:
		return OK
	step(t - time_s)
	time_s = t
	return OK


func _f_start_at_place(t: float) -> int:
	if not _f_time_ok(t):
		return _f_fail(BAD_INPUT, "start_at: t < 0 или не конечно")
	_f_t_req = t
	if _f_state == STATE_LOADING and _f_stage <= 1:
		if _f_stage == 1 and _dp_placed:
			_dp.start_at(t)  # крейт ещё готовит поле: пересчёт на момент t
		return NOT_READY  # воздух ещё не собран или ждёт поле: момент старта запомнен
	if _dp_placed:
		_dp.start_at(t)  # поле на момент t — фоном в крейте; ждём его на стадии 1
		_f_stage = 1
		_f_progress = 0.1
	else:
		_f_stage = 2
		_f_progress = 0.7
	_f_set_state(STATE_LOADING)
	return OK


## Время главного потока реализации: сборка воздуха, поле Пикара (ждёт) и порции первого
## обновления. Звать каждый кадр, пока state = LOADING.
func pump(budget_us: int) -> void:
	if _f_place == null or _f_state != STATE_LOADING:
		return
	if _f_stage == 0:
		_f_build()
		_f_progress = 0.1
		_f_stage = 1
		_dp_start()
	if _f_stage == 1:
		if _dp_loading():
			_f_progress = 0.1 + 0.6 * _dp.progress()
			return
		_f_stage = 2
		_f_progress = 0.7
	if _f_stage == 2:
		if not air_sources_ready(_f_place.terrain):
			return  # поля рельефа ещё считаются — источники термиков собирать рано (FL-17)
		time_s = _f_t_req
		_target.clear()
		field.reset_dynamic()
		if _dp_placed:
			prefetch_air_sources()  # поле подано — источники термиков собираются сразу (FL-5)
		begin_load_refresh()
		_f_stage = 3
		_f_progress = 0.75
	if _f_stage == 3:
		if load_refresh_step(maxi(budget_us, 1)):
			_f_stage = 4
			_f_progress = 1.0
			if _f_sun_set:
				field.sun_dir = _f_sun
			_f_set_state(STATE_READY)


## Место из рельефа игры без остановки кадров (FL-9): снимок поверхности считает задача пула, по
## кадрам ждём готовности. Те же растры, что у AirPlaceData.from_terrain (слой detail 25 м). null —
## рельеф без слоя detail или снимка поверхности. Переходное (gd): сборку растров заберёт RW-4/RW-6.
func place_from_terrain(
	p_terrain: Node, utc_offset_h: float, month: int, day: int
) -> AirPlaceData:
	var snap := AirPlaceData.terrain_snapshot(p_terrain, utc_offset_h, month, day)
	var sf: AirPlace.Surface = snap.surface
	if snap.detail == null or sf == null:
		return null
	while not sf.is_ready() and is_inside_tree():
		await get_tree().process_frame
	return AirPlaceData.from_snapshot(snap, p_terrain, month, day)


## Можно ли собирать источники термиков поля (FL-17): точка источника и его сила (pick_fn →
## Terrain.thermal_source_strength_at) читают влажность ложбин из полей рельефа, которые считаются
## в фоне и подменяются на главном потоке. Сборка, начатая до их готовности, видела бы то
## нейтральную влажность, то настоящую — число и точки источников зависели бы от скорости машины,
## а ведущий и клиенты сети получали бы разные источники при одном ключе мира.
static func air_sources_ready(t: Object) -> bool:
	return t == null or not t.has_method("relief_busy") or not bool(t.call("relief_busy"))


# ---------------------------------------------------------------- поле из крейта (RW-7b)
# Поле Пикара ведёт DpAir (W3): фасад отдаёт ему конфиги, место (с запечёнными полями), условия,
# фокусы и время, а снимок поля (field_export, W3 v4) подаёт в свой air_field для слагаемых на
# GDScript. AirRuntime и расчёт на видеокарте фасад не вызывает. Нет расширения — ветер без поля.

const FOCUS_STEP_M := 25.0


## Один DpAir на фасад; null — нет расширения (одна строка в журнале, W9).
func _dp_object() -> RefCounted:
	if _dp != null or _dp_missing:
		return _dp
	if not ClassDB.class_exists("DpAir"):
		_dp_missing = true
		_dp_log("dp_air: нет расширения, ветер без поля")
		return null
	_dp = ClassDB.instantiate("DpAir")
	return _dp


func _dp_log(line: String) -> void:
	if line != _air_log_last:
		_air_log_last = line
		print(line)


func _dp_deterministic() -> bool:
	return deterministic or bool(Config.get_config("atmosphere").get("air", {}).get("deterministic", false))


## Текст конфига для крейта «как есть»: единственный слой res://configs — файл целиком (числа не
## переписываются), пилотские слои поверх — слитый словарь.
func _dp_config_text(config_name: String) -> String:
	var texts := PackedStringArray()
	for dir in Config.search_dirs():
		var path: String = dir.path_join(config_name + ".json")
		if FileAccess.file_exists(path):
			texts.append(FileAccess.get_file_as_string(path))
	if texts.size() == 1:
		return texts[0]
	return JSON.stringify(Config.get_config(config_name))


func _dp_configs() -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in ["atmosphere", "weather_model", "surface_heat", "world"]:
		var text := _dp_config_text(n)
		if n == "atmosphere" and _dp_deterministic():
			var re := RegEx.create_from_string('"deterministic"\\s*:\\s*false')
			text = re.sub(text, '"deterministic": true')
		out.append(n)
		out.append(text)
	for n: String in Config.list_configs("weather"):
		out.append(n)
		out.append(_dp_config_text(n))
	return out


func _dp_seed() -> int:
	return _f_seed if _f_seed >= 0 else int(Config.get_config("atmosphere").get("seed", 0))


## Условия для крейта: запомненные (или погода по умолчанию), без rebuild (перестройка — загрузка).
func _dp_cond_json() -> String:
	var c: Dictionary = (
		_f_cond.duplicate(true)
		if _f_cond_set
		else {"preset": String(Config.value("atmosphere", "default_weather"))}
	)
	c["rebuild"] = false
	return JSON.stringify(c)


## Поле нужно крейту (W2 «Режим поля»): off — нет; on — да; auto — да, кроме headless. Расчёт
## нужен только для прогноза (эталон погоды — превью и тесты — без поля, как раньше).
func _dp_field_wanted() -> bool:
	if _air_mode == "off" or not (_f_cond_set and _f_cond.has("forecast")):
		return false
	return _air_mode == "on" or DisplayServer.get_name() != "headless"


func _dp_sync_mode() -> void:
	if _dp == null:
		return
	var want := 1 if _dp_field_wanted() else 0
	if want != _dp_mode_sent:
		_dp_mode_sent = want
		_dp.set_field_enabled(want == 1)


func _dp_fail(what: String) -> void:
	_dp_log("dp_air: %s: %s — ветер без поля" % [what, _dp.last_error()])
	_dp_placed = false


## Стадия 0 загрузки: место, условия и фокус — крейту; он готовит поле в фоне.
func _dp_start() -> void:
	var dp := _dp_object()
	_dp_stop_task()
	if dp == null:
		return
	if _dp_placed:
		dp.unload_place()
		_dp_placed = false
	var sig := "%d|%s" % [_dp_seed(), _dp_deterministic()]
	if sig != _dp_cfg_sig:
		if dp.configure(_dp_configs(), _dp_seed()) != 0:
			_dp_fail("configure")
			return
		_dp_cfg_sig = sig
	dp.set_cache_dir(ProjectSettings.globalize_path("user://air_cache") if air_cache_enabled else "")
	var place := _f_place
	if not place.header.has("model_hash"):
		place.fill_crate_inputs()
	dp.set_conditions(_dp_cond_json())
	_dp_mode_sent = -1
	_dp_sync_mode()
	_dp_send_focus(true)
	var code: int = dp.load_place(
		place.header_json(), place.heights, place.water, place.surface_cls, place.surface_moist
	)
	if code != 0:
		_dp_fail("load_place")
		return
	for b: Dictionary in place.baked:
		if dp.add_baked_field(b.header_json, b.data) != 0:
			_dp_log("dp_air: запечённое поле не принято: %s" % dp.last_error())
	if _f_t_req > 0.0:
		dp.start_at(_f_t_req)
	_dp_placed = true
	_dp_fail_logged = false
	_dp_ver = dp.field_version()  # подача пустого места не нужна: прежнее поле остаётся до новой


## Крейт готовит поле (LOADING) или принятый снимок ещё собирается в фоне. Здесь же — подача.
func _dp_loading() -> bool:
	if not _dp_placed:
		return false
	var st: int = _dp.state()
	if st == 1:
		return true
	_dp_feed()
	if st == 3 and not _dp_fail_logged:
		_dp_fail_logged = true
		_dp_log("dp_air: поле не готово: %s — ветер без поля" % _dp.call("status_reason"))
	return _dp_task >= 0


## Шаг игры: фокус, время и подача поля.
func _dp_tick() -> void:
	if not _dp_placed:
		return
	_dp_send_focus(false)
	if _dp.state() == 2 and time_s > _dp.time_s():
		_dp.advance_to(time_s)
	_dp_feed()


func _dp_send_focus(force: bool) -> void:
	if _dp == null:
		return
	if _f_focus_manual:
		if force:
			_dp.set_focuses(_f_focus_pts, _f_focus_w)  # точки игры — как есть, индекс 0 — игрок
		return
	if not force and _focus.distance_to(_dp_focus_sent) < FOCUS_STEP_M:
		return
	_dp_focus_sent = _focus
	_dp.set_focuses(PackedVector3Array([_focus]), PackedFloat32Array([1.0]))


## Условия сменились (мягко): крейту — новый json; поле и режим пересчитаются там.
func _dp_conditions() -> void:
	if not _dp_placed:
		return
	_dp.set_conditions(_dp_cond_json())
	_dp_sync_mode()
	_dp_feed()


## Принять новую подачу поля: сменился номер → снимок (field_export) → уровни → air_field.
## Детерминированный режим — сборка уровней в этом же вызове; иначе — в фоне, главный поток не ждёт.
func _dp_feed() -> void:
	if _dp == null or not _dp_placed:
		return
	if _dp_task >= 0:
		if not WorkerThreadPool.is_task_completed(_dp_task):
			return
		WorkerThreadPool.wait_for_task_completion(_dp_task)
		_dp_task = -1
		_dp_apply(_dp_job)
		_dp_job = {}
	var ver: int = _dp.field_version()
	if ver == _dp_ver:
		return
	var got: int = _dp.field_export()
	_dp_ver = got
	var head_text := String(_dp.field_export_header())
	if head_text == "":
		if _dp_fed:
			set_air_field(null, 0.0)  # поля нет (выключено, выгружено): заголовок пуст
			_dp_fed = false
		return
	var head: Variant = JSON.parse_string(head_text)
	if not head is Dictionary:
		push_warning("Atmosphere: заголовок снимка поля не разобран")
		return
	_dp_job = {"head": head, "data": _dp.field_export_data(), "fs": null}
	if _dp_deterministic():
		_dp_build(_dp_job)
		_dp_apply(_dp_job)
		_dp_job = {}
	else:
		_dp_task = WorkerThreadPool.add_task(_dp_build.bind(_dp_job), false, "Atmosphere.field")


func _dp_build(job: Dictionary) -> void:
	job["fs"] = AirBakedField.load_bytes(job.head, job.data)


func _dp_apply(job: Dictionary) -> void:
	var fs: AirFieldSet = job.fs
	if fs == null:
		push_warning("Atmosphere: снимок поля не собрался — поле остаётся прежним")
		return
	var head: Dictionary = job.head
	# подмена — за blend_s с момента blend_t0 (время крейта); сборка в фоне уже съела часть
	var blend := float(head.get("blend_s", 0.0))
	if blend > 0.0:
		blend = maxf(blend - maxf(time_s - float(head.get("blend_t0", time_s)), 0.0), 0.0)
	_dp_fed = true
	set_air_field(fs.levels, blend)


func _dp_stop_task() -> void:
	if _dp_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_dp_task)
		_dp_task = -1
	_dp_job = {}


## Выгрузка места: крейту — unload_place, поле крейта снимается.
func _dp_unload() -> void:
	_dp_stop_task()
	if _dp != null and _dp_placed:
		_dp.unload_place()
	_dp_placed = false
	_dp_ver = -1
	_dp_mode_sent = -1
	_dp_focus_sent = Vector3(INF, INF, INF)
	if _dp_fed and air_field != null:
		set_air_field(null, 0.0)
	_dp_fed = false


## {state, progress 0..1, time_s, reason, stage, field_on, iters} (W2 v3).
## stage — подпись этапа для экрана загрузки («» — этапа нет): пока крейт готовит поле Пикара —
## «Рассчитываем ветер…»; iters — итерации решателя в этом этапе (W3 v3, из DpAir.iters()).
func status() -> Dictionary:
	var s := _f_state_eff()
	var label := _f_stage_label() if s == STATE_LOADING else ""
	return {
		"state": s,
		"progress": 1.0 if s == STATE_READY else (_f_progress if s == STATE_LOADING else 0.0),
		"time_s": time_s,
		"reason": _f_err if s == STATE_FAILED else "",
		"stage": label,
		"field_on": is_air_field_on(),
		"iters": int(_dp.iters()) if label != "" else 0,
	}


## Подпись этапа для экрана загрузки по идентификатору этапа (ключи locale/ui.csv). Идентификаторы
## крейта — из doc-комментария Status.stage (W4 v4): lookup (поиск готового поля — быстро, этапа на
## экране нет), prepare, phases, coarse, solve_mech, solve_heat, windows — все «Рассчитываем ветер»;
## "solver" — то же (прежний идентификатор), "simple" — упрощённый ветер. Неизвестный идентификатор
## и "" — подписи нет.
static func stage_label(stage_id: String) -> String:
	match stage_id:
		"solver", "prepare", "phases", "coarse", "solve_mech", "solve_heat", "windows":
			return TranslationServer.translate("loading_wind")
		"simple":
			return TranslationServer.translate("loading_wind_simple")
	return ""


## Подпись этапа крейта (пока он готовит поле на загрузке места).
func _f_stage_label() -> String:
	if not _dp_placed or _f_stage != 1:
		return ""
	return stage_label(String(_dp.stage()))


func is_ready() -> bool:
	return _f_state_eff() == STATE_READY


func _f_finite3(p: Vector3) -> bool:
	return is_finite(p.x) and is_finite(p.y) and is_finite(p.z)


## Пачка точек → [vx, vy, vz, σ] на точку (длина 4N). SAMPLE_FULL — весь ветер; SAMPLE_MEAN — то же
## без неразрешённой болтанки и порывов (air_velocity_at при turbulence_enabled = false, как
## сняты эталоны RW-1); σ в обоих режимах — полная. Не конечная точка и пустое место — нули.
func sample_many(points: PackedVector3Array, mode: int = SAMPLE_FULL) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size() * 4)
	if not _f_queryable():
		return out
	var was := turbulence_enabled
	for i in points.size():
		var p := points[i]
		if not _f_finite3(p):
			continue
		turbulence_enabled = true
		var v := air_velocity_at(p)
		var sg := _last_sigma
		if mode == SAMPLE_MEAN:
			turbulence_enabled = false
			v = air_velocity_at(p)
		if not (_f_finite3(v) and is_finite(sg)):
			continue
		out[4 * i] = v.x
		out[4 * i + 1] = v.y
		out[4 * i + 2] = v.z
		out[4 * i + 3] = sg
	turbulence_enabled = was
	return out


## Одна точка: (vx, vy, vz, σ).
func sample(pos: Vector3, mode: int = SAMPLE_FULL) -> Vector4:
	var r := sample_many(PackedVector3Array([pos]), mode)
	return Vector4(r[0], r[1], r[2], r[3])


func cloud_density_many(points: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size())
	if not _f_queryable() or cloud_phys == null:
		return out
	for i in points.size():
		if _f_finite3(points[i]):
			var d := cloud_phys.density_at(points[i])
			out[i] = d if is_finite(d) else 0.0
	return out


func cloudbase_msl() -> float:
	return field.cloudbase_msl if _f_queryable() else 0.0


## Фоновый (синоптический) ветер по высоте MSL без рельефа и термиков: длина 2N [vx, vz].
func background_wind(heights_msl: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(heights_msl.size() * 2)
	if not _f_queryable():
		return out
	for i in heights_msl.size():
		var h := heights_msl[i]
		if not is_finite(h):
			continue
		var u := wind.speed_at_pos(maxf(h - _ground_ref, 0.0), h)
		out[2 * i] = wind.dir.x * u
		out[2 * i + 1] = wind.dir.z * u
	return out


## Выведенная погода (копия, только чтение): ключи пресета и _derived. Фасад W2 `weather()`.
## До сборки места фасада (EMPTY/LOADING) — пусто; прежняя настройка (configure со словарями,
## тесты внутренностей) отдаёт погоду сразу.
func weather() -> Dictionary:
	if not _configured or (_f_place != null and not _f_queryable()):
		return {}
	return _weather.duplicate(true)


## (на солнце x, y, z; прогрев 0..1) на текущий момент.
func sun_state() -> Vector4:
	if not _f_queryable():
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var s := field.sun_dir
	return Vector4(s.x, s.y, s.z, clampf(field.insolation, 0.0, 1.0))


# ---- W2 v4: объекты-облака, волны, порыв у поверхности (из крейта) ----


## Объекты-облака для рисования (W6 v4), шаг OBJ_STRIDE. Нет места или не READY — пусто.
func cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array:
	if not _dp_queryable():
		return PackedFloat32Array()
	return _dp.cloud_objects(center, radius, t)


## [enabled, wavelength_m] (W6 v4). Нет места или не READY — [0, 0].
func wave_info() -> PackedFloat32Array:
	if not _dp_queryable():
		return PackedFloat32Array([0.0, 0.0])
	return _dp.wave_info()


## Порыв на 10 м, м/с, длина min(len(xz), len(t)) (W6 v4). Не READY — нули. Пачками.
func surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array:
	if not _dp_queryable():
		var z := PackedFloat32Array()
		z.resize(mini(xz.size(), t.size()))
		return z
	return _dp.surface_gust_many(xz, t)


## Крейт держит место и готов отвечать (state READY).
func _dp_queryable() -> bool:
	return _dp != null and _dp_placed and _f_state_eff() == STATE_READY


# ---- описания W6 ----


## Ядра подъёма (шаг CORE_STRIDE) с осью ближе radius к center по горизонтали. Состояние — на
## последнее обновление термиков (до state_update_interval_s); время не сдвигается.
## Охват (W6 v3): только ядра, которые реализация держит в детализации, — активные термики
## ThermalField._active в радиусе физики (~6 км) вокруг фокуса; дальше ядра не отдаются. Поэтому
## набор зависит от фокуса (set_focuses); у крейта охват будет по его окнам. Слабые ядра
## (w < 1,5 м/с) отдаются, но подъём их на фоне может быть неразличим — фильтруйте по w.
func cores(center: Vector3, radius: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not _f_queryable():
		return out
	var c2 := Vector2(center.x, center.z)
	var t := time_s
	var ids: Array = field.thermals.keys()
	ids.sort()
	# Ядро — то, что реально действует на воздух: термики в радиусе физики вокруг фокуса
	# (ThermalField._active), живые (w > 0). Остальные в наборе — ещё не рождённые/доживающие.
	var active := {}
	for ath: AtmoThermal in field._active:
		active[ath.id] = true
	for id: int in ids:
		var th: AtmoThermal = field.thermals[id]
		if not active.has(id) or th.strength * th.env <= 0.0:
			continue
		var ax := th.axis_at(th.src.y)
		if c2.distance_to(ax) > radius:
			continue
		var age := t - th.t_birth
		var stage := 1.5
		if not th.is_static:
			if age < th.t_grow:
				stage = clampf(age / maxf(th.t_grow, 1.0e-6), 0.0, 1.0)
			elif age <= th.t_grow + th.t_mature:
				stage = 1.0 + (age - th.t_grow) / maxf(th.t_mature, 1.0e-6)
			else:
				stage = 2.0 + th.decay_progress(t)
		var flags := (1 if th.is_static else 0) | (2 if th.has_cloud else 0) | (4 if th.is_cb else 0)
		var storm_k := storm.intensity(th, t) if th.is_cb else 0.0
		var life := NAN if th.is_static else th.t_end() - th.t_birth
		out.append_array(
			PackedFloat32Array(
				[
					id & 0xFFFFFF, flags, ax.x, ax.y, th.src.y, th.top, th.strength * th.env,
					th.radius, th.lean.x, th.lean.y, age, life, stage, th.noise_seed, storm_k,
				]
			)
		)
	return out


## Облака (шаг CLOUD_STRIDE): облака поля и грозовые Cb-объекты (флаг 4).
func clouds(center: Vector3, radius: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not _f_queryable():
		return out
	var c2 := Vector2(center.x, center.z)
	var t := time_s
	var ids: Array = field.thermals.keys()
	ids.sort()
	var fld := cloud_phys.field
	var cid := 0
	if fld != null and fld.nx > 0:
		for cl: Dictionary in cloud_phys.visible_clouds(field.thermals, t, _focus):
			var cc: Vector2 = cl.center
			if c2.distance_to(cc) > radius:
				continue
			var s := fld.sample(Vector3(cc.x, fld.base_msl, cc.y))
			var core_id := -1
			for id: int in ids:
				var th2: AtmoThermal = field.thermals[id]
				if not th2.is_cb and th2.axis_at(fld.base_msl) == cc:
					core_id = id & 0xFFFFFF
					break
			cid += 1
			out.append_array(
				PackedFloat32Array(
					[cid, core_id, cc.x, cc.y, s.y, s.z, cl.radius, cl.growth, cl.decay, 0]
				)
			)
	for id: int in ids:
		var th3: AtmoThermal = field.thermals[id]
		if not th3.is_cb:
			continue
		var st := cloud_phys.model.stage(th3, t)
		if st.x < 0.0:
			continue
		var c3 := cloud_phys.model.center(th3, t)
		if c2.distance_to(c3) > radius:
			continue
		var sz := cloud_phys.model.size(th3, st)
		out.append_array(
			PackedFloat32Array(
				[
					(100000 + id) & 0xFFFFFF, id & 0xFFFFFF, c3.x, c3.y, th3.top, th3.top + sz.z,
					maxf(sz.x, sz.y), st.x, st.y, 4,
				]
			)
		)
	return out


## Растр облаков {version, nx, ny, dx, x0, z0, base_msl, time_s, cover, depth, stage, activity,
## bg_cover, bg_depth} в осях W1: строка растёт к +Z, x0, z0 — центр ячейки (0, 0). Нет поля —
## {version: 0}.
func cloud_raster() -> Dictionary:
	if not _f_queryable() or cloud_phys == null or cloud_phys.field == null:
		return {"version": 0}
	var f := cloud_phys.field
	if f.nx <= 0:
		return {"version": 0}
	var n := f.nx * f.ny
	var out := {
		"version": cloud_raster_version(),
		"nx": f.nx,
		"ny": f.ny,
		"dx": f.dx,
		"x0": f.x0 + 0.5 * f.dx,
		"z0": -(f.y0 + (f.ny - 0.5) * f.dx),
		"base_msl": f.base_msl,
		"time_s": f.time,
	}
	out.cover = _f_flip_rows(f.cover, f.nx, f.ny)
	out.depth = _f_flip_rows(f.depth, f.nx, f.ny)
	out.stage = _f_flip_rows(f.stage, f.nx, f.ny)
	out.activity = _f_flip_rows(f.activity, f.nx, f.ny)
	var bgc := PackedFloat32Array()
	bgc.resize(n)
	bgc.fill(f.bg_cover)
	var bgd := PackedFloat32Array()
	bgd.resize(n)
	bgd.fill(f.bg_depth)
	out.bg_cover = bgc
	out.bg_depth = bgd
	return out


## Поле облаков хранит строки к −Z (y = −Z); наружу — к +Z.
func _f_flip_rows(src: PackedFloat32Array, nx: int, ny: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(nx * ny)
	for j in ny:
		for i in nx:
			out[j * nx + i] = src[(ny - 1 - j) * nx + i]
	return out


## Растёт при обновлении поля облаков; 0 — поля нет.
func cloud_raster_version() -> int:
	if not _f_queryable() or cloud_phys == null or cloud_phys.field == null:
		return 0
	return 0 if cloud_phys.field.nx <= 0 else cloud_phys.field_version + 1


## Гребни волн [x, z, eta, crest] (шаг CREST_STRIDE); волн нет — пусто.
func wave_crests(
	center: Vector2, radius: float, min_eta: float, spacing: float = 5000.0
) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not _f_queryable() or wave == null or not wave.enabled or not wave.ground.has_ground:
		return out
	for cr: Dictionary in wave.crests(Vector3(center.x, 0.0, center.y), radius, min_eta, spacing):
		var p2: Vector2 = cr.pos
		out.append_array(PackedFloat32Array([p2.x, p2.y, cr.eta, cr.crest]))
	return out


# ---- разложение и отладка W7 ----


## Слагаемые ветра в точке: {names, vel, sigma, total} (W7). Имена — T_NAMES (набор постоянный,
## отсутствующее в точке — нули): field (поле Пикара: u, v, w_mech), analytic (профиль ветра,
## линия тени, подветренный поток и рывки, доля аналитики в полосе края), ridge (склоновый
## подъём), thermal (термики и фоновое опускание), storm, wave, cloud (выброс из облака),
## turb (болтанка поля: FieldTurbulence × GustSpectrum, рывки слоя смешения), gust (шум
## аналитики WindModel.gust_unit и бурление в облаке). Вклады со своими весами; total =
## sample(pos, SAMPLE_FULL) побитно, Σ vel = total.xyz (погрешность float32). sigma — справочно:
## turb — σ_u поля, gust — σ аналитики; total.w — как у sample.
func decompose(pos: Vector3) -> Dictionary:
	var names := PackedStringArray(T_NAMES)
	var n := names.size()
	var vel := PackedVector3Array()
	vel.resize(n)
	var sigma := PackedFloat32Array()
	sigma.resize(n)
	if not _f_queryable() or not _f_finite3(pos):
		return {"names": names, "vel": vel, "sigma": sigma, "total": Vector4()}
	var tot := sample(pos, SAMPLE_FULL)
	_rec = vel
	_rec_sig = sigma
	_rec_on = true
	var was := turbulence_enabled
	turbulence_enabled = true
	air_velocity_at(pos)
	turbulence_enabled = was
	_rec_on = false
	vel = _rec
	sigma = _rec_sig
	_rec = PackedVector3Array()
	_rec_sig = PackedFloat32Array()
	return {"names": names, "vel": vel, "sigma": sigma, "total": tot}


func debug_raster_names() -> PackedStringArray:
	var names := PackedStringArray()
	if _f_place != null:
		names.append("terrain_height")
	if cloud_raster_version() > 0:
		names.append_array(["cloud_cover", "cloud_depth", "cloud_activity"])
	var hf := _f_heat_field()
	if hf != null and hf.heat_flux().size() == hf.nx * hf.ny:
		names.append("heat_flux")
	if _f_phase_map().size() > 0:
		names.append("phase_main")
	return names


## Растр для оверлеев {nx, ny, dx, x0, z0, data} (оси W1: строка — к +Z; x0, z0 — положение данных
## [0] — центр ячейки/узел, как у поля реализации); неизвестное имя — {}.
## «heat_flux» — поток тепла H, Вт/м² (F7), грубейший уровень поля Пикара (тот же, что у
## источников термиков). «phase_main» — индекс главной фазы воздуха (карта фаз F4) клетки 400 м,
## сверх того: labels (имена фаз по индексам) и version (растёт при новой карте).
func debug_raster(raster_name: String) -> Dictionary:
	if raster_name == "terrain_height" and _f_place != null:
		var g: Dictionary = _f_place.header.grid
		return {
			"nx": int(g.width), "ny": int(g.height), "dx": float(g.spacing),
			"x0": float(g.origin_x), "z0": float(g.origin_z), "data": _f_place.heights,
		}
	if raster_name.begins_with("cloud_") and cloud_raster_version() > 0:
		var r := cloud_raster()
		var key := raster_name.substr(6)
		if r.has(key) and key in ["cover", "depth", "activity"]:
			return {
				"nx": r.nx, "ny": r.ny, "dx": r.dx, "x0": r.x0, "z0": r.z0, "data": r[key],
			}
	if raster_name == "heat_flux":
		var f := _f_heat_field()
		if f == null:
			return {}
		var heat := f.heat_flux()
		if heat.size() != f.nx * f.ny:
			return {}
		return {
			"nx": f.nx, "ny": f.ny, "dx": f.dx, "x0": f.x0, "z0": -(f.y0 + (f.ny - 1) * f.dx),
			"data": _f_flip_rows(heat, f.nx, f.ny),
		}
	if raster_name == "phase_main":
		return _f_phase_raster()
	return {}


## Грубейший уровень поля Пикара — из него берут H и источники термиков; нет поля — null.
func _f_heat_field() -> WindField:
	if not _air_on or air_field == null or air_field.levels.is_empty():
		return null
	return air_field.levels[air_field.levels.size() - 1]


## Карта фаз последнего расчёта поля; нет — {}. Поле считает крейт (RW-7b), карту фаз он пока
## не отдаёт — растр «phase_main» пуст (вернётся с debug_raster крейта, RW-9…12).
func _f_phase_map() -> Dictionary:
	return {}


func _f_phase_raster() -> Dictionary:
	var pm := _f_phase_map()
	if pm.is_empty():
		return {}
	var w: PackedFloat32Array = pm.weights
	if not is_same(_f_phase_src, w):
		_f_phase_src = w
		_f_phase_ver += 1
		_f_phase_cache = phase_main_raster(pm)
	var out := _f_phase_cache.duplicate()
	out.version = _f_phase_ver
	return out


## Растр «phase_main» из карты фаз AirRuntime.phase_map {nx, ny, dx, x0, y0, weights, phases}:
## индекс главной фазы клетки (наибольший вес), строки к +Z, x0/z0 — центр первой ячейки.
static func phase_main_raster(pm: Dictionary) -> Dictionary:
	var w: PackedFloat32Array = pm.weights
	var nx := int(pm.nx)
	var ny := int(pm.ny)
	var names: Array = pm.phases
	var kk := names.size()
	var data := PackedFloat32Array()
	data.resize(nx * ny)
	for j in ny:
		for i in nx:
			var q := j * nx + i
			var best := 0
			for k in range(1, kk):
				if w[k * nx * ny + q] > w[best * nx * ny + q]:
					best = k
			# строки наружу — к +Z (карта хранит к −Z)
			data[(ny - 1 - j) * nx + i] = float(best)
	return {
		"nx": nx, "ny": ny, "dx": float(pm.dx), "x0": float(pm.x0) + 0.5 * float(pm.dx),
		"z0": -(float(pm.y0) + (ny - 0.5) * float(pm.dx)), "data": data,
		"labels": PackedStringArray(names),
	}


# ================================================================ визуал


## Входы визуальных слоёв (не воздух, а рельеф места): высота земли и класс поверхности в точке.
## Слои получают их вызываемыми значениями при создании и не ходят в ground сами (W10).
# TODO(этап 3: RW-8/RW-11): в W2 нет высоты земли и класса поверхности для визуальных слоёв
# (облака, пыль, вихри); пока — вызываемые значения реализации gd, дальше — из места W5.
func _v_ground_height(x: float, z: float) -> float:
	return ground.height(x, z) if ground != null and ground.has_ground else NAN


## Класс поверхности (x, z); поверхности нет — 3 (пашня: сухо и пылит, как раньше без surface_fn).
# TODO(этап 3: RW-8/RW-11): см. выше — класс поверхности для слоёв в W2 отсутствует.
func _v_surface_class(x: float, z: float) -> int:
	if ground != null and ground.surface_fn.is_valid():
		return int(ground.surface_fn.call(x, z))
	return 3


func _create_visuals() -> void:
	if bool(cfg.clouds.enabled):
		var cloud_script: Script = load("res://scripts/atmosphere/cloud_layer.gd")
		if cloud_script != null:
			_clouds = cloud_script.new()
			_clouds.name = "Clouds"
			add_child(_clouds)
			_clouds.set("ground_fn", Callable(self, "_v_ground_height"))
			_clouds.set("surface_fn", Callable(self, "_v_surface_class"))
			_clouds.call("setup", self)
			_clouds.set("select_budget_us", 3000)
	var cirrus := CirrusLayer.new()
	cirrus.name = "Cirrus"
	add_child(cirrus)
	cirrus.setup(self)
	var dust := DustDevils.new()
	dust.name = "DustDevils"
	add_child(dust)
	dust.setup(self, Callable(self, "_v_ground_height"), Callable(self, "_v_surface_class"))
	if bool(cfg.gust_dust.enabled):
		# TODO(этап 3: RW-8/RW-11): wind — внутренняя модель ветра для шума порывов по слоту времени
		# (GustDustModel.gust_unit); в W2 такой функции нет — перейдёт в крейт с RW-8.
		var gdust := GustDust.new()
		gdust.name = "GustDust"
		add_child(gdust)
		gdust.setup(
			self, Callable(self, "_v_ground_height"), Callable(self, "_v_surface_class"), wind
		)
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
