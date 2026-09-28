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
var _net_pause_timer: Timer  ## обновление списка пилотов зоны в паузе (NET-52), 2 Гц
## Выбор «Полёт…» до сетевого полёта (мир зоны его подменяет) — вернуть после выхода из зоны.
var _flight_before_net: FlightSettings
## Сеть: полёт кончился, пока открыта пауза (мир идёт) — итог покажем после «Продолжить».
var _pending_result: Array = []

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
	_net_pause_timer = Timer.new()
	_net_pause_timer.process_mode = Node.PROCESS_MODE_ALWAYS  # пауза дерева его не должна стопорить
	_net_pause_timer.wait_time = 0.5
	_net_pause_timer.timeout.connect(_refresh_net_pause)
	add_child(_net_pause_timer)
	_connect_ui()
	NetZone.zone_left.connect(_on_zone_left)
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
	if opts.net_host or opts.net_join != "":
		await _debug_net()
	elif opts.autostart:
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
	loading_screen.set_net_info(NetPauseInfo.build(NetZone, NetPilots))
	start_menu.visible = false  # под экраном загрузки — только фон (при ошибке меню вернётся)
	game.air_start_m = opts.air_start_m
	game.air_start_agl_m = opts.air_start_agl_m
	game.bots_count = opts.bots if game.net == null else 0  # боты зоны — NET-44
	var ok: bool = await game.start(s)
	if ok and game.net != null:
		ok = await game.net.join_world()  # мир — на время зоны, сверка ключа мира
	loading_screen.close()
	start_menu.set_busy(false)
	if not ok:
		state = State.MENU
		start_menu.visible = true
		return
	flight.pilot_mass_kg = game.settings.pilot_mass_kg
	if not opts.autostart and game.net == null:
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
	_net_pause_timer.stop()
	_pending_result = []
	_end_net()
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
## В сети (NET-40) мир не останавливается — только меню, ввод выключен (крыло летит само).
func _pause() -> void:
	state = State.PAUSED
	get_tree().paused = game.net == null
	game.set_paused(true)
	_refresh_net_pause()
	_net_pause_timer.start()
	pause_menu.visible = true


func _resume() -> void:
	_net_pause_timer.stop()
	pause_menu.visible = false
	get_tree().paused = false
	game.set_paused(false)
	state = State.FLYING
	if not _pending_result.is_empty():
		var r := _pending_result
		_pending_result = []
		_show_result(String(r[0]), r[1])


func _restart() -> void:
	_net_pause_timer.stop()
	_pending_result = []
	result_screen.visible = false
	pause_menu.visible = false
	get_tree().paused = false
	game.restart()
	game.set_paused(false)
	state = State.FLYING


## Список пилотов зоны в паузе (NET-52) — не в зоне: NetPauseInfo.build вернёт {}, блок скрыт.
func _refresh_net_pause() -> void:
	if not is_instance_valid(game):  # выход из игры: мир уже убран
		return
	var own_alt: Variant = null
	if game.settings != null:
		own_alt = game.glider.get_telemetry().altitude_msl
	pause_menu.set_net_info(NetPauseInfo.build(NetZone, NetPilots, own_alt))


## «Выйти из зоны» в паузе (NET-52): выйти и вернуться в меню, как «В меню»
## (_show_menu выходит из зоны сама).
func _on_leave_zone_requested() -> void:
	_show_menu()


func _on_flight_ended(kind: String, info: Dictionary) -> void:
	if state != State.FLYING:
		_keep_net_result(kind, info)
		return
	await get_tree().create_timer(float(Config.value("game", "result_delay_s", 2.0)), false).timeout
	if state != State.FLYING:
		_keep_net_result(kind, info)
		return
	_show_result(kind, info)


## Сеть: на паузе мир идёт, и полёт может кончиться под меню — итог после «Продолжить».
func _keep_net_result(kind: String, info: Dictionary) -> void:
	if state == State.PAUSED and game.net != null:
		_pending_result = [kind, info]


func _show_result(kind: String, info: Dictionary) -> void:
	state = State.RESULT
	get_tree().paused = game.net == null  # в сети мир идёт дальше (NET-40)
	game.set_paused(true)
	result_screen.set_net_mode(game.net != null, game.net != null and game.net.friends_airborne())
	result_screen.show_result(kind, info)


## Настройки: время суток настраивается только вне зоны (время держит ×1 — game.gd, К3).
func _open_settings(back: Control) -> void:
	settings_panel.set_net_mode(game.net != null)
	_open_overlay(settings_panel, back)


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
	start_menu.settings_requested.connect(_open_settings.bind(start_menu))
	start_menu.about_requested.connect(_open_overlay.bind(about_screen, start_menu))
	start_menu.controls_requested.connect(_open_overlay.bind(controls_screen, start_menu))
	pause_menu.controls_requested.connect(_open_overlay.bind(controls_screen, pause_menu))
	controls_screen.closed.connect(_close_overlay)
	flight_setup_screen.closed.connect(_close_overlay)
	flight_setup_screen.done.connect(_on_flight_setup_done)
	start_menu.quit_requested.connect(_quit.bind(0))
	pause_menu.resume_requested.connect(_resume)
	pause_menu.restart_requested.connect(_restart)
	pause_menu.settings_requested.connect(_open_settings.bind(pause_menu))
	pause_menu.menu_requested.connect(_show_menu)
	pause_menu.quit_requested.connect(_quit.bind(0))
	pause_menu.leave_zone_requested.connect(_on_leave_zone_requested)
	settings_panel.closed.connect(_on_settings_closed)
	about_screen.closed.connect(_close_overlay)
	result_screen.restart_requested.connect(_restart)
	result_screen.continue_requested.connect(_on_result_continue)
	result_screen.menu_requested.connect(_show_menu)
	result_screen.continue_near_requested.connect(_on_result_continue_near)
	result_screen.to_start_requested.connect(_on_result_to_start)


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
## «Лететь» в зоне — _on_net_fly (NET-40).
func _open_net_screen() -> void:
	if net_screen == null:
		net_screen = (load("res://scenes/ui/net_screen.tscn") as PackedScene).instantiate()
		net_screen.settings = flight.duplicate()
		net_screen.visible = false
		$UI.add_child(net_screen)
		net_screen.closed.connect(_close_overlay)
		net_screen.fly_requested.connect(_on_net_fly)
	_open_overlay(net_screen, start_menu)


# ---------------------------------------------------------------- сетевой полёт (NET-40)


## «Лететь» в зоне: мир — из ключа зоны (у всех один), крыло и масса — свои из «Полёт…».
func _on_net_fly(_zone_settings: FlightSettings = null) -> void:
	if state != State.MENU or not NetZone.in_zone:
		return
	_close_net_screen_keep_zone()
	_flight_before_net = flight
	var ws := NetFlight.world_settings(NetZone, flight)
	game.world_seed = NetZone.world_seed
	game.enable_net(NetFlight.new())
	game.net.airborne_changed.connect(_on_net_airborne_changed)
	await _fly(ws)
	if state != State.FLYING:  # не загрузилось или вышли из зоны во время загрузки
		_end_net()


## Экран «Сетевая игра» убрать, не выходя из зоны: он выходит из неё, когда его прячут.
func _close_net_screen_keep_zone() -> void:
	if net_screen == null:
		return
	net_screen.release_to_flight()
	_overlay_back = null
	net_screen.queue_free()
	net_screen = null


## Выход из сетевого режима (меню, «Выйти из зоны», зона пропала): чужих убрать, из зоны выйти,
## сид и выбор «Полёт…» — как до сети.
func _end_net() -> void:
	if game.net == null:
		return
	game.disable_net()
	game.world_seed = -1
	if NetZone.in_zone:
		NetZone.leave_zone()
	if _flight_before_net != null:
		flight = _flight_before_net
		_flight_before_net = null


## Зона закрылась или связь пропала насовсем — в главное меню.
func _on_zone_left() -> void:
	if game.net != null and state != State.MENU and state != State.LOADING:
		_show_menu()


## Кто-то из друзей взлетел/сел — «Продолжить рядом» в открытом итоге появляется/пропадает.
func _on_net_airborne_changed(any: bool) -> void:
	if state == State.RESULT and game.net != null:
		result_screen.set_net_mode(true, any)


## «Продолжить рядом»: дальше с места посадки, буксир к другу — NET-42 (game.catch_up_nearest).
func _on_result_continue_near() -> void:
	_on_result_continue()
	game.catch_up_nearest()


## «На старт»: снова на старт, мир не сбрасывается (очередь — NET-43, game.return_to_launch).
func _on_result_to_start() -> void:
	_net_pause_timer.stop()
	_pending_result = []
	result_screen.visible = false
	pause_menu.visible = false
	get_tree().paused = false
	game.return_to_launch()
	game.set_paused(false)
	state = State.FLYING


## Отладка и скриншоты (--net-host / --net-join=КОД): войти в зону без экрана и сразу лететь.
func _debug_net() -> void:
	var pilot_name := opts.net_name if opts.net_name != "" else UserSettings.pilot_name()
	var entered := [""]
	var on_enter := func(c: String) -> void: entered[0] = c
	var on_err := func(c: String, t: String) -> void: entered[0] = "error: %s %s" % [c, t]
	NetZone.zone_entered.connect(on_enter)
	NetZone.zone_error.connect(on_err)
	if opts.net_host:
		NetZone.host_local(flight, opts.net_seed, maxi(opts.bots, 0), pilot_name, opts.net_port)
	else:
		# первые кадры (сборка шейдеров) бывают дольше таймаута подключения — переждать
		for i in 60:
			await get_tree().process_frame
		NetClient.connect_to_server(opts.net_server, pilot_name)
		var t0 := Time.get_ticks_msec()
		while not NetClient.is_online and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
		print("net: связь с %s — %s" % [opts.net_server, NetClient.is_online])
		NetZone.join_zone(opts.net_join)
	var t1 := Time.get_ticks_msec()
	while entered[0] == "" and Time.get_ticks_msec() - t1 < 15000:
		await get_tree().process_frame
	NetZone.zone_entered.disconnect(on_enter)
	NetZone.zone_error.disconnect(on_err)
	print("net: зона %s (я %s, ведущий %s)" % [entered[0], NetZone.my_id, NetZone.leader_id])
	if not NetZone.in_zone:
		_quit(1)
		return
	if opts.net_code_file != "":
		var f := FileAccess.open(opts.net_code_file, FileAccess.WRITE)
		if f != null:
			f.store_string(NetZone.code)
			f.close()
	await _on_net_fly()
	if opts.net_hide_remote and game.net != null:
		game.net.remote.visible = false
		_fix_sky_camera()


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
	if game.net != null and opts.time_s > 0.0:
		# сеть: --time — время зоны (кадры с двух машин в один момент), и итог — если открылся
		while NetZone.zone_time() < opts.time_s and state in [State.FLYING, State.RESULT]:
			await get_tree().process_frame
	elif state == State.FLYING and opts.time_s > 0.0:
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
				if game.net != null:  # сеть: мир под меню паузы идёт дальше (лог для проверки)
					var at: Vector3 = game.get_start().position
					print("net: пауза, мир %s" % game.net.world_summary(at, 0.0))
					await get_tree().create_timer(3.0).timeout
					print("net: пауза +3 с, мир %s" % game.net.world_summary(at, 0.0))
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
	if game.net != null and opts.net_hide_remote:
		_fix_sky_camera()
	if game.net != null:
		print("net: мир %s" % game.net.world_summary(game.get_start().position))
	for i in 8:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var jpg := opts.screenshot.get_extension().to_lower() in ["jpg", "jpeg"]
	var err := img.save_jpg(opts.screenshot, 0.9) if jpg else img.save_png(opts.screenshot)
	print("screenshot: %s (%s), t=%.1f с" % [opts.screenshot, error_string(err), game.sim_time_s])
	_quit(0 if err == OK else 1)


## Кадр неба сети (--net-hide-remote): камера неподвижно в 30 м над стартом, поворот --look от
## курса старта — у двух машин одна и та же точка и направление, что бы ни делали пилоты.
func _fix_sky_camera() -> void:
	var st := game.get_start()
	game.camera.process_mode = Node.PROCESS_MODE_DISABLED
	result_screen.visible = false
	var yaw := -deg_to_rad(float(st.heading_deg) + opts.look.x)
	var b := Basis.from_euler(Vector3(deg_to_rad(opts.look.y), yaw, 0.0), EULER_ORDER_YXZ)
	game.camera.global_transform = Transform3D(b, (st.position as Vector3) + Vector3.UP * 30.0)
	# Фокус атмосферы (круг, где рождаются термики) — тоже на старте, а не на своём пилоте:
	# пилоты стоят «без рук» и могут съехать по-разному — дальний край неба был бы разный.
	var focus := game.get_node_or_null("SkyShotFocus") as Node3D
	if focus == null:
		focus = Node3D.new()
		focus.name = "SkyShotFocus"
		game.add_child(focus)
	focus.global_position = st.position
	game.air.set("focus_node", focus)


## Точка для --look-at: старт, центр ботов (в воздухе, иначе всех) или бот N; +2 м (крыло).
func _look_point() -> Vector3:
	var up := Vector3.UP * 2.0
	if opts.look_at == "start":
		return game.get_start().position + up
	if opts.look_at == "remote":  # сеть: первый чужой пилот (кадры NET-40/41)
		var rp: Array = game.net.remote.pilots() if game.net != null else []
		return (rp[0].position as Vector3) + up if not rp.is_empty() else game.get_start().position + up
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
