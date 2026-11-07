# gdlint: disable=max-public-methods
class_name Game
extends Node3D
## Полётный мир: небо, рельеф, воздух, планер, ввод, камеры, прибор, звук (scenes/game/game.tscn).
## Главная сцена вызывает start(settings) / restart() и слушает сигналы.
##
## Порядок шага физики (tick): воздух → ввод → планер → приборы и звук (по сигналу
## telemetry_updated). Физику планера и воздуха ведёт Game, их собственный
## _physics_process выключен — порядок явный и одинаковый в игре и в тестах.
## Подробно — docs/guide/game.md.

## Полёт закончился: kind — "landed" (info — оценка посадки + сводка FlightStats)
## или "takeoff_failed" (info.reason, info.text + сводка).
## Формат info — docs/guide/game.md → «Итог полёта».
## Посадку засчитывает FlightStats (is_finished): короткие касания у старта полёт не завершают.
signal flight_ended(kind: String, info: Dictionary)
## Текст о загрузке для меню ("" — готово).
signal status_changed(text: String)
## «Догнать» (NET-42): буксир поехал / кончился (state — "done", "aborted", "lost" — как
## CatchUpTow; управление и физика уже у пилота).
signal catch_up_started
signal catch_up_ended(state: String)

## Буксир: ниже этой высоты над рельефом управление отдаётся «на земле» (отмена сразу после
## отрыва), м.
const TOW_GROUND_AGL_M := 8.0
## Буксир: потолок воздушной скорости для звука потока, м/с (на 1000 км/ч звук не «ревёт»).
const TOW_FLOW_CAP_MS := 28.0
## Загрузка места: бюджет порции первого обновления термиков на кадр экрана загрузки, мкс (FL-5;
## кадр — порция + отрисовка + неделимый конец ~25 мс, предел замирания — 200 мс).
const LOAD_REFRESH_BUDGET_US := 40000
## Вид ботов на экране загрузки — не дольше за кадр, мкс (по боту, модель крыла — сотни мс).
const LOAD_BOTS_BUDGET_US := 40000
## Подготовка воздуха в полёте после start_at (сеть: догон часов зоны) — порция за тик, мкс.
const AIR_PUMP_BUDGET_US := 4000

var settings: FlightSettings
## Модель воздуха: Atmosphere или запасная CalmAir (game.json → air).
var air: Node3D
## Приборы на трапеции (game.json → mounted_instruments); первый — планшет Instrument3D.
var mounted: Array[Node3D] = []
var stats := FlightStats.new()
## Поток событий полёта для ачивок (контракт S2): отрыв, 1 Гц, итог.
var feed: AchievementFeed
## Синтетический пилот (тесты, --autopilot); null — управляет игрок.
var autopilot: Autopilot
## Объекты мира, просеки, столкновения.
var world_link: WorldLink
## Столкновения крыла с проводами, препятствиями и кронами (docs/guide/game.md).
var collisions := CollisionCheck.new()
## Другие пилоты в небе (configs/bots.json, docs/guide/game.md → «Другие пилоты»).
var bots: BotPilots
## Пасхалки мира и неба (чисто визуально, docs/contracts/easter-eggs.md).
var eggs: EasterEggs
## Сколько ботов (--bots=N); < 0 — из настроек (bots.json → count).
var bots_count := -1
## Время симуляции с начала полёта, с.
var sim_time_s: float = 0.0
## Управление и приборы в полёте (в меню — выключены).
var flying_enabled := false
## Старт в воздухе (--air-start, docs/guide/game.md): в air_start_m м от старта по его курсу, на
## air_start_agl_m м над рельефом, на скорости трима; < 0 — обычный старт с земли.
var air_start_m := -1.0
var air_start_agl_m := 300.0
## Флаг --air-start (Main): главнее выбора игрока (ASM-К2); < 0 — флага нет.
var cli_air_start_m := -1.0
var cli_air_start_agl_m := 300.0
## Настройки воздуха применяются (Main: false в «Тренировке»; в сети и осмотре — всегда нет).
var menu_air_allowed := true
var _probe_flight_no := -1  # номер полёта, для которого строка _log_flight_probe уже в журнале
## Сид мира (термики, порывы); < 0 — atmosphere.json → seed. Задать до start(): «Лететь» из
## меню — новый случайный, «Ещё раз» его не меняет; сеть — сид зоны.
var world_seed := -1
## Сетевой режим (NET-40): NetFlight, пока летим в зоне; null — одиночная игра.
## Задаётся enable_net() до start(). Правила режима — scripts/game/net_flight.gd.
var net: NetFlight = null
## «Догнать» (NET-42): буксир к другу, пока летим на нём; null — физика у пилота.
var tow: CatchUpTow = null
## Руки с трапеции снаружи (меню «Догнать» открыто): крыло летит само, как при свободной камере.
var hands_off := false
## Очередь на старт (сеть, NET-43): идти к месту ожидания {position, heading_deg}; {} — нет.
## Клавиши ходьбы и разбега пилота (или отрыв, буксир) отменяют ходьбу.
var queue_walk: Dictionary = {}
## Индикатор смещения пилота внизу экрана (FB-1).
var shift_indicator: PilotShiftIndicator
var clock_label: ClockLabel
var trike_hud: TrikeGaugesHud  ## TP-К4/К8: тахометр и топливо в HUD дельталёта
var trike_gauges: TrikeGauges3D  ## приборы на панели тележки (кабина)
## Цели полёта (GL-4, GL-К3): null — целей нет (пусто, сеть, осмотр карты или неверный список).
var goals: GoalTracker = null
var goal_list: GoalList
## Файл рекордов (FlightRecords); "" — из настроек (user://records.json). Тесты подменяют.
var records_path := ""
## Отладочные слои F1/F5/F6 (DebugOverlays).
var debug_overlays: DebugOverlays

## «Осмотр карты»: мир и ветер как для полёта, но крыло стоит скрытым и ни на что не влияет,
## камера свободная. Задать до start(); сбрасывается leave_inspect().
var inspect_mode := false

var _cfg: Dictionary
var _start_pos := Vector3.ZERO
var _start_heading := 0.0
## Буксировка со статической лебёдки (TW-10): узел-сессия и место полосы (TowSite.check), {} — без буксировки.
var tow_session: TowSession = null
var _tow_site: Dictionary = {}
var _trike_start := false  ## TP-К6: старт дельталёта на полосе места буксировки (без TowSession)
const TOW_DEFAULT_WIDTH_M := 35.0  # ширина полосы для точки без блока tow (как у единственной полосы места, TW-8b)
var _exact_start := false  # точный старт пилота применён (SP-К1): курс не выравнивается по ветру
var _site_heading := 0.0  # курс площадки (до выравнивания по ветру поля)
var _load_error := ""
var _dt: float = 1.0 / 120.0
var _whiteout := CloudWhiteout.new()
var _animator := PilotAnimator.new()
var _graphics := ""
var _terrain_dirty := false
var _crashed := false  ## врезался в препятствие — планер стоит до «Ещё раз»
var _goals_sig := ""  ## ведущий маршрут и активная точка на приборе (смена — set_task)
var _goal_cylinders: GoalCylinders = null  ## столбы пунктов ведущего маршрута (GL-К4)
var _goals_sync_s := -1.0  ## Telemetry.time_s последней синхронизации прибора с целями
var _ended := false  ## flight_ended уже отправлен (до «Ещё раз» / «Продолжить»)
## Номер текущего отрезка полёта (QL-К1): +1 при start/restart/continue_on_foot; только растёт.
var flight_no := 0
## Погода из прогноза (FR-16): место для Weather.derive (дата, широта, пояс, высоты долины и средней земли).
var _weather_ctx := {}
## Часы суток по времени воздуха (сеть: час = функция времени зоны, NET-00; Weather.hour_at). Погоду и
## источники ход дня ведёт сам воздух (Atmosphere.set_conditions); здесь — только часы:
## час в момент t0 воздуха и скорость времени (ход меняется в _air_rebase_clock).
var _day_on := false
var _day_start_hour := 13.0
var _day_t0 := 0.0
var _day_speed := 1.0
## Время воздуха, с: аргумент advance_to / start_at (воздух идёт от нуля в начале полёта).
var _air_t := 0.0
## Узел, вокруг которого живёт воздух (отладка кадров неба, scenes/main.gd); null — крыло
## (камера в режиме осмотра).
var air_focus_node: Node3D
## Где стоял фокус воздуха при последнем set_focuses (повторно зовём, когда сдвинулся).
var _air_focus := PackedVector3Array()
var _recentered := false  ## дельталёт: камера уже по центру после первого отрыва полёта (подскоки не в счёт)
var _touchdown := {}  ## оценка последнего касания (LandingJudge) — для итога
var _prev_phase := ""
var _alt_pub_at := -1.0  ## sim_time_s последней публикации высоты в Activity (−1 — ещё нет)
var _paused := false
var _motion_gap := false  ## поток движения прерывался (меню/пауза): следующий шаг — с reset()

@onready var sky: SkyEnvironment = $Environment
@onready var terrain: Terrain = $Terrain
@onready var glider: Glider = $Glider
@onready var input_controller: InputController = $InputController
@onready var camera: CameraRig = $CameraRig
@onready var instrument: FlightInstrument = $FlightInstrument
@onready var overlay: InstrumentOverlay = $InstrumentOverlay
@onready var vario_audio: VarioAudio = $VarioAudio
@onready var flight_audio: FlightAudio = $FlightAudio
## Реплики пилота игрока (PV-К4); создаётся в _ready, шина Voice.
var pilot_voice: PilotVoice
# Подошвы пилота на прошлом шаге (шуршание о траву, _rustle_feet).
var _feet_prev := PackedVector3Array()
var _feet_prev_usec: int = 0
var _feet_speed: Array[float] = []


func _exit_tree() -> void:
	MotionRig.detach(self)


func _ready() -> void:
	# Первый запуск: пресет графики по видеокарте (до создания облаков и рельефа).
	if DisplayServer.get_name() != "headless" and GraphicsPresets.ensure_detected():
		sky.apply_config()
	GraphicsPresets.apply_viewport(get_viewport())
	_cfg = Config.get_config("game")
	glider.set_physics_process(false)
	world_link = WorldLink.new()
	world_link.name = "WorldLink"
	add_child(world_link)
	bots = BotPilots.new()
	bots.name = "Bots"
	add_child(bots)
	eggs = EasterEggs.new()
	eggs.name = "EasterEggs"
	add_child(eggs)
	air = _create_air()
	air.name = "Air"
	add_child(air)
	air.set_physics_process(false)
	if "air_cache_enabled" in air:
		air.set("air_cache_enabled", true)  # кеш поля на диске (FL-К1) — только в игре
	if air.has_signal("weather_updated"):
		air.connect("weather_updated", _apply_haze)  # ход дня: дымка за погодой
	debug_overlays = DebugOverlays.new()
	debug_overlays.name = "DebugOverlays"
	add_child(debug_overlays)
	debug_overlays.setup(air, glider, terrain.height_at)
	debug_overlays.camera = camera
	var fkey_hint := FKeyHint.new()
	fkey_hint.name = "FKeyHint"
	fkey_hint.overlays = debug_overlays
	add_child(fkey_hint)
	shift_indicator = PilotShiftIndicator.new()
	shift_indicator.name = "PilotShiftIndicator"
	add_child(shift_indicator)
	Config.reloaded.connect(shift_indicator.reload)
	clock_label = ClockLabel.new()
	clock_label.name = "ClockLabel"
	clock_label.clock = sky.clock
	add_child(clock_label)
	Config.reloaded.connect(clock_label.reload)
	trike_hud = TrikeGaugesHud.new()
	trike_hud.name = "TrikeGaugesHud"
	add_child(trike_hud)
	goal_list = GoalList.new()
	goal_list.name = "GoalList"
	add_child(goal_list)
	Config.reloaded.connect(goal_list.reload)
	Config.reloaded.connect(_reload_wrist)
	var wfd := get_node_or_null("WindFieldDebug")
	if wfd != null and wfd.has_signal("toggled"):
		wfd.connect("toggled", func(on: bool) -> void: debug_overlays.wind_field_on = on)
	terrain.load_failed.connect(func(msg: String) -> void: _load_error = msg)
	SkyEnvironment.setup_camera(camera)
	camera.set_mode(camera.mode)  # near по режиму
	camera.target = glider
	camera.ground_fn = terrain.height_at
	camera.keys_look_fn = input_controller.keys_look  # У2 v2: W/S/A/D в полёте — обзор головой
	camera.mode_changed.connect(func(_m: String) -> void: _update_overlay())
	camera.mode_chosen.connect(_on_camera_chosen)
	overlay.use_instrument(instrument)
	glider.telemetry_updated.connect(_on_telemetry)
	glider.landed.connect(_on_landed)
	feed = AchievementFeed.new(self)
	glider.took_off.connect(_on_took_off)
	_connect_achievements()
	glider.takeoff_failed.connect(_on_takeoff_failed)
	_whiteout.setup(_cfg.get("cloud_whiteout", {}))
	pilot_voice = PilotVoice.new()
	pilot_voice.name = "PilotVoice"
	pilot_voice.height_fn = terrain.height_at
	add_child(pilot_voice)
	apply_user_settings()
	set_flying(false)


func _process(dt: float) -> void:
	# Белая мгла в облаке — по положению камеры (кадр, не шаг физики).
	if air.has_method("cloud_density_at") and sky.world_env != null:
		# CVW-К3: плотность по рисуемым облакам; −1 (не рисуются) — грубое поле как запасной путь.
		var d := -1.0
		var layer := air.get_node_or_null("Clouds") as CloudLayer
		if layer != null:
			d = layer.visible_density_at(camera.global_position)
		if d < 0.0:
			d = float(air.call("cloud_density_at", camera.global_position))
		if d > 0.0 or _whiteout.amount > 0.0:
			_whiteout.update(d, dt)
			_whiteout.apply(sky.world_env.environment)


func _physics_process(dt: float) -> void:
	tick(dt)


## Activity (S3): режим по фазе, сеть, высота (не чаще раза в 10 с и при изменении ≥ 50 м).
func _publish_activity(phase: String) -> void:
	var st: Dictionary = Activity.state()
	var d := {}
	if String(st.mode) in Activity.FLIGHT_MODES:
		d["mode"] = Activity.mode_for_phase(phase)
	d["net"] = NetZone.in_zone
	d["zone_code"] = NetZone.code if NetZone.in_zone else ""
	d["peers"] = NetZone.peer_ids().size() if NetZone.in_zone else 0
	var t := glider.get_telemetry()
	if phase == "flying" and (sim_time_s - _alt_pub_at >= 10.0 and absf(t.altitude_msl - float(st.alt_msl)) >= 50.0
			or _alt_pub_at < 0.0):
		d["alt_msl"] = roundi(t.altitude_msl)
		_alt_pub_at = sim_time_s
	elif phase != "flying":
		_alt_pub_at = -1.0
	Activity.set_state(d)


## Одна строка в журнал на полёт (признак для smoke собранной игры, RW-29): фаза flying и ветер
## у крыла ≠ 0 при готовом воздухе. Не чаще раза за полёт.
func _log_flight_probe(phase: String) -> void:
	if phase != "flying" or _probe_flight_no == flight_no or not bool(air.call("is_ready")):
		return
	_probe_flight_no = flight_no
	var t := glider.get_telemetry()
	var w: Vector3 = air.call("mean_wind_at", t.position)
	print("game: фаза flying, ветер у крыла %.2f м/с, t=%.1f с" % [w.length(), sim_time_s])


## Один шаг симуляции в явном порядке. Тесты зовут его напрямую.
func tick(dt: float) -> void:
	if settings == null:
		return
	_dt = dt
	sim_time_s += dt
	if net != null:
		_net_world_step(dt)
	else:
		var wdt := dt * (wait_speed() if _wait_left_s > 0.0 else 1.0)
		sky.clock.advance(wdt)  # время суток идёт (VR-5)
		_air_advance(wdt)
	if _wait_left_s > 0.0:
		_wait_step(dt)
		return
	if inspect_mode:
		camera.free_keys_enabled = true  # крыло не шагает: ни ввода, ни столкновений, ни итога
		return
	var phase := glider.phase()
	_publish_activity(phase)
	_log_flight_probe(phase)
	if autopilot != null:
		autopilot.hold = input_controller.run_blocked or not queue_walk.is_empty()
		autopilot.drive(glider.get_telemetry(), dt)
	input_controller.on_ground = phase != "flying"
	# Свободная камера занимает WASD — крыло без рук; при автопилоте крыло ведёт он, а камера
	# клавиш не слушает (он жмёт run = Shift).
	var free_cam := camera.mode == "free" and autopilot == null
	input_controller.hands_off = free_cam or hands_off
	camera.free_keys_enabled = autopilot == null
	var control := input_controller.update(dt)
	if autopilot != null:
		control.roll = autopilot.roll_command  # ПИД крена: положение пилота (R7)
	if not queue_walk.is_empty():
		_queue_walk_step(control, phase)
	glider.set_input(control)
	bots.tick(dt, glider.get_telemetry())
	if tow_session != null:
		_winch_step(dt, control)
	if tow != null:
		_tow_step(dt)  # без физики, столкновений и итога полёта
		return
	if _crashed:
		_motion_step(dt)  # стоянка после столкновения: поза неподвижна, поток идёт
		return
	glider.step(dt)  # → telemetry_updated → приборы, звук, статистика
	_motion_step(dt)  # свой пилот во всех фазах (MR-К1 v2); reset() — только на разрывах
	_feed_step(dt)
	var hit := collisions.check(glider.get_telemetry())
	if not hit.is_empty():
		_on_collision(hit)
	_check_finished()


## Шаг потока движения своего пилота: только в полёте (не в меню) и не на паузе; иначе живого шага нет, а пакеты
## идут (hold/neutral, MotionRig). При возврате после меню/паузы (в сети дерево на паузе не стоит) — reset().
func _motion_step(dt: float) -> void:
	if not flying_enabled or _paused:
		_motion_gap = true
		return
	if _motion_gap:
		_motion_gap = false
		MotionRig.reset()
	MotionRig.step(glider.get_telemetry(), dt)


## Новый полёт: загрузить рельеф (если нужно), настроить крыло, погоду и поставить на старт.
## Асинхронно (рельеф с карты грузится из сети). Возвращает false при ошибке.
func start(s: FlightSettings) -> bool:
	flight_no += 1
	_voice_reset()
	_tracks_finish()
	stop_wait()
	settings = s.duplicate()
	StartWeather.apply(settings)  # TI-К2: последняя страховка
	_choose_air_start()
	eggs.reset()
	_lock_net_clock()
	var progress := terrain.progress
	progress.begin()
	# Пока грузится — шаг физики стоит: воздух и планер ещё не настроены на новое место
	# (иначе каждый кадр загрузки догоняет пропущенные шаги — окно «не отвечает»).
	set_physics_process(false)
	status_changed.emit(tr("status_loading_terrain"))
	if not await _load_terrain():
		status_changed.emit(tr("status_terrain_failed") % _load_error)
		set_physics_process(true)
		progress.finish()
		return false
	# Дальше — порциями между кадрами: экран загрузки живой (docs/guide/game.md → «Загрузка»).
	progress.stage("weather", tr("loading_weather"))
	await get_tree().process_frame
	_weather_ctx = _weather_context()
	sky.valley_msl_m = float(_weather_ctx.get("valley_msl_m", 0.0))
	# Новый полёт — воздух с нуля: прежнее место выгружено, сид мира, часы атмосферы с нуля —
	# порывы и жизнь термиков у старта зависят только от локации, погоды и сида, а не от того,
	# сколько летали до этого (детерминизм, F01).
	air.call("unload_place")
	air.call("configure", world_seed)
	_air_t = 0.0
	_air_focus = PackedVector3Array()
	# Солнце по времени и дате старта над центром локации (sky.clock → небо, свет, облака,
	# тени облаков на источниках термиков, прогрев поверхности с инерцией по классам).
	sky.clock.start_flight(
		terrain.center_lat,
		terrain.center_lon,
		settings.month,
		settings.day,
		settings.start_hour,
		float(terrain.location.get("utc_offset_h", NAN))
	)
	# Рельеф (тень склонов, освещённость) — за солнцем по часам.
	if terrain.has_method("set_sun"):
		if not sky.clock.sun_changed.is_connected(terrain.set_sun):
			sky.clock.sun_changed.connect(terrain.set_sun)
		terrain.set_sun(sky.clock.to_sun())
	# Дата полёта — шейдерам (сезон, scene-look SL-К2): там же, где солнце.
	if terrain.has_method("set_flight_date"):
		terrain.set_flight_date(settings.month, settings.day)
	if not sky.clock.sun_changed.is_connected(_on_sun_changed):
		sky.clock.sun_changed.connect(_on_sun_changed)
	_on_sun_changed(sky.clock.to_sun())
	_day_on = false
	if air is Atmosphere:
		_day_on = true  # только часы суток; погоду и источники ведёт воздух
		_day_start_hour = sky.clock.hour
		_day_t0 = 0.0
		_day_speed = sky.clock.speed
	glider.set_ground_fn(terrain.height_at)
	glider.set_air_fn(air.air_velocity_at)
	# Старт — до объектов и поля воздуха (FL-10): выбор зависит только от рельефа (высоты, карта поверхности,
	# площадки); пустырь у старта с карты входит в снимок поверхности поля, как и раньше.
	_choose_start()
	_site_heading = _start_heading
	# Среднее поле на час старта (до термиков: их источники — из поля) и объекты мира — одновременно (FL-10):
	# поле (запечённое → кеш → расчёт) готовится в рабочих потоках и на GPU порциями, объекты — порциями по
	# кадрам; пока считается ветер, экран показывает его долю, а объекты — строкой под ним.
	progress.stage("objects", tr("loading_objects"))
	await get_tree().process_frame
	var job := {"air": true, "objects": true, "air_ready": false}
	_air_field_job(progress, job)
	await world_link.link_async(terrain, air, glider)
	job.objects = false
	if progress.note == tr("loading_objects"):
		progress.note = ""
	# Поле ещё считается — планер и препятствия у старта для ботов (от курса и поля не зависят) — сейчас.
	var glider_ready := false
	if job.air:
		await get_tree().process_frame
		_setup_glider()
		glider_ready = true
		await bots.prefetch_obstacles(terrain, _start_pos)
	while job.air:
		await get_tree().process_frame
	_align_start_heading()
	# Верх дымки — на высоте инверсии (основание облаков).
	_apply_haze()
	progress.stage("glider", tr("loading_almost"))
	await get_tree().process_frame
	if not glider_ready:
		_setup_glider()
		await get_tree().process_frame
	collisions.setup(
		world_link.objects,
		terrain.forest_at,
		glider.model.span,
		float(Config.value("flight", "visual.hang_height_m", 2.0))
	)
	# Лагерь и вещи — до ботов: места ожидания обходят палатки (SC-K1)
	world_link.place_camp()
	await get_tree().process_frame
	# Боты: места и агенты — сразу, вид — порциями вместе с термиками ниже (FL-10).
	_make_tow_session()
	# Напарники (WM-К1): в одиночной игре; в сети — нет
	bots.wingmen = int(Config.value("bots", "wingman.count", 1)) if net == null else 0
	await bots.setup_in_world_async(
		terrain, air, _start_pos, _start_heading, bots_count, world_link.objects, 50.0, _tow_bots_opts()
	)
	# Поля рельефа (влажность ложбин ослабляет источники термиков) считаются в фоне — термики
	# рождаются только после них, иначе первые термики зависели бы от скорости машины.
	# Поля доводит Terrain._process; у выключенного узла (тесты шагают сами) — ждать здесь.
	await _wait_relief()
	_goals_setup()
	restart()
	# Термики вокруг старта — ещё на экране загрузки (первое обновление — самое долгое, секунды):
	# порциями по кадрам, без замирания экрана (FL-5; их двигает _air_load_job через pump); полёт —
	# когда воздух READY. В тех же кадрах — вид ботов.
	var bots_done := false
	while true:
		bots_done = bots_done or bots.build_visuals_step(LOAD_BOTS_BUDGET_US)
		if bool(job.air_ready) and bots_done:
			break
		await get_tree().process_frame
	set_physics_process(true)
	progress.finish()
	status_changed.emit("")
	return true


## Поля рельефа досчитаны: кадрами, пока их доводит Terrain._process; у выключенного узла — ожидание.
func _wait_relief() -> void:
	while terrain.has_method("relief_busy") and terrain.relief_busy():
		if not terrain.can_process() and terrain.has_method("wait_relief"):
			terrain.wait_relief()
			break
		await get_tree().process_frame


## Воздух на загрузке — фоном, одновременно с объектами (FL-10): место из рельефа, условия, фокус,
## старт с нуля, дальше pump каждый кадр до READY. job.air = false, когда поле Пикара подано (или
## этап пропущен): после него можно выбирать курс по ветру у старта; job.air_ready = true — воздух
## готов (термики первого обновления посчитаны).
func _air_field_job(progress: LoadProgress, job: Dictionary) -> void:
	# снимок поверхности (SurfaceSnapshot.start) ждёт поля рельефа — ждать кадрами, а не блокирующе
	await _wait_relief()
	var place: AirPlaceData = await _air_place()
	if air.call("load_place", place) != 0:
		push_warning("Game: воздух не принял место: %s" % air.call("last_error"))
	if air.call("set_conditions", _air_conditions()) != 0:
		push_warning("Game: воздух не принял условия: %s" % air.call("last_error"))
	air.call("set_static_thermals", _location_thermals(), 0)
	_air_set_focus(true)
	air.call("start_at", 0.0)
	var wind_stage := false
	var wind_seen := false
	while true:
		air.call("pump", LOAD_REFRESH_BUDGET_US)
		var st: Dictionary = air.call("status")
		var state := int(st.state)
		var label := String(st.get("stage", ""))
		# Этап подготовки ветра ведёт воздух (подпись и число итераций — status, W2 v3).
		if label != "":
			if not wind_stage:
				progress.stage("wind", label)
				if bool(job.get("objects", false)):
					progress.note = tr("loading_objects")
				wind_stage = true
				wind_seen = true
			progress.text = label
			# прогресс решателя заранее не известен: отдельной строкой — итерации (и номер прогона)
			progress.iter_line = _wind_iter_line(st)
			progress.sub(float(st.get("progress", 0.0)), 1.0)
		var field_done := (wind_seen and label == "") or bool(st.get("field_on", false)) or state != 1
		if field_done and bool(job.air):
			if wind_stage and bool(job.get("objects", false)):
				progress.stage("objects", tr("loading_objects"))  # ветер готов, объекты ещё строятся
				progress.note = ""
			wind_stage = false
			progress.iter_line = ""
			job.air = false
		if state != 1:  # READY (или FAILED/EMPTY — дальше без ожидания)
			break
		await get_tree().process_frame
	job.air = false
	job.air_ready = true


## Место для воздуха из рельефа игры (слой detail 25 м; снимок поверхности — задачей пула, кадры
## идут). Нет слоя или снимка — редкая сетка 3 × 3 по высотам рельефа: воздух берёт высоту,
## источники и поверхность у рельефа (AirPlaceData.terrain), поле Пикара недоступно.
func _air_place() -> AirPlaceData:
	var utc := _clock_utc_offset()
	var place: AirPlaceData
	if air.has_method("place_from_terrain"):
		place = await air.call("place_from_terrain", terrain, utc, settings.month, settings.day)
	else:
		place = AirPlaceData.from_terrain(terrain, utc, settings.month, settings.day)
	if place != null:
		return place
	var loc := {
		"id": String(terrain.location_id),
		"center_lat": terrain.center_lat,
		"center_lon": terrain.center_lon,
		"utc_offset_h": utc,
		"month": settings.month,
		"day": settings.day,
	}
	var span := 20000.0
	var grid := {"origin_x": -span, "origin_z": -span, "spacing": span, "width": 3, "height": 3}
	var heights := PackedFloat32Array()
	for j in 3:
		for i in 3:
			heights.append(terrain.height_at(-span + i * span, -span + j * span))
	var moist := PackedFloat32Array()
	moist.resize(9)
	var place_fb := AirPlaceData.from_arrays(
		AirPlaceData.make_header(loc, grid), heights, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0]),
		PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0]), moist
	)
	place_fb.terrain = terrain
	return place_fb


## Условия воздуха (W5): прогноз пилота, часы старта (sky.clock) и ветер прогноза — набегающий поток
## (10 м над открытой местностью, WF-К1). Ветер «встречный» — румб по курсу площадки (поверх прогноза),
## выше старта ветер сильнее (прирост по климату считает крейт).
func _air_conditions() -> Dictionary:
	var cond := {
		"forecast": settings.forecast(),
		"start_hour": sky.clock.hour,
		"speed": sky.clock.speed,
		# шаг пересчёта погоды по часу (крейт требует)
		"quantum_h": Weather.quantum_h(),
		"wind_ref": {"ref_msl": _start_pos.y},  # прирост ветра с высотой (gain_per_km) берёт крейт из климата
	}
	if settings.wind_into_launch:
		cond["overrides"] = {"wind_from_deg": _site_heading}
	return cond


## Статичные термики места (configs/locations): [x_m, z_m, strength_ms, radius_m] подряд.
func _location_thermals() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for st: Dictionary in terrain.location.get("thermals", []):
		out.append_array(
			PackedFloat32Array(
				[float(st.x_m), float(st.z_m), float(st.strength_ms), float(st.radius_m)]
			)
		)
	return out


## Вес точки внимания воздуха (W2 set_focuses): игрок — 1; другие пилоты в небе — меньше.
const AIR_FOCUS_W_BOT := 0.3
const AIR_FOCUS_W_PEER := 0.5
## Больше стольких других точек внимания воздух не получает (ближайшие к игроку).
const AIR_FOCUS_OTHERS_MAX := 16


## Точки внимания воздуха (вокруг кого живут термики и облака; индекс 0 — игрок): игрок — крыло
## (камера в режиме осмотра); на загрузке — старт; в полёте — ещё боты в воздухе и пилоты сети.
## Зовём, когда любая точка сдвинулась не меньше чем на метр или их число изменилось.
## Строка итераций экрана загрузки по status() воздуха ("" — итераций нет): «Итерация: N», при
## нескольких прогонах решателя — «Прогон r из n · Итерация: N».
static func _wind_iter_line(st: Dictionary) -> String:
	var iters := int(st.get("iters", 0))
	if iters <= 0:
		return ""
	var run := int(st.get("run", 0))
	var runs := int(st.get("runs", 0))
	if runs > 1 and run >= 1:
		return TranslationServer.translate("loading_wind_run_iter") % [run, runs, iters]
	return TranslationServer.translate("loading_wind_iter") % iters


func _air_set_focus(force := false) -> void:
	var p := _start_pos
	if flying_enabled or not force:
		var n: Node3D = air_focus_node if air_focus_node != null else (camera if inspect_mode else glider)
		if n != null and n.is_inside_tree():
			p = n.global_position
	var pts := PackedVector3Array([p])
	var ws := PackedFloat32Array([1.0])
	if flying_enabled and not force:
		_air_other_focuses(p, pts, ws)
	if not force and _air_focus_same(pts):
		return
	_air_focus = pts
	air.call("set_focuses", pts, ws)


func _air_focus_same(pts: PackedVector3Array) -> bool:
	if pts.size() != _air_focus.size():
		return false
	for i in pts.size():
		if pts[i].distance_squared_to(_air_focus[i]) >= 1.0:
			return false
	return true


## Боты в воздухе (BotPilots) и пилоты сети (RemotePilots): точки и веса после игрока.
func _air_other_focuses(from: Vector3, pts: PackedVector3Array, ws: PackedFloat32Array) -> void:
	var found: Array[Vector4] = []  # x, y, z — точка, w — вес
	if bots != null:
		for a: BotAgent in bots.agents:
			if a.state == BotAgent.State.FLY:
				found.append(Vector4(a.model.position.x, a.model.position.y, a.model.position.z, AIR_FOCUS_W_BOT))
	if net != null and net.remote != null:
		for r: Dictionary in net.remote.pilots():
			if String(r.get("phase", "")) == "flying":
				var q: Vector3 = r.position
				found.append(Vector4(q.x, q.y, q.z, AIR_FOCUS_W_BOT if bool(r.get("is_bot", false)) else AIR_FOCUS_W_PEER))
	found.sort_custom(
		func(u: Vector4, v: Vector4) -> bool:
			return Vector3(u.x, u.y, u.z).distance_squared_to(from) < Vector3(v.x, v.y, v.z).distance_squared_to(from)
	)
	for i in mini(found.size(), AIR_FOCUS_OTHERS_MAX):
		pts.append(Vector3(found[i].x, found[i].y, found[i].z))
		ws.append(found[i].w)


## Продвинуть воздух на dt (раз в тик): фокус, время, и пока он готовится (start_at) — порции.
func _air_advance(dt: float) -> void:
	_air_set_focus()
	_air_t += dt
	air.call("advance_to", _air_t)
	if not bool(air.call("is_ready")):
		air.call("pump", AIR_PUMP_BUDGET_US)


## Ход часов изменился (новый полёт, смена скорости времени): перепривязать воздух.
func _air_rebase_clock() -> void:
	if _day_on:
		_day_t0 = _air_t
		_day_start_hour = sky.clock.hour
		_day_speed = sky.clock.speed
	if settings != null and not _weather_ctx.is_empty():
		air.call("set_conditions", _air_conditions())


## Погода воздуха (копия, только чтение): weather() фасада W2.
func _air_weather() -> Dictionary:
	return air.call("weather") if air != null and air.has_method("weather") else {}


## Место для погоды: дата, широта/долгота, пояс, высоты долины и средней земли вокруг (0, 0).
func _weather_context() -> Dictionary:
	var g: Dictionary = Config.get_config("atmosphere").ground
	var ctx := Weather.ground_context(
		terrain.height_at,
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(Weather.config().valley_percentile)
	)
	ctx.merge(
		{
			"month": settings.month,
			"day": settings.day,
			"lat": terrain.center_lat,
			"lon": terrain.center_lon,
			"utc_offset_h": _clock_utc_offset(),
		}
	)
	return ctx


## Пояс часов места так же, как у SunClock: world.json → time.utc_offset_h ("solar" — солнечное
## время, NAN), иначе пояс локации, иначе по долготе.
func _clock_utc_offset() -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)


## Сеть (NET-40): мир — на момент t зоны, с (от начала зоны = от старта часов start_hour):
## воздух сразу в t (то же, что прогон от 0; готовится порциями — тик зовёт pump), часы — на
## час старта + t.
func set_world_time(t: float) -> void:
	if _day_on:
		sky.clock.set_hour(_day_hour_at(t))
	_air_t = t
	air.call("start_at", t)


## Дымка: верх — у кромки (инверсия), густота — по влажности.
func _apply_haze() -> void:
	if air.has_method("cloudbase_msl") and sky.has_method("set_inversion_height_msl"):
		sky.set_inversion_height_msl(float(air.call("cloudbase_msl")))
	if sky.has_method("set_haze_density"):
		sky.set_haze_density(float(_air_weather().get("haze_k", 1.0)))


## Час места через t с времени воздуха (сеть: функция времени зоны): от часа в момент t0 со скоростью времени.
func _day_hour_at(t: float) -> float:
	return Weather.hour_at(_day_start_hour, _day_speed, t - _day_t0)


func _on_sun_changed(to_sun: Vector3) -> void:
	if air.has_method("set_sun_direction"):
		air.call("set_sun_direction", to_sun)


## Треки (GL-К5, GL-К6): запись полёта с отрыва, след прошлой попытки места полосой. В сети — ничего.
var goal_tracks: Array = []  ## [FlightTrack]: след прошлой попытки (source "last") и др.
var _track_rec: TrackRecorder = null
var _track_key := ""  ## ключ места записи; пусто — не пишем / уже сохранено
var _track_ribbons: Array[TrackRibbon] = []


func _tracks_active() -> bool:
	return net == null and not inspect_mode and settings != null


## Новая попытка: след прошлой (если нужен) в goal_tracks и полосы, запись с нуля.
func _tracks_begin() -> void:
	goal_tracks = goal_tracks.filter(
		func(f: FlightTrack) -> bool: return f.source != "last" and not f.source.is_absolute_path()
	)
	_track_rec = null
	_track_key = ""
	if _tracks_active():
		_track_key = LastTrackStore.place_key(settings)
		_track_rec = TrackRecorder.new()
		_track_rec.start(terrain.local_to_latlon)
		if settings.show_last_track:
			var last := LastTrackStore.load(_track_key)
			if last != null:
				goal_tracks.append(last)
		for path in settings.track_paths:  # загруженные IGC/GPX (GL-10); чужого места — пропуск
			var ft := TrackIO.read(path)
			if ft != null and ft.inside_fraction(terrain.detail_bounds(), terrain.latlon_to_local) >= 0.5:
				ft.source = path
				goal_tracks.append(ft)
	for r in _track_ribbons:
		remove_child(r)
		r.queue_free()
	_track_ribbons.clear()
	if net != null:
		return
	for f: FlightTrack in goal_tracks:
		var r := TrackRibbon.new()
		r.name = "TrackRibbon"
		add_child(r)
		r.set_track(f, terrain.latlon_to_local)
		_track_ribbons.append(r)


func _tracks_record(t: Telemetry) -> void:
	if _track_rec != null and _track_key != "":
		_track_rec.update(t)


## Конец попытки: если взлёт был — запись заменяет след прошлой попытки места.
func _tracks_finish() -> void:
	if _track_rec == null or _track_key == "":
		return
	var key := _track_key
	_track_key = ""
	if not stats.took_off or _track_rec.track().size() < 2:
		return
	var f := _track_rec.track()
	f.name = key
	LastTrackStore.save(key, f)


## Заново с того же старта (клавиша R, «Ещё раз», «На старт»). keep_clock = true — одиночная
## «На старт»: часы и день не сбрасываются (время идёт дальше); в сети часы и так не трогаем.
func restart(keep_clock: bool = false) -> void:
	if settings == null:
		return
	flight_no += 1
	_voice_reset()
	_tracks_finish()
	stop_wait()
	if autopilot != null:
		autopilot.reset()
	tow = null  # «Ещё раз» / «На старт» посреди буксира
	feed.cancel()  # полёт без посадки не засчитывается
	camera.tight = false
	queue_walk = {}
	MotionRig.reset()
	_align_start_heading()
	if air_start_m >= 0.0:
		glider.reset_in_air(air_start_position(), _start_heading)
	elif net != null:  # в сети — на своё место в очереди на старт (NET-43)
		var sp := net.queue_start_spot()
		glider.reset_on_ground(sp.position, float(sp.heading_deg))
	elif _trike_start:
		glider.reset_on_wheels(_start_pos, _start_heading)  # TP-К6: начало полосы, заглушен, полный бак
	else:
		glider.reset_on_ground(_start_pos, _start_heading)
	if tow_session != null:
		tow_session.reset()  # трос снова лежит, ждёт W
	_animator.bind(glider.visual, _cfg.get("pilot_animation", {}))
	input_controller.reset()
	collisions.reset()
	bots.reset()
	eggs.reset()
	_crashed = false
	_ended = false
	_touchdown = {}
	_recentered = false
	_prev_phase = ""
	sim_time_s = 0.0
	if net == null and not keep_clock:  # в сети мир идёт по часам зоны — «Ещё раз» его не сбрасывает
		sky.clock.reset()
		_air_rebase_clock()
	stats.reset(glider.get_telemetry().position)
	stats.armed = air_start_m >= 0.0  # в воздухе взлёта не было — касание это посадка (ASM-К2)
	stats.trike = _trike_start
	instrument.reset()
	_goals_reset()
	for n in mounted:
		if not bool(n.get_meta("shares_tablet", false)) and n.get("vario90s") != null:
			(n.get("vario90s") as VarioDisplay90s).reset()
	_tracks_begin()
	camera.snap()


## «Встречный» ветер: поле у земли поворачивает поток по рельефу, и на высоте крыла он приходит
## сбоку — боковой поток кренит крыло на разбеге. Пилот встаёт носом против среднего ветра поля
## у старта (без пульсаций, по нескольким точкам), но не дальше max_turn_deg от курса площадки.
## Штиль (< min_speed_ms), аналитика (поля нет), ветер с румба и сеть — курс площадки.
func _align_start_heading() -> void:
	if settings == null or net != null or not settings.wind_into_launch or _exact_start:
		return
	_start_heading = _site_heading
	if not bool((air.call("status") as Dictionary).get("field_on", false)):
		return
	var c: Dictionary = _cfg.get("start_wind_align", {})
	var r := float(c.get("sample_radius_m", 15.0))
	var hub := float(Config.value("flight", "takeoff.wing_height_m", 1.8))
	var w := Vector2.ZERO
	var n := 0
	for o in [Vector2.ZERO, Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
		var x: float = _start_pos.x + o.x
		var z: float = _start_pos.z + o.y
		var v: Vector3 = air.call("mean_wind_at", Vector3(x, terrain.height_at(x, z) + hub, z))
		w += Vector2(v.x, v.z)
		n += 1
	w /= float(n)
	if w.length() < float(c.get("min_speed_ms", 1.0)):
		return
	# Курс (0 = −Z, по часовой): вектор курса (sin h, −cos h); против ветра — вектор (−w.x, −w.y).
	var want := rad_to_deg(atan2(-w.x, w.y))
	var d := wrapf(want - _site_heading, -180.0, 180.0)
	var lim := float(c.get("max_turn_deg", 60.0))
	_start_heading = fposmod(_site_heading + clampf(d, -lim, lim), 360.0)


## Точка старта в воздухе: air_start_m по курсу старта, air_start_agl_m над рельефом там.
## forward_m/agl_m < 0 — air_start_m/air_start_agl_m (режим «Маятник» задаёт свои).
func air_start_position(forward_m := -1.0, agl_m := -1.0) -> Vector3:
	var h := deg_to_rad(_start_heading)
	var f := forward_m if forward_m >= 0.0 else air_start_m
	var p := _start_pos + Vector3(sin(h), 0.0, -cos(h)) * f
	p.y = terrain.height_at(p.x, p.z) + (agl_m if agl_m >= 0.0 else air_start_agl_m)
	return p


## После итога «Продолжить»: пилот на земле ходит дальше; новый разбег — новый полёт.
func continue_on_foot() -> void:
	flight_no += 1
	_voice_reset()
	_tracks_finish()
	_ended = false
	_touchdown = {}
	_recentered = false
	_tracks_begin()
	stats.reset(glider.get_telemetry().position)
	_goals_reset()


## «Подождать час» (Q-17): одиночная игра, пилот стоит на старте. Время мира идёт в wait_speed раз
## быстрее (солнце, термики, облака, поле ветра — по обычному расписанию), пока не пройдёт
## wait_hours часов, не упрётся в конец дня или не вызовут stop_wait(). Крыло не шагает.
signal wait_finished

var _wait_left_s := 0.0  ## осталось мирового времени ожидания, с (0 — не ждём)
var _wait_frames_ms: PackedFloat32Array = []  ## время кадров во время ожидания, мс (замер рывков)
var _wait_last_us := 0


func can_wait() -> bool:
	return net == null and settings != null and not inspect_mode and glider != null \
		and glider.phase() == "standing" and _wait_left_s <= 0.0 and tow == null


func wait_speed() -> float:
	return maxf(float(_cfg.get("wait_speed", 60.0)), 1.0)


func is_waiting() -> bool:
	return _wait_left_s > 0.0


func start_wait() -> bool:
	if not can_wait() or sky.clock.hour >= SunClock.clamp_hour(1.0e9):
		return false
	_wait_left_s = float(_cfg.get("wait_hours", 1.0)) * 3600.0
	_wait_frames_ms = []
	_wait_last_us = 0
	set_input_enabled(false)
	if "refresh_scale" in air:
		air.set("refresh_scale", float(_cfg.get("wait_refresh_s", 10.0)))
	return true


func stop_wait() -> void:
	if _wait_left_s <= 0.0:
		return
	_wait_left_s = 0.0
	if "refresh_scale" in air:
		air.set("refresh_scale", 1.0)
	set_input_enabled(not _paused)
	wait_finished.emit()


## Время кадров (мс) за последнее ожидание — для замера рывков.
func wait_frame_times_ms() -> PackedFloat32Array:
	return _wait_frames_ms


func _wait_step(dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _wait_last_us > 0:
		_wait_frames_ms.append(float(now - _wait_last_us) / 1000.0)
	_wait_last_us = now
	_wait_left_s -= dt * wait_speed()
	if _wait_left_s <= 0.0 or sky.clock.hour >= SunClock.clamp_hour(1.0e9):
		stop_wait()


## Пауза (Esc): физика стоит (дерево на паузе), ввод и звук выключены.
func set_paused(on: bool) -> void:
	_paused = on
	set_input_enabled(not on)
	vario_audio.set_enabled(flying_enabled and not on)
	flight_audio.set_enabled(flying_enabled and not on)
	_sync_engine_sound_pause()


## Звук двигателя дельталёта игрока гаснет на паузе и в меню, как vario/flight_audio (TP-22).
func _sync_engine_sound_pause() -> void:
	if glider != null:
		glider.set_engine_sound_muted(_paused or not flying_enabled)


func is_paused() -> bool:
	return _paused


## В полёте (true) — ввод, прибор в углу, звук; в меню (false) — только вид.
func set_flying(on: bool) -> void:
	flying_enabled = on
	if on:
		MotionRig.attach(self)
	else:
		MotionRig.detach(self)  # меню: платформе нейтраль (MR-К1 v3)
	if not on and feed != null:
		feed.cancel()  # выход в меню из полёта: flight_finished не шлётся
	_paused = false
	glider.visible = true
	set_input_enabled(on)
	camera.set_mode(
		(
			UserSettings.start_camera()
			if on
			else String(_cfg.get("menu_camera_mode", "chase"))
		)
	)
	vario_audio.set_enabled(on)
	flight_audio.set_enabled(on)
	_sync_engine_sound_pause()
	if on:
		flight_audio.play_carabiner()
	_update_overlay()


## Пилот выбрал камеру клавишей в полёте — следующий полёт начнётся с неё (Q-09).
func _on_camera_chosen(m: String) -> void:
	if flying_enabled and not inspect_mode:
		UserSettings.save_start_camera(m)


## Осмотр карты: свободная камера, крыло скрыто и стоит, стрелки ветра включены.
func enter_inspect() -> void:
	set_flying(false)
	inspect_mode = true
	glider.visible = false
	camera.locked_free = true
	camera.set_mode("free")
	set_input_enabled(true)
	input_controller.set_mouse_captured(false)  # панель выбора старта кликается мышью
	debug_overlays.enable(PackedStringArray(["wind"]))
	_pick_enter()


## Выход из осмотра (в меню): вернуть крыло, режимы камеры и выключить стрелки ветра.
func leave_inspect() -> void:
	if not inspect_mode:
		return
	inspect_mode = false
	_pick_leave()
	camera.locked_free = false
	glider.visible = true
	if debug_overlays.wind_on:
		debug_overlays.toggle_wind()


# ------------------------------------------------ выбор старта в осмотре (SP-2)

## Выбор старта изменился (точка, курс, сброс): main сохраняет его как последний полёт.
signal pick_changed
## Текущая точка осмотра: {} (нет) или {x, z, heading, ok, reason, height_m, slope_deg, downhill_deg}.
var pick: Dictionary = {}
var _pick_marker: StartMarker
var _pick_drag := false


func _pick_enter() -> void:
	pick = {}
	if _pick_marker == null:
		_pick_marker = StartMarker.new()
		add_child(_pick_marker)
	if settings != null and settings.has_exact_start():
		var q := terrain.latlon_to_local(settings.start_lat, settings.start_lon)
		_pick_apply(q.x, q.y, settings.start_heading_deg, false)
	else:
		_pick_marker.visible = false


func _pick_leave() -> void:
	_pick_drag = false
	pick = {}
	if _pick_marker != null:
		_pick_marker.queue_free()
		_pick_marker = null


## Луч (начало, направление) → первая точка на рельефе; Vector3.INF — не попал за max_m.
static func ray_to_ground(
	height_at: Callable, origin: Vector3, dir: Vector3, max_m := 30000.0
) -> Vector3:
	var d := dir.normalized()
	if d.is_zero_approx():
		return Vector3.INF
	var step := 10.0
	var t := 0.0
	var prev := 0.0
	while t <= max_m:
		var p := origin + d * t
		if p.y <= float(height_at.call(p.x, p.z)):
			var lo := prev
			var hi := t
			for i in 20:
				var mid := 0.5 * (lo + hi)
				var q := origin + d * mid
				if q.y <= float(height_at.call(q.x, q.z)):
					hi = mid
				else:
					lo = mid
			var r := origin + d * hi
			r.y = float(height_at.call(r.x, r.z))
			return r
		prev = t
		t += step
		step = minf(step * 1.02, 100.0)
	return Vector3.INF


## Точка рельефа под экранной позицией (при захваченной мыши — центр экрана).
func pick_ground_at_screen(pos: Vector2) -> Vector3:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		pos = get_viewport().get_visible_rect().size * 0.5
	return ray_to_ground(
		terrain.height_at, camera.project_ray_origin(pos), camera.project_ray_normal(pos)
	)


## Новая точка: курс вниз по склону. Недопустимая — маркер красный, старт сбрасывается.
func pick_point(x: float, z: float) -> void:
	var chk := StartSpot.check(terrain, x, z)
	_pick_apply(x, z, float(chk.downhill_deg), true)


## Курс к точке (x, z) на земле (протяжка мышью).
func pick_heading_to(x: float, z: float) -> void:
	if pick.is_empty():
		return
	var dx := x - float(pick.x)
	var dz := z - float(pick.z)
	if dx * dx + dz * dz < 1.0:
		return
	_pick_apply(float(pick.x), float(pick.z), rad_to_deg(atan2(dx, -dz)), true)


func pick_turn(delta_deg: float) -> void:
	if not pick.is_empty():
		_pick_apply(float(pick.x), float(pick.z), float(pick.heading) + delta_deg, true)


func pick_downhill() -> void:
	if not pick.is_empty():
		_pick_apply(float(pick.x), float(pick.z), float(pick.downhill_deg), true)


## «Сбросить старт»: автостарт места.
func pick_clear() -> void:
	pick = {}
	if settings != null:
		settings.clear_exact_start()
	if _pick_marker != null:
		_pick_marker.visible = false
	pick_changed.emit()


func _pick_apply(x: float, z: float, heading: float, notify: bool) -> void:
	var chk := StartSpot.check(terrain, x, z)
	heading = fposmod(heading, 360.0)
	pick = chk.duplicate()
	pick.x = x
	pick.z = z
	pick.heading = heading
	var ll0 := terrain.local_to_latlon(x, z)
	pick.lat = ll0.x
	pick.lon = ll0.y
	if _pick_marker != null:
		_pick_marker.show_spot(Vector3(x, float(chk.height_m), z), heading, bool(chk.ok))
	if settings != null:
		if bool(chk.ok):
			var ll := terrain.local_to_latlon(x, z)
			settings.set_exact_start(ll.x, ll.y, heading)
		else:
			settings.clear_exact_start()
	if notify:
		pick_changed.emit()


func _pick_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pick_drag = event.pressed
		if event.pressed:
			var g := pick_ground_at_screen(event.position)
			if g != Vector3.INF:
				pick_point(g.x, g.z)
	elif event is InputEventMouseMotion and _pick_drag and not pick.is_empty():
		var p := Vector2(event.position)
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_pick_drag = false
			return
		var g := pick_ground_at_screen(p)
		if g != Vector3.INF:
			pick_heading_to(g.x, g.z)


## Ввод игрока и обзор мышью (выключается на паузе и на экране итога).
func set_input_enabled(on: bool) -> void:
	input_controller.enabled = on
	camera.look_enabled = on
	_update_overlay()
	if not on:
		input_controller.set_mouse_captured(false)
	elif bool(Config.value("controls", "mouse.capture_on_start")):
		input_controller.set_mouse_captured(true)


## Настройки пилота поменялись (user://configs): перечитать то, что закешировано в нодах.
## Графика: небо, облака и окно — сразу; деревья — при следующей загрузке рельефа.
func apply_user_settings() -> void:
	# Масштаб окна (пресет и/или «Масштаб рендера» из настроек) — сразу, вне зависимости от
	# того, поменялся ли сам пресет.
	GraphicsPresets.apply_viewport(get_viewport())
	sky.apply_fog_sun_scatter()
	if GraphicsPresets.current() != _graphics:
		if _graphics != "":
			sky.apply_config()
			var clouds := air.get_node_or_null("Clouds")
			if clouds != null and clouds.has_method("set_quality"):
				clouds.call("set_quality", String(Config.value("atmosphere", "clouds.quality")))
			_terrain_dirty = true
		_graphics = GraphicsPresets.current()
	input_controller.reload_config()
	sky.clock.reload_config()
	_lock_net_clock()
	_air_rebase_clock()
	var va: Dictionary = Config.get_config("audio").get("vario_audio", {})
	vario_audio.set_volume_db(float(va.get("volume_db", -6.0)))
	if va.has("preset") and vario_audio.has_method("set_preset"):
		vario_audio.call("set_preset", String(va.preset))
	if pilot_voice != null:
		pilot_voice.set_voice(String(Config.value("pilot_voice", "voice", "male")))


func next_instrument_page() -> void:
	instrument.next_page()


func get_start() -> Dictionary:
	return {"position": _start_pos, "heading_deg": _start_heading}


func _unhandled_input(event: InputEvent) -> void:
	if inspect_mode:
		_pick_input(event)
	if not flying_enabled:
		return
	if event.is_action_pressed("instrument_page"):
		next_instrument_page()
		get_viewport().set_input_as_handled()
		return
	# Клавиши 1…N — страница напрямую (controls.json → instrument_page_1…).
	var i := 1
	while InputMap.has_action("instrument_page_%d" % i):
		if event.is_action_pressed("instrument_page_%d" % i):
			instrument.set_page(i - 1)
			get_viewport().set_input_as_handled()
			return
		i += 1


## Ключ мира текущего полёта (FlightSettings.world_key; сид < 0 — atmosphere.json → seed): по
## нему день повторяется (--seed и те же место, дата, время и погода). "" — мир не загружен.
func world_key() -> String:
	if settings == null:
		return ""
	var sd := world_seed if world_seed >= 0 else int(Config.value("atmosphere", "seed", 0))
	return settings.world_key(sd, bots.agents.size())


# ---------------------------------------------------------------- сеть (NET-40)


## Включить сетевой режим (до start()): NetFlight — в мир, часы ×1.
func enable_net(n: NetFlight, zone: Object = null, pilots: Object = null) -> void:
	disable_net()
	net = n
	add_child(n)
	n.setup(self, zone, pilots)
	_lock_net_clock()


## Выключить сетевой режим (вышли из зоны): чужих убрать, часы — снова из настроек.
func disable_net() -> void:
	if net == null:
		return
	net.teardown()
	net.queue_free()
	net = null
	sky.clock.reload_config()


## Время мира (атмосферы), с — в сети идёт вровень с часами зоны.
func world_time() -> float:
	return _air_t


## Разбился (препятствие или авария на касании) — для фазы CRASHED в сети.
func is_crashed() -> bool:
	return _crashed or String(_touchdown.get("grade", "")) == "crash"


## «Продолжить рядом» (итог полёта в сети): один живой друг в воздухе — буксир к нему (true).
## Нескольких — false: главная сцена открывает меню «Догнать»; никого — false.
func catch_up_nearest() -> bool:
	if net == null:
		return false
	var list := net.catch_up_list()
	if CatchUpMenu.airborne_count(list) != 1:
		return false
	var id := CatchUpMenu.pick_nearest_airborne_human(list, glider.model.position)
	return start_catch_up(net.target_fn(id))


## «Догнать» пилота id (меню `=`): в воздухе — буксир к нему ("tow"); на земле — на старт
## ("launch", NET-43: в конец очереди); нет такого — ничего ("").
func catch_up_to(id: String) -> String:
	if net == null:
		return ""
	match net.target_state(id):
		"air":
			return "tow" if start_catch_up(net.target_fn(id)) else ""
		"ground":
			return_to_launch()  # цель на земле — в конец очереди на старт (NET-43)
			return "launch"
	return ""


## Буксир к цели target_fn() -> {position, velocity} ({} — цель ушла/села) — откуда угодно: из
## воздуха, со старта, с посадки, после аварии (крыло поднимается с места). false — цели нет.
func start_catch_up(target_fn: Callable) -> bool:
	if settings == null:
		return false
	var m = glider.model
	var vel: Vector3 = m.velocity if m.mode == FlightModel.Mode.AIR else Vector3.ZERO
	var t := CatchUpTow.new({}, terrain.height_at)
	t.start(m.position, vel, target_fn, m.heading)
	if not t.is_active():
		return false
	tow = t
	_update_overlay()
	MotionRig.reset()  # разрыв потока (MR-К1 v3): на буксире — hold
	_crashed = false
	_ended = true  # на буксире итога полёта нет
	_leave_queue_for_tow()
	catch_up_started.emit()
	return true


## Отмена буксира (Esc / `=`): физика возвращается на месте.
func abort_catch_up() -> void:
	if tow == null:
		return
	tow.abort()
	_end_catch_up(tow.last)


func is_towing() -> bool:
	return tow != null


## Игрок в очереди на старт уходит из неё, когда буксир поднимает его с земли (NET-43).
func _leave_queue_for_tow() -> void:
	queue_walk = {}
	if net != null:
		net.leave_queue()


## Очередь на старт (сеть, NET-43): пойти к месту ожидания spot {position, heading_deg}.
func queue_walk_to(spot: Dictionary) -> void:
	queue_walk = spot


## Шаг ходьбы к месту в очереди: управление — как у ботов (BotAgent.walk_control); пилот сам
## пошёл или побежал, оторвался, буксир — ходьба отменяется.
func _queue_walk_step(c: ControlInput, phase: String) -> void:
	if tow != null or not phase in ["standing", "walking"] or c.run or c.walk != 0.0:
		queue_walk = {}
		return
	var p: Vector3 = queue_walk.position
	if BotAgent.walk_control(glider.get_telemetry(), p, float(queue_walk.heading_deg), c):
		queue_walk = {}


## Шаг буксира: крыло — куда скажет CatchUpTow, камера сзади — вплотную; кончился — пилоту.
func _tow_step(dt: float) -> void:
	var r := tow.step(dt)
	if not bool(r.active):
		_end_catch_up(r)
		return
	camera.tight = true
	glider.set_kinematic(
		r.position, r.velocity, r.heading, r.bank, r.basis, minf(float(r.speed), TOW_FLOW_CAP_MS)
	)


## Буксир кончился (прибыли, отмена, цель потеряна): крыло на месте на триммерной скорости
## (у самой земли — стоит), физика и столкновения снова считаются, статистика — с этой точки.
func _end_catch_up(r: Dictionary) -> void:
	tow = null
	_update_overlay()
	feed.cancel()
	camera.tight = false
	var pos: Vector3 = r.position
	var heading_deg := rad_to_deg(float(r.heading))
	MotionRig.reset()
	_prev_phase = ""
	if pos.y - terrain.height_at(pos.x, pos.z) < TOW_GROUND_AGL_M:
		glider.reset_on_ground(pos, heading_deg)
	else:
		glider.reset_in_air(pos, heading_deg)
	input_controller.reset()
	collisions.reset()
	_crashed = false
	_ended = false
	_touchdown = {}
	_recentered = false
	stats.reset(pos)
	stats.armed = glider.phase() == "flying"
	instrument.reset()
	_goals_reset()
	catch_up_ended.emit(String(r.get("state", "")))


## «На старт» (итог полёта в сети): снова на старт, мир не сбрасывается; в сети — в конец
## очереди на старт (restart ставит на место: не в очереди — конец живых пилотов, NET-43).
func return_to_launch() -> void:
	restart()


## Шаг мира в сети: воздух — по часам зоны (NetFlight.world_dt), часы суток — от времени
## атмосферы (Weather.hour_at): после паузы и долгих кадров время не прыгает относительно зоны.
func _net_world_step(dt: float) -> void:
	_air_advance(net.world_dt(dt))
	if _day_on:
		sky.clock.set_hour(_day_hour_at(world_time()))
	else:
		sky.clock.advance(dt)


## В сети время только ×1 (часы зоны идут ×1 у всех).
func _lock_net_clock() -> void:
	if net != null:
		sky.clock.speed = 1.0


# ---------------------------------------------------------------- сборка


func _create_air() -> Node3D:
	var a: Dictionary = _cfg.get("air", {})
	for key in ["script", "fallback_script"]:
		var path := String(a.get(key, ""))
		if path == "" or not ResourceLoader.exists(path):
			push_warning("Game: нет модели воздуха %s" % path)
			continue
		var scr := load(path) as Script
		if scr == null or not scr.can_instantiate():
			push_warning("Game: модель воздуха %s не загрузилась" % path)
			continue
		var n: Object = scr.new()
		if n is Node3D and n.has_method("air_velocity_at"):
			return n
		push_warning("Game: %s — не модель воздуха" % path)
	return CalmAir.new()


func _load_terrain() -> bool:
	_load_error = ""
	var ok := true
	var what := ""
	if settings.has_pick():
		what = "%.4f, %.4f" % [settings.pick_lat, settings.pick_lon]
		# Точка внутри встроенного места — оно и грузится (старт — в точке); иначе место точки:
		# из кеша user://locations или сборка (OA-К4), дальше тот же load_location.
		var builtin := Locations.builtin_at(settings.pick_lat, settings.pick_lon)
		var id := (
			builtin if builtin != "" else LocationCache.key_for(settings.pick_lat, settings.pick_lon)
		)
		if terrain.location_id == id and not terrain.layers.is_empty() and not _terrain_dirty:
			return true  # то же место уже стоит
		if builtin != "":
			await terrain.load_builtin(builtin)
			ok = _load_error == "" and not terrain.layers.is_empty()
			_terrain_dirty = not ok
		else:
			await terrain.load_point(settings.pick_lat, settings.pick_lon, "", settings.has_air_start())
			ok = _load_error == "" and not terrain.layers.is_empty()
			_terrain_dirty = not ok
	elif (
		terrain.location_id == settings.location_id
		and not terrain.layers.is_empty()
		and not _terrain_dirty
	):
		return true
	else:
		what = settings.location_id
		if Locations.is_builtin(settings.location_id):
			await terrain.load_builtin(settings.location_id)
			ok = _load_error == "" and not terrain.layers.is_empty()
		else:
			ok = bool(terrain.load_location(settings.location_id)) and not terrain.layers.is_empty()
		_terrain_dirty = not ok
	if not ok:
		# Рельеф не всегда говорит причину (например, скрипт не собрался) — объясняем сами.
		var why := (
			_load_error if _load_error != "" else tr("status_terrain_module_error")
		)
		# точка с карты: рельеф уже объяснил простыми словами (море, нет сети, нет данных)
		if not (settings.has_pick() and _load_error != ""):
			_load_error = tr("status_terrain_failed_detail") % [what, why]
		push_error("Game: рельеф не загружен: " + _load_error)
	return ok


## Источник старта в воздухе на полёт (ASM-К2): флаг --air-start, иначе выбор игрока, иначе с земли.
func _choose_air_start() -> void:
	if cli_air_start_m >= 0.0:
		air_start_m = cli_air_start_m
		air_start_agl_m = cli_air_start_agl_m
	elif menu_air_allowed and net == null and not inspect_mode and settings.has_air_start():
		air_start_m = 0.0
		air_start_agl_m = settings.air_start_agl_m
	else:
		air_start_m = -1.0


func _choose_start() -> void:
	_exact_start = false
	_tow_site = {}
	_trike_start = false
	if _choose_tow_start():
		return
	if settings.has_exact_start():
		var q := terrain.latlon_to_local(settings.start_lat, settings.start_lon)
		var chk := StartSpot.check(terrain, q.x, q.y)
		# В воздухе над озером, кратером, обрывом можно: отказ только «вне карты» (ASM-К2)
		if bool(chk.ok) or (air_start_m >= 0.0 and chk.reason != "outside"):
			_start_pos = Vector3(q.x, terrain.height_at(q.x, q.y), q.y)
			_start_heading = settings.start_heading_deg
			_exact_start = true
			if air_start_m < 0.0:
				_clear_exact_start(q)
			return
		push_warning("Game: точный старт недопустим (%s), автостарт" % chk.reason)
	if settings.has_pick():
		var p := terrain.latlon_to_local(settings.pick_lat, settings.pick_lon)
		var cfg: Dictionary = _cfg.start_search
		var launch := StartPlacement.evaluate(terrain.height_at, p.x, p.y, cfg)
		_start_pos = launch.position
		_start_heading = float(launch.heading_deg)
		# Пустырь вокруг старта (≥ 2 длины разбега): в лесу иначе не разбежаться и не набрать
		# высоту до крон (docs/guide/game.md → «Старт с карты»).
		if air_start_m < 0.0:
			terrain.add_start_clearing(_start_pos.x, _start_pos.z, float(cfg.clearing_radius_m))
		return
	var sites := terrain.get_start_sites()
	if sites.is_empty():
		_start_pos = Vector3(0, terrain.height_at(0, 0), 0)
		_start_heading = 0.0
		return
	var site: Dictionary = sites[0]
	for st in sites:
		if st.id == settings.site_id:
			site = st
	_start_pos = site.position
	_start_heading = float(site.heading_deg)
	MotionRig.place = String(site.get("name", settings.location_id)) if site.get("name") is String else settings.location_id


## Старт со статической лебёдки (TW-10, TW-К6/К7, TA-К2): настройка tow_kind, «Маятник», одиночная игра; рельеф не
## проверяется (берутся начало линии и курс из TowSite.check). Площадка с блоком tow — её ось и размеры; точка с карты и точный старт — курс выбранный, длина троса
## из configs/tow.json. Не вышло (сеть, воздух, нечисловые входы) — обычный старт без буксировки. aerotow (TW-10b) — та же
## полоса, но старт пилота на тележке в начале, Ан-2 впереди на длину троса.
func _choose_tow_start() -> bool:
	var trike := settings.vehicle == "trike"
	var kind := "aerotow" if trike else settings.tow_kind  # дельталёт: полоса как у аэробуксировки, без троса
	if kind == "":
		return false
	if kind != "winch_static" and kind != "aerotow":
		push_warning("Game: буксировка %s неизвестна, старт без буксировки" % kind)
		return false
	if net != null or air_start_m >= 0.0:
		push_warning("Game: буксировка — только одиночная игра с земли, старт без буксировки")
		return false
	var rope_len := float(Config.value("tow", "%s.%s" % [kind, "rope_length_m" if kind == "winch_static" else "runway_length_m"], 1000.0))
	var x := 0.0
	var z := 0.0
	var heading := 0.0
	var length := rope_len
	var width := TOW_DEFAULT_WIDTH_M
	var site_name := ""
	var q := Vector2.ZERO
	var from_site := false
	var no_tow_site := false  # площадка без блока tow (или место без площадок): поляну вырубаем
	if settings.has_exact_start() or settings.has_pick():
		if settings.has_exact_start():
			q = terrain.latlon_to_local(settings.start_lat, settings.start_lon)
			heading = settings.start_heading_deg
		else:
			q = terrain.latlon_to_local(settings.pick_lat, settings.pick_lon)
			heading = (
				settings.start_heading_deg
				if is_finite(settings.start_heading_deg)
				else float(StartPlacement.evaluate(terrain.height_at, q.x, q.y, _cfg.start_search).heading_deg)
			)
		x = q.x
		z = q.y
		for st in terrain.get_start_sites():  # точный старт на площадке с tow — её ось и размеры
			var tw: Dictionary = st.get("tow", {})
			if (
				settings.has_exact_start()
				and not tw.is_empty()
				and Vector2(st.position.x, st.position.z).distance_to(q) <= 5.0
			):
				heading = float(st.heading_deg)
				length = float(tw.runway_length_m)
				width = float(tw.runway_width_m)
	else:
		var sites := terrain.get_start_sites()
		var tw: Dictionary = {}
		if sites.is_empty():  # места без площадок — (0, h, 0), курс 0
			x = 0.0
			z = 0.0
			heading = 0.0
		else:
			var site: Dictionary = sites[0]
			for st in sites:
				if st.id == settings.site_id:
					site = st
			tw = site.get("tow", {})
			x = site.position.x
			z = site.position.z
			heading = float(site.heading_deg)
			if not tw.is_empty():
				length = float(tw.get("runway_length_m", length))
				width = float(tw.get("runway_width_m", width))
			from_site = true
			site_name = String(site.get("name", settings.location_id)) if site.get("name") is String else settings.location_id
		no_tow_site = tw.is_empty()
	if not (is_finite(x) and is_finite(z) and is_finite(heading) and is_finite(length) and is_finite(width)):
		push_warning("Game: буксировка — нечисловые входы, старт без буксировки")
		return false
	# TA-К2: рельеф не проверяется — берутся начало линии и курс; ok игнорируется
	var chk := TowSite.check(terrain, x, z, heading, length, width)
	_start_pos = chk.start_pos
	_start_heading = float(chk.heading_deg)
	_exact_start = true  # курс — ось полосы, по ветру не выравнивается
	_trike_start = trike
	_tow_site = chk
	_tow_site["width_m"] = width
	_tow_site["length_m"] = length
	if from_site:
		MotionRig.place = site_name
		if no_tow_site:
			_clear_tow_runway()
	elif no_tow_site:
		_clear_tow_runway()
	elif settings.has_exact_start():
		_clear_exact_start(q)
		if not _site_has_tow_at(q):
			_clear_tow_runway()
	else:
		_clear_tow_runway()  # точка с карты: лес на полосе лебёдки — иначе не разогнаться и не набрать высоту
	return true


func _site_has_tow_at(q: Vector2) -> bool:
	for st in terrain.get_start_sites():
		var tw: Dictionary = st.get("tow", {})
		if not tw.is_empty() and Vector2(st.position.x, st.position.z).distance_to(q) <= 5.0:
			return true
	return false


## Поляна-полоса вдоль оси _tow_site: от старта на длину до лебёдки, шириной полосы (TW-К6, как TowSite.clearing_size).
func _clear_tow_runway() -> void:
	var margin := float(Config.value("game", "tow_site.clearing_margin_m", 30.0))
	terrain.add_runway_clearing(
		_start_pos,
		_start_heading,
		float(_tow_site.get("length_m", Config.value("tow", "winch_static.rope_length_m", 1000.0))),
		float(_tow_site.get("width_m", TOW_DEFAULT_WIDTH_M)) + 2.0 * margin
	)


## Узел буксировки на старт полёта (после _setup_glider): старый — убрать; нет места полосы — внешней силы нет.
func _make_tow_session() -> void:
	if tow_session != null:
		tow_session.queue_free()
		tow_session = null
	if _trike_start:
		return  # TP-К6: внешняя сила дельталёта - его тяга (Glider.setup_trike), троса нет
	glider.clear_external_force()
	if _tow_site.is_empty():
		return
	tow_session = TowSession.new()
	tow_session.name = "TowSession"
	add_child(tow_session)
	tow_session.setup(glider, Callable(terrain, "height_at"), _tow_site, settings.tow_kind)


## Боты на буксирном месте стартуют в воздухе над полосой на высоте отцепа (Q1): opts для setup_in_world_async.
func _tow_bots_opts() -> Dictionary:
	if tow_session == null:
		return {}
	var l := tow_session.rope_length_m()
	if tow_session.is_aerotow():
		l = float(_tow_site.get("length_m", l))  # трос 80 м — полоса много длиннее: боты над всей полосой
	return {
		"agl_m": tow_session.release_height_m(),
		"ahead_m": [0.2 * l, 0.8 * l],
		"lateral_m": 0.5 * float(_tow_site.get("width_m", TOW_DEFAULT_WIDTH_M)),
	}


## Шаг лебёдки до glider.step: старт — W (на геймпаде — кнопка разбега; Shift трос не запускает), tow_release (B / кнопка геймпада) — отцеп.
func _winch_step(dt: float, c: ControlInput) -> void:
	var start := false
	var release := false
	if input_controller.enabled and not hands_off:
		start = _action_held("walk_forward") or input_controller.pad_run or c.walk > 0.0  # c.walk — автопилот
		release = InputMap.has_action("tow_release") and Input.is_action_just_pressed("tow_release")
	tow_session.step(dt, start, release)


static func _action_held(action: String) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


## Поляна точного старта: у встроенной площадки с блоком tow (в пределах 5 м) — полоса вдоль оси
## (TW-К6, ось — heading_deg площадки, не курс пилота; запас по ширине — game.json → tow_site.clearing_margin_m), иначе круг.
func _clear_exact_start(q: Vector2) -> void:
	for st in terrain.get_start_sites():
		var tow: Dictionary = st.get("tow", {})
		if tow.is_empty() or Vector2(st.position.x, st.position.z).distance_to(q) > 5.0:
			continue
		var dim := TowSite.clearing_size(tow)
		if dim.x > 0.0:
			terrain.add_runway_clearing(
				Vector3(q.x, terrain.height_at(q.x, q.y), q.y), float(st.heading_deg), dim.x, dim.y
			)
			return
	terrain.add_start_clearing(q.x, q.y, Terrain.start_clearing_radius_m())


func _setup_glider() -> void:
	for n in mounted:
		n.queue_free()
	mounted.clear()
	var wing_id := settings.wing_id()
	if _trike_start:
		glider.setup_trike(Config.get_config("tow_tug"), settings.pilot_mass_kg, Config.get_config("trike_pilot"))
		input_controller.vehicle = "trike"
	else:
		glider.setup(wing_id, settings.pilot_mass_kg, settings.resolved_apparatus(wing_id))
		settings.pilot_mass_kg = glider.pilot_mass_kg
		input_controller.vehicle = "glider"
	camera.set_head(glider.get_marker("PilotHead"))
	camera.eye_offset_enabled = not glider.is_trike()
	trike_gauges = null
	_sync_engine_sound_pause()
	# Смещение центра масс пилота от подвески в полёте (крен/тангаж ручкой), оси планера: голова
	# кабинной камеры повторяет его долей (camera.json → cockpit.head_follow_body). На земле — ноль.
	var v := glider.visual
	camera.body_shift_fn = func() -> Vector3:
		if glider.phase() != "flying" or not is_instance_valid(v):
			return Vector3.ZERO
		return v.body_shift
	_hide_from_cockpit()
	if v != null:
		v.set_wrist_clock(sky.clock)  # наручные часы — время игры (PH-7)
	if v != null and v.sky_shade != null:
		v.sky_shade.env_fn = _sky_shade_env
	if glider.is_trike():
		_mount_trike_gauges()  # маркеров крыла дельтаплана у дельталёта нет
	else:
		for m: Dictionary in _cfg.get("mounted_instruments", []):
			_mount_instrument(m)
	_animator.bind(glider.visual, _cfg.get("pilot_animation", {}))
	camera.glance_target = null  # Q: середина смонтированных приборов; кадры (--look-at) задают свою цель
	camera.glance_nodes.clear()
	for inst: Node in mounted:
		camera.glance_nodes.append(inst as Node3D)


## Освещение для тени от неба (SkyShade.env_fn): sin высоты солнца и облачность прогноза.
func _sky_shade_env() -> Vector2:
	var sin_el := 1.0
	if sky != null and sky.sun != null:
		sin_el = maxf(sky.sun.global_transform.basis.z.y, 0.0)
	var cover := 0.0
	var w: Variant = _air_weather() if air != null else null
	if w is Dictionary and (w as Dictionary).has("_derived"):
		var dv: Dictionary = (w as Dictionary)["_derived"]
		if dv.has("sky"):
			cover = float(Weather.sky_params(String(dv.sky)).get("cover", 0.0))
	return Vector2(sin_el, cover)


## Флажки «Часы»/«Компас» на лету: наручные приборы перечитывают ui.json (PH-7).
func _reload_wrist() -> void:
	if glider != null and glider.visual != null and glider.visual.wrist != null:
		glider.visual.wrist.reload()


## Шлем и т. п. (camera.json → cockpit.hidden_nodes) — на слой, который кабина не рисует.
func _hide_from_cockpit() -> void:
	var ck: Dictionary = Config.get_config("camera").cockpit
	var bit := 1 << (int(ck.get("hidden_layer", 20)) - 1)
	if glider.trike_visual != null:  # дельталёт: пилот целиком не виден из кабины
		glider.trike_visual.set_pilot_layers(bit)
	for node_name: String in ck.get("hidden_nodes", []):
		for n in glider.find_children(node_name, "VisualInstance3D", true, false):
			(n as VisualInstance3D).layers = bit


## TP-К8: приборы дельталёта на маркер InstrumentPanel тележки (нормаль панели - +Z маркера, TP-К4).
func _mount_trike_gauges() -> void:
	var panel := glider.get_marker("InstrumentPanel")
	var path := "res://scenes/instruments/trike_gauges_3d.tscn"
	if panel == null or not ResourceLoader.exists(path):
		push_warning("Game: у дельталёта нет маркера InstrumentPanel или сцены приборов")
		return
	trike_gauges = (load(path) as PackedScene).instantiate() as TrikeGauges3D
	panel.add_child(trike_gauges)
	# маркер лежит в толще плиты панели - вынести приборы к её лицу (configs/instruments.json -> panel_3d.mount_z_m)
	var p3: Dictionary = GaugeDial.scales()["panel_3d"]
	trike_gauges.position.z = float(p3.get("mount_z_m", 0.0))
	mounted.append(trike_gauges)


## TKF-К3: струя винта дельталёта игрока по траве. Центр диска - узел Propeller тележки (иначе ось винта на
## prop_axis_below_hang_m ниже подвески), струя - назад по продольной оси тележки (+Z тележки).
func _update_trike_wash() -> void:
	if not glider.is_trike() or glider.trike == null or glider.trike_visual == null:
		return
	var cart := glider.trike_visual.cart
	if cart == null or not cart.is_inside_tree():
		return
	var prop := cart.find_child("Propeller", true, false) as Node3D
	var pos := prop.global_position if prop != null else cart.global_position - cart.global_basis.y * 1.4
	terrain.set_wash(pos, cart.global_basis.z.normalized(), glider.trike.thrust_n)


## Обороты и топливо - приборам (кабина и HUD), TP-К4.
func _update_trike_gauges() -> void:
	if not glider.is_trike() or glider.engine == null:
		return
	var e := glider.engine
	if is_instance_valid(trike_gauges):
		trike_gauges.update_readout(e.engine_rpm, e.fuel_l, e.tank_l, e.running)
	if trike_hud != null:
		trike_hud.update_readout(e.engine_rpm, e.fuel_l, e.tank_l, e.running)


## Прибор на маркер крыла (game.json → mounted_instruments).
func _mount_instrument(m: Dictionary) -> void:
	var optional := bool(m.get("optional", false))
	var path := String(m.get("scene", ""))
	if not ResourceLoader.exists(path):
		if not optional:
			push_warning("Game: нет сцены прибора %s" % path)
		return
	var mount := glider.get_marker(String(m.get("marker", "")))
	if mount == null:
		if optional:
			return
		push_warning("Game: у крыла нет маркера %s — прибор на планере" % m.get("marker"))
		mount = glider
	var inst := (load(path) as PackedScene).instantiate()
	if not inst is Node3D:
		if not optional:
			push_warning("Game: %s — не Node3D, на трапецию не повесить" % path)
		inst.free()
		return
	mount.add_child(inst)
	mounted.append(inst)
	inst.set_meta("marker", String(m.get("marker", "")))
	inst.set_meta("shares_tablet", bool(m.get("shares_tablet", false)))
	# Маркер: −Z смотрит на глаза пилота; сцена прибора может рисовать экран иначе.
	(inst as Node3D).rotation.y = deg_to_rad(float(m.get("rotate_y_deg", 0.0)))
	if bool(m.get("shares_tablet", false)) and inst.has_method("use_instrument"):
		inst.call("use_instrument", instrument)


func _update_overlay() -> void:
	# Прибор в углу — только в полёте во внешних камерах (не в меню, не на паузе).
	overlay.visible = flying_enabled and input_controller.enabled and camera.mode != "cockpit"
	if shift_indicator != null:  # индикатор смещения — во всех камерах, не в меню и не на буксире
		shift_indicator.set_active(flying_enabled and input_controller.enabled and tow == null)
	if clock_label != null:  # часы текстом — только в 3-м лице (PH-К2)
		clock_label.set_active(flying_enabled and input_controller.enabled and camera.mode != "cockpit")
	if trike_hud != null:  # приборы дельталёта - только у него и не из кабины (TP-К8)
		trike_hud.set_active(
			glider != null and glider.is_trike() and flying_enabled and input_controller.enabled and camera.mode != "cockpit"
		)
	if goal_list != null:  # список целей — в любой камере, пока есть цели
		goal_list.set_active(flying_enabled and input_controller.enabled and goals != null)


# ---------------------------------------------------------------- сигналы планера


## Подошвы пилота для шуршания о траву (PH-4, PH-К6): [{clearance_m, speed_ms, grass_h_m}].
## Скорость — по смещению подошв между шагами физики; пусто, если трава выключена, пилот выше
## flight.rustle.feet_max_agl_m или скелета нет.
func _rustle_feet(t: Telemetry) -> Array:
	var out: Array = []
	var rc: Dictionary = Config.get_config("audio").get("flight", {}).get("rustle", {})
	var feet := PackedVector3Array()
	if (
		terrain.grass != null
		and is_instance_valid(glider.visual)
		and t.altitude_agl <= float(rc.get("feet_max_agl_m", 2.0))
	):
		feet = glider.visual.feet_positions()
	var now := Time.get_ticks_usec()
	var dt := float(now - _feet_prev_usec) * 1e-6
	for i in feet.size():
		var p := feet[i]
		var speed := _feet_speed[i] if i < _feet_speed.size() else 0.0
		if i < _feet_prev.size() and dt > 0.001 and dt < 0.5:
			speed = (p - _feet_prev[i]).length() / dt
		var gh := terrain.grass.height_at(p.x, p.z)
		out.append(
			{
				"clearance_m": p.y - terrain.height_at(p.x, p.z),
				"speed_ms": speed,
				"grass_h_m": gh,
			}
		)
	if dt > 0.001 or feet.is_empty():
		_feet_prev = feet
		_feet_prev_usec = now
		_feet_speed.resize(out.size())
		for i in out.size():
			_feet_speed[i] = out[i].speed_ms
	return out


func _voice_reset() -> void:
	if pilot_voice != null:
		pilot_voice.reset()


func _voice_event(event_name: String, data := {}) -> void:
	if pilot_voice != null:
		pilot_voice.on_event(event_name, data)


## Реплики пилота (PV-К1): только свой дельтаплан, время ×1, не осмотр, не буксир.
func _voice_update(t: Telemetry) -> void:
	if pilot_voice == null:
		return
	pilot_voice.set_suppressed(
		net != null or glider.is_trike() or inspect_mode or not is_equal_approx(sky.clock.speed, 1.0)
	)
	pilot_voice.update(t, _sound_vario().vario_ms, _whiteout.amount, _dt)
	pilot_voice.watch_eggs(camera, eggs.active(), _dt)


func _on_telemetry(t: Telemetry) -> void:
	_update_trike_gauges()
	_update_trike_wash()
	if tow != null:  # буксир: без приборов и статистики, писк молчит, поток — по скорости
		vario_audio.set_vario(0.0)
		flight_audio.update(t, {"phase": t.phase, "stall_amount": 0.0, "load_factor": 1.0})
		_animator.update(t.phase, t.altitude_agl, 0.0, 0.0, _dt)
		return
	_tracks_record(t)
	instrument.update(t, _dt)
	shift_indicator.update(t)
	for n in mounted:
		if not bool(n.get_meta("shares_tablet", false)) and n.has_method("update"):
			n.call("update", t, _dt)
	vario_audio.set_vario(_sound_vario().vario_ms)
	var extra := {
		"phase": t.phase, "stall_amount": 1.0 if t.stalled else 0.0, "load_factor": t.load_factor
	}
	if t.on_ground and air.has_method("mean_wind_at"):
		extra["ground_wind_ms"] = (air.call("mean_wind_at", t.position) as Vector3).length()
	extra["feet"] = _rustle_feet(t)
	flight_audio.update(t, extra)
	_voice_update(t)
	stats.flight_position_started = glider.model.flight_position_started  # FB-К2
	stats.update(t, _dt)
	# Старт в воздухе (reset_in_air: тесты, «свободный полёт»): взлёта со склона не было —
	# полёт сразу засчитан, касание будет посадкой, а не «взлёт сорван».
	if t.phase == "flying" and not (_prev_phase in ["flying", "running", "walking"]):
		stats.armed = true
	_prev_phase = t.phase
	_goals_update(t)
	_animator.update(t.phase, t.altitude_agl, t.vario, glider.model.flare_amount(), _dt)


## Нужен ли recenter камеры при отрыве: дельтаплан — всегда; дельталёт — только первый отрыв с разбега
## (подскоки на колёсах шлют took_off на каждом отрыве, взгляд пилота не сбрасываем).
static func recenter_on_takeoff(trike: bool, already: bool) -> bool:
	return not (trike and already)


## Отрыв (glider.took_off): взгляд по центру (как средняя кнопка), начало потока ачивок.
func _on_took_off() -> void:
	if tow == null:
		_voice_event("took_off", {"altitude_msl": glider.get_telemetry().altitude_msl})
	if recenter_on_takeoff(glider.is_trike(), _recentered):
		camera.recenter()
	_recentered = true
	_feed_begin()


## Отрыв (glider.took_off) и старт в воздухе: начало потока для ачивок.
func _feed_begin() -> void:
	if not _ended and tow == null and not inspect_mode and not is_air_start():  # ASM-К4: в воздухе ачивки не идут
		feed.begin(glider.get_telemetry())


func _feed_step(dt: float) -> void:
	var t := glider.get_telemetry()
	if t.phase == "flying" and not feed.active:
		_feed_begin()  # старт в воздухе: took_off не было
	if feed.active and t.phase == "flying":
		feed.tick(dt, t)


## Поток ачивок → автозагрузка Achievements (ST-6); её нет — вызовов нет (тесты игры).
func _connect_achievements() -> void:
	var ach := get_node_or_null("/root/Achievements")
	if ach == null:
		return
	if ach.has_method("on_flight_started"):
		feed.flight_started.connect(Callable(ach, "on_flight_started"))
	if ach.has_method("on_flight_sample"):
		feed.flight_sample.connect(Callable(ach, "on_flight_sample"))
	if ach.has_method("on_flight_finished"):
		feed.flight_finished.connect(Callable(ach, "on_flight_finished"))


## Касание: звук — на каждом касании (у дельталёта и на подскоках), оценка перезаписывается — итог по последнему.
## Касание ногами: звук и оценка сейчас, итог — когда FlightStats засчитает посадку.
func _on_landed(result: Dictionary) -> void:
	flight_audio.play_landing(result)
	if tow == null:
		_voice_event("landed", {"grade": String(result.get("grade", ""))})
	_touchdown = result.duplicate()


## Итог — только когда FlightStats считает полёт законченным (FR-27b): посадка удержана
## LANDING_CONFIRM_S и полёт был «взведён»; касание до взведения — "takeoff_failed".
## Авария на касании — всегда "landed" с grade "crash".
func _check_finished() -> void:
	if _ended or not stats.is_finished():
		return
	var t := glider.get_telemetry()
	var kind := stats.finish_reason()
	var info := _touchdown.duplicate()
	if kind == "takeoff_failed" and String(info.get("grade", "")) == "crash":
		kind = "landed"
	if kind == "takeoff_failed":
		info["reason"] = "short_flight"
		info["text"] = tr("launch_fail_touchdown")
	# Сводка — целиком из FlightStats (поверх flight_time_s касания: после reset_in_air
	# время модели обнуляется и было бы занижено).
	info.merge(stats.summary(t.position), true)
	_emit_end(kind, info)


## Q-02: пилот на земле после полёта и уже не подскок (>= min_s) — подтверждение посадки ещё идёт.
func landing_pending(min_s: float) -> bool:
	return not _ended and stats.grounded_pending_s() >= min_s


## Q-02: не ждать подтверждения посадки — итог сейчас (false — подтверждать нечего).
func finish_now() -> bool:
	if _ended or not stats.force_finish():
		return false
	_check_finished()
	return _ended


## ASM-К4: у текущего полёта старт в воздухе (флаг или выбор игрока, ASM-К2).
func is_air_start() -> bool:
	return air_start_m >= 0.0


## В воздухе (не на земле): R в полёте — удержанием (Q-03).
func is_airborne() -> bool:
	return glider != null and settings != null and not glider.get_telemetry().on_ground


func _emit_end(kind: String, info: Dictionary) -> void:
	if _ended:
		return
	if not info.has("finish_reason"):
		info["finish_reason"] = kind
	info["flight_no"] = flight_no
	if is_air_start():
		info["air_start"] = true  # ASM-К4: пометка в итоге
	_goals_finish(kind, info)
	_ended = true
	_tracks_finish()
	feed.finish(kind, info, glider.get_telemetry())
	flight_ended.emit(kind, info)


## Вариометр, который пищит (game.json → vario_sound_from по пресету звука); иначе планшет.
func _sound_vario() -> Vario:
	var preset := String(Config.value("audio", "vario_audio.preset", ""))
	var marker := String(_cfg.get("vario_sound_from", {}).get(preset, ""))
	for n in mounted:
		if n.get_meta("marker", "") != marker:
			continue
		var vd: Variant = n.get("vario90s")
		if vd is VarioDisplay90s:
			return (vd as VarioDisplay90s).get_vario()
	return instrument.get_vario()


## Врезался в провод, опору, здание, дерево или забор — авария, полёт окончен.
func _on_collision(hit: Dictionary) -> void:
	_crashed = true
	var kind := String(hit.get("kind", ""))
	var texts: Dictionary = _cfg.get("collision_texts", {})
	var t := glider.get_telemetry()
	var info := {
		"grade": "crash",
		"collision": kind,
		"finish_reason": String(hit.get("reason", "crash_obstacle")),
		"text": tr(String(texts.get(kind, "collision"))),
		"vertical_speed_ms": maxf(-t.vario, 0.0),
		"horizontal_speed_ms": t.groundspeed,
		"bank_deg": t.bank_deg,
	}
	flight_audio.play_landing(info)
	if tow == null:
		_voice_event("landed", {"grade": "crash"})
	info.merge(stats.summary(t.position), true)
	_emit_end("landed", info)


func _on_takeoff_failed(reason: String) -> void:
	var text := GroundRun.failure_text(reason)
	if reason in ["nose", "keel", "fell"]:  # причины разбега маятника (PD-3)
		text = tr("launch_fail_" + reason)
	var info := {"reason": reason, "text": text}
	info.merge(stats.summary(glider.get_telemetry().position), true)
	_emit_end("takeoff_failed", info)


# ---------------------------------------------------------------- цели полёта (GL-4)


## Цели из настроек: GoalTracker (К3) — не в сети, не в осмотре карты и только с верным списком.
## До restart(): он же и сбросит трекер, и поставит маршрут на прибор.
func _goals_setup() -> void:
	var had := goals != null
	goals = null
	_goals_sig = ""
	if _goal_cylinders != null:
		_goal_cylinders.set_points([])
	if settings != null and net == null and not inspect_mode and not settings.goals.is_empty():
		var errs := GoalSpec.validate(settings.goals)
		if errs.is_empty():
			goals = GoalTracker.new()
			goals.setup(settings.goals, _goals_ctx())
			goals.goal_done.connect(func(_i: int) -> void: _goals_sync_instrument(true))
			goals.turnpoint_taken.connect(func() -> void: _voice_event("turnpoint"))
			goals.route_goal_reached.connect(func() -> void: _voice_event("goal"))
			goals.goal_failed.connect(func(_i: int) -> void: _goals_sync_instrument(true))
		else:
			push_warning("Game: цели пропущены: %s" % "; ".join(errs))
	goal_list.set_tracker(goals)
	if goals != null:
		_goals_sync_instrument(true)
	elif had:  # прошлый полёт был с целями — маршрут с прибора долой
		instrument.set_task([], 0)
		instrument.set_task_state({})
	_update_overlay()


## Контекст GoalTracker (GL-К3): старт, ветер, карта, круг посадки.
func _goals_ctx() -> Dictionary:
	var ctx := {
		"start_pos": air_start_position() if is_air_start() else _start_pos,
		"start_heading_deg": _start_heading,
		"wind_from_deg": _site_heading if settings.wind_into_launch else settings.wind_from_deg,
		"wind_ms": settings.wind_speed_kmh / 3.6,
		"latlon_fn": terrain.latlon_to_local,
		"height_fn": terrain.height_at,
		"bounds": terrain.detail_bounds(),
		"location_id": settings.location_id,
	}
	var target: Variant = _goals_landing_target()
	if target is Vector3:
		ctx["landing_target"] = target
	return ctx


## Круг посадки: ближайшая к старту посадочная площадка локации, иначе мишень тренировки
## «точность приземления» для встроенной локации; нет — null.
func _goals_landing_target() -> Variant:
	var best: Variant = null
	var best_d := INF
	for site: Dictionary in terrain.get_landing_sites():
		var p: Vector3 = site.position
		var d := Vector2(p.x - _start_pos.x, p.z - _start_pos.z).length()
		if d < best_d:
			best_d = d
			best = p
	if best != null or settings.has_pick():
		return best
	var targets: Dictionary = Config.get_config("tasks/training_spot_landing").get("targets", {})
	var t: Variant = targets.get(settings.location_id)
	if not t is Dictionary:
		return null
	var x := 0.0
	var z := 0.0
	if t.has("lat") and t.has("lon"):
		var q := terrain.latlon_to_local(float(t.lat), float(t.lon))
		x = q.x
		z = q.y
	elif t.has("x_m") and t.has("z_m"):
		x = float(t.x_m)
		z = float(t.z_m)
	else:
		return null
	return Vector3(x, terrain.height_at(x, z), z)


## Новая попытка (restart, «Продолжить», конец буксира): те же цели, всё заново.
func _goals_reset() -> void:
	if goals == null:
		return
	goals.reset()
	_goals_sig = ""
	_goals_sync_instrument(true)
	goal_list.refresh()


func _goals_update(t: Telemetry) -> void:
	if goals == null:
		return
	goals.update(t)
	_goals_sync_instrument(false, t.time_s)


## Ведущий маршрут — на прибор: точки при смене маршрута/активной точки, состояние ≤ 4 Гц.
## Без маршрута (или без целей) прибор пуст.
func _goals_sync_instrument(force: bool, time_s := NAN) -> void:
	if not force and not is_nan(time_s):
		if time_s >= _goals_sync_s and time_s - _goals_sync_s < 0.25:
			return
		_goals_sync_s = time_s
	if goals == null:
		if _goals_sig != "":
			_goals_sig = ""
			instrument.set_task([], 0)
			instrument.set_task_state({})
			_goals_sync_cylinders()
		return
	var lead := goals.lead_tracker()
	var idx := goals.instrument_active_index()
	var sig := "%d:%d" % [lead.get_instance_id() if lead != null else 0, idx]
	if sig != _goals_sig:
		_goals_sig = sig
		instrument.set_task(goals.instrument_points(), maxi(idx, 0))
		_goals_sync_cylinders()
	instrument.set_task_state(goals.instrument_state())


## Столбы в мире — пункты ведущего маршрута; узел создаётся при первом обращении.
func _goals_sync_cylinders() -> void:
	if goals == null:
		if _goal_cylinders != null:
			_goal_cylinders.set_points([])
		return
	if _goal_cylinders == null:
		_goal_cylinders = GoalCylinders.new()
		_goal_cylinders.name = "GoalCylinders"
		add_child(_goal_cylinders)
	_goal_cylinders.set_points(goals.world_points())


## Конец полёта: итог по целям и новые рекорды (info.goals, info.new_records). Не в сети.
func _goals_finish(kind: String, info: Dictionary) -> void:
	if goals == null or kind != "landed":
		return
	goals.on_landed(info)
	_goals_sync_instrument(true)
	goal_list.refresh()
	var res := goals.result()
	info["goals"] = res
	if is_air_start():  # ASM-К4: рекорды при старте в воздухе не засчитываются
		info["new_records"] = {}
		return
	if not stats.took_off:
		return
	var flight := info.duplicate()
	flight["location"] = (
		"pick_%.3f_%.3f" % [settings.pick_lat, settings.pick_lon]
		if settings.has_pick()
		else settings.location_id
	)
	flight["wing"] = settings.wing_id()
	if not (res.route as Dictionary).is_empty():
		flight["task"] = res.route
	flight.erase("goals")
	info["new_records"] = FlightRecords.new(records_path).add_flight(flight)


## Температура воздуха, °C, на высоте z_m над уровнем моря — для порога снежных флагов (SNW-4).
## Есть контекст погоды — суточный ход и градиент крейта; нет — прогноз меню минус 6,5 К/км.
func air_temp_c_at(z_m: float) -> float:
	var t_max := float(settings.forecast().get("temperature_c", 20.0))
	if _weather_ctx.is_empty():
		return t_max - 0.0065 * z_m
	return Weather.air_temp_c(sky.clock.hour, t_max, z_m, _weather_ctx)
