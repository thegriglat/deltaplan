class_name AirRuntime
extends Node
## Жизненный цикл среднего поля (масштаб 1) в игре (AM-06Б, контракт C9): по месту, часу, ветру
## и погоде — вход решателя (AirPlace.domain_case, область 400 м по всему месту; в рабочем
## потоке), расчёт на GPU (AirPicardJob, mech = true), сборка WindField (field_async, рабочий
## поток) и подача в атмосферу (set_air_field). Хранит state() для тёплого старта следующего
## пересчёта. docs/air_model.md → «Загрузка и пересчёт поля».
##
##   rt.setup(atmo, {detail = layer, water = img, loc = {...}}, conditions_fn)
##   await rt.load_field()        # экран загрузки: порции poll_slice, доля — progress_changed
##   rt.recompute_enabled = true  # полёт: пересчёт каждые recompute_game_min и при смене условий
##
## Опрос решателя — сам, в _process (RD — только главный поток): при загрузке poll_slice(40 мс),
## в полёте poll() порциями ≤ 25 мс. Ошибка/нет GPU/таймаут: при загрузке — аналитика и строка
## «air_model: analytic (<причина>)», в полёте — остаётся прежнее поле, следующая попытка — на
## следующем сроке. Очереди нет: пересчёт, не успевший до следующего срока, по окончании сразу
## сменяется новым — на последний срок.

## Поле подано в атмосферу. info: {hour, u10, wdir, t_max, sky, reason, wall_s, gpu_s, iters,
## warm, loading}.
signal field_applied(info: Dictionary)
## Расчёт не удался: при загрузке — аналитика, в полёте — прежнее поле.
signal fallback(reason: String)
## Доля расчёта 0..1 (экран загрузки).
signal progress_changed(fraction: float)

enum Stage { IDLE, PREP, SOLVE, BUILD }

## Клетка области, м (один уровень; окна 100/50 м вокруг пилота — AM-04).
const DX := 400.0
## Экран загрузки: работа решателя за кадр, мс главного потока.
const LOAD_SLICE_MS := 40.0
## Полёт: бюджет GPU-порции, мс (кадр не ждёт: poll() раз в кадр).
const FLIGHT_CHUNK_MS := 25.0
## Смена условий, после которой пересчёт — внеочередной (ветер, м/с и °; погода — t_max, °C).
const WIND_TOL_MS := 0.05
const DIR_TOL_DEG := 1.0
const TMAX_TOL_C := 0.25
const CMD_FIELD := "поле из файла (--air-field)"

## Атмосфера: set_air_field(поле, blend_s) (Atmosphere или заглушка с тем же методом).
var atmosphere: Object
## Условия расчёта: () -> {hour, u10 (м/с на 10 м), wdir (откуда, °), t_max (°C, NAN — обычный),
## sky}. Game — по часам неба, ветру атмосферы и прогнозу пилота.
var conditions_fn: Callable
## Пересчёт в полёте (Game включает после загрузки).
var recompute_enabled := false
## Тёплый старт пересчёта от state() текущего поля.
var warm_start := true
## Последняя ошибка / причина аналитики ("" — нет).
var last_error := ""
## Итог последнего расчёта (как info field_applied: + iters, gpu_s, wall_s, start_ms — запуск
## задачи на главном потоке, main_max_ms — наибольшая доля кадра, poll_max_ms) — для замеров.
var last_info := {}
## Число поданных полей и неудач за жизнь узла (замеры, тесты).
var applied_count := 0
var failed_count := 0

var _place := {}
var _place_key := ""
var _cfg := {}
var _stage := Stage.IDLE
var _loading := false
var _req := {}
var _cur := {}
var _cur_key := ""
var _warm := {}
var _warm_next := {}
var _task := -1
var _prep := {}
var _job: AirPicardJob
## Локальный RD с ядрами — один на жизнь узла (создание ~0,2 с — при запуске игры, не в полёте).
var _gpu: RuntimeGpu
## Задача, чьё поле собирается в рабочем потоке (field_async), и её номер: поле чужой
## (остановленной) задачи не подаётся.
var _building: AirPicardJob
var _build_id := 0
var _t0 := 0
var _ok := false
## Наибольшее время главного потока за кадр в расчёте, мс (опрос, запуск задачи, чтение буферов).
var _main_ms := 0.0


func _init() -> void:
	name = "AirRuntime"
	_cfg = Config.get_config("atmosphere").get("air_model", {})


## RD и ядра — сразу при появлении узла (запуск игры: кадр и так длинный), не на экране
## загрузки и не в полёте.
func _ready() -> void:
	_device()


func _device() -> RuntimeGpu:
	if _gpu == null and String(_cfg.get("enabled", "auto")) != "off":
		if DisplayServer.get_name() != "headless":
			_gpu = RuntimeGpu.new()
			if not _gpu.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES):
				last_error = _gpu.error
	return _gpu


## Место: detail (HeightLayer, узлы 25 м), water (Image или null), loc ({id, center_lat,
## center_lon, utc_offset_h}). Новое место — прежний расчёт и тёплый старт сбрасываются.
func setup(atmo: Object, place: Dictionary, cond_fn: Callable) -> void:
	atmosphere = atmo
	conditions_fn = cond_fn
	var key := _key_of(place)
	if key != _place_key:
		stop()
		_warm = {}
		_cur = {}
		_cur_key = ""
	_place = place
	_place_key = key


## Место для расчёта по рельефу игры (Terrain): слой detail (25 м), маска воды, координаты,
## пояс часов (как у неба: NAN — солнечное время).
static func place_of(terrain: Node, utc_offset_h: float) -> Dictionary:
	var detail: HeightLayer = null
	for l: HeightLayer in terrain.get("layers"):
		if l.id == "detail":
			detail = l
	var water: Image = null
	if detail != null and detail.water_texture != null:
		water = detail.water_texture.get_image()
		if water != null:
			water = water.duplicate()
			if water.is_compressed():
				water.decompress()
	return {
		detail = detail,
		water = water,
		loc = {
			id = String(terrain.get("location_id")),
			center_lat = float(terrain.get("center_lat")),
			center_lon = float(terrain.get("center_lon")),
			utc_offset_h = utc_offset_h,
		},
	}


## Условия поля сейчас (Game): час неба (SunClock), ветер атмосферы (на 10 м у старта),
## прогноз пилота (FlightSettings: temperature_c — дневной максимум, sky).
static func conditions_of(clock: Object, atmo: Object, settings: Object) -> Dictionary:
	var w: Dictionary = atmo.get("weather")
	return {
		hour = float(clock.get("hour")),
		u10 = float(w.get("wind_speed_kmh", 0.0)) / 3.6,
		wdir = float(w.get("wind_from_deg", 0.0)),
		t_max = float(settings.get("temperature_c")),
		sky = String(settings.get("sky")),
	}


## Причина, по которой поле не считается ("" — считается): режим off, headless, поле из файла,
## нет места.
func unavailable_reason() -> String:
	var why := ""
	if String(_cfg.get("enabled", "auto")) == "off":
		why = "air_model.enabled = off"
	elif DisplayServer.get_name() == "headless":
		why = "нет RenderingDevice: headless"
	elif Array(OS.get_cmdline_user_args()).any(_is_cmd_field):
		why = CMD_FIELD
	elif _place.get("detail") == null:
		why = "нет слоя рельефа detail"
	elif atmosphere == null or not atmosphere.has_method("set_air_field"):
		why = "атмосфера без поля"
	else:
		var g := _device()
		if g == null or g.rd == null:
			why = g.error if g != null else "нет RenderingDevice"
	return why


static func _is_cmd_field(a: String) -> bool:
	return a.begins_with("--air-field=")


## Экран загрузки: точное поле для текущих условий (conditions_fn), сразу в атмосферу (без
## подмены). true — поле есть (посчитано или то же место и условия — уже в атмосфере).
func load_field() -> bool:
	recompute_enabled = false
	stop()
	var why := unavailable_reason()
	if why == CMD_FIELD:
		return false  # поле из файла подаёт сама атмосфера
	if why != "":
		_analytic(why)
		fallback.emit(why)
		return false
	var c: Dictionary = conditions_fn.call()
	if _cur_key == _place_key and needs_recompute(_cur, c, _step_min()) == "":
		progress_changed.emit(1.0)
		return true  # то же место и условия: поле уже в атмосфере
	_begin(c, "загрузка", true)
	while _stage != Stage.IDLE:
		await get_tree().process_frame
	return _ok


## Внеочередной пересчёт по текущим условиям (в полёте). Идёт расчёт — не копится.
func request_recompute(reason := "запрос") -> void:
	if _stage == Stage.IDLE and unavailable_reason() == "":
		_begin(conditions_fn.call(), reason, false)


## Идёт расчёт.
func busy() -> bool:
	return _stage != Stage.IDLE


## Условия поля, что сейчас в атмосфере ({} — нет).
func current_conditions() -> Dictionary:
	return _cur


## Остановить расчёт и освободить GPU (поле в атмосфере остаётся).
func stop() -> void:
	if _job != null:
		_job.release()
		_job = null
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_build_id += 1  # собираемое поле больше не подаётся
	_stage = Stage.IDLE


## Причина пересчёта ("" — не нужен): срок по игровому времени (step_min), смена ветра, погоды.
static func needs_recompute(have: Dictionary, want: Dictionary, step_min: float) -> String:
	if have.is_empty():
		return "нет поля"
	if absf(float(have.u10) - float(want.u10)) > WIND_TOL_MS:
		return "смена ветра"
	var dd := angle_difference(deg_to_rad(float(have.wdir)), deg_to_rad(float(want.wdir)))
	if absf(dd) > deg_to_rad(DIR_TOL_DEG):
		return "смена ветра"
	var ta := float(have.t_max)
	var tb := float(want.t_max)
	var t_changed := is_nan(ta) != is_nan(tb) or absf(ta - tb) > TMAX_TOL_C
	if String(have.sky) != String(want.sky) or t_changed:
		return "смена погоды"
	if slot(float(want.hour), step_min) != slot(float(have.hour), step_min):
		return "срок %s мин" % step_min
	return ""


## Номер срока пересчёта для часа (срок — каждые step_min игровых минут).
static func slot(hour: float, step_min: float) -> int:
	return floori(hour * 60.0 / maxf(step_min, 1.0) + 1.0e-6)


## Час начала срока.
static func slot_hour(hour: float, step_min: float) -> float:
	return slot(hour, step_min) * maxf(step_min, 1.0) / 60.0


func _step_min() -> float:
	return float(_cfg.get("recompute_game_min", 15.0))


func _process(_dt: float) -> void:
	var t_in := Time.get_ticks_usec()
	match _stage:
		Stage.IDLE:
			if recompute_enabled and not _cur.is_empty() and conditions_fn.is_valid():
				var c: Dictionary = conditions_fn.call()
				var why := needs_recompute(_cur, c, _step_min())
				if why != "" and unavailable_reason() == "":
					_begin(c, why, false)
		Stage.PREP:
			_poll_prep()
		Stage.SOLVE:
			_poll_solve()
	if _stage != Stage.IDLE and _timed_out():
		_fail("таймаут расчёта (%.0f с)" % _timeout_s())
	_main_ms = maxf(_main_ms, (Time.get_ticks_usec() - t_in) / 1000.0)


func _timeout_s() -> float:
	return float(_cfg.get("timeout_s", 60.0))


func _timed_out() -> bool:
	return (Time.get_ticks_usec() - _t0) / 1e6 > _timeout_s()


func _begin(c: Dictionary, reason: String, loading: bool) -> void:
	_req = c.duplicate()
	_req.hour = slot_hour(float(c.hour), _step_min()) if not loading else float(c.hour)
	_req.reason = reason
	_loading = loading
	_ok = false
	_t0 = Time.get_ticks_usec()
	_main_ms = 0.0
	_prep = {}
	_stage = Stage.PREP
	var r := _req
	_task = WorkerThreadPool.add_task(_prep_task.bind(_place, r, _prep), false, "AirRuntime")
	if loading:
		progress_changed.emit(0.0)


## Рабочий поток: вход решателя по месту и условиям (~0,5 с на 400 м).
static func _prep_task(place: Dictionary, c: Dictionary, out: Dictionary) -> void:
	var base := AirPlace.domain_case(
		place.detail,
		place.get("water"),
		place.loc,
		DX,
		float(c.hour),
		float(c.u10),
		float(c.wdir),
		float(c.get("t_max", NAN)),
		String(c.get("sky", "clear"))
	)
	if base != null:
		out.case = PreparedCase.from_case(base)


func _poll_prep() -> void:
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var c: AirCase = _prep.get("case")
	if c == null:
		_fail("область вне слоя рельефа")
		return
	_job = AirPicardJob.new()
	_job.case = c
	_job.mech = true
	_job.chunk_ms = 30.0 if _loading else FLIGHT_CHUNK_MS
	_job.timeout_s = maxf(_timeout_s() - (Time.get_ticks_usec() - _t0) / 1e6, 1.0)
	var n := c.dims().x * c.dims().y * c.dims().z
	var warm_ok := warm_start and not _loading and not _warm.is_empty()
	if warm_ok and PackedFloat32Array(_warm.get("u", PackedFloat32Array())).size() == n:
		_job.warm = _warm
	var t_start := Time.get_ticks_usec()
	if not _job.start(_gpu):
		_fail(_job.error)
		return
	_req.start_ms = (Time.get_ticks_usec() - t_start) / 1000.0
	_stage = Stage.SOLVE


func _poll_solve() -> void:
	var p := _job.poll_slice(LOAD_SLICE_MS) if _loading else _job.poll()
	if _loading:
		progress_changed.emit(p)
	if _job.error != "":
		_fail(_job.error)
		return
	if not _job.is_done():
		return
	_warm_next = _job.state()
	var st := {
		iters = _job.results.map(_iters_of),
		gpu_s = _job.gpu_ms_total / 1000.0,
		warm = not _job.warm.is_empty(),
		poll_max_ms = _job.max_poll_cpu_ms,
		chunk_max_ms = _job.max_chunk_gpu_ms,
	}
	_req.merge(st, true)
	_build_id += 1
	_building = _job
	_job = null
	_building.field_ready.connect(_on_field.bind(_build_id), CONNECT_ONE_SHOT)
	# буферы читаются здесь (главный поток), сборка WindField — в рабочем потоке
	_building.field_async(
		float(_cfg.get("max_speed_ms", 40.0)), float(_cfg.get("max_w_ms", 10.0))
	)
	_building.release()
	_stage = Stage.BUILD


static func _iters_of(r: Dictionary) -> int:
	return int(r.iters)


func _on_field(f: WindField, id: int) -> void:
	if id != _build_id or _stage != Stage.BUILD:
		return  # остановлен или устарел
	_building = null
	if f == null:
		_fail("поле не собралось")
		return
	f.meta.source = "gpu"
	f.meta.cond = {wind = snappedf(float(_req.u10), 0.01), wdir = snappedf(float(_req.wdir), 0.1)}
	atmosphere.call("set_air_field", f, 0.0 if _loading else -1.0)
	_cur = _req.duplicate()
	_cur_key = _place_key
	_warm = _warm_next
	_warm_next = {}
	_req.wall_s = (Time.get_ticks_usec() - _t0) / 1e6
	_req.loading = _loading
	_req.main_max_ms = _main_ms
	last_info = _req.duplicate()
	last_error = ""
	applied_count += 1
	_ok = true
	_stage = Stage.IDLE
	print(
		(
			"air_model: поле %s ч, %.1f м/с с %.0f° (%s): %.2f с, итераций %s%s"
			% [
				_hour_text(float(_req.hour)),
				float(_req.u10),
				float(_req.wdir),
				_req.reason,
				float(_req.wall_s),
				_req.iters,
				", тёплый старт" if _req.warm else ""
			]
		)
	)
	if _loading:
		progress_changed.emit(1.0)
	field_applied.emit(last_info)


func _fail(reason: String) -> void:
	var loading := _loading
	stop()
	_warm_next = {}
	failed_count += 1
	last_error = reason
	_ok = false
	if loading or _cur.is_empty():
		_analytic(reason)
	else:
		print("air_model: пересчёт не удался (%s) — прежнее поле" % reason)
		# условия считаются учтёнными: следующая попытка — на следующем сроке или смене условий
		for k in ["hour", "u10", "wdir", "t_max", "sky"]:
			_cur[k] = _req.get(k, _cur.get(k))
	fallback.emit(reason)


## Аналитика: поле прошлого места/полёта из атмосферы убрать (сразу), строка в журнал.
func _analytic(reason: String) -> void:
	last_error = reason
	if _cur_key != "" and atmosphere != null and atmosphere.has_method("set_air_field"):
		atmosphere.call("set_air_field", null, 0.0)
	_cur = {}
	_cur_key = ""
	_warm = {}
	print("air_model: analytic (%s)" % reason)


func _exit_tree() -> void:
	stop()
	if _gpu != null:
		_gpu.destroy()
		_gpu = null


static func _hour_text(h: float) -> String:
	var m := roundi(h * 60.0)
	return "%02d:%02d" % [posmod(m / 60, 24), m % 60]


static func _key_of(place: Dictionary) -> String:
	var d: Variant = place.get("detail")
	var loc: Dictionary = place.get("loc", {})
	return "%s|%s" % [d.get_instance_id() if d != null else 0, loc.get("id", "")]


## Случай, подготовленный заранее (в рабочем потоке): prepare() обоих решений (~0,7 с на 400 м)
## не ложится на главный поток в AirPicardJob.start (он зовёт prepare() и without_heat()).
class PreparedCase:
	extends AirCase
	var mech_case: AirCase
	var _prepared := false

	static func from_case(src: AirCase) -> PreparedCase:
		var c := PreparedCase.new()
		c.copy_from(src)
		c._prepared = c.prepare()
		var m := PreparedCase.new()
		m.copy_from(src.without_heat())
		m._prepared = m.prepare()
		c.mech_case = m
		return c if c._prepared and m._prepared else null

	func copy_from(src: AirCase) -> void:
		for pr in src.get_property_list():
			if pr.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				set(pr.name, src.get(pr.name))

	func prepare() -> bool:
		return true if _prepared else super.prepare()

	func without_heat() -> AirCase:
		return mech_case if mech_case != null else super.without_heat()


## RD на жизнь AirRuntime: AirGpuJob.release() освобождает только буферы задачи (и наборы),
## ядра, конвейеры и сам RD остаются для следующего расчёта; destroy() — всё.
class RuntimeGpu:
	extends AirGpu
	var _base := 0

	func init(shaders: Array = SHADERS) -> bool:
		var ok := super.init(shaders)
		_base = _owned.size()
		return ok

	func release() -> void:
		if rd == null:
			return
		_close_list()
		for s: RID in _sets.values():
			if rd.uniform_set_is_valid(s):
				rd.free_rid(s)
		_sets.clear()
		for i in range(_base, _owned.size()):
			rd.free_rid(_owned[i])
		_owned.resize(_base)
		_scratch.clear()
		_last_pipe = RID()
		_last_set = RID()

	func destroy() -> void:
		super.release()
