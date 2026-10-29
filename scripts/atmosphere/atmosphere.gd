# gdlint: disable=max-public-methods,max-file-lines
class_name Atmosphere
extends Node3D
## Атмосфера: фасад W2 v4 (docs/contracts/rust-wind/facade.md) над DpAir (расширение dp_air).
## Весь ветер, термики, облака, погода и солнце считает крейт; здесь — настройка, проверки входа,
## разбор ответов крейта в формы W2 и визуальные слои (облака, птицы, пыль — дочерние ноды).
##
## Использование:
##   atmo.configure(seed)                         # сид мира (< 0 — из configs/atmosphere.json)
##   atmo.set_conditions({forecast: {…}, start_hour: 12.0, speed: 1.0, …})   # погода и ход дня
##   atmo.load_place(AirPlaceData.from_terrain(terrain, utc_offset_h, month, day))
##   atmo.set_focuses(points, weights)            # вокруг кого генерировать термики (0 — игрок)
##   atmo.start_at(0.0)                           # асинхронно; ждать is_ready()
##   atmo.advance_to(t)                           # раз в тик; sample_many — опрос
##
## Подготовка места у крейта начинается лениво — при start_at (или первом status/pump/advance_to
## после load_place): игра шлёт место, условия и статические термики до start_at, и крейт получает
## их все сразу, а не пересчитывает поле дважды.

signal weather_changed
## Погода мягко обновлена (ход дня, мягкая смена условий) — термики и облака не пересоздаются.
signal weather_updated
## Фасад W2: состояние воздуха сменилось (STATE_*).
signal state_changed(state: int)

# ---- Фасад W2 (docs/contracts/rust-wind/facade.md): константы ----
const WIND_API_VERSION := 5
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
const COND_KEYS_COMMON: Array[String] = ["start_hour", "speed", "blend_s", "rebuild", "inflow_mode"]
const COND_KEYS_FORECAST: Array[String] = ["forecast", "quantum_h", "wind_ref", "overrides"]
const COND_KEYS_PRESET: Array[String] = ["preset"]
## Шаг сдвига фокуса, после которого он уходит крейту, м.
const FOCUS_STEP_M := 25.0
const FIELD_SET_SCRIPT := "res://scripts/atmosphere/air_model/air_field_set.gd"
const FIELD_LOAD_SCRIPT := "res://scripts/atmosphere/air_model/air_baked_field.gd"

## Журнал режима поля: последняя напечатанная строка (одна строка на смену режима, не на мир).
static var _air_log_last := ""

## Нода, вокруг которой живут термики и облака (обычно планер). Если не задана — активная камера.
@export var focus_node: Node3D
## Рисовать облака и птиц (в тестах без окна — выключено автоматически).
@export var visuals_enabled: bool = true

## Конфиг атмосферы (configs/atmosphere.json): читают визуальные слои.
var cfg: Dictionary = {}
## Переходное (до RW-13): свой конфиг атмосферы вместо configs/atmosphere.json — превью и отпечаток
## мира. Уходит крейту текстом вместо файла.
var cfg_override: Dictionary = {}
## Время атмосферы, с (зеркало времени крейта).
var time_s: float = 0.0
## Сид мира (≥ 0) вместо atmosphere.json → seed — задать до configure (сеть: сид зоны).
var seed_value: int = -1
## Во сколько раз реже обновлять воздух на «Подождать час» (Q-17). Крейт ведёт воздух сам;
## поле оставлено, чтобы игра могла его ставить (удаляется в RW-13).
var refresh_scale: float = 1.0
## Кеш поля Пикара на диске (FL-К1): включает игра; тесты — нет. Каталог кеша крейту отдаётся
## при загрузке места (user://air_cache).
var air_cache_enabled := false
## Детерминированный режим крейта (W1 v2, air.deterministic): снимок поля принимается синхронно.
var deterministic := false
## Снимок поля Пикара для отладки и превью (AirFieldSet): подача включается первым обращением
## к полю (или want_air_field), горячий путь его не читает.
var air_field: Variant:
	get:
		want_air_field(true)
		return _air_field_object()

var _air_field: RefCounted
var _air_field_wanted := false
var _air_blend_s: float = 60.0
var _focus: Vector3 = Vector3.ZERO
## Место и запомненные команды фасада.
var _f_place: AirPlaceData
var _f_seed: int = -1
var _f_cond: Dictionary = {}
var _f_cond_set := false
var _f_sun := Vector3.ZERO
var _f_sun_set := false
var _f_statics := PackedFloat32Array()
var _f_static_mode := 0
var _f_statics_set := false
var _f_focus_pts := PackedVector3Array()
var _f_focus_w := PackedFloat32Array()
var _f_focus_manual := false
var _f_state := STATE_EMPTY
## Момент старта, запрошенный start_at / advance_to во время загрузки.
var _f_t_req := 0.0
var _f_err := ""
## Поле Пикара ведёт крейт (DpAir, W3). Нет расширения — состояние FAILED.
var _dp: RefCounted
var _dp_missing := false
var _dp_failed := false
## Подпись последнего configure крейта (сид, режим, конфиг): повторный configure — только при смене.
var _dp_cfg_sig := ""
## load_place отправлен крейту и место не выгружено.
var _dp_placed := false
## Номер подачи поля (field_version), уже принятый в air_field; −1 — ещё не принимали.
var _dp_ver := -1
## Поле в air_field пришло из крейта (выгрузка места его снимает).
var _dp_fed := false
## Сборка уровней снимка в фоне (WorkerThreadPool): id задачи и её задание {head, data, fs}.
var _dp_task := -1
var _dp_job: Dictionary = {}
var _dp_focus_sent := Vector3(INF, INF, INF)
## Версии погоды крейта (мягкая, перестройка), по которым слались сигналы; кэш разбора weather_json.
var _w_seen := Vector2i(-1, -1)
var _w_cache_ver := Vector2i(-1, -1)
var _w_cache: Dictionary = {}
## Сборка воздуха места началась — первое READY шлёт weather_changed.
var _rebuilt := false
var _clouds: Node3D
var _birds: Node3D


func _ready() -> void:
	add_to_group("atmosphere")
	if cfg.is_empty():
		cfg = cfg_override if not cfg_override.is_empty() else _conf("atmosphere")
	if visuals_enabled and DisplayServer.get_name() != "headless":
		_create_visuals()


func _physics_process(_delta: float) -> void:
	if _f_place == null:
		return
	_update_focus()
	_dp_send_focus(false)
	_dp_poll()


func _exit_tree() -> void:
	_dp_stop_task()
	if _dp != null and _dp_placed:
		_dp.unload_place()  # фоновая работа крейта прерывается, без зависания (W3)
		_dp_placed = false


# ================================================================ настройка


## Фасад W2: configure(seed: int) -> int — сид до первого load_place (< 0 — из конфига).
## Переходное (до RW-13, не W2): configure(atmo_cfg: Dictionary, weather_cfg: Dictionary) принимает
## конфиг для визуальных слоёв; погоду и физику в нём крейт не берёт (их задают set_conditions).
func configure(a: Variant, weather_cfg: Variant = null) -> int:
	if a is Dictionary:
		cfg = a
		return OK
	if (a is int or a is float) and weather_cfg == null:
		if _f_place != null:
			return _fail(BAD_INPUT, "configure после load_place")
		_f_seed = int(a)
		seed_value = _f_seed
		return OK
	return _fail(BAD_INPUT, "configure: ожидается seed (int)")


## Поле Пикара на месте считает крейт всегда, когда заданы условия с прогнозом (эталон погоды —
## превью и тесты — без прогноза и без поля); готово при READY.
func is_air_field_on() -> bool:
	return _f_state == STATE_READY and _dp_field_wanted()


## Подавать снимок поля крейта в air_field (отладка, превью): по умолчанию выключено.
func want_air_field(on: bool = true) -> void:
	if on == _air_field_wanted:
		return
	_air_field_wanted = on
	_dp_ver = -1
	if on:
		_dp_feed()


## Подать поле воздуха: WindField, массив уровней (от мелкого к грубому) или null — без поля.
## blend_s — время плавной подмены старого поля новым, с; < 0 — air_model.blend_s.
func set_air_field(new_field: Variant, blend_s: float = -1.0) -> void:
	_air_field_object().call("set_field", new_field, _air_blend_s if blend_s < 0.0 else blend_s)


## Направление на солнце (единичный вектор, мир): тени облаков на источниках термиков.
func set_sun_direction(to_sun: Vector3) -> void:
	if not _finite3(to_sun) or to_sun.length_squared() < 1.0e-12:
		return
	_f_sun = to_sun.normalized()
	_f_sun_set = true
	if _dp != null:
		_dp.set_sun_direction(_f_sun)


## Статические термики шага 4: [x_m, z_m, strength_ms, radius_m]; mode 0 dynamic, 1 static, 2 both.
func set_static_thermals(list: PackedFloat32Array, mode: int) -> int:
	if list.size() % 4 != 0 or mode < 0 or mode > 2:
		return _fail(BAD_INPUT, "set_static_thermals: длина кратна 4, mode 0..2")
	for i in range(0, list.size(), 4):
		for k in 4:
			if not is_finite(list[i + k]):
				return _fail(BAD_INPUT, "set_static_thermals: не число")
		if list[i + 3] <= 0.0:
			return _fail(BAD_INPUT, "set_static_thermals: radius ≤ 0")
	_f_statics = list
	_f_static_mode = mode
	_f_statics_set = true
	if _dp != null:
		_dp.set_static_thermals(list, mode)
	return OK


func set_focus(pos: Vector3) -> void:
	_focus = pos


func get_focus() -> Vector3:
	return _focus


## Точки внимания (индекс 0 — игрок), вес > 0; размеры равны. Детализацию выбирает крейт.
func set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int:
	if points.size() != weights.size():
		return _fail(BAD_INPUT, "set_focuses: размеры points и weights различаются")
	for i in points.size():
		if not _finite3(points[i]):
			return _fail(BAD_INPUT, "set_focuses: точка не конечна")
		if not (is_finite(weights[i]) and weights[i] > 0.0):
			return _fail(BAD_INPUT, "set_focuses: вес ≤ 0")
	_f_focus_pts = points
	_f_focus_w = weights
	_f_focus_manual = true
	_focus = points[0] if points.size() > 0 else Vector3(0.0, _origin_height(), 0.0)
	_dp_send_focus(true)
	return OK


# ================================================================ место, условия, время


## Растры места один раз (W5). Возвращает сразу; подготовка у крейта — асинхронно (LOADING).
func load_place(place: AirPlaceData) -> int:
	if place == null:
		return _fail(BAD_INPUT, "load_place: место null")
	var why := place.validate()
	if why != "":
		return _fail(BAD_INPUT, "load_place: " + why)
	if _f_place != null:
		unload_place()
	if not (place.header.loc as Dictionary).has("climate"):
		place.fill_climate()  # W5 v3: климат центра места считает фасад
	_f_place = place
	_f_err = ""
	_f_t_req = 0.0
	time_s = 0.0
	_rebuilt = true
	_set_state(STATE_LOADING)
	return OK


## Сброс всего, что связано с местом: время, фокусы, статические термики. Конфиги, сид, условия и
## солнце остаются.
func unload_place() -> void:
	_dp_unload()
	_f_place = null
	_f_statics = PackedFloat32Array()
	_f_static_mode = 0
	_f_statics_set = false
	_f_focus_pts = PackedVector3Array()
	_f_focus_w = PackedFloat32Array()
	_f_focus_manual = false
	_focus = Vector3.ZERO
	_f_t_req = 0.0
	time_s = 0.0
	_w_cache = {}
	_w_cache_ver = Vector2i(-1, -1)
	_w_seen = Vector2i(-1, -1)
	_rebuilt = false
	_set_state(STATE_EMPTY)


## Погода и ход дня (W5): ровно один вид — прогноз или эталон. Не горячий путь.
func set_conditions(cond: Dictionary) -> int:
	var why := _check_conditions(cond)
	if why != "":
		return _fail(BAD_INPUT, "set_conditions: " + why)
	_f_cond = cond.duplicate(true)
	_f_cond_set = true
	if not _dp_placed:
		return OK  # место не загружено или крейт ещё не начал — условия уйдут при начале
	if bool(cond.get("rebuild", false)):
		_f_t_req = time_s
		_rebuilt = true
		_dp_start()
		_set_state(STATE_LOADING)
		return OK
	_dp.set_conditions(_dp_cond_json())
	_dp_poll()
	return OK


## Начать сразу с момента t (время атмосферы/зоны, с). Асинхронно: LOADING до готовности.
func start_at(t: float) -> int:
	if not (is_finite(t) and t >= 0.0):
		return _fail(BAD_INPUT, "start_at: t < 0 или не конечно")
	if _f_place == null:
		return NO_PLACE
	_f_t_req = t
	time_s = t
	if _dp_placed:
		_dp.start_at(t)  # поле на момент t — фоном в крейте
	else:
		_dp_start()
	_dp_poll()
	return OK


## Продвинуть воздух до t. t меньше текущего — BAD_INPUT; равно — OK; идёт загрузка — NOT_READY
## (t запоминается как момент старта).
func advance_to(t: float) -> int:
	if not (is_finite(t) and t >= 0.0):
		return _fail(BAD_INPUT, "advance_to: t < 0 или не конечно")
	if _f_place == null:
		return NO_PLACE
	_dp_poll()
	if _f_state != STATE_READY:
		return _advance_pending(t)
	return _advance_ready(t)


## Реализации с главным потоком давали ему время здесь; у DpAir работа в потоках крейта — ничего
## не делает, кроме ленивого начала подготовки места.
func pump(_budget_us: int) -> void:
	_dp_poll()


## {state, progress 0..1, time_s, reason, stage, field_on, iters} (W2 v3).
## stage — подпись этапа для экрана загрузки («» — этапа нет); iters — итерации решателя в этапе.
func status() -> Dictionary:
	_dp_poll()
	var s := _f_state
	var label := _stage_text() if s == STATE_LOADING else ""
	var live := _dp_placed and s == STATE_READY
	return {
		"state": s,
		"progress": _progress(s),
		"time_s": float(_dp.time_s()) if live else maxf(_f_t_req, time_s),
		"reason": _f_err if s == STATE_FAILED else "",
		"stage": label,
		"field_on": is_air_field_on(),
		"iters": int(_dp.iters()) if label != "" else 0,
	}


func is_ready() -> bool:
	_dp_poll()
	return _f_state == STATE_READY


## Текст последней ошибки; пусто — не было.
func last_error() -> String:
	return _f_err


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


## Место из рельефа игры без остановки кадров (FL-9): снимок поверхности считает задача пула, по
## кадрам ждём готовности. null — рельеф без слоя detail или снимка поверхности.
func place_from_terrain(
	p_terrain: Node, utc_offset_h: float, month: int, day_of_month: int
) -> AirPlaceData:
	var snap := AirPlaceData.terrain_snapshot(p_terrain, utc_offset_h, month, day_of_month)
	var sf: AirPlace.Surface = snap.surface
	if snap.detail == null or sf == null:
		return null
	while not sf.is_ready() and is_inside_tree():
		await get_tree().process_frame
	return AirPlaceData.from_snapshot(snap, p_terrain, month, day_of_month)


## Можно ли собирать источники термиков поля (FL-17): поля рельефа считаются в фоне и подменяются
## на главном потоке; сборка, начатая до их готовности, видела бы то нейтральную влажность, то
## настоящую. Крейт сам ждёт готовности; метод оставлен для тестов рельефа.
static func air_sources_ready(t: Object) -> bool:
	return t == null or not t.has_method("relief_busy") or not bool(t.call("relief_busy"))


# ================================================================ опрос


## Пачка точек → [vx, vy, vz, σ] на точку (длина 4N). SAMPLE_FULL — весь ветер; SAMPLE_MEAN — то же
## без неразрешённой болтанки и порывов; σ в обоих режимах — полная. Не конечная точка и пустое
## место — нули.
func sample_many(points: PackedVector3Array, mode: int = SAMPLE_FULL) -> PackedFloat32Array:
	if not _dp_has():
		return _zeros(points.size() * 4)
	return _dp.sample_many(points, mode)


## Одна точка: (vx, vy, vz, σ).
func sample(pos: Vector3, mode: int = SAMPLE_FULL) -> Vector4:
	if not _dp_has():
		return Vector4()
	return _dp.sample(pos, mode)


## Скорость воздуха в точке, м/с, мир: sample(pos).xyz (на нём air_fn модели полёта).
func air_velocity_at(pos: Vector3) -> Vector3:
	var s := sample(pos)
	return Vector3(s.x, s.y, s.z)


## Средний ветер без пульсаций: sample(pos, SAMPLE_MEAN).xyz (с вертикалью).
func mean_wind_at(pos: Vector3) -> Vector3:
	var s := sample(pos, SAMPLE_MEAN)
	return Vector3(s.x, s.y, s.z)


## Интенсивность болтанки в точке — СКО пульсаций скорости воздуха, м/с: sample(pos).w.
func turbulence_intensity_at(pos: Vector3) -> float:
	return sample(pos).w


## Термики рядом — обёртка над cores (W6): словарь на ядро. Не показывать пилоту (FR-22).
func thermals_near(pos: Vector3, radius: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var c := cores(pos, radius)
	for j in range(0, c.size(), CORE_STRIDE):
		var fl := int(c[j + CORE_FLAGS])
		(
			out
			. append(
				{
					"x": c[j + CORE_X],
					"z": c[j + CORE_Z],
					"y_src": c[j + CORE_Y_SRC],
					"top": c[j + CORE_TOP],
					"w": c[j + CORE_W],
					"radius": c[j + CORE_RADIUS],
					"age_s": c[j + CORE_AGE],
					"life_s": c[j + CORE_LIFE],
					"stage": c[j + CORE_STAGE],
					"id": int(c[j + CORE_ID]),
					"static": (fl & 1) != 0,
					"has_cloud": (fl & 2) != 0,
					"is_cb": (fl & 4) != 0,
				}
			)
		)
	return out


## Плотность облака в точках 0..1 (0 — ясно).
func cloud_density_many(points: PackedVector3Array) -> PackedFloat32Array:
	if not _dp_has():
		return _zeros(points.size())
	return _dp.cloud_density_many(points)


## Плотность облака в точке 0..1: для «белой мглы» у камеры и оценки «в облаке».
func cloud_density_at(pos: Vector3) -> float:
	return cloud_density_many(PackedVector3Array([pos]))[0]


## Нижняя кромка облаков, м MSL.
func cloudbase_msl() -> float:
	return float(_dp.cloudbase_msl()) if _dp_has() else 0.0


func get_cloudbase_msl() -> float:
	return cloudbase_msl()


## Фоновый (синоптический) ветер по высоте MSL без рельефа и термиков: длина 2N [vx, vz].
func background_wind(heights_msl: PackedFloat32Array) -> PackedFloat32Array:
	if not _dp_has():
		return _zeros(heights_msl.size() * 2)
	return _dp.background_wind(heights_msl)


## Выведенная погода (копия, только чтение): ключи пресета и _derived. Разбор weather_json
## кэшируется по версиям крейта. Нет места — пусто.
func weather() -> Dictionary:
	if not _dp_has():
		return {}
	var v := Vector2i(int(_dp.weather_version()), int(_dp.weather_rebuild_version()))
	if v != _w_cache_ver:
		var parsed: Variant = JSON.parse_string(String(_dp.weather_json()))
		_w_cache = parsed if parsed is Dictionary else {}
		_w_cache_ver = v
	return _w_cache.duplicate(true)


## (на солнце x, y, z; прогрев 0..1) на текущий момент.
func sun_state() -> Vector4:
	return _dp.sun_state() if _dp_has() else Vector4()


## Доля солнечного прогрева земли под перистой пеленой 0..1 (1 — ясно).
func get_insolation() -> float:
	return clampf(sun_state().w, 0.0, 1.0) if _dp_has() else 1.0


# ---- описания W6 ----


## Ядра подъёма (шаг CORE_STRIDE) с осью ближе radius к center по горизонтали.
func cores(center: Vector3, radius: float) -> PackedFloat32Array:
	return _dp.cores(center, radius) if _dp_has() else PackedFloat32Array()


## Облака (шаг CLOUD_STRIDE): облака поля и грозовые Cb-объекты (флаг 4).
func clouds(center: Vector3, radius: float) -> PackedFloat32Array:
	return _dp.clouds(center, radius) if _dp_has() else PackedFloat32Array()


## Объекты-облака для рисования (W6 v4), шаг OBJ_STRIDE. t — момент атмосферы; вне окна —
## ближайшая граница. Нет места или не READY — пусто.
func cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array:
	if not _dp_ready():
		return PackedFloat32Array()
	return _dp.cloud_objects(center, radius, t)


## [enabled, wavelength_m] (W6 v4). Нет места или не READY — [0, 0].
func wave_info() -> PackedFloat32Array:
	if not _dp_ready():
		return PackedFloat32Array([0.0, 0.0])
	return _dp.wave_info()


## Порыв на 10 м, м/с, длина min(len(xz), len(t)) (W6 v4). Не READY — нули. Звать пачками.
func surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array:
	if not _dp_ready():
		return _zeros(mini(xz.size(), t.size()))
	return _dp.surface_gust_many(xz, t)


## Растр облаков {version, nx, ny, dx, x0, z0, base_msl, time_s, cover, depth, stage, activity,
## bg_cover, bg_depth} в осях W1: строка растёт к +Z. Нет поля — {version: 0}.
func cloud_raster() -> Dictionary:
	var head := _raster_head(true, "")
	if int(head.get("version", 0)) <= 0:
		return {"version": 0}
	var out: Dictionary = head.duplicate()
	out.erase("layers")
	for k: Variant in head.get("layers", []):
		out[String(k)] = _dp.cloud_raster_channel(String(k))
	return out


## Растёт при обновлении поля облаков; 0 — поля нет.
func cloud_raster_version() -> int:
	return int(_raster_head(true, "").get("version", 0))


## Гребни волн [x, z, eta, crest] (шаг CREST_STRIDE); волн нет — пусто.
func wave_crests(
	center: Vector2, radius: float, min_eta: float, spacing: float = 5000.0
) -> PackedFloat32Array:
	if not _dp_has():
		return PackedFloat32Array()
	return _dp.wave_crests(center, radius, min_eta, spacing)


# ---- разложение и отладка W7 ----


## Слагаемые ветра в точке: {names, vel, sigma, total} (W7), из крейта. total = sample(pos,
## SAMPLE_FULL) побитно; Σ vel = total.xyz (погрешность float32).
func decompose(pos: Vector3) -> Dictionary:
	var names := PackedStringArray()
	var flat := PackedFloat32Array()
	if _dp_has():
		names = _dp.decompose_names()
		if _finite3(pos):
			flat = _dp.decompose(pos)
	var n := names.size()
	var vel := PackedVector3Array()
	vel.resize(n)
	var sigma := PackedFloat32Array()
	sigma.resize(n)
	var total := Vector4()
	if flat.size() == 4 * (n + 1):
		for i in n:
			vel[i] = Vector3(flat[4 * i], flat[4 * i + 1], flat[4 * i + 2])
			sigma[i] = flat[4 * i + 3]
		total = Vector4(flat[4 * n], flat[4 * n + 1], flat[4 * n + 2], flat[4 * n + 3])
	return {"names": names, "vel": vel, "sigma": sigma, "total": total}


## Имена отладочных растров: рельеф места (из места фасада) и растры крейта (без «phase»).
func debug_raster_names() -> PackedStringArray:
	var names := PackedStringArray()
	if _f_place != null:
		names.append("terrain_height")
	if _dp_has():
		for n in _dp.debug_raster_names():
			if not String(n).begins_with("phase"):
				names.append(n)
	return names


## Растр для оверлеев {nx, ny, dx, x0, z0, data} (оси W1: строка — к +Z); неизвестное имя — {}.
func debug_raster(raster_name: String) -> Dictionary:
	if raster_name == "terrain_height" and _f_place != null:
		var g: Dictionary = _f_place.get("header").grid
		return {
			"nx": int(g.width),
			"ny": int(g.height),
			"dx": float(g.spacing),
			"x0": float(g.origin_x),
			"z0": float(g.origin_z),
			"data": _f_place.get("heights"),
		}
	if not _dp_has() or raster_name.begins_with("phase"):
		return {}
	var head := _raster_head(false, raster_name)
	if int(head.get("version", 0)) <= 0:
		return {}
	var out := head.duplicate()
	out.erase("layers")
	out.data = _dp.debug_raster_data(raster_name)
	return out


# ================================================================ внутреннее


func _fail(code: int, msg: String) -> int:
	_f_err = msg
	return code


func _finite3(p: Vector3) -> bool:
	return is_finite(p.x) and is_finite(p.y) and is_finite(p.z)


static func _zeros(n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	return out


func _set_state(s: int) -> void:
	if s == _f_state:
		return
	_f_state = s
	state_changed.emit(s)


## Загрузка: t запоминается как момент старта (не меньше прежнего), ответ NOT_READY.
func _advance_pending(t: float) -> int:
	if t < _f_t_req:
		return _fail(BAD_INPUT, "advance_to: t меньше текущего")
	_f_t_req = t
	return NOT_READY


func _advance_ready(t: float) -> int:
	var cur := float(_dp.time_s())
	if t < cur:
		return _fail(BAD_INPUT, "advance_to: t меньше текущего")
	if t == cur:
		return OK
	var code: int = _dp.advance_to(t)
	if code != OK:
		return _fail(code, String(_dp.last_error()))
	if _air_field != null:
		_air_field.call("advance", t - cur)
	_f_t_req = t
	time_s = t
	_dp_poll()
	return OK


## Крейт держит место (опросы идут к нему: и пустое место, и загрузка дают определённый ответ).
func _dp_has() -> bool:
	return _dp != null and _dp_placed


## Крейт держит место и готов (READY): объекты облаков, волны, порывы.
func _dp_ready() -> bool:
	return _dp_has() and _f_state == STATE_READY


func _progress(s: int) -> float:
	if s == STATE_READY:
		return 1.0
	return float(_dp.progress()) if s == STATE_LOADING and _dp_placed else 0.0


func _stage_text() -> String:
	return stage_label(String(_dp.stage())) if _dp_placed else ""


func _origin_height() -> float:
	return float(_f_place.call("height_at", 0.0, 0.0)) if _f_place != null else 0.0


## Заголовок растра крейта (json → словарь с nx, ny, dx, x0, z0, version, layers); пустой — {}.
func _raster_head(is_cloud: bool, raster_name: String) -> Dictionary:
	if not _dp_has():
		return {}
	var text: String
	if is_cloud:
		text = String(_dp.cloud_raster_header())
	else:
		text = String(_dp.debug_raster_header(raster_name))
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## Текущее состояние: нет места — EMPTY; крейт ещё не начал — LOADING; иначе его состояние.
func _compute_state() -> int:
	if _f_place == null:
		return STATE_EMPTY
	if _dp_failed:
		return STATE_FAILED
	if not _dp_placed:
		return STATE_LOADING
	var s := int(_dp.state())
	return STATE_LOADING if s == STATE_EMPTY else s


## Шаг опроса состояния: ленивый старт, смена состояния (сигналы), версии погоды, подача поля.
func _dp_poll() -> void:
	if _f_place == null:
		return
	if not _dp_placed and not _dp_failed:
		_dp_start()
	var s := _compute_state()
	if s == STATE_READY and _f_state != STATE_READY:
		_on_ready()
	_set_state(s)
	_poll_weather()
	_dp_feed()


## Первое READY после сборки: запомненный момент старта и weather_changed.
func _on_ready() -> void:
	if _f_t_req > float(_dp.time_s()) + 1.0e-6:
		_dp.advance_to(_f_t_req)
	time_s = float(_dp.time_s())
	if _rebuilt:
		_rebuilt = false
		_w_seen = Vector2i(int(_dp.weather_version()), int(_dp.weather_rebuild_version()))
		weather_changed.emit()


## Версии погоды выросли — сигналы: перестройка — weather_changed, мягкая — weather_updated.
func _poll_weather() -> void:
	if _f_state != STATE_READY or not _dp_placed:
		return
	var v := Vector2i(int(_dp.weather_version()), int(_dp.weather_rebuild_version()))
	if v == _w_seen:
		return
	var rebuilt := v.y != _w_seen.y
	_w_seen = v
	if rebuilt:
		weather_changed.emit()
	else:
		weather_updated.emit()


## Один DpAir на фасад; null — нет расширения (одна строка в журнале, W9).
func _dp_object() -> RefCounted:
	if _dp != null or _dp_missing:
		return _dp
	if not ClassDB.class_exists("DpAir"):
		_dp_missing = true
		_dp_log("dp_air: нет расширения — воздух недоступен")
		return null
	_dp = ClassDB.instantiate("DpAir")
	return _dp


func _dp_log(line: String) -> void:
	if line != _air_log_last:
		_air_log_last = line
		print(line)


func _dp_failed_with(what: String) -> void:
	_dp_failed = true
	_dp_placed = false
	_f_err = "dp_air: %s: %s" % [what, _dp.last_error()]
	_dp_log(_f_err)


## Конфиг по имени (слитый словарь Config).
func _conf(config_name: String) -> Dictionary:
	return Config.get_config(config_name)


func _dp_deterministic() -> bool:
	return deterministic or bool(_conf("atmosphere").get("air", {}).get("deterministic", false))


## Текст конфига для крейта «как есть»: единственный слой res://configs — файл целиком (числа не
## переписываются), пилотские слои поверх — слитый словарь.
func _dp_config_text(config_name: String) -> String:
	if config_name == "atmosphere" and not cfg_override.is_empty():
		return JSON.stringify(cfg_override)
	var texts := PackedStringArray()
	for dir: String in Config.search_dirs():
		var path: String = dir.path_join(config_name + ".json")
		if FileAccess.file_exists(path):
			texts.append(FileAccess.get_file_as_string(path))
	if texts.size() == 1:
		return texts[0]
	return JSON.stringify(_conf(config_name))


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
	return _f_seed if _f_seed >= 0 else int(_conf("atmosphere").get("seed", 0))


## Условия для крейта: запомненные (или погода по умолчанию), без rebuild (перестройка — загрузка).
func _dp_cond_json() -> String:
	var c: Dictionary = (
		_f_cond.duplicate(true)
		if _f_cond_set
		else {"preset": String(_conf("atmosphere").get("default_weather", ""))}
	)
	c["rebuild"] = false
	return JSON.stringify(c)


## Поле считается для прогноза; эталон погоды (пресет — превью и тесты) идёт без поля.
func _dp_field_wanted() -> bool:
	return _f_cond_set and _f_cond.has("forecast")


## Подготовка места у крейта: конфиги, условия, солнце, статические термики, фокус,
## место и запечённые поля. Повторный вызов (rebuild) — выгрузка и загрузка заново.
func _dp_start() -> void:
	var dp := _dp_object()
	_dp_stop_task()
	_dp_failed = false
	if dp == null:
		_dp_failed = true
		_f_err = "dp_air: нет расширения DpAir"
		return
	if _dp_placed:
		dp.unload_place()
		_dp_placed = false
	var sig := "%d|%s|%s" % [_dp_seed(), _dp_deterministic(), hash(cfg_override)]
	if sig != _dp_cfg_sig:
		if dp.configure(_dp_configs(), _dp_seed()) != 0:
			_dp_failed_with("configure")
			return
		_dp_cfg_sig = sig
	dp.set_cache_dir(
		ProjectSettings.globalize_path("user://air_cache") if air_cache_enabled else ""
	)
	var place := _f_place
	if not place.get("header").has("model_hash"):
		place.call("fill_crate_inputs")
	dp.set_conditions(_dp_cond_json())
	if _f_sun_set:
		dp.set_sun_direction(_f_sun)
	if _f_statics_set:
		dp.set_static_thermals(_f_statics, _f_static_mode)
	_dp_send_focus(true)
	var code: int = dp.load_place(
		place.call("header_json"),
		place.get("heights"),
		place.get("water"),
		place.get("surface_cls"),
		place.get("surface_moist")
	)
	if code != 0:
		_dp_failed_with("load_place")
		return
	for b: Dictionary in place.get("baked"):
		if dp.add_baked_field(b.header_json, b.data) != 0:
			_dp_log("dp_air: запечённое поле не принято: %s" % dp.last_error())
	if _f_t_req > 0.0:
		dp.start_at(_f_t_req)
	_dp_placed = true
	_dp_ver = -1
	_dp_fed = false


func _update_focus() -> void:
	if _f_focus_manual:
		return  # точки внимания заданы фасадом (set_focuses), узел и камера не нужны
	if focus_node != null and is_instance_valid(focus_node) and focus_node.is_inside_tree():
		_focus = focus_node.global_position
	elif is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			_focus = cam.global_position


func _dp_send_focus(force: bool) -> void:
	if _dp == null or (not force and not _dp_placed):
		return
	if _f_focus_manual:
		if force:
			_dp.set_focuses(_f_focus_pts, _f_focus_w)  # точки игры — как есть, индекс 0 — игрок
		return
	if not force and _focus.distance_to(_dp_focus_sent) < FOCUS_STEP_M:
		return
	_dp_focus_sent = _focus
	_dp.set_focuses(PackedVector3Array([_focus]), PackedFloat32Array([1.0]))


## Выгрузка места: крейту — unload_place, поле крейта снимается.
func _dp_unload() -> void:
	_dp_stop_task()
	if _dp != null and _dp_placed:
		_dp.unload_place()
	_dp_placed = false
	_dp_failed = false
	_dp_ver = -1
	_dp_focus_sent = Vector3(INF, INF, INF)
	if _dp_fed and _air_field != null:
		set_air_field(null, 0.0)
	_dp_fed = false


# ---------------------------------------------------------------- снимок поля для отладки


func _air_field_object() -> RefCounted:
	if _air_field == null:
		var script: GDScript = load(FIELD_SET_SCRIPT)
		_air_field = script.new()
	return _air_field


## Принять новую подачу поля: сменился номер → снимок (field_export) → уровни → air_field. Только
## по запросу потребителя air_field. Детерминированный режим — сборка уровней в этом же вызове;
## иначе — в фоне, главный поток не ждёт.
func _dp_feed() -> void:
	if not _air_field_wanted or _dp == null or not _dp_placed:
		return
	if _dp_task >= 0:
		if not WorkerThreadPool.is_task_completed(_dp_task):
			return
		WorkerThreadPool.wait_for_task_completion(_dp_task)
		_dp_task = -1
		_dp_apply(_dp_job)
		_dp_job = {}
	if int(_dp.field_version()) == _dp_ver:
		return
	_dp_ver = _dp.field_export()
	var head_text := String(_dp.field_export_header())
	var head: Variant = JSON.parse_string(head_text) if head_text != "" else null
	if not head is Dictionary:
		if _dp_fed:
			set_air_field(null, 0.0)  # поля нет (выключено, выгружено): заголовок пуст
			_dp_fed = false
		return
	_dp_job = {"head": head, "data": _dp.field_export_data(), "fs": null}
	if _dp_deterministic():
		_dp_build(_dp_job)
		_dp_apply(_dp_job)
		_dp_job = {}
	else:
		_dp_task = WorkerThreadPool.add_task(_dp_build.bind(_dp_job), false, "Atmosphere.field")


func _dp_build(job: Dictionary) -> void:
	var baked: GDScript = load(FIELD_LOAD_SCRIPT)
	job["fs"] = baked.call("load_bytes", job.head, job.data)


func _dp_apply(job: Dictionary) -> void:
	var fs: Variant = job.fs
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


# ---------------------------------------------------------------- проверка условий (W5)


func _check_conditions(cond: Dictionary) -> String:
	var has_fc := cond.has("forecast")
	if has_fc == cond.has("preset"):
		return "нужен ровно один из ключей forecast / preset"
	var allowed: Array[String] = COND_KEYS_COMMON.duplicate()
	allowed.append_array(COND_KEYS_FORECAST if has_fc else COND_KEYS_PRESET)
	for k: Variant in cond:
		if not allowed.has(String(k)):
			return "посторонний ключ %s" % str(k)
	var why := _check_numbers(cond)
	if why != "":
		return why
	return _check_forecast(cond) if has_fc else _check_preset(cond.preset)


func _is_num(v: Variant) -> bool:
	return typeof(v) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(v))


func _check_numbers(cond: Dictionary) -> String:
	for k in ["start_hour", "speed", "quantum_h"]:
		if cond.has(k) and not _is_num(cond[k]):
			return "%s: не число" % k
	if cond.has("speed") and float(cond.speed) <= 0.0:
		return "speed ≤ 0"
	if cond.has("quantum_h") and float(cond.quantum_h) <= 0.0:
		return "quantum_h ≤ 0"
	if cond.get("blend_s") != null and not _is_num(cond.blend_s):
		return "blend_s: не число"
	if cond.has("inflow_mode") and not (String(cond.inflow_mode) in ["start", "inflow"]):
		return "inflow_mode: start | inflow"
	return ""


func _check_forecast(cond: Dictionary) -> String:
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
	return ""


func _check_preset(p: Variant) -> String:
	if p is String:
		if not FileAccess.file_exists("res://configs/%s.json" % p):
			return "preset %s не найден" % p
	elif not p is Dictionary:
		return "preset: имя или словарь"
	return ""


# ================================================================ визуал


## Высота земли (x, z) для визуальных слоёв — из рельефа игры или растров места; нет места — NAN.
func _v_ground_height(x: float, z: float) -> float:
	if _f_place == null:
		return NAN
	var t: Variant = _f_place.get("terrain")
	if t != null and is_instance_valid(t):
		return float(t.height_at(x, z))
	return float(_f_place.call("height_at", x, z))


## Класс поверхности (x, z); поверхности нет — 3 (пашня: сухо и пылит).
func _v_surface_class(x: float, z: float) -> int:
	if _f_place == null:
		return 3
	var t: Variant = _f_place.get("terrain")
	if t != null and is_instance_valid(t):
		return int(t.surface_at(x, z))
	return int(_f_place.call("surface_at", x, z))


## Дочерняя нода слоя по пути скрипта (классы слоёв тянут Config — через load, не по имени).
func _spawn(path: String, node_name: String) -> Node:
	var script: Script = load(path)
	if script == null:
		return null
	var n: Node = script.new()
	n.name = node_name
	add_child(n)
	return n


func _create_visuals() -> void:
	var gh := Callable(self, "_v_ground_height")
	var sc := Callable(self, "_v_surface_class")
	if bool(cfg.clouds.enabled):
		_clouds = _spawn("res://scripts/atmosphere/cloud_layer.gd", "Clouds") as Node3D
		if _clouds != null:
			_clouds.set("ground_fn", gh)
			_clouds.set("surface_fn", sc)
			_clouds.call("setup", self)
			_clouds.set("select_budget_us", 3000)
	_spawn("res://scripts/atmosphere/cirrus_layer.gd", "Cirrus").call("setup", self)
	_spawn("res://scripts/atmosphere/dust_devils.gd", "DustDevils").call("setup", self, gh, sc)
	if bool(cfg.gust_dust.enabled):
		_spawn("res://scripts/atmosphere/gust_dust.gd", "GustDust").call("setup", self, gh, sc)
	if bool(cfg.birds.enabled):
		_birds = _spawn("res://scripts/atmosphere/bird_flock.gd", "Birds") as Node3D
		if _birds != null:
			_birds.call("setup", self)
	if bool(cfg.thermal_signs.enabled):
		_spawn("res://scripts/atmosphere/thermal_signs.gd", "ThermalSigns").call("setup", self)
