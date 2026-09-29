# gdlint: disable=max-public-methods
class_name Game
extends Node3D
## Полётный мир: небо, рельеф, воздух, планер, ввод, камеры, прибор, звук (scenes/game/game.tscn).
## Главная сцена вызывает start(settings) / restart() и слушает сигналы.
##
## Порядок шага физики (tick): воздух → ввод → планер → приборы и звук (по сигналу
## telemetry_updated). Физику планера и воздуха ведёт Game, их собственный
## _physics_process выключен — порядок явный и одинаковый в игре и в тестах.
## Подробно — docs/game.md.

## Полёт закончился: kind — "landed" (info — оценка посадки + сводка FlightStats)
## или "takeoff_failed" (info.reason, info.text + сводка).
## Формат info — docs/game.md → «Итог полёта».
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

var settings: FlightSettings
## Модель воздуха: Atmosphere или запасная CalmAir (game.json → air).
var air: Node3D
## Приборы на трапеции (game.json → mounted_instruments); первый — планшет Instrument3D.
var mounted: Array[Node3D] = []
var stats := FlightStats.new()
## Синтетический пилот (тесты, --autopilot); null — управляет игрок.
var autopilot: Autopilot
## Объекты мира, просеки, столкновения.
var world_link: WorldLink
## Столкновения крыла с проводами, препятствиями и кронами (docs/game.md).
var collisions := CollisionCheck.new()
## Другие пилоты в небе (configs/bots.json, docs/game.md → «Другие пилоты»).
var bots: BotPilots
## Пасхалки мира и неба (чисто визуально, docs/easter_eggs_contracts.md).
var eggs: EasterEggs
## Сколько ботов (--bots=N); < 0 — из настроек (bots.json → count).
var bots_count := -1
## Время симуляции с начала полёта, с.
var sim_time_s: float = 0.0
## Управление и приборы в полёте (в меню — выключены).
var flying_enabled := false
## Старт в воздухе (--air-start, docs/game.md): в air_start_m м от старта по его курсу, на
## air_start_agl_m м над рельефом, на скорости трима; < 0 — обычный старт с земли.
var air_start_m := -1.0
var air_start_agl_m := 300.0
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
## Отладочные слои F1/F5/F6 (DebugOverlays).
var debug_overlays: DebugOverlays

var _cfg: Dictionary
var _start_pos := Vector3.ZERO
var _start_heading := 0.0
var _load_error := ""
var _dt: float = 1.0 / 120.0
var _whiteout := CloudWhiteout.new()
var _animator := PilotAnimator.new()
var _graphics := ""
var _terrain_dirty := false
var _crashed := false  ## врезался в препятствие — планер стоит до «Ещё раз»
var _ended := false  ## flight_ended уже отправлен (до «Ещё раз» / «Продолжить»)
## Погода из прогноза (FR-16): место для WeatherModel.derive, час последнего пересчёта (ход дня),
## шаг сетки источников (по разгару дня — весь полёт один), инерция прогрева по классам.
var _weather_ctx := {}
var _weather_hour := NAN
var _peak_spacing := NAN
var _heating := SurfaceHeating.new()
## Ход дня для атмосферы (погода, солнце, источники — функции времени атмосферы, NET-00).
var _day: AtmoDay
var _touchdown := {}  ## оценка последнего касания (LandingJudge) — для итога
var _prev_phase := ""
var _paused := false

@onready var sky: SkyEnvironment = $Environment
@onready var terrain: Terrain = $Terrain
@onready var glider: Glider = $Glider
@onready var input_controller: InputController = $InputController
@onready var camera: CameraRig = $CameraRig
@onready var instrument: FlightInstrument = $FlightInstrument
@onready var overlay: InstrumentOverlay = $InstrumentOverlay
@onready var vario_audio: VarioAudio = $VarioAudio
@onready var flight_audio: FlightAudio = $FlightAudio


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
	if air.has_signal("weather_updated"):
		air.connect("weather_updated", _apply_haze)  # ход дня (AtmoDay): дымка за погодой
	air.set("focus_node", glider)
	debug_overlays = DebugOverlays.new()
	debug_overlays.name = "DebugOverlays"
	add_child(debug_overlays)
	debug_overlays.setup(air, glider, terrain.height_at)
	terrain.load_failed.connect(func(msg: String) -> void: _load_error = msg)
	SkyEnvironment.setup_camera(camera)
	camera.set_mode(camera.mode)  # near по режиму
	camera.target = glider
	camera.ground_fn = terrain.height_at
	camera.mode_changed.connect(func(_m: String) -> void: _update_overlay())
	overlay.use_instrument(instrument)
	glider.telemetry_updated.connect(_on_telemetry)
	glider.landed.connect(_on_landed)
	glider.takeoff_failed.connect(_on_takeoff_failed)
	_whiteout.setup(_cfg.get("cloud_whiteout", {}))
	apply_user_settings()
	set_flying(false)


func _process(dt: float) -> void:
	# Белая мгла в облаке — по положению камеры (кадр, не шаг физики).
	if air.has_method("cloud_density_at") and sky.world_env != null:
		var d := float(air.call("cloud_density_at", camera.global_position))
		if d > 0.0 or _whiteout.amount > 0.0:
			_whiteout.update(d, dt)
			_whiteout.apply(sky.world_env.environment)


func _physics_process(dt: float) -> void:
	tick(dt)


## Один шаг симуляции в явном порядке. Тесты зовут его напрямую.
func tick(dt: float) -> void:
	if settings == null:
		return
	_dt = dt
	sim_time_s += dt
	if net != null:
		_net_world_step(dt)
	else:
		sky.clock.advance(dt)  # время суток идёт (VR-5)
		air.call("step", dt)
	_update_day_weather()
	var phase := glider.phase()
	if autopilot != null:
		autopilot.hold = input_controller.run_blocked or not queue_walk.is_empty()
		autopilot.drive(glider.get_telemetry(), dt)
	input_controller.on_ground = phase != "flying"
	# Свободная камера занимает WASD — крыло без рук (автопилот тестов жмёт те же клавиши).
	var free_cam := camera.mode == "free" and autopilot == null
	input_controller.hands_off = free_cam or hands_off
	camera.free_keys_enabled = autopilot == null
	var control := input_controller.update(dt)
	if not queue_walk.is_empty():
		_queue_walk_step(control, phase)
	glider.set_input(control)
	bots.tick(dt, glider.get_telemetry())
	if tow != null:
		_tow_step(dt)  # без физики, столкновений и итога полёта
		return
	if _crashed:
		return
	glider.step(dt)  # → telemetry_updated → приборы, звук, статистика
	var hit := collisions.check(glider.get_telemetry())
	if not hit.is_empty():
		_on_collision(hit)
	_check_finished()


## Новый полёт: загрузить рельеф (если нужно), настроить крыло, погоду и поставить на старт.
## Асинхронно (рельеф с карты грузится из сети). Возвращает false при ошибке.
func start(s: FlightSettings) -> bool:
	settings = s.duplicate()
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
	# Дальше — порциями между кадрами: экран загрузки живой (docs/game.md → «Загрузка»).
	progress.stage("weather", tr("loading_weather"))
	await get_tree().process_frame
	_weather_ctx = _weather_context()
	_weather_hour = settings.start_hour
	_peak_spacing = float(
		WeatherModel.derive(settings.forecast(), _weather_ctx).thermal_spacing_m
	)
	if "seed_value" in air:
		air.set("seed_value", world_seed)
	if air.has_method("set_day"):
		air.call("set_day", null)
	air.call("set_weather", _derive_weather(_weather_hour))
	# Новый полёт — часы атмосферы с нуля: порывы и жизнь термиков у старта зависят только от
	# локации, погоды и сида, а не от того, сколько летали до этого (детерминизм, F01).
	if "time_s" in air:
		air.set("time_s", 0.0)
	# Источники термиков: покров × солнце (если рельеф умеет), иначе только солнце на склоне.
	var src := (
		terrain.thermal_source_strength_at
		if terrain.has_method("thermal_source_strength_at")
		else terrain.sun_exposure_at
	)
	air.call("set_ground", terrain.height_at, src)
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
	_heating.setup(
		float(_weather_ctx.lat),
		float(_weather_ctx.lon),
		settings.month,
		settings.day,
		float(_weather_ctx.utc_offset_h)
	)
	if not sky.clock.sun_changed.is_connected(_on_sun_changed):
		sky.clock.sun_changed.connect(_on_sun_changed)
	_on_sun_changed(sky.clock.to_sun())
	if air.has_method("set_day"):
		_day = _make_day()
		air.call("set_day", _day)
	if air.has_method("load_static_thermals"):
		air.call("load_static_thermals", terrain.location.get("thermals", []))
	glider.set_ground_fn(terrain.height_at)
	glider.set_air_fn(air.air_velocity_at)
	progress.stage("objects", tr("loading_objects"))
	await get_tree().process_frame
	world_link.link(terrain, air, glider)
	_choose_start()
	# Ветер прогноза (пилот): встречный или с заданного румба; выше старта сильнее.
	air.call(
		"set_wind",
		settings.wind_speed_kmh,
		_start_heading if settings.wind_into_launch else settings.wind_from_deg,
		_start_pos.y
	)
	if air.has_method("place_thermals_near"):
		air.call("place_thermals_near", _start_pos, _start_heading)
	# Верх дымки — на высоте инверсии (основание облаков).
	_apply_haze()
	progress.stage("glider", tr("loading_almost"))
	await get_tree().process_frame
	_setup_glider()
	collisions.setup(
		world_link.objects,
		terrain.forest_at,
		glider.model.span,
		float(Config.value("flight", "visual.hang_height_m", 2.0))
	)
	bots.setup_in_world(terrain, air, _start_pos, _start_heading, bots_count)
	# Поля рельефа (влажность ложбин ослабляет источники термиков) считаются в фоне — термики
	# рождаются только после них, иначе первые термики зависели бы от скорости машины.
	# Поля доводит Terrain._process; у выключенного узла (тесты шагают сами) — ждать здесь.
	while terrain.has_method("relief_busy") and terrain.relief_busy():
		if not terrain.can_process() and terrain.has_method("wait_relief"):
			terrain.wait_relief()
			break
		await get_tree().process_frame
	restart()
	# Термики вокруг старта — ещё на экране загрузки (первое обновление — самое долгое).
	if air.has_method("refresh_now"):
		air.call("refresh_now")
	set_physics_process(true)
	progress.finish()
	status_changed.emit("")
	return true


## Место для погоды: дата, широта/долгота, пояс, высоты долины и средней земли вокруг (0, 0).
func _weather_context() -> Dictionary:
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at,
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(wc.valley_percentile)
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


## День в час hour из прогноза пилота (сетка источников — по разгару дня).
func _derive_weather(hour: float) -> Dictionary:
	var w := WeatherModel.derive(settings.forecast(), _weather_ctx, {}, hour)
	w.thermal_spacing_m = _peak_spacing
	return w


## Ход дня для атмосферы: час места по времени атмосферы (часы старта — при её текущем времени),
## погода по часу, солнце по дате и месту, источники термиков по солнцу с инерцией прогрева.
func _make_day() -> AtmoDay:
	var d := AtmoDay.new()
	d.start_hour = sky.clock.hour
	d.t0 = float(air.get("time_s"))
	d.speed = sky.clock.speed
	var diurnal: Dictionary = WeatherModel.config().get("diurnal", {})
	d.quantum_h = float(diurnal.get("update_s", 60.0)) / 3600.0
	d.weather_fn = _derive_weather
	var c := sky.clock
	var sun := AtmoDay.sun_direction.bind(
		c.latitude_deg, c.longitude_deg, c.month, c.day, _clock_utc_offset()
	)
	d.sun_fn = sun
	if terrain.has_method("thermal_source_strength_for"):
		var heating := _heating
		var cache := {"h": NAN, "dirs": PackedVector3Array(), "sun": Vector3.UP}
		d.source_fn = func(x: float, z: float, h: float) -> float:
			if h != float(cache.h):
				cache.h = h
				cache.dirs = heating.directions(h)
				cache.sun = sun.call(h)
			return terrain.thermal_source_strength_for(x, z, cache.dirs, cache.sun)
	return d


## Сеть (NET-40): мир — на момент t зоны, с (от начала зоны = от старта часов start_hour):
## атмосфера сразу в t (то же, что прогон от 0), часы — на час старта + t.
func set_world_time(t: float) -> void:
	if _day != null:
		sky.clock.set_hour(_day.hour_at(t))
	if air.has_method("start_at"):
		air.call("start_at", t)


## Ход дня без AtmoDay (запасной воздух): раз в diurnal.update_s игрового времени — мягко к
## погоде этого часа (Atmosphere ведёт кромку, фон и болтанку плавно за blend_s).
func _update_day_weather() -> void:
	if _day != null or _weather_ctx.is_empty() or not air.has_method("thermals_near"):
		return
	var d: Dictionary = WeatherModel.config().get("diurnal", {})
	if absf(sky.clock.hour - _weather_hour) * 3600.0 < float(d.get("update_s", 60.0)):
		return
	_weather_hour = sky.clock.hour
	var blend := float(d.get("blend_s", 300.0)) / maxf(sky.clock.speed, 1.0)
	air.call("set_weather", _derive_weather(_weather_hour), blend)
	_apply_haze()


## Дымка: верх — у кромки (инверсия), густота — по ходу дня.
func _apply_haze() -> void:
	if air.has_method("get_cloudbase_msl") and sky.has_method("set_inversion_height_msl"):
		sky.set_inversion_height_msl(float(air.call("get_cloudbase_msl")))
	if sky.has_method("set_haze_density"):
		sky.set_haze_density(float(air.get("weather").get("haze_k", 1.0)))


func _on_sun_changed(to_sun: Vector3) -> void:
	if air.has_method("set_sun_direction"):
		air.call("set_sun_direction", to_sun)
	if terrain.has_method("set_class_sun"):
		terrain.set_class_sun(_heating.directions(sky.clock.hour))


## Заново с того же старта (клавиша R, «Ещё раз»).
func restart() -> void:
	if settings == null:
		return
	if autopilot != null:
		autopilot.reset()
	tow = null  # «Ещё раз» / «На старт» посреди буксира
	camera.tight = false
	queue_walk = {}
	if air_start_m >= 0.0:
		glider.reset_in_air(air_start_position(), _start_heading)
	elif net != null:  # в сети — на своё место в очереди на старт (NET-43)
		var sp := net.queue_start_spot()
		glider.reset_on_ground(sp.position, float(sp.heading_deg))
	else:
		glider.reset_on_ground(_start_pos, _start_heading)
	_animator.bind(glider.visual, _cfg.get("pilot_animation", {}))
	input_controller.reset()
	collisions.reset()
	bots.reset()
	eggs.reset()
	_crashed = false
	_ended = false
	_touchdown = {}
	_prev_phase = ""
	sim_time_s = 0.0
	if net == null:  # в сети мир идёт по часам зоны — «Ещё раз» его не сбрасывает
		sky.clock.reset()
		if _day != null:
			_day.rebase(float(air.get("time_s")), sky.clock.hour, sky.clock.speed)
	stats.reset(glider.get_telemetry().position)
	instrument.reset()
	for n in mounted:
		if not bool(n.get_meta("shares_tablet", false)) and n.get("vario90s") != null:
			(n.get("vario90s") as VarioDisplay90s).reset()
	camera.snap()


## Точка старта в воздухе: air_start_m по курсу старта, air_start_agl_m над рельефом там.
func air_start_position() -> Vector3:
	var h := deg_to_rad(_start_heading)
	var p := _start_pos + Vector3(sin(h), 0.0, -cos(h)) * air_start_m
	p.y = terrain.height_at(p.x, p.z) + air_start_agl_m
	return p


## После итога «Продолжить»: пилот на земле ходит дальше; новый разбег — новый полёт.
func continue_on_foot() -> void:
	_ended = false
	_touchdown = {}
	stats.reset(glider.get_telemetry().position)


## Пауза (Esc): физика стоит (дерево на паузе), ввод и звук выключены.
func set_paused(on: bool) -> void:
	_paused = on
	set_input_enabled(not on)
	vario_audio.set_enabled(flying_enabled and not on)
	flight_audio.set_enabled(flying_enabled and not on)


func is_paused() -> bool:
	return _paused


## В полёте (true) — ввод, прибор в углу, звук; в меню (false) — только вид.
func set_flying(on: bool) -> void:
	flying_enabled = on
	_paused = false
	set_input_enabled(on)
	camera.set_mode(
		(
			String(Config.value("camera", "default_mode"))
			if on
			else String(_cfg.get("menu_camera_mode", "chase"))
		)
	)
	vario_audio.set_enabled(on)
	flight_audio.set_enabled(on)
	if on:
		flight_audio.play_carabiner()
	_update_overlay()


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
	if _day != null:
		_day.rebase(float(air.get("time_s")), sky.clock.hour, sky.clock.speed)
	var va: Dictionary = Config.get_config("audio").get("vario_audio", {})
	vario_audio.set_volume_db(float(va.get("volume_db", -6.0)))
	if va.has("preset") and vario_audio.has_method("set_preset"):
		vario_audio.call("set_preset", String(va.preset))


func next_instrument_page() -> void:
	instrument.next_page()


func get_start() -> Dictionary:
	return {"position": _start_pos, "heading_deg": _start_heading}


func _unhandled_input(event: InputEvent) -> void:
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
	return float(air.get("time_s")) if "time_s" in air else sim_time_s


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
	var m := glider.model
	var vel := m.velocity if m.mode == FlightModel.Mode.AIR else Vector3.ZERO
	var t := CatchUpTow.new({}, terrain.height_at)
	t.start(m.position, vel, target_fn, m.heading)
	if not t.is_active():
		return false
	tow = t
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
	camera.tight = false
	var pos: Vector3 = r.position
	var heading_deg := rad_to_deg(float(r.heading))
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
	stats.reset(pos)
	stats.armed = glider.phase() == "flying"
	instrument.reset()
	catch_up_ended.emit(String(r.get("state", "")))


## «На старт» (итог полёта в сети): снова на старт, мир не сбрасывается; в сети — в конец
## очереди на старт (restart ставит на место: не в очереди — конец живых пилотов, NET-43).
func return_to_launch() -> void:
	restart()


## Шаг мира в сети: воздух — по часам зоны (NetFlight.world_dt), часы суток — от времени
## атмосферы (AtmoDay.hour_at): после паузы и долгих кадров время не прыгает относительно зоны.
func _net_world_step(dt: float) -> void:
	air.call("step", net.world_dt(dt))
	if _day != null:
		sky.clock.set_hour(_day.hour_at(world_time()))
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
		var size := float(_cfg.get("picked_location_size_km", -1.0))
		await terrain.load_location_latlon(settings.pick_lat, settings.pick_lon, size)
		ok = _load_error == ""
	elif (
		terrain.location_id == settings.location_id
		and not terrain.layers.is_empty()
		and not _terrain_dirty
	):
		return true
	else:
		what = settings.location_id
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


func _choose_start() -> void:
	if settings.has_pick():
		var p := terrain.latlon_to_local(settings.pick_lat, settings.pick_lon)
		var cfg: Dictionary = _cfg.start_search
		var launch := StartPlacement.find_launch(terrain.height_at, p.x, p.y, cfg)
		if not launch.ok:
			push_warning("Game: у выбранной точки нет склона для разбега — старт на месте")
		_start_pos = launch.position
		_start_heading = float(launch.heading_deg)
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


func _setup_glider() -> void:
	for n in mounted:
		n.queue_free()
	mounted.clear()
	glider.setup(settings.wing_id(), settings.pilot_mass_kg)
	settings.pilot_mass_kg = glider.pilot_mass_kg
	camera.set_head(glider.get_marker("PilotHead"))
	# Смещение центра масс пилота от подвески в полёте (крен/тангаж ручкой), оси планера: голова
	# кабинной камеры повторяет его долей (camera.json → cockpit.head_follow_body). На земле — ноль.
	var v := glider.visual
	camera.body_shift_fn = func() -> Vector3:
		if glider.phase() != "flying" or not is_instance_valid(v):
			return Vector3.ZERO
		return v.body_shift
	_hide_from_cockpit()
	for m: Dictionary in _cfg.get("mounted_instruments", []):
		_mount_instrument(m)
	_animator.bind(glider.visual, _cfg.get("pilot_animation", {}))
	var gl := String(Config.value("camera", "cockpit.glance.target", "InstrumentMount"))
	camera.glance_target = glider.get_marker(gl)


## Шлем и т. п. (camera.json → cockpit.hidden_nodes) — на слой, который кабина не рисует.
func _hide_from_cockpit() -> void:
	var ck: Dictionary = Config.get_config("camera").cockpit
	var bit := 1 << (int(ck.get("hidden_layer", 20)) - 1)
	for node_name: String in ck.get("hidden_nodes", []):
		for n in glider.find_children(node_name, "VisualInstance3D", true, false):
			(n as VisualInstance3D).layers = bit


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


# ---------------------------------------------------------------- сигналы планера


func _on_telemetry(t: Telemetry) -> void:
	if tow != null:  # буксир: без приборов и статистики, писк молчит, поток — по скорости
		vario_audio.set_vario(0.0)
		flight_audio.update(t, {"phase": t.phase, "stall_amount": 0.0, "load_factor": 1.0})
		_animator.update(t.phase, t.altitude_agl, 0.0, 0.0, _dt)
		return
	instrument.update(t, _dt)
	for n in mounted:
		if not bool(n.get_meta("shares_tablet", false)) and n.has_method("update"):
			n.call("update", t, _dt)
	vario_audio.set_vario(_sound_vario().vario_ms)
	var extra := {
		"phase": t.phase, "stall_amount": 1.0 if t.stalled else 0.0, "load_factor": t.load_factor
	}
	if t.on_ground and air.has_method("mean_wind_at"):
		extra["ground_wind_ms"] = (air.call("mean_wind_at", t.position) as Vector3).length()
	flight_audio.update(t, extra)
	stats.update(t, _dt)
	# Старт в воздухе (reset_in_air: тесты, «свободный полёт»): взлёта со склона не было —
	# полёт сразу засчитан, касание будет посадкой, а не «взлёт сорван».
	if t.phase == "flying" and not (_prev_phase in ["flying", "running", "walking"]):
		stats.armed = true
	_prev_phase = t.phase
	_animator.update(t.phase, t.altitude_agl, t.vario, glider.model.flare_amount(), _dt)


## Касание ногами: звук и оценка сейчас, итог — когда FlightStats засчитает посадку.
func _on_landed(result: Dictionary) -> void:
	flight_audio.play_landing(result)
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


func _emit_end(kind: String, info: Dictionary) -> void:
	if _ended:
		return
	if not info.has("finish_reason"):
		info["finish_reason"] = kind
	_ended = true
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
	info.merge(stats.summary(t.position), true)
	_emit_end("landed", info)


func _on_takeoff_failed(reason: String) -> void:
	var info := {"reason": reason, "text": GroundRun.failure_text(reason)}
	info.merge(stats.summary(glider.get_telemetry().position), true)
	_emit_end("takeoff_failed", info)
