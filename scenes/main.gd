extends Node
## Главная сцена: полётный мир (Game) + экраны интерфейса. Переходы:
## меню → загрузка → полёт ⇄ пауза, полёт → итог → (ещё раз | продолжить | меню).
## Никакого HUD в полёте (FR-21): экраны только меню, пауза, настройки, «Об игре», итог.
## Аргументы командной строки — scripts/game/launch_options.gd (--smoke, --screenshot=…).

enum State { MENU, LOADING, FLYING, PAUSED, RESULT }

const SMOKE_STEPS := 300
const SMOKE_TIMEOUT_S := 90.0

var state: State = State.MENU:
	set(v):
		state = v
		_publish_activity()
var opts: LaunchOptions
var flight: FlightSettings
## Папка user-конфигов для выбора языка (тесты подменяют, чтобы не трогать профиль).
var user_config_dir: String = UserSettings.DEFAULT_DIR
## «Сетевая игра» (NET-50): создаётся при открытии, удаляется при закрытии.
var net_screen: NetScreen = null
## «Догнать» (NET-42): меню `=` поверх полёта в сетевой зоне.
var catch_up_menu: CatchUpMenu

## Подсказка управления на старте каждого полёта (Q-08): слева клавиши, справа мышь.
var _start_hint: Control
var _toast: Label  ## строка «Снимок: …»
var _toast_stamp := 0
## Каталог снимков экрана по F12 (Q-11); тесты подменяют.
var screenshot_dir: String = ""  # пусто — UserSettings.screenshot_dir()
## Откуда брать картинку для F12 (по умолчанию — вьюпорт; тесты без экрана подставляют свою).
var screenshot_source: Callable = func() -> Image: return get_viewport().get_texture().get_image()

var _look_prev_mode := ""  ## «Осмотреться» в паузе (Q-18): прежний режим камеры, "" — не осматриваемся
var _overlay_back: Control  ## экран, к которому вернуться из настроек / «Об игре»
var _look_target: Node3D  ## --look-at: куда смотреть в кабине (скриншоты)
var _ui_locale := ""  ## язык, на котором построены экраны (сменился — перестроить)
var _net_pause_timer: Timer  ## обновление списка пилотов зоны в паузе (NET-52), 2 Гц
## Выбор «Полёт…» до сетевого полёта (мир зоны его подменяет) — вернуть после выхода из зоны.
var _flight_before_net: FlightSettings
## Сеть: полёт кончился, пока открыта пауза (мир идёт) — итог покажем после «Продолжить».
var _pending_result: Array = []
## Q-02: итог ждёт result_delay_s после конца полёта — любая клавиша показывает его сразу.
var _result_waiting := false
var _skip_result := false
## Q-03: R в воздухе — удержание restart_hold_s; _restart_hold_s < 0 — не удерживаем.
var _restart_hold_s := -1.0
var _hold_bar: ProgressBar
var _hold_box: Control
## Лобби Steam (ST-8, S5): автозагрузка SteamLobby; тесты подставляют свой экземпляр до add_child.
var steam_lobby: Node
## Вход по приглашению Steam уже ждёт конца загрузки (не запускать второй раз).
var _steam_join_scheduled := false

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
	_setup_catch_up_menu()
	NetZone.zone_left.connect(_on_zone_left)
	if steam_lobby == null:
		steam_lobby = get_node_or_null("/root/SteamLobby")
	if steam_lobby != null:
		steam_lobby.join_lobby_requested.connect(_on_steam_join_requested)
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
	if opts.seed >= 0:
		game.world_seed = opts.seed  # --seed: день задан (меню и --autostart)
	if opts.net_host or opts.net_create or opts.net_join != "":
		await _debug_net()
	elif opts.autostart:
		await _fly(flight)
	else:
		await _show_menu()
		# запуск Steam с «+connect_lobby <id>»: сразу экран «Сетевая игра» и вход
		if steam_lobby != null and int(steam_lobby.pending_lobby) > 0:
			_on_steam_join_requested(int(steam_lobby.pending_lobby))
	if opts.smoke:
		_smoke_test()
	elif opts.perf_s > 0.0:
		_perf()
	elif opts.screenshot != "":
		_screenshot()


func _process(delta: float) -> void:
	_restart_hold_step(delta)
	if _start_hint != null and _start_hint.visible:
		var phase: String = game.glider.phase() if game.glider != null else ""
		if state != State.FLYING or not phase in ["standing", "walking", "running"]:
			_hide_start_hint()


func _unhandled_input(event: InputEvent) -> void:
	if _skip_on_key(event):
		return
	if event.is_action_pressed("screenshot"):
		get_viewport().set_input_as_handled()
		_screenshot_key()
		return
	if _start_hint != null and _start_hint.visible and event.is_action_pressed("walk_forward"):
		_hide_start_hint()  # первое W — подсказка уходит; клавишу не съедаем
	# «Догнать» (NET-42): Esc или `=` на буксире — отмена (физика на месте); `=` — меню.
	if state == State.FLYING and game.is_towing():
		if event.is_action_pressed("pause") or event.is_action_pressed(CatchUpMenu.ACTION):
			get_viewport().set_input_as_handled()
			game.abort_catch_up()
			return
	if event.is_action_pressed(CatchUpMenu.ACTION) and state == State.FLYING and game.net != null:
		get_viewport().set_input_as_handled()
		open_catch_up_menu()
		return
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		match state:
			State.FLYING:
				_pause()
			State.PAUSED:
				if _look_prev_mode != "":
					_end_look_around()
				elif _overlay_open():
					_close_overlay()
				else:
					_resume()
			State.MENU:
				if _overlay_open():
					_close_overlay()
	elif (
		event.is_action_pressed("restart")
		and state in [State.FLYING, State.RESULT]
		and not game.inspect_mode
	):
		get_viewport().set_input_as_handled()
		if state == State.FLYING and game.is_airborne():
			_restart_hold_s = 0.0  # в воздухе — удержание (Q-03), ход — в _process
		else:
			_restart()


## Q-03: ход удержания R в воздухе — полоска; отпустили, ушли в паузу или сели — отмена.
func _restart_hold_step(delta: float) -> void:
	if _restart_hold_s < 0.0:
		return
	var need := maxf(float(Config.value("game", "restart_hold_s", 1.0)), 0.01)
	if (
		state != State.FLYING
		or not game.is_airborne()
		or not Input.is_action_pressed("restart")
	):
		_set_restart_hold(-1.0, need)
		return
	_restart_hold_s += delta
	if _restart_hold_s >= need:
		_set_restart_hold(-1.0, need)
		_restart()
		return
	_set_restart_hold(_restart_hold_s, need)


func _set_restart_hold(v: float, need: float) -> void:
	_restart_hold_s = v
	if _hold_box == null:
		if v < 0.0:
			return
		_build_hold_bar()
	_hold_box.visible = v >= 0.0
	_hold_bar.max_value = need
	_hold_bar.value = maxf(v, 0.0)


func _build_hold_bar() -> void:
	var box := VBoxContainer.new()
	box.name = "RestartHold"
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.offset_top = -160.0
	box.custom_minimum_size = Vector2(280, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := Label.new()
	lbl.text = tr("restart_hold")
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(lbl)
	_hold_bar = ProgressBar.new()
	_hold_bar.show_percentage = false
	_hold_bar.custom_minimum_size = Vector2(280, 14)
	_hold_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_hold_bar)
	$UI.add_child(box)
	_hold_box = box


func _is_wing_control(event: InputEvent) -> bool:
	for a in ["pitch_push_out", "pitch_pull_in", "roll_left", "roll_right", "center", "run", "walk_forward", "walk_back", "turn_left", "turn_right"]:
		if InputMap.has_action(a) and event.is_action_pressed(a):
			return true
	var key := event as InputEventKey
	if key != null:
		var k := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		return k in [KEY_W, KEY_S, KEY_A, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_SHIFT]
	return false


## Q-02: после касания любая клавиша (кроме R и Esc) не ждёт подтверждения посадки и задержки итога.
func _skip_on_key(event: InputEvent) -> bool:
	if state != State.FLYING or game.inspect_mode:
		return false
	var key := event as InputEventKey
	var pressed: bool = (
		(key != null and key.pressed and not key.echo)
		or (event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed)
	)
	if not pressed or event.is_action_pressed("restart") or event.is_action_pressed("pause"):
		return false
	var min_s := float(Config.value("game", "landing_skip_min_s", 0.5))
	if not _result_waiting:
		# Посадка ещё не подтверждена: клавиши управления крылом ожидание не пропускают.
		if not game.landing_pending(min_s) or _is_wing_control(event):
			return false
	get_viewport().set_input_as_handled()
	if not _result_waiting:
		game.finish_now()  # flight_ended → _on_flight_ended начнёт ожидание
	_skip_result = true
	return true


# ---------------------------------------------------------------- переходы


## «Лететь» из меню: новый день — новый случайный сид мира (--seed — заданный). «Ещё раз» и
## «Продолжить» сид не меняют; --autostart сюда не ходит (сид из atmosphere.json или --seed).
func _on_menu_fly(s: FlightSettings) -> void:
	game.world_seed = opts.seed if opts.seed >= 0 else _new_seed()
	await _fly(s)


## «Осмотр карты»: тот же мир и ветер, но без полёта — сразу свободная камера. Выход — Esc → меню.
func _on_menu_inspect(s: FlightSettings) -> void:
	game.world_seed = opts.seed if opts.seed >= 0 else _new_seed()
	await _fly(s, true)


## Новый случайный сид мира (0..2^31−1), как у «Создать» на экране сети.
static func _new_seed() -> int:
	return randi() & 0x7fffffff


func _fly(s: FlightSettings, inspect := false) -> void:
	state = State.LOADING
	flight = s
	get_tree().paused = false
	start_menu.set_busy(true)
	loading_screen.open(game.terrain.progress, StartMenu.summary_text(s).replace("\n", " · "))
	loading_screen.set_net_info(NetPauseInfo.build(NetZone, NetPilots))
	start_menu.visible = false  # под экраном загрузки — только фон (при ошибке меню вернётся)
	game.air_start_m = opts.air_start_m
	game.air_start_agl_m = opts.air_start_agl_m
	game.inspect_mode = inspect
	game.bots_count = 0 if inspect else (opts.bots if game.net == null else 0)  # боты зоны — NET-44
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
	print("Мир: %s" % game.world_key())  # повторить день: --seed и те же место/время/погода
	if not opts.autostart and game.net == null:
		UserSettings.save_last_flight(s)
	start_menu.visible = false
	if inspect:
		game.enter_inspect()
		state = State.FLYING
		return
	game.set_flying(true)
	if opts.camera != "":
		game.camera.set_mode(opts.camera)
	if opts.fov_deg > 0.0:
		game.camera.fov = opts.fov_deg
	if opts.look != Vector2.ZERO:
		game.camera.set_look(opts.look.x, opts.look.y)
	if opts.glance:
		Input.action_press("look_instrument")
	game.debug_overlays.enable(opts.debug_overlays)
	_force_eggs()
	if opts.look_at != "":
		_look_target = Node3D.new()
		_look_target.name = "LookTarget"
		game.add_child(_look_target)
		_look_target.global_position = _look_point()
		game.camera.glance_target = _look_target
		Input.action_press("look_instrument")
	state = State.FLYING
	_maybe_show_start_hint()


func _maybe_show_start_hint() -> void:
	if not opts.autostart and not game.inspect_mode:
		_show_start_hint()


## Старт полёта: полупрозрачная подсказка слева (клавиши) и справа (мышь), центр свободен.
func _show_start_hint() -> void:
	if _start_hint == null:
		_start_hint = Control.new()
		_start_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_start_hint.set_anchors_preset(Control.PRESET_FULL_RECT)
		_start_hint.modulate.a = 0.65
		for side: String in ["Left", "Right"]:
			var p := PanelContainer.new()
			p.name = side
			p.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var left: bool = side == "Left"
			p.set_anchors_preset(Control.PRESET_BOTTOM_LEFT if left else Control.PRESET_BOTTOM_RIGHT)
			p.grow_vertical = Control.GROW_DIRECTION_BEGIN
			p.grow_horizontal = Control.GROW_DIRECTION_END if left else Control.GROW_DIRECTION_BEGIN
			p.offset_left = 40 if left else -40
			p.offset_right = p.offset_left
			p.offset_top = -60
			p.offset_bottom = -60
			var l := Label.new()
			l.name = "Text"
			l.custom_minimum_size.x = 420
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			p.add_child(l)
			_start_hint.add_child(p)
		$UI.add_child(_start_hint)
	(_start_hint.get_node("Left/Text") as Label).text = ControlsScreen.start_hint_keys_text()
	(_start_hint.get_node("Right/Text") as Label).text = ControlsScreen.start_hint_mouse_text()
	_start_hint.visible = true


func _hide_start_hint() -> void:
	if _start_hint != null:
		_start_hint.visible = false


## F12: снимок экрана в screenshot_dir; путь — в журнал.
func _screenshot_key() -> void:
	if DisplayServer.get_name() != "headless":  # без окна кадр не рисуется
		await RenderingServer.frame_post_draw
	var path := UserSettings.save_screenshot(screenshot_source.call(), screenshot_dir)
	var shown := ProjectSettings.globalize_path(path) if path != "" else "ошибка записи"
	print("screenshot: %s" % shown)
	_show_toast(tr("screenshot_saved") % shown)


## Короткая строка внизу экрана (~2 с).
func _show_toast(text: String) -> void:
	if _toast == null:
		_toast = Label.new()
		_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_toast.offset_bottom = -20
		_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_toast.process_mode = Node.PROCESS_MODE_ALWAYS
		$UI.add_child(_toast)
	_toast.text = text
	_toast.visible = true
	var my := Time.get_ticks_msec()
	_toast_stamp = my
	await get_tree().create_timer(2.0, true).timeout
	if _toast_stamp == my:
		_toast.visible = false


## Состояние экрана → Activity (S3). В полёте режим по фазе пилота ведёт Game; здесь — начальный.
func _publish_activity() -> void:
	if game == null:
		return
	match state:
		State.MENU:
			Activity.set_state({"mode": "menu", "place": "", "net": false, "zone_code": "", "peers": 0})
		State.LOADING:
			Activity.set_state({"mode": "loading", "place": Activity.place_name(flight)})
		State.PAUSED:
			Activity.set_state({"mode": "paused"})
		State.RESULT:
			Activity.set_state({"mode": "landed"})
		State.FLYING:
			var phase: String = game.glider.phase() if game.glider != null else "standing"
			Activity.set_state({"mode": Activity.mode_for_phase(phase)})


func _show_menu() -> void:
	catch_up_menu.close()
	_net_pause_timer.stop()
	_pending_result = []
	_end_look_around(false)
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
	game.leave_inspect()
	game.set_flying(false)
	start_menu.visible = true
	start_menu.set_settings(flight)
	# Мир за меню не грузим: он тяжёлый (рельеф, OSM, боты, фоновые поля рельефа) и тормозил
	# меню, а под картинкой фона его не видно. Грузится по «Лететь» с экраном загрузки.
	# После полёта мир уже есть — сброс на старт, как раньше.
	if game.settings != null:
		game.restart()


## Загрузить мир «за меню» (как было до 0.8.0): на площадке локации, точку с карты — нет.
## Меню само мир больше не грузит; нужно тестам, которым нужен готовый мир без «Лететь».
func load_menu_world() -> void:
	if game.settings != null:
		return
	var bg := flight.duplicate()
	bg.pick_lat = NAN
	bg.pick_lon = NAN
	await game.start(bg)


## Esc: физика стоит (дерево на паузе, Telemetry.time_s не растёт), звук молчит.
## В сети (NET-40) мир не останавливается — только меню, ввод выключен (крыло летит само).
func _pause() -> void:
	catch_up_menu.close()
	state = State.PAUSED
	get_tree().paused = game.net == null
	game.set_paused(true)
	_refresh_net_pause()
	_net_pause_timer.start()
	pause_menu.visible = true


## Осмотреться в паузе (Q-18): мир стоит, камера обрабатывается (свободная); Esc — назад в меню.
func _look_around() -> void:
	_look_prev_mode = game.camera.mode
	pause_menu.visible = false
	game.camera.process_mode = Node.PROCESS_MODE_ALWAYS
	game.camera.look_enabled = true
	game.camera.set_mode("free")


## Вернуть прежний режим камеры; menu — показать меню паузы (Esc), иначе уходим из паузы.
func _end_look_around(menu := true) -> void:
	if _look_prev_mode == "":
		return
	game.camera.set_mode(_look_prev_mode)
	_look_prev_mode = ""
	game.camera.process_mode = Node.PROCESS_MODE_INHERIT
	game.camera.look_enabled = not game.is_paused()
	pause_menu.visible = menu


func _resume() -> void:
	_end_look_around(false)
	_net_pause_timer.stop()
	pause_menu.visible = false
	get_tree().paused = false
	game.set_paused(false)
	state = State.FLYING
	if not _pending_result.is_empty():
		var r := _pending_result
		_pending_result = []
		_show_result(String(r[0]), r[1])


func _cancel_result_wait() -> void:
	_skip_result = _result_waiting  # ждущий итог проснётся и сам отбросит старый полёт
	_restart_hold_s = -1.0
	if _hold_box != null:
		_hold_box.visible = false


func _restart() -> void:
	catch_up_menu.close()
	_net_pause_timer.stop()
	_pending_result = []
	_cancel_result_wait()
	result_screen.visible = false
	pause_menu.visible = false
	get_tree().paused = false
	game.restart()
	game.set_paused(false)
	_force_eggs()
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
	_skip_result = false
	_result_waiting = true
	var left := float(Config.value("game", "result_delay_s", 2.0))
	while left > 0.0 and not _skip_result and is_inside_tree():
		await get_tree().process_frame
		if state == State.FLYING:
			left -= get_process_delta_time()
		elif state != State.PAUSED or game.net != null:
			break  # сеть на паузе — итог ждёт в _pending_result; одиночная — таймер стоит на паузе
	_result_waiting = false
	_skip_result = false
	if not is_inside_tree():
		return
	if state != State.FLYING:
		_keep_net_result(kind, info)
		return
	_show_result(kind, info)


## Сеть: на паузе мир идёт, и полёт может кончиться под меню — итог после «Продолжить».
func _keep_net_result(kind: String, info: Dictionary) -> void:
	if state == State.PAUSED and game.net != null:
		_pending_result = [kind, info]


func _show_result(kind: String, info: Dictionary) -> void:
	# QL-К1: итог старого полёта (после R / «Ещё раз» / «Продолжить») отбрасывается молча.
	if int(info.get("flight_no", game.flight_no)) != game.flight_no:
		return
	catch_up_menu.close()
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
	start_menu.fly_requested.connect(_on_menu_fly)
	start_menu.inspect_requested.connect(_on_menu_inspect)
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
	pause_menu.look_around_requested.connect(_look_around)
	pause_menu.settings_requested.connect(_open_settings.bind(pause_menu))
	pause_menu.menu_requested.connect(_show_menu)
	pause_menu.quit_requested.connect(_quit.bind(0))
	pause_menu.leave_zone_requested.connect(_on_leave_zone_requested)
	settings_panel.closed.connect(_on_settings_closed)
	about_screen.closed.connect(_close_overlay)
	result_screen.restart_requested.connect(_restart)
	result_screen.menu_requested.connect(_show_menu)
	result_screen.continue_near_requested.connect(_on_result_continue_near)
	result_screen.to_start_requested.connect(_on_result_to_start)
	result_screen.continue_on_foot_requested.connect(_on_result_continue)


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
		if steam_lobby != null:
			net_screen.backend = NetUiClientBackend.new(null, null, null, steam_lobby)
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
	game.world_seed = opts.seed  # как до сети: --seed или «не задан» (новый — по «Лететь»)
	if NetZone.in_zone:
		NetZone.leave_zone()
	if _flight_before_net != null:
		flight = _flight_before_net
		_flight_before_net = null


## Приглашение Steam принято (оверлей, «Присоединиться», «+connect_lobby», ST-8/S5): пилот сам
## выбрал — из полёта/паузы/итога выйти в меню (из зоны тоже), открыть «Сетевая игра»; вход
## в лобби начинает её клиент (ждущее лобби SteamLobby.pending_lobby). Отложенно: открытый
## экран ввода успевает войти сам, тогда ничего не трогаем.
func _on_steam_join_requested(_lobby_id: int) -> void:
	if _steam_join_scheduled:
		return
	_steam_join_scheduled = true
	await get_tree().process_frame
	while state == State.LOADING and is_inside_tree():
		await get_tree().process_frame
	_steam_join_scheduled = false
	if not is_inside_tree() or steam_lobby == null or int(steam_lobby.pending_lobby) <= 0:
		return  # уже вошёл открытый экран (или вход отменён)
	if state != State.MENU:
		_show_menu()
	if net_screen != null:
		net_screen.go_back()  # старая зона/подключение экрана — выйти, экран закрывается
	_overlay_back = start_menu  # не пауза/итог, из которых могли открыть настройки
	_close_overlay()
	_open_net_screen()


## Зона закрылась или связь пропала насовсем — в главное меню.
func _on_zone_left() -> void:
	if game.net != null and state != State.MENU and state != State.LOADING:
		_show_menu()


## Кто-то из друзей взлетел/сел — «Продолжить рядом» в открытом итоге появляется/пропадает.
func _on_net_airborne_changed(any: bool) -> void:
	if state == State.RESULT and game.net != null:
		result_screen.set_net_mode(true, any)


## «Продолжить рядом»: окно итога закрыть; один друг в воздухе — буксир к нему с места, где
## стоим; несколько — меню «Догнать» (NET-42).
func _on_result_continue_near() -> void:
	_on_result_continue()
	if game.catch_up_nearest() or game.net == null:
		return
	if CatchUpMenu.airborne_count(game.net.catch_up_list()) > 1:
		open_catch_up_menu()


# ---------------------------------------------------------------- «догнать» (NET-42)


func _setup_catch_up_menu() -> void:
	var ps := load("res://scenes/ui/catch_up_menu.tscn") as PackedScene
	catch_up_menu = ps.instantiate()
	catch_up_menu.name = "CatchUpMenu"
	$UI.add_child(catch_up_menu)
	catch_up_menu.catch_up_requested.connect(_on_catch_up_requested)
	catch_up_menu.closed.connect(func() -> void: game.hands_off = false)


## Меню «Догнать» поверх полёта (только в зоне): пока открыто — руки с трапеции.
func open_catch_up_menu() -> void:
	if game.net == null or state != State.FLYING:
		return
	var z: Object = game.net.zone
	catch_up_menu.self_id = String(z.get("my_id")) if z != null and "my_id" in z else ""
	var own_pos := func() -> Vector3: return game.glider.model.position
	catch_up_menu.set_source(game.net.catch_up_list, own_pos)
	catch_up_menu.open()
	game.hands_off = true


## Enter в меню: в воздухе — буксир к нему; на земле — на старт (NET-43: в конец очереди).
func _on_catch_up_requested(id: String) -> void:
	if game.net == null or state != State.FLYING:
		return
	game.catch_up_to(id)


## «На старт»: снова на старт, мир не сбрасывается (очередь — NET-43, game.return_to_launch).
func _on_result_to_start() -> void:
	_net_pause_timer.stop()
	_pending_result = []
	result_screen.visible = false
	pause_menu.visible = false
	get_tree().paused = false
	if game.net == null:
		game.restart(true)  # одиночная: без сброса дня и часов (Q-05)
	else:
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
		var zone_seed := opts.net_seed if opts.net_seed_set else opts.seed
		if zone_seed < 0:
			zone_seed = _new_seed()  # как «Создать» на экране сети — новый день
		NetZone.host_local(flight, zone_seed, maxi(opts.bots, 0), pilot_name, opts.net_port)
	else:
		# первые кадры (сборка шейдеров) бывают дольше таймаута подключения — переждать
		for i in 60:
			await get_tree().process_frame
		NetClient.connect_to_server(opts.net_server, pilot_name)
		var t0 := Time.get_ticks_msec()
		while not NetClient.is_online and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
		print("net: связь с %s — %s" % [opts.net_server, NetClient.is_online])
		if opts.net_create:
			var zone_seed := opts.net_seed if opts.net_seed_set else opts.seed
			if zone_seed < 0:
				zone_seed = _new_seed()
			NetZone.create_zone(flight, zone_seed, maxi(opts.bots, 0))
		else:
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
		var held := false
		while game.sim_time_s < opts.time_s and state == State.FLYING:
			if not held and opts.hold_key != "" and game.sim_time_s >= opts.time_s - opts.hold_key_s:
				held = true
				var ev := InputEventKey.new()
				ev.physical_keycode = OS.find_keycode_from_string(opts.hold_key)
				ev.pressed = true
				Input.parse_input_event(ev)
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
	if opts.gpu_report != "":
		await _report_gpu(opts.gpu_report)
	for i in 8:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var jpg := opts.screenshot.get_extension().to_lower() in ["jpg", "jpeg"]
	var err := img.save_jpg(opts.screenshot, 0.9) if jpg else img.save_png(opts.screenshot)
	print("screenshot: %s (%s), t=%.1f с" % [opts.screenshot, error_string(err), game.sim_time_s])
	_quit(0 if err == OK else 1)


## --gpu-report: среднее GPU-время кадра за 2 с (реальное время), строка EGG_GPU_MS <метка> <мс>.
func _report_gpu(label: String) -> void:
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 10:
		await RenderingServer.frame_post_draw
	var sum := 0.0
	var draws := 0
	var prims := 0
	var n := 0
	var t_end := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < t_end:
		await RenderingServer.frame_post_draw
		if _look_target != null:
			_look_target.global_position = _look_point()
		sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		draws += RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
		)
		prims += RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
		)
		n += 1
	n = maxi(n, 1)
	# Время GPU шумит сильнее цены лёгкой пасхалки — рядом вызовы отрисовки и примитивы кадра.
	print("EGG_GPU_MS %s %.3f draws %d prims %d" % [label, sum / n, draws / n, prims / n])


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


## Пасхалки по ключу --egg (или configs/easter_eggs.json → force): вызвать без кубика.
func _force_eggs() -> void:
	game.eggs.force_spec(opts.egg if opts.egg != "" else String(game.eggs.cfg.get("force", "")))


## Точка для --look-at: старт, центр ботов (в воздухе, иначе всех) или бот N; +2 м (крыло).
func _look_point() -> Vector3:
	var up := Vector3.UP * 2.0
	if opts.look_at == "start":
		return game.get_start().position + up
	if opts.look_at == "egg" or opts.look_at.begins_with("egg:"):
		# первая живая пасхалка; «egg:<id>» — первая с этим id (кадры пасхалок)
		var want := opts.look_at.substr(4)
		for e in game.eggs.active():
			if want == "" or e.id == want:
				return e.global_position
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
## --perf: время до меню, «Лететь» → первый кадр полёта, рывки кадра в первые perf_s с полёта.
## Время — от старта движка (Time.get_ticks_msec) и настенное (unix, для внешнего замера).
func _perf() -> void:
	await RenderingServer.frame_post_draw
	print("PERF menu_ms=%d unix=%.3f" % [Time.get_ticks_msec(), Time.get_unix_time_from_system()])
	var t0 := Time.get_ticks_usec()
	await _fly(flight)
	await RenderingServer.frame_post_draw
	print("PERF fly_ms=%d" % ((Time.get_ticks_usec() - t0) / 1000))
	# Рывок — кадр > 50 мс и > 2,5 медианы последних 30 кадров (фон загрузки GPU не считается).
	var hitches: Array[int] = []
	var recent: Array[int] = []
	var all_dt: Array[int] = []
	var t_prev := Time.get_ticks_usec()
	var t_end := t_prev + int(opts.perf_s * 1e6)
	while t_prev < t_end:
		await RenderingServer.frame_post_draw
		var t := Time.get_ticks_usec()
		var dt_ms := (t - t_prev) / 1000
		t_prev = t
		all_dt.append(dt_ms)
		var sorted := recent.duplicate()
		sorted.sort()
		var med: int = sorted[sorted.size() / 2] if not sorted.is_empty() else 16
		if dt_ms > 50 and dt_ms > med * 2.5:
			hitches.append(dt_ms)
		recent.append(dt_ms)
		if recent.size() > 30:
			recent.pop_front()
	all_dt.sort()
	var total := 0
	var worst := 0
	for h in hitches:
		total += h
		worst = maxi(worst, h)
	print(
		(
			"PERF hitches=%d total_ms=%d worst_ms=%d frames=%d median_ms=%d list=%s"
			% [hitches.size(), total, worst, all_dt.size(), all_dt[all_dt.size() / 2], hitches]
		)
	)
	print("PERF cloud_build_ms=%.1f" % CloudCompositorEffect.build_ms)
	_quit(0)


func _quit(code: int) -> void:
	if is_instance_valid(game):
		game.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
