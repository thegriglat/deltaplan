extends Node
## Главная сцена: полётный мир (Game) + экраны интерфейса. Переходы:
## меню → загрузка → полёт ⇄ пауза, полёт → итог → (ещё раз | продолжить | меню).
## Никакого HUD в полёте (FR-21): экраны только меню, пауза, настройки, «Об игре», итог.
## Аргументы командной строки — scripts/game/launch_options.gd (--smoke, --screenshot=…).

enum State { MENU, LOADING, FLYING, PAUSED, RESULT }

const SMOKE_STEPS := 300
const SMOKE_TIMEOUT_S := 90.0

var state: State = State.MENU
var opts: LaunchOptions
var flight: FlightSettings
## Папка user-конфигов для выбора языка (тесты подменяют, чтобы не трогать профиль).
var user_config_dir: String = UserSettings.DEFAULT_DIR
## «Сетевая игра» (NET-50): создаётся при открытии, удаляется при закрытии.
var net_screen: NetScreen = null

var _overlay_back: Control  ## экран, к которому вернуться из настроек / «Об игре»
var _look_target: Node3D  ## --look-at: куда смотреть в кабине (скриншоты)
var _ui_locale := ""  ## язык, на котором построены экраны (сменился — перестроить)

@onready var game: Game = $Game
@onready var start_menu: StartMenu = $UI/StartMenu
@onready var pause_menu: PauseMenu = $UI/PauseMenu
@onready var settings_panel: SettingsPanel = $UI/SettingsPanel
@onready var about_screen: AboutScreen = $UI/AboutScreen
@onready var result_screen: ResultScreen = $UI/ResultScreen
@onready var controls_screen: ControlsScreen = $UI/ControlsScreen
@onready var flight_setup_screen: FlightSetupScreen = $UI/FlightSetupScreen
@onready var loading_screen: LoadingScreen = $UI/LoadingScreen


## Язык ставится до _ready экранов (они строят тексты в своих _ready).
func _enter_tree() -> void:
	Language.apply(Language.configured())
	_ui_locale = TranslationServer.get_locale()


func _ready() -> void:
	if opts == null:  # тесты задают свои
		opts = LaunchOptions.parse(OS.get_cmdline_user_args())
	_connect_ui()
	var overlays: Array[Control] = [
		pause_menu,
		settings_panel,
		about_screen,
		result_screen,
		controls_screen,
		flight_setup_screen
	]
	for c: Control in overlays:
		c.visible = false
	# Меню помнит прошлый выбор; автостарт (smoke, скриншоты) — всегда с настроек по умолчанию.
	var base := FlightSettings.defaults() if opts.autostart else UserSettings.load_last_flight()
	flight = opts.apply_to(base)
	start_menu.set_settings(flight)
	if opts.smoke:
		# Сторож: smoke не должен висеть, если что-то сломалось.
		get_tree().create_timer(SMOKE_TIMEOUT_S).timeout.connect(_quit.bind(1))
	if opts.autopilot:
		game.autopilot = Autopilot.new()
		game.autopilot.circle_after_s = opts.autopilot_circle_s
		game.autopilot.circle_bank_deg = opts.autopilot_circle_bank
	if opts.autostart:
		await _fly(flight)
	else:
		await _show_menu()
	if opts.smoke:
		_smoke_test()
	elif opts.screenshot != "":
		_screenshot()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		match state:
			State.FLYING:
				_pause()
			State.PAUSED:
				if _overlay_open():
					_close_overlay()
				else:
					_resume()
			State.MENU:
				if _overlay_open():
					_close_overlay()
	elif event.is_action_pressed("restart") and state in [State.FLYING, State.RESULT]:
		get_viewport().set_input_as_handled()
		_restart()


# ---------------------------------------------------------------- переходы


func _fly(s: FlightSettings) -> void:
	state = State.LOADING
	flight = s
	get_tree().paused = false
	start_menu.set_busy(true)
	loading_screen.open(game.terrain.progress, StartMenu.summary_text(s).replace("\n", " · "))
	start_menu.visible = false  # под экраном загрузки — только фон (при ошибке меню вернётся)
	game.air_start_m = opts.air_start_m
	game.air_start_agl_m = opts.air_start_agl_m
	game.bots_count = opts.bots
	var ok: bool = await game.start(s)
	loading_screen.close()
	start_menu.set_busy(false)
	if not ok:
		state = State.MENU
		start_menu.visible = true
		return
	flight.pilot_mass_kg = game.settings.pilot_mass_kg
	if not opts.autostart:
		UserSettings.save_last_flight(s)
	start_menu.visible = false
	game.set_flying(true)
	if opts.camera != "":
		game.camera.set_mode(opts.camera)
	if opts.look != Vector2.ZERO:
		game.camera.set_look(opts.look.x, opts.look.y)
	if opts.glance:
		Input.action_press("look_instrument")
	if opts.look_at != "":
		_look_target = Node3D.new()
		_look_target.name = "LookTarget"
		game.add_child(_look_target)
		_look_target.global_position = _look_point()
		game.camera.glance_target = _look_target
		Input.action_press("look_instrument")
	state = State.FLYING


func _show_menu() -> void:
	state = State.MENU
	get_tree().paused = false
	var overlays: Array[Control] = [
		pause_menu,
		settings_panel,
		about_screen,
		result_screen,
		controls_screen,
		flight_setup_screen
	]
	for c: Control in overlays:
		c.visible = false
	game.set_flying(false)
	start_menu.visible = true
	start_menu.set_settings(flight)
	if game.settings == null:
		# Мир за меню — на площадке локации (точку с карты грузим только по «Лететь»).
		var bg := flight.duplicate()
		bg.pick_lat = NAN
		bg.pick_lon = NAN
		await game.start(bg)
	else:
		game.restart()


## Esc: физика стоит (дерево на паузе, Telemetry.time_s не растёт), звук молчит.
func _pause() -> void:
	state = State.PAUSED
	get_tree().paused = true
	game.set_paused(true)
	pause_menu.visible = true


func _resume() -> void:
	pause_menu.visible = false
	get_tree().paused = false
	game.set_paused(false)
	state = State.FLYING


func _restart() -> void:
	result_screen.visible = false
	pause_menu.visible = false
	get_tree().paused = false
	game.restart()
	game.set_paused(false)
	state = State.FLYING


func _on_flight_ended(kind: String, info: Dictionary) -> void:
	if state != State.FLYING:
		return
	await get_tree().create_timer(float(Config.value("game", "result_delay_s", 2.0)), false).timeout
	if state != State.FLYING:
		return
	state = State.RESULT
	get_tree().paused = true
	game.set_paused(true)
	result_screen.show_result(kind, info)


func _open_overlay(panel: Control, back: Control) -> void:
	_overlay_back = back
	back.visible = false
	panel.visible = true


func _overlay_open() -> bool:
	return (
		settings_panel.visible
		or about_screen.visible
		or controls_screen.visible
		or flight_setup_screen.visible
		or (net_screen != null and net_screen.visible)
	)


func _close_overlay() -> void:
	settings_panel.visible = false
	about_screen.visible = false
	controls_screen.visible = false
	flight_setup_screen.visible = false
	if net_screen != null:
		net_screen.queue_free()
		net_screen = null
	if _overlay_back != null:
		_overlay_back.visible = true


func _connect_ui() -> void:
	game.flight_ended.connect(_on_flight_ended)
	game.status_changed.connect(func(text: String) -> void: start_menu.set_status(text))
	_connect_screens()


## Сигналы экранов (заново — после перестройки UI при смене языка).
func _connect_screens() -> void:
	start_menu.language_requested.connect(_on_language_requested)
	start_menu.fly_requested.connect(func(s: FlightSettings) -> void: _fly(s))
	start_menu.setup_requested.connect(_open_flight_setup)
	start_menu.net_requested.connect(_open_net_screen)
	start_menu.settings_requested.connect(_open_overlay.bind(settings_panel, start_menu))
	start_menu.about_requested.connect(_open_overlay.bind(about_screen, start_menu))
	start_menu.controls_requested.connect(_open_overlay.bind(controls_screen, start_menu))
	pause_menu.controls_requested.connect(_open_overlay.bind(controls_screen, pause_menu))
	controls_screen.closed.connect(_close_overlay)
	flight_setup_screen.closed.connect(_close_overlay)
	flight_setup_screen.done.connect(_on_flight_setup_done)
	start_menu.quit_requested.connect(_quit.bind(0))
	pause_menu.resume_requested.connect(_resume)
	pause_menu.restart_requested.connect(_restart)
	pause_menu.settings_requested.connect(_open_overlay.bind(settings_panel, pause_menu))
	pause_menu.menu_requested.connect(_show_menu)
	pause_menu.quit_requested.connect(_quit.bind(0))
	settings_panel.closed.connect(_on_settings_closed)
	about_screen.closed.connect(_close_overlay)
	result_screen.restart_requested.connect(_restart)
	result_screen.continue_requested.connect(_on_result_continue)
	result_screen.menu_requested.connect(_show_menu)


func _on_settings_closed(changed: bool) -> void:
	if changed:
		game.apply_user_settings()
	_close_overlay()
	if TranslationServer.get_locale() != _ui_locale:
		_rebuild_ui.call_deferred()


## Переключатель языка в главном меню: включить, запомнить, перестроить экраны.
func _on_language_requested(code: String) -> void:
	Language.select(code, user_config_dir)
	if TranslationServer.get_locale() != _ui_locale:
		_rebuild_ui.call_deferred(true)


## Экраны строят тексты один раз в _ready — при смене языка они пересоздаются из своих сцен
## (видимость и «куда вернуться» переносятся), сигналы подключаются заново.
func _rebuild_ui(focus_language: bool = false) -> void:
	_ui_locale = TranslationServer.get_locale()
	var old: Array[Control] = [
		start_menu,
		pause_menu,
		settings_panel,
		about_screen,
		result_screen,
		controls_screen,
		flight_setup_screen,
		loading_screen
	]
	var ui := $UI
	var fresh: Array[Control] = []
	for c: Control in old:
		var n: Control = load(c.scene_file_path).instantiate()
		var idx := c.get_index()
		var node_name := c.name
		ui.remove_child(c)
		n.name = node_name
		ui.add_child(n)
		n.visible = c.visible
		ui.move_child(n, idx)
		fresh.append(n)
		if _overlay_back == c:
			_overlay_back = n
	start_menu = fresh[0]
	pause_menu = fresh[1]
	settings_panel = fresh[2]
	about_screen = fresh[3]
	result_screen = fresh[4]
	controls_screen = fresh[5]
	flight_setup_screen = fresh[6]
	loading_screen = fresh[7]
	for c: Control in old:
		c.free()
	_connect_screens()
	start_menu.set_settings(flight)
	start_menu.set_busy(state == State.LOADING)
	if focus_language:
		start_menu.focus_language()


func _open_flight_setup() -> void:
	flight_setup_screen.set_settings(flight)
	_open_overlay(flight_setup_screen, start_menu)


## «Сетевая игра»: место — здесь, крыло/масса/время/погода — из последнего «Полёт…».
## fly_requested экрана пока не подключён: сетевой полёт — NET-40 (scripts/game/).
func _open_net_screen() -> void:
	if net_screen == null:
		net_screen = (load("res://scenes/ui/net_screen.tscn") as PackedScene).instantiate()
		net_screen.settings = flight.duplicate()
		net_screen.visible = false
		$UI.add_child(net_screen)
		net_screen.closed.connect(_close_overlay)
	_open_overlay(net_screen, start_menu)


## «Готово» в «Полёт…»: выбор запомнить и вернуться в меню (в полёт — только «Лететь»).
func _on_flight_setup_done(s: FlightSettings) -> void:
	flight = s
	UserSettings.save_last_flight(s)
	start_menu.set_settings(s)
	_close_overlay()


## «Продолжить» после посадки: ходьба по земле с места посадки, новый разбег — новый полёт.
func _on_result_continue() -> void:
	result_screen.visible = false
	get_tree().paused = false
	game.continue_on_foot()
	game.set_paused(false)
	state = State.FLYING


# ---------------------------------------------------------------- проверки и скриншоты


## Проверка собранной игры (tools/build.sh): конфиги, данные, атрибуция, полёт 300 шагов.
func _smoke_test() -> void:
	var sim := Config.get_config("sim")
	print("smoke: physics_hz=%s dirs=%s" % [sim.get("physics_hz"), Config.search_dirs()])
	print("smoke: wings=%s" % [Config.list_configs("wings")])
	print("smoke: locations=%s" % [Config.list_configs("locations")])
	var terrain_ok := FileAccess.file_exists("res://data/terrain/altai/meta.json")
	print("smoke: terrain data=%s" % terrain_ok)
	var ui: Dictionary = Config.get_config("ui")
	var credits := AssetsCredits.build_text(ui.about_sources, ui.license_files)
	var credits_ok := credits.contains("Copernicus")
	print("smoke: about text %d chars, ok=%s" % [credits.length(), credits_ok])
	var start: Vector3 = game.glider.get_telemetry().position
	for i in SMOKE_STEPS:
		await get_tree().physics_frame
	var t := game.glider.get_telemetry()
	var moved := t.position.distance_to(start)
	var air_name := (game.air.get_script() as Script).get_global_name()
	print(
		(
			"smoke: %d шагов, t=%.2f с, фаза %s, сдвиг %.1f м, воздух %s"
			% [SMOKE_STEPS, game.sim_time_s, t.phase, moved, air_name]
		)
	)
	var ok := not sim.is_empty() and terrain_ok and credits_ok and state == State.FLYING
	ok = ok and game.sim_time_s > 1.0 and moved > 1.0
	print("smoke: %s" % ("OK" if ok else "FAIL"))
	_quit(0 if ok else 1)


func _screenshot() -> void:
	if state == State.FLYING and opts.time_s > 0.0:
		while game.sim_time_s < opts.time_s and state == State.FLYING:
			await get_tree().physics_frame
			if _look_target != null:
				_look_target.global_position = _look_point()
	elif opts.time_s > 0.0:
		await get_tree().create_timer(opts.time_s).timeout
	match opts.open_screen:
		"pause":
			if state == State.FLYING:
				_pause()
		"settings":
			_open_overlay(settings_panel, start_menu if state == State.MENU else pause_menu)
		"about":
			_open_overlay(about_screen, start_menu if state == State.MENU else pause_menu)
		"controls":
			_open_overlay(controls_screen, start_menu if state == State.MENU else pause_menu)
		"setup":
			_open_flight_setup()
	if opts.no_overlay:
		game.overlay.visible = false
	for i in 8:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var jpg := opts.screenshot.get_extension().to_lower() in ["jpg", "jpeg"]
	var err := img.save_jpg(opts.screenshot, 0.9) if jpg else img.save_png(opts.screenshot)
	print("screenshot: %s (%s), t=%.1f с" % [opts.screenshot, error_string(err), game.sim_time_s])
	_quit(0 if err == OK else 1)


## Точка для --look-at: старт, центр ботов (в воздухе, иначе всех) или бот N; +2 м (крыло).
func _look_point() -> Vector3:
	var up := Vector3.UP * 2.0
	if opts.look_at == "start":
		return game.get_start().position + up
	var agents := game.bots.agents
	if opts.look_at.begins_with("bot") and opts.look_at != "bots":
		var i := int(opts.look_at.substr(3))
		return agents[i].model.position + up if i < agents.size() else Vector3.ZERO
	var sum := Vector3.ZERO
	var n := 0
	for pass_i in 2:
		for a in agents:
			if pass_i == 1 or a.is_airborne():
				sum += a.model.position
				n += 1
		if n > 0:
			break
	return sum / n + up if n > 0 else game.get_start().position + up


## Выход: сначала убрать игровой мир и дать аудиосерверу отпустить генераторы звука
## (quit в том же кадре, где удаляется сцена, оставляет их висеть).
func _quit(code: int) -> void:
	if is_instance_valid(game):
		game.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
