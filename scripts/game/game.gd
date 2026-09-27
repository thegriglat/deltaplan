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
## Время симуляции с начала полёта, с.
var sim_time_s: float = 0.0
## Управление и приборы в полёте (в меню — выключены).
var flying_enabled := false
## Старт в воздухе (--air-start, docs/game.md): в air_start_m м от старта по его курсу, на
## air_start_agl_m м над рельефом, на скорости трима; < 0 — обычный старт с земли.
var air_start_m := -1.0
var air_start_agl_m := 300.0

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
	air = _create_air()
	air.name = "Air"
	add_child(air)
	air.set_physics_process(false)
	air.set("focus_node", glider)
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
	sky.clock.advance(dt)  # время суток идёт (VR-5)
	air.call("step", dt)
	var phase := glider.phase()
	if autopilot != null:
		autopilot.drive(glider.get_telemetry(), dt)
	input_controller.on_ground = phase != "flying"
	# Свободная камера занимает WASD — крыло без рук (автопилот тестов жмёт те же клавиши).
	var free_cam := camera.mode == "free" and autopilot == null
	input_controller.hands_off = free_cam
	camera.free_keys_enabled = autopilot == null
	glider.set_input(input_controller.update(dt))
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
	var progress := terrain.progress
	progress.begin()
	# Пока грузится — шаг физики стоит: воздух и планер ещё не настроены на новое место
	# (иначе каждый кадр загрузки догоняет пропущенные шаги — окно «не отвечает»).
	set_physics_process(false)
	status_changed.emit(tr("Загрузка рельефа…"))
	if not await _load_terrain():
		status_changed.emit(tr("Не удалось загрузить рельеф: %s") % _load_error)
		set_physics_process(true)
		progress.finish()
		return false
	# Дальше — порциями между кадрами: экран загрузки живой (docs/game.md → «Загрузка»).
	progress.stage("weather", tr("Погода и термики…"))
	await get_tree().process_frame
	air.call("set_weather", settings.weather)
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
	if air.has_method("set_sun_direction"):
		air.call("set_sun_direction", terrain.sun_direction())
	# Солнце по времени и дате старта над центром локации (sky.clock → небо, свет, облака).
	# Воздуху (тени облаков на источниках термиков) — пока статичное: термики от времени суток
	# не зависят (решение пользователя, docs/game.md → «Время суток»).
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
	if air.has_method("load_static_thermals"):
		air.call("load_static_thermals", terrain.location.get("thermals", []))
	glider.set_ground_fn(terrain.height_at)
	glider.set_air_fn(air.air_velocity_at)
	progress.stage("objects", tr("Камни, кусты и дороги…"))
	await get_tree().process_frame
	world_link.link(terrain, air, glider)
	_choose_start()
	var weather: Dictionary = Config.get_config(settings.weather)
	if settings.wind_mode == "into_site":
		air.call("set_wind", float(weather.get("wind_speed_kmh", 0.0)), _start_heading)
	if air.has_method("place_thermals_near"):
		air.call("place_thermals_near", _start_pos, _start_heading)
	# Верх дымки — на высоте инверсии (основание облаков).
	if air.has_method("get_cloudbase_msl") and sky.has_method("set_inversion_height_msl"):
		sky.set_inversion_height_msl(float(air.call("get_cloudbase_msl")))
	progress.stage("glider", tr("Почти готово…"))
	await get_tree().process_frame
	_setup_glider()
	collisions.setup(
		world_link.objects,
		terrain.forest_at,
		glider.model.span,
		float(Config.value("flight", "visual.hang_height_m", 2.0))
	)
	restart()
	set_physics_process(true)
	progress.finish()
	status_changed.emit("")
	return true


## Заново с того же старта (клавиша R, «Ещё раз»).
func restart() -> void:
	if settings == null:
		return
	if autopilot != null:
		autopilot.reset()
	if air_start_m >= 0.0:
		glider.reset_in_air(air_start_position(), _start_heading)
	else:
		glider.reset_on_ground(_start_pos, _start_heading)
	_animator.bind(glider.visual, _cfg.get("pilot_animation", {}))
	input_controller.reset()
	collisions.reset()
	_crashed = false
	_ended = false
	_touchdown = {}
	_prev_phase = ""
	sim_time_s = 0.0
	sky.clock.reset()
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
			_load_error if _load_error != "" else tr("нет данных или ошибка в модуле рельефа")
		)
		# точка с карты: рельеф уже объяснил простыми словами (море, нет сети, нет данных)
		if not (settings.has_pick() and _load_error != ""):
			_load_error = tr("«%s» — %s (подробности — в журнале Godot)") % [what, why]
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
		info["text"] = tr("Касание сразу после старта — полёт не засчитан")
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
		"text": tr(String(texts.get(kind, "Столкновение"))),
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
