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
##
## Ветер меню (conditions_fn().u10) — на 10 м над стартом (C9 v3). Загрузка с центром окон и
## ветром — в два прохода: проход 1 с множителем притока k₀ (1 или k прошлой загрузки того же
## места и направления), замер U₁ — горизонталь среднего поля на 10 м над землёй старта;
## k₁ = k₀·u10/U₁ (в пределах INFLOW_K_MIN…MAX); проход 2 с k₁ — его поле и подаётся. В полёте
## пересчёт — один проход с k последней загрузки.

## Поле подано в атмосферу. info: {hour, u10, wdir, t_max, sky, reason, wall_s, gpu_s, iters,
## warm, loading}.
signal field_applied(info: Dictionary)
## Расчёт не удался: при загрузке — аналитика, в полёте — прежнее поле.
signal fallback(reason: String)
## Доля расчёта 0..1 (экран загрузки).
signal progress_changed(fraction: float)

enum Stage { IDLE, PREP, SOLVE, BUILD, WINDOWS, SHIFT }

## Клетка области, м (окна 100/50 м вокруг пилота — AirClipmap, AM-04).
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
## Пределы множителя притока k (C9 v3). Над стартами мест игры поле при k = 1 даёт на 10 м
## 1,0–2,1 × ветра притока (WPC-2) → k 0,5–1; разгон над холмом в потенциальном обтекании —
## не больше ≈ 2–2,5 (Jackson & Hunt 1975; Taylor & Lee 1984: ΔS ≤ 1,6), отсюда нижний предел
## 0,3. Верхний 3: старт в тени/отрыве (U₁ → 0) не должен раздувать приток до бури — U над
## стартом тогда остаётся ниже меню (граница модели), приток — не больше 3 × меню.
const INFLOW_K_MIN := 0.3
const INFLOW_K_MAX := 3.0
## Высота замера U над землёй старта, м (ветер меню — на 10 м).
const START_AGL_M := 10.0

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
## Точка, вокруг которой окна клипмапа 100/50 м (AM-04, C7): () -> Vector3 (мир) — при загрузке
## старт, в полёте пилот. Пусто — только область 400 м.
var focus_fn: Callable
## Сдвигов окон за пилотом (замеры, тесты).
var shift_count := 0
## Число поданных полей и неудач за жизнь узла (замеры, тесты).
var applied_count := 0
var failed_count := 0
## Множитель притока поля в атмосфере (C2 v6, C9 v3): U меню / U поля на 10 м над стартом после
## прохода 1 загрузки; пересчёт в полёте — с ним же. 1 — без подстройки (штиль, без старта).
var inflow_k := 1.0
## Проход 2 загрузки — с тёплого старта от прохода 1 (область и окна).
var warm_second_pass := true
## Проходов загрузки (C9 v3: 2; 1 — без подстройки, k = 1: тесты против эталонов). Сверх двух — секущая, пока |U/u10 − 1| > pass_tol (исследование
## шлюза air-start: tools/research/air_start/passes_probe.gd).
var max_passes := 2
## Остаток |U/u10 − 1| над стартом, при котором проходы сверх второго не нужны.
var pass_tol := 0.03
## Только тесты: предел времени проходов ≥ 2, с (NAN — air_model.timeout_s) — вызвать неудачу
## прохода 2 и проверить откат к полю прохода 1.
var timeout_later_pass_s := NAN

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
## Клипмап (окна вокруг focus_fn) и поле области, ждущее окон; parent_data() задачи области.
var _clip: AirClipmap
var _focus_node: Node3D
var _focus_start := Vector3.ZERO
var _dom_field: WindField
var _pd := {}
## Проход загрузки (1, 2), число проходов этого расчёта и k притока текущего прохода.
var _pass := 1
var _passes := 1
var _k := 1.0
## U на 10 м над стартом после прохода 1, м/с; точка старта (мир; x NAN — нет).
var _u_first := NAN
var _start_pt := Vector3(NAN, NAN, NAN)
## Состояние области прохода 1 — тёплый старт прохода 2.
var _warm_pass := {}
## k прошлых загрузок этого места по направлению ветра (ключ — румб, °).
var _k_mem := {}
## Проходы этого расчёта: {k, u, wall_s (от начала), iters, warm}.
var _pass_log: Array[Dictionary] = []
## Уровни прошлого прохода загрузки (не поданы): подаются, если следующий проход не удался.
var _prev_levels: Array[WindField] = []
## Начало прохода и готовность поля области в нём (мкс) — для замеров по проходам.
var _t_pass := 0
var _t_dom := 0


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
			if not _gpu.init(
				AirGpu.SHADERS + AirPicardJob.SHADER_NAMES + AirWindowJob.WINDOW_SHADERS
			):
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
		_clip = null
		_warm = {}
		_cur = {}
		_cur_key = ""
		_k_mem = {}
		inflow_k = 1.0
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


## Окна вокруг узла node (пилот) в полёте; при загрузке — вокруг start (старт: пилот ещё не на
## месте). focus_fn = эта пара.
func set_focus(node: Node3D, start: Vector3) -> void:
	_focus_node = node
	_focus_start = start
	focus_fn = _focus_of_node


## Полёт идёт, когда родитель узла (Game) шагает физику — до этого пилот ещё не на старте.
func _focus_of_node() -> Vector3:
	if _loading or _focus_node == null or not is_instance_valid(_focus_node):
		return _focus_start
	var host := _focus_node.get_parent()
	if host != null and not host.is_physics_processing():
		return _focus_start
	return _focus_node.global_position


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
	if _clip != null and _clip.is_busy():
		_clip.release()
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
				else:
					_update_windows()
		Stage.PREP:
			_poll_prep()
		Stage.SOLVE:
			_poll_solve()
		Stage.WINDOWS, Stage.SHIFT:
			if _loading:
				_clip.poll_slice(LOAD_SLICE_MS)
				_progress(0.5 + 0.5 * _clip.progress())
			else:
				_clip.poll()
	# сдвиг окон — свои пределы у задач окон (AirClipmap.timeout_s)
	if _stage != Stage.IDLE and _stage != Stage.SHIFT and _timed_out():
		_fail("таймаут расчёта (%.0f с)" % _timeout_s())
	_main_ms = maxf(_main_ms, (Time.get_ticks_usec() - t_in) / 1000.0)


func _timeout_s() -> float:
	if _pass > 1 and not is_nan(timeout_later_pass_s):
		return timeout_later_pass_s
	return float(_cfg.get("timeout_s", 60.0))


func _timed_out() -> bool:
	# предел — на проход (расчёт одного поля); wall_s загрузки — от _t0, по всем проходам
	return (Time.get_ticks_usec() - _t_pass) / 1e6 > _timeout_s()


func _begin(c: Dictionary, reason: String, loading: bool) -> void:
	_req = c.duplicate()
	_req.hour = slot_hour(float(c.hour), _step_min()) if not loading else float(c.hour)
	_req.reason = reason
	_loading = loading
	_ok = false
	_t0 = Time.get_ticks_usec()
	_main_ms = 0.0
	_pass = 1
	_warm_pass = {}
	_u_first = NAN
	_pass_log.clear()
	_prev_levels = []
	var u10 := float(c.u10)
	if loading:
		_start_pt = Vector3(NAN, NAN, NAN)
		if _windows_wanted():
			_start_pt = focus_fn.call()
		# штиль (ниже порога трогания анемометра, WindProfile.U10_MIN) — один проход, k = 1
		var two := _windows_wanted() and u10 >= WindProfile.U10_MIN and max_passes >= 2
		_passes = max_passes if two else 1
		_k = float(_k_mem.get(_dir_key(float(c.wdir)), 1.0)) if two else 1.0
	else:
		_passes = 1
		_k = inflow_k
	_start_prep()
	if loading:
		progress_changed.emit(0.0)


## Вход решателя прохода (_k) — в рабочем потоке.
func _start_prep() -> void:
	_t_pass = Time.get_ticks_usec()
	_t_dom = 0
	_prep = {}
	_stage = Stage.PREP
	var r := _req
	_task = WorkerThreadPool.add_task(
		_prep_task.bind(_place, r, _k, _prep), false, "AirRuntime"
	)


static func _dir_key(wdir: float) -> int:
	return posmod(roundi(wdir), 360)


## Доля загрузки: при двух проходах проход 1 — 0…0,5, проход 2 — 0,5…1.
func _progress(x: float) -> void:
	if _passes > 1:
		x = (_pass - 1 + x) / _passes
	progress_changed.emit(x)


## Рабочий поток: вход решателя по месту и условиям (~0,5 с на 400 м); k — множитель притока.
static func _prep_task(place: Dictionary, c: Dictionary, k: float, out: Dictionary) -> void:
	var base := AirPlace.domain_case(
		place.detail,
		place.get("water"),
		place.loc,
		DX,
		float(c.hour),
		float(c.u10),
		float(c.wdir),
		float(c.get("t_max", NAN)),
		String(c.get("sky", "clear")),
		true,
		k
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
	_job.timeout_s = maxf(_timeout_s() - (Time.get_ticks_usec() - _t_pass) / 1e6, 1.0)
	var n := c.dims().x * c.dims().y * c.dims().z
	var warm := {}
	if warm_start and not _loading:
		warm = _warm
	elif _loading and _pass > 1 and warm_second_pass:
		warm = _warm_pass
	if not warm.is_empty() and PackedFloat32Array(warm.get("u", PackedFloat32Array())).size() == n:
		_job.warm = warm
	var t_start := Time.get_ticks_usec()
	if not _job.start(_gpu):
		_fail(_job.error)
		return
	_req.start_ms = (Time.get_ticks_usec() - t_start) / 1000.0
	_stage = Stage.SOLVE


func _poll_solve() -> void:
	var p := _job.poll_slice(LOAD_SLICE_MS) if _loading else _job.poll()
	if _loading:
		_progress(p * (0.5 if _windows_wanted() else 1.0))
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
	# окна: поле области как родитель — до освобождения задачи (буферы с GPU)
	_pd = _job.parent_data() if _windows_wanted() else {}
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


## Проход для журнала: «k → U м/с за с (область с, GPU с)».
static func _pass_text(e: Dictionary) -> String:
	return "%.3f → %.2f м/с за %.1f с (область %.1f, GPU %.2f)" % [
		float(e.k), float(e.u), float(e.pass_s), float(e.domain_s), float(e.gpu_s)
	]


static func _window_text(h: Dictionary) -> String:
	return "%d м %s" % [int(h.dx), str(h.iters)]


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
	_t_dom = Time.get_ticks_usec()
	if not _pd.is_empty():
		_dom_field = f
		_start_windows()
		return
	var one: Array[WindField] = [f]
	_levels_done(one)


## Окна клипмапа от новой области: при загрузке — заново с центром в focus_fn(), в полёте — на
## прежних местах от новой области (тёплый старт). Готовый набор — _on_levels.
func _start_windows() -> void:
	# проход 2 загрузки с тёплого старта — окна прохода 1 на тех же местах (как пересчёт в полёте)
	var reuse := not _loading or (_pass > 1 and warm_second_pass)
	var fresh := not reuse or _clip == null or not _clip.is_ready()
	if fresh:
		_clip = AirClipmap.new()
		_clip.use_gpu(_gpu)
		_clip.chunk_ms = 30.0 if _loading else FLIGHT_CHUNK_MS
		_clip.setup(
			_place.detail,
			_place.get("water"),
			_place.loc,
			float(_req.hour),
			float(_req.u10),
			float(_req.wdir),
			float(_req.get("t_max", NAN)),
			String(_req.get("sky", "clear")),
			_k
		)
		_clip.levels_changed.connect(_on_levels)
		_clip.failed.connect(_on_windows_failed)
	else:
		_clip.set_conditions(
			float(_req.hour),
			float(_req.u10),
			float(_req.wdir),
			float(_req.get("t_max", NAN)),
			String(_req.get("sky", "clear")),
			_k
		)
	_clip.set_domain_data(_pd, _dom_field)
	_pd = {}
	if fresh:
		var p: Vector3 = focus_fn.call()
		_clip.start(Vector2(p.x, -p.z))
	_stage = Stage.WINDOWS


func _windows_wanted() -> bool:
	return focus_fn.is_valid() and not Array(_cfg.get("window_levels_m", [100.0])).is_empty()


## В полёте, без расчёта: сдвиг окон за пилотом (фоном; готовый набор — _on_levels).
func _update_windows() -> void:
	if _clip == null or not _clip.is_ready() or not focus_fn.is_valid():
		return
	_clip.update(focus_fn.call())
	if _clip.is_busy():
		_t0 = Time.get_ticks_usec()
		_t_pass = _t0
		_main_ms = 0.0
		_loading = false
		_stage = Stage.SHIFT


func _on_levels(levels: Array[WindField]) -> void:
	if _stage == Stage.SHIFT:
		atmosphere.call("set_air_field", levels, -1.0)
		shift_count += 1
		_stage = Stage.IDLE
		return
	if _stage == Stage.WINDOWS:
		_req.windows = _clip.history.slice(-levels.size() + 1)
		_levels_done(levels)


func _on_windows_failed(reason: String) -> void:
	if _stage == Stage.SHIFT:
		print("air_model: сдвиг окон не удался (%s) — прежние уровни" % reason)
		_stage = Stage.IDLE
	elif _stage == Stage.WINDOWS:
		print("air_model: окна не посчитались (%s) — только область" % reason)
		var one: Array[WindField] = [_dom_field]
		_levels_done(one)


## Уровни прохода готовы: замер U на 10 м над стартом; после прохода 1 из двух — k₁ = k₀·u10/U₁
## и проход 2 (поле прохода 1 в атмосферу не подаётся), иначе — подача.
func _levels_done(levels: Array[WindField]) -> void:
	var u := start_speed(levels, _start_pt, float(_req.u10), float(_req.wdir))
	var u10 := float(_req.u10)
	_pass_log.append(
		{
			k = _k,
			u = u,
			wall_s = (Time.get_ticks_usec() - _t0) / 1e6,
			pass_s = (Time.get_ticks_usec() - _t_pass) / 1e6,
			domain_s = (_t_dom - _t_pass) / 1e6 if _t_dom > 0 else NAN,
			gpu_s = float(_req.get("gpu_s", 0.0)),
			iters = _req.get("iters", []),
			windows = _req.get("windows", []).map(_window_text),
			warm = bool(_req.get("warm", false)),
		}
	)
	if _pass == 1:
		_u_first = u
	var more := _pass < _passes
	if more and _pass >= 2:
		# сверх контрактных двух — только если остаток больше pass_tol
		more = not is_nan(u) and absf(u / u10 - 1.0) > pass_tol
	if more:
		var k1 := _next_k(u10)
		_warm_pass = _warm_next
		_warm_next = {}
		_prev_levels = levels
		_req.prev_windows = _req.get("windows", [])
		_dom_field = null
		_req.erase("windows")
		_pass += 1
		_k = k1
		_start_prep()
		return
	_req.inflow_k = _k
	_req.passes = _pass
	_req.u_start10_first = _u_first
	_req.u_start10 = u
	_req.pass_log = _pass_log.duplicate()
	_apply(levels)


## k следующего прохода: после первого — k·u10/U (поле ∝ притоку); дальше — секущая по двум
## последним проходам (U = a + b·k: нагрев склонов даёт часть ветра, не растущую с притоком).
func _next_k(u10: float) -> float:
	var last: Dictionary = _pass_log[-1]
	var k := float(last.k)
	var u := float(last.u)
	if is_nan(u) or u <= 1.0e-3:
		return INFLOW_K_MAX
	var k1 := k * u10 / u
	if _pass_log.size() >= 2:
		var prev: Dictionary = _pass_log[-2]
		var dk := k - float(prev.k)
		var du := u - float(prev.u)
		if absf(dk) > 1.0e-4 and du / dk > 1.0e-3:
			k1 = k + (u10 - u) * dk / du
	return clampf(k1, INFLOW_K_MIN, INFLOW_K_MAX)


## Горизонталь среднего поля (без болтанки, как Atmosphere.mean_wind_at) на START_AGL_M над
## землёй точки p (мир; земля — слой detail места, = Terrain.height_at) по набору уровней с весами
## края (как AirFieldSet в атмосфере); непокрытая доля — аналитика, на 10 м над стартом она = u10
## меню по направлению ветра. Земля для выборки поля (сдвиг по рельефу) — как у атмосферы:
## GroundField (сетка 30 м, у гребня старта на 0,3–2 м ниже рельефа), нет её — рельеф.
## NAN — нет точки или слоя.
func start_speed(levels: Array[WindField], p: Vector3, u10: float, wdir: float) -> float:
	var detail: HeightLayer = _place.get("detail")
	if is_nan(p.x) or detail == null or levels.is_empty():
		return NAN
	var h := detail.sample(p.x, p.z)
	var gh := h
	var gf: Variant = atmosphere.get("ground") if atmosphere != null else null
	if gf is GroundField and (gf as GroundField).has_ground:
		gh = (gf as GroundField).sample(p.x, p.z).x
	var fs := AirFieldSet.new()
	fs.edge_cells = float(_cfg.get("edge_blend_cells", 5.0))
	fs.max_speed = float(_cfg.get("max_speed_ms", 40.0))
	fs.max_w = float(_cfg.get("max_w_ms", 10.0))
	fs.set_field(levels, 0.0)
	var fw := fs.sample(Vector3(p.x, h + START_AGL_M, p.z), gh)
	var a := deg_to_rad(wdir)
	var rest := u10 * (1.0 - fw.w)
	return Vector2(fw.x - sin(a) * rest, fw.z + cos(a) * rest).length()


## Подать уровни (от мелкого к грубому) в атмосферу: загрузка — сразу, полёт — подмена (C8).
func _apply(levels: Array[WindField]) -> void:
	atmosphere.call("set_air_field", levels, 0.0 if _loading else -1.0)
	_dom_field = null
	_cur = _req.duplicate()
	_cur_key = _place_key
	_warm = _warm_next
	_warm_next = {}
	_warm_pass = {}
	inflow_k = _k
	if _loading and _passes > 1:
		_k_mem[_dir_key(float(_req.wdir))] = _k
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
			(
				"air_model: поле %s ч, %.1f м/с с %.0f° (%s): %.2f с, итераций %s%s%s; "
				+ "k притока %.3f, U над стартом на 10 м %.2f м/с (проход 1: %.2f), проходов %d %s"
			)
			% [
				_hour_text(float(_req.hour)),
				float(_req.u10),
				float(_req.wdir),
				_req.reason,
				float(_req.wall_s),
				_req.iters,
				", тёплый старт" if _req.warm else "",
				", окна %s" % [_req.windows.map(_window_text)] if _req.has("windows") else "",
				_k,
				float(_req.u_start10),
				float(_req.u_start10_first),
				_pass,
				_pass_log.map(_pass_text),
			]
		)
	)
	if _loading:
		progress_changed.emit(1.0)
	_loading = false
	field_applied.emit(last_info)


func _fail(reason: String) -> void:
	var loading := _loading
	if loading and _pass > 1 and not _prev_levels.is_empty():
		_use_previous_pass(reason)
		return
	stop()
	_warm_next = {}
	_warm_pass = {}
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


## Загрузка: проход ≥ 2 не удался (таймаут, расхождение, нет окна) — подать поле прошлого прохода
## (его k и U над стартом), а не аналитику.
func _use_previous_pass(reason: String) -> void:
	var lv := _prev_levels
	_prev_levels = []
	var failed_pass := _pass
	stop()
	failed_count += 1
	var e: Dictionary = _pass_log[-1]
	_pass = failed_pass - 1
	_k = float(e.k)
	_warm_next = _warm_pass
	_warm_pass = {}
	_req.windows = _req.get("prev_windows", [])
	_req.inflow_k = _k
	_req.passes = _pass
	_req.u_start10_first = _u_first
	_req.u_start10 = float(e.u)
	_req.pass_failed = "проход %d: %s" % [failed_pass, reason]
	_req.pass_log = _pass_log.duplicate()
	print(
		"air_model: проход %d не удался (%s) — поле прохода %d" % [failed_pass, reason, _pass]
	)
	_apply(lv)
	last_error = reason


## Аналитика: поле прошлого места/полёта из атмосферы убрать (сразу), строка в журнал.
func _analytic(reason: String) -> void:
	last_error = reason
	if _cur_key != "" and atmosphere != null and atmosphere.has_method("set_air_field"):
		atmosphere.call("set_air_field", null, 0.0)
	_cur = {}
	_cur_key = ""
	_warm = {}
	inflow_k = 1.0
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
