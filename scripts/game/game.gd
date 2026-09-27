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
## или "takeoff_failed" (info.reason, info.text).
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
## Время симуляции с начала полёта, с.
var sim_time_s: float = 0.0
## Управление и приборы в полёте (в меню — выключены).
var flying_enabled := false

var _cfg: Dictionary
var _start_pos := Vector3.ZERO
var _start_heading := 0.0
var _load_error := ""
var _dt: float = 1.0 / 120.0

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
	_cfg = Config.get_config("game")
	glider.set_physics_process(false)
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
	apply_user_settings()
	set_flying(false)


func _physics_process(dt: float) -> void:
	tick(dt)


## Один шаг симуляции в явном порядке. Тесты зовут его напрямую.
func tick(dt: float) -> void:
	if settings == null:
		return
	_dt = dt
	sim_time_s += dt
	air.call("step", dt)
	var phase := glider.phase()
	if autopilot != null:
		autopilot.drive(glider.get_telemetry(), dt)
	input_controller.on_ground = phase != "flying"
	glider.set_input(input_controller.update(dt))
	glider._physics_process(dt)  # → telemetry_updated → приборы, звук, статистика


## Новый полёт: загрузить рельеф (если нужно), настроить крыло, погоду и поставить на старт.
## Асинхронно (рельеф с карты грузится из сети). Возвращает false при ошибке.
func start(s: FlightSettings) -> bool:
	settings = s.duplicate()
	status_changed.emit(tr("Загрузка рельефа…"))
	if not await _load_terrain():
		status_changed.emit(tr("Не удалось загрузить рельеф: %s") % _load_error)
		return false
	air.call("set_weather", settings.weather)
	air.call("set_ground", terrain.height_at, terrain.sun_exposure_at)
	if air.has_method("set_sun_direction"):
		air.call("set_sun_direction", terrain.sun_direction())
	if air.has_method("load_static_thermals"):
		air.call("load_static_thermals", terrain.location.get("thermals", []))
	glider.set_ground_fn(terrain.height_at)
	glider.set_air_fn(air.air_velocity_at)
	_choose_start()
	var weather: Dictionary = Config.get_config(settings.weather)
	if settings.wind_mode == "into_site":
		air.call("set_wind", float(weather.get("wind_speed_kmh", 0.0)), _start_heading)
	if air.has_method("place_thermals_near"):
		air.call("place_thermals_near", _start_pos, _start_heading)
	_setup_glider()
	restart()
	status_changed.emit("")
	return true


## Заново с того же старта (клавиша R, «Ещё раз»).
func restart() -> void:
	if settings == null:
		return
	if autopilot != null:
		autopilot.reset()
	glider.reset_on_ground(_start_pos, _start_heading)
	sim_time_s = 0.0
	stats.reset(glider.get_telemetry().position)
	instrument.reset()
	camera.snap()


## В полёте (true) — ввод, прибор в углу, звук; в меню (false) — только вид.
func set_flying(on: bool) -> void:
	flying_enabled = on
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
	if not on:
		input_controller.set_mouse_captured(false)
	elif bool(Config.value("controls", "mouse.capture_on_start")):
		input_controller.set_mouse_captured(true)


## Настройки пилота поменялись (user://configs): перечитать то, что закешировано в нодах.
func apply_user_settings() -> void:
	input_controller.reload_config()
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
	if settings.has_pick():
		var size := float(_cfg.get("picked_location_size_km", -1.0))
		await terrain.load_location_latlon(settings.pick_lat, settings.pick_lon, size)
		return _load_error == ""
	if terrain.location_id == settings.location_id and not terrain.layers.is_empty():
		return true
	return terrain.load_location(settings.location_id)


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
	for m: Dictionary in _cfg.get("mounted_instruments", []):
		_mount_instrument(m)


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
	var ps := load(path) as PackedScene
	var inst := ps.instantiate() as Node3D if ps != null else null
	if inst == null:
		push_warning("Game: %s — не Node3D" % path)
		return
	mount.add_child(inst)
	mounted.append(inst)
	if inst.has_method("use_instrument"):
		inst.call("use_instrument", instrument)
	# Сразу после setup визуал в позе полёта: PilotHead — глаза лежащего пилота.
	var eye := glider.get_marker("PilotHead")
	if bool(m.get("face_pilot", false)) and eye != null and mount != glider:
		var to_eye := eye.global_position - inst.global_position
		if to_eye.length() > 0.01:
			inst.global_basis = Basis.looking_at(to_eye, glider.global_basis.y, true)


func _update_overlay() -> void:
	overlay.visible = flying_enabled and camera.mode != "cockpit"


# ---------------------------------------------------------------- сигналы планера


func _on_telemetry(t: Telemetry) -> void:
	instrument.update(t, _dt)
	for n in mounted:
		if not n.has_method("use_instrument") and n.has_method("update"):
			n.call("update", t, _dt)
	vario_audio.set_vario(instrument.get_vario().vario_ms)
	var extra := {"phase": t.phase, "stall_amount": 1.0 if t.stalled else 0.0}
	if t.on_ground and air.has_method("mean_wind_at"):
		extra["ground_wind_ms"] = (air.call("mean_wind_at", t.position) as Vector3).length()
	flight_audio.update(t, extra)
	stats.update(t, _dt)


func _on_landed(result: Dictionary) -> void:
	flight_audio.play_landing(result)
	var info := result.duplicate()
	info.merge(stats.summary(glider.get_telemetry().position))
	flight_ended.emit("landed", info)


func _on_takeoff_failed(reason: String) -> void:
	flight_ended.emit("takeoff_failed", {"reason": reason, "text": GroundRun.failure_text(reason)})
