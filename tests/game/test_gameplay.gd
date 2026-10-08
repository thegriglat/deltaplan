extends Node
## 12-03. Геймплей свободного полёта: разбег (шаг/бег, поворот, трапеция на земле, отрыв без защёлки), камеры
## cockpit → chase → free и прибор в углу, страницы 1–5, вариометр 90-х = звук, пауза,
## «Заново», итог (поля info, завершение через FlightStats, кнопки итога).
## Физика — Game.tick() вручную (как tests/game/test_game_flight.gd); пауза — настоящим деревом.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const KEYS: Array[String] = [
	"run",
	"walk_forward",
	"walk_back",
	"turn_left",
	"turn_right",
	"pitch_pull_in",
	"pitch_push_out",
	"roll_left",
	"roll_right"
]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Главная сцена с автостартом, физику шагает тест. null — не загрузилась.
func _open() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	for i in 1200:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	if main.get("state") != 2:
		await _close(main)
		return null
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.camera.set_mode("cockpit")
	game.restart()
	return main


func _close(main: Node) -> void:
	_release()
	get_tree().paused = false
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func _release() -> void:
	for a in KEYS:
		if InputMap.has_action(a):
			Input.action_release(a)


func _press(actions: Array) -> void:
	for a: String in actions:
		Input.action_press(a)


func _ticks(game: Game, seconds: float) -> void:
	for i in int(seconds / DT):
		game.tick(DT)


static func _action(name: String) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = name
	ev.pressed = true
	return ev


## Нажать/отпустить физическую клавишу (как с клавиатуры: действия InputMap и состояние клавиши).
func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## Первая клавиша действия в карте controls.json → keys (раскладка не закладывается в тест).
static func _first_key(action: String, skip: Array = []) -> Key:
	for ev in InputMap.action_get_events(action):
		var k := ev as InputEventKey
		if k != null and not k.physical_keycode in skip:
			return k.physical_keycode
	return KEY_NONE


## С2 v2: шаг (walk_forward) без Shift, Shift — разбег без W, отпустил Shift — снова шаг;
## поворот на месте (turn_*) — курс без крена крыла.
func test_walk_run_and_turn_on_ground() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	_press(["walk_forward"])
	_ticks(game, 0.3)
	check(game.glider.phase() == "walking", "шаг (%s)" % game.glider.phase())
	check(not game.input_controller.control.run, "без Shift не бежит")
	_release()
	_press(["run"])
	_ticks(game, 0.3)
	check(game.glider.phase() == "running", "Shift без W — разбег (%s)" % game.glider.phase())
	check(game.input_controller.control.walk == 0.0, "на бегу walk = 0")
	Input.action_release("run")
	_press(["walk_forward"])
	_ticks(game, 0.1)
	check(
		not game.input_controller.control.run and game.input_controller.control.walk > 0.9,
		"отпустил Shift — снова шаг"
	)
	check(game.glider.phase() == "walking", "фаза — ходьба (%s)" % game.glider.phase())
	_release()
	_ticks(game, 0.2)
	var h0 := game.glider.get_telemetry().heading_deg
	_press(["turn_right"])
	_ticks(game, 1.0)
	var t := game.glider.get_telemetry()
	var dh := wrapf(t.heading_deg - h0, -180.0, 180.0)
	check(dh > 5.0, "turn_right на земле — поворот направо (%.1f°)" % dh)
	check(absf(game.input_controller.control.roll) < 1e-6, "поворот на месте — roll 0")
	await _close(main)


## У1 v3 / У2 v2 (ui-controls): на земле W/S — шаг, A/D — поворот; крыло — стрелки (и мышь, стик),
## стоя и на бегу (Shift); W/S/A/D крыло не двигают ни стоя, ни на бегу (мышь захвачена или нет).
## Клавиши — из карты, знак — по действию.
func test_ground_bar_keys() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ic := game.input_controller
	var inv := -1.0 if bool(Config.value("controls", "invert_pitch")) else 1.0
	var move := []
	for a in ["walk_forward", "walk_back", "turn_left", "turn_right"]:
		for ev in InputMap.action_get_events(a):
			if ev is InputEventKey:
				move.append((ev as InputEventKey).physical_keycode)
	var bar_key := _first_key("pitch_push_out", move)
	check(bar_key != KEY_NONE, "у «от себя» есть клавиша вне шага/поворота")
	_key(bar_key, true)
	_ticks(game, 1.0)
	var p_stand := ic.control.pitch
	_key(bar_key, false)
	_ticks(game, 1.5)
	print("    стоя «от себя» (%s) 1 с: pitch %.2f" % [OS.get_keycode_string(bar_key), p_stand])
	check(p_stand * inv > 0.9, "стоя клавиша трапеции — нос на полный ход: %.2f" % p_stand)
	check(game.glider.phase() == "standing", "стоит (%s)" % game.glider.phase())
	for captured in [true, false]:
		ic.set_mouse_captured(captured)
		for code in move:
			_key(code, true)
			_ticks(game, 0.5)
			var c := ic.control
			print(
				"    стоя %s (захват %s): pitch %.2f roll %.2f walk %.2f turn %.2f"
				% [OS.get_keycode_string(code), captured, c.pitch, c.roll, c.walk, c.turn]
			)
			check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "стоя %s — не крыло" % OS.get_keycode_string(code))
			check(absf(c.walk) > 0.9 or absf(c.turn) > 0.9, "стоя %s — шаг или поворот" % OS.get_keycode_string(code))
			_press(["run"])
			_ticks(game, 0.5)
			c = ic.control
			print("    на бегу %s: pitch %.2f roll %.2f" % [OS.get_keycode_string(code), c.pitch, c.roll])
			check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "на бегу %s — не крыло" % OS.get_keycode_string(code))
			check(c.walk == 0.0 and c.turn == 0.0, "на бегу walk/turn = 0")
			check(not ic.keys_look(), "на земле W/S/A/D — не обзор")
			_key(code, false)
			Input.action_release("run")
			# вернуться к старту: новый полёт с того же места
			game.restart()
			_ticks(game, 0.5)
	_key(bar_key, true)
	_press(["run"])
	_ticks(game, 0.5)
	var p_run := ic.control.pitch
	_key(bar_key, false)
	Input.action_release("run")
	print("    на бегу «от себя» (%s): pitch %.2f" % [OS.get_keycode_string(bar_key), p_run])
	check(p_run * inv > 0.5, "на бегу клавиша трапеции — нос: %.2f" % p_run)
	await _close(main)


## С2 v2: защёлки нет — зажатая на отрыве клавиша трапеции продолжает действовать, pitch/roll
## на отрыве непрерывны.
func test_no_latch_on_liftoff() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ic := game.input_controller
	ic.roll_input = "body"  # непрерывность на отрыве без PV1-инверсии (см. отчёт PV-3)
	# крен рукой на малую долю хода (≈ 1,5°): с большим креном бег уходит дугой поперёк склона и
	# опущенная консоль касается склона (срыв wingtip, на старте по умолчанию уже при ≈ 10°) — это
	# физика; здесь проверяется только непрерывность трапеции на отрыве
	_press(["run"])
	Input.action_press("roll_right", 0.1)
	var flew := false
	var prev_p := 0.0
	var prev_r := 0.0
	var dp := 0.0
	var dr := 0.0
	for i in int(15.0 / DT):
		game.tick(DT)
		var ph := game.glider.phase()
		if ph == "flying":
			dp = absf(ic.control.pitch - prev_p)
			dr = absf(ic.control.roll - prev_r)
			flew = true
			break
		prev_p = ic.control.pitch
		prev_r = ic.control.roll
	game.tick(DT)
	var tt := game.glider.get_telemetry()
	print("    отрыв: Δpitch %.4f, Δroll %.4f за шаг; roll после %.2f; фаза %s %s, крен %.1f°" % [dp, dr, ic.control.roll, tt.phase, game.glider.model.takeoff_failure, tt.bank_deg])
	check(flew, "взлетел разбегом Shift")
	check(dp < 0.02 and dr < 0.02, "на отрыве трапеция без скачка: %.4f / %.4f" % [dp, dr])
	check(ic.control.roll > 0.05, "зажатая клавиша крена действует и после отрыва: %.2f" % ic.control.roll)
	check(not ic.has_method("is_latched"), "защёлки нет")
	await _close(main)


## C: cockpit → chase → free → cockpit; прибор в углу только во внешних камерах.
func test_camera_cycle_and_corner_instrument() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	check(game.camera.mode == "cockpit" and not game.overlay.visible, "кабина: угла нет")
	var seen: Array[String] = []
	var overlay: Array[bool] = []
	for i in 3:
		game.camera._unhandled_input(_action("camera_next"))
		seen.append(game.camera.mode)
		overlay.append(game.overlay.visible)
	check(seen == ["chase", "free", "cockpit"], "порядок камер: %s" % [seen])
	check(overlay == [true, true, false], "прибор в углу по камере: %s" % [overlay])
	await _close(main)


## Сзади — не в рельефе; свободная — WASD двигает камеру, а не крыло.
func test_chase_above_ground_free_does_not_fly_wing() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var cam := game.camera
	cam.set_mode("chase")
	game.tick(DT)
	for i in 30:
		cam._process(1.0 / 60.0)
	var p := cam.global_position
	var min_agl := float(Config.value("camera", "chase.min_agl_m"))
	check(
		p.y >= game.terrain.height_at(p.x, p.z) + min_agl - 0.01,
		"chase над рельефом (%.1f м)" % (p.y - game.terrain.height_at(p.x, p.z))
	)
	cam.set_mode("free")
	cam._process(1.0 / 60.0)
	var c0 := cam.global_position
	var g0 := game.glider.get_telemetry().position
	_press(["walk_forward", "pitch_pull_in"])
	for i in 60:
		game.tick(DT * 2.0)
		cam._process(1.0 / 60.0)
	var moved := c0.distance_to(cam.global_position)
	check(moved > 3.0, "W двигает свободную камеру (%.1f м)" % moved)
	var g1 := game.glider.get_telemetry().position
	check(g0.distance_to(g1) < 0.05, "крыло стоит (%.2f м)" % g0.distance_to(g1))
	check(game.input_controller.control.walk == 0.0, "управление крылом нейтрально")
	await _close(main)


## Клавиши 1–5 листают планшет в любой камере.
func test_pages_1_to_5_any_camera() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	check(game.instrument.page_count() >= 5, "у планшета ≥ 5 страниц")
	var ok := true
	for m in ["cockpit", "chase", "free"]:
		game.camera.set_mode(m)
		for i in [3, 1, 5, 2, 4]:
			game._unhandled_input(_action("instrument_page_%d" % i))
			if game.instrument.get_page() != i - 1:
				ok = false
				failures.append("камера %s: клавиша %d → страница %d" % [m, i, game.instrument.get_page()])
	check(ok, "страницы 1–5 во всех камерах")
	await _close(main)


## Вариометр 90-х на стойке и звук: одно и то же показание.
func test_vario_90s_matches_sound() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 300.0
	game.glider.reset_in_air(p, float(st.heading_deg))
	var v90: Vario = null
	for n in game.mounted:
		var vd: Variant = n.get("vario90s")
		if vd is VarioDisplay90s:
			v90 = (vd as VarioDisplay90s).get_vario()
	var diff := 0.0
	var changed := false
	for i in int(8.0 / DT):
		game.tick(DT)
		var snd := game.vario_audio.synth.get_target_vario()
		if v90 != null and String(Config.value("audio", "vario_audio.preset")) == "classic_90s":
			diff = maxf(diff, absf(snd - v90.vario_ms))
		changed = changed or absf(snd) > 0.3
	check(changed, "звук получает показание вариометра")
	check(diff < 1e-4, "стрелка 90-х = звук (расхождение %.4f м/с)" % diff)
	await _close(main)


## Esc: дерево на паузе — Telemetry.time_s стоит, звук выключен; Esc ещё раз — идёт дальше.
func test_pause_freezes_time_and_sound() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_PAUSABLE  # как в main.tscn: время идёт настоящей физикой
	for i in 10:
		await get_tree().physics_frame
	main._unhandled_input(_action("pause"))
	check(main.get("state") == 3, "Esc — пауза")
	var t0 := game.glider.get_telemetry().time_s
	var s0 := game.sim_time_s
	for i in 20:
		await get_tree().physics_frame
	check(game.glider.get_telemetry().time_s == t0, "Telemetry.time_s стоит на паузе")
	check(game.sim_time_s == s0, "время симуляции стоит")
	check(not game.vario_audio.enabled and not game.flight_audio.enabled, "звук выключен")
	main._unhandled_input(_action("pause"))
	check(main.get("state") == 2, "Esc — снова полёт")
	for i in 10:
		await get_tree().physics_frame
	check(game.glider.get_telemetry().time_s > t0, "после паузы время идёт")
	check(game.vario_audio.enabled, "звук снова включён")
	await _close(main)


## QL-7 (Q-18): пауза → «Осмотреться»: камера двигается, физика и время стоят; Esc — меню паузы;
## «Продолжить» — полёт и прежний режим камеры.
func test_pause_look_around() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	for i in 5:
		await get_tree().physics_frame
	var mode0 := game.camera.mode
	main._unhandled_input(_action("pause"))
	var pos0 := game.glider.get_telemetry().position
	var t0 := game.glider.get_telemetry().time_s
	main.pause_menu.look_around_requested.emit()
	check(game.camera.mode == "free", "осмотр — свободная камера")
	check(not main.pause_menu.visible, "меню паузы скрыто на время осмотра")
	for i in 3:
		await get_tree().process_frame
	var c0 := game.camera.global_position
	Input.action_press("walk_back")
	for i in 20:
		await get_tree().process_frame
	Input.action_release("walk_back")
	check(game.camera.global_position.distance_to(c0) > 0.5, "камера сдвинулась в паузе")
	check(game.glider.get_telemetry().position == pos0, "положение пилота не изменилось")
	check(game.glider.get_telemetry().time_s == t0, "time_s не изменился")
	main._unhandled_input(_action("pause"))
	check(main.get("state") == 3 and main.pause_menu.visible, "Esc в осмотре — меню паузы")
	check(game.camera.mode == mode0, "из осмотра возвращён прежний режим камеры")
	main.pause_menu.look_around_requested.emit()
	main._unhandled_input(_action("pause"))
	main._unhandled_input(_action("pause"))
	check(main.get("state") == 2, "Esc из меню — полёт")
	check(game.camera.mode == mode0, "режим камеры прежний после продолжения")
	for i in 10:
		await get_tree().physics_frame
	check(game.glider.get_telemetry().time_s > t0, "после паузы время идёт")
	await _close(main)


## «Заново» (R) — на тот же старт ±1 м.
func test_restart_returns_to_start() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var st: Vector3 = game.get_start().position
	var far := st + Vector3(400, 0, 300)
	far.y = game.terrain.height_at(far.x, far.z) + 200.0
	game.glider.reset_in_air(far, 90.0)
	_ticks(game, 1.0)
	# В воздухе R — удержание (Q-03): нажатие само полёт не стирает, удержание — стирает.
	var n := game.flight_no
	Input.action_press("restart")
	main._unhandled_input(_action("restart"))
	check(game.flight_no == n, "R в воздухе сразу не рестартует")
	await get_tree().create_timer(float(Config.value("game", "restart_hold_s")) + 0.4).timeout
	Input.action_release("restart")
	check(game.flight_no == n + 1, "удержание R — рестарт")
	game.tick(DT)
	var p := game.glider.get_telemetry().position
	var dh := Vector2(p.x - st.x, p.z - st.z).length()
	var dv := absf(p.y - game.terrain.height_at(st.x, st.z))
	check(dh <= 1.0 and dv <= 1.0, "на старте: %.2f м по горизонтали, %.2f м по высоте" % [dh, dv])
	check(game.glider.phase() == "standing", "стоит на старте")
	check(game.sim_time_s < 0.1, "время полёта с нуля")
	await _close(main)


## Итог: все поля (время, дистанция, след, набор, макс. MSL, оценка посадки);
## время — из FlightStats целиком (reset_in_air посреди полёта не занижает его).
func test_result_info_fields() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ended: Array = []
	game.flight_ended.connect(func(k: String, i: Dictionary) -> void: ended.append([k, i]))
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 150.0
	game.glider.reset_in_air(p, float(st.heading_deg))
	_ticks(game, 12.0)
	# Как в test_e2e: подвинуть к земле, время модели обнуляется.
	var q := game.glider.get_telemetry().position
	q.y = game.terrain.height_at(q.x, q.z) + 3.0
	game.glider.reset_in_air(q, float(st.heading_deg) + 180.0)
	var t_touch := -1.0
	for i in int(20.0 / DT):
		game.tick(DT)
		if t_touch < 0.0 and game.glider.phase() == "landed":
			t_touch = game.sim_time_s
		if not ended.is_empty():
			break
	check(ended.size() == 1 and ended[0][0] == "landed", "посадка: %s" % [ended])
	if ended.is_empty():
		await _close(main)
		return
	var info: Dictionary = ended[0][1]
	for k in [
		"flight_time_s",
		"distance_m",
		"track_length_m",
		"height_gain_m",
		"total_climb_m",
		"max_altitude_msl_m",
		"grade",
		"vertical_speed_ms"
	]:
		check(info.has(k), "в info есть %s" % k)
	check(String(info.get("grade", "")) in ["soft", "hard", "crash"], "оценка: %s" % info.get("grade"))
	check(float(info.flight_time_s) >= 12.0, "время полёта целиком: %.1f с" % info.flight_time_s)
	check(float(info.track_length_m) > 50.0, "след: %.0f м" % info.track_length_m)
	check(
		game.sim_time_s - t_touch >= FlightStats.LANDING_CONFIRM_S - 0.05,
		"итог — после подтверждения посадки FlightStats"
	)
	await _close(main)


## Короткое касание сразу после разбега — не посадка: итог не сразу и «взлёт сорван».
func test_touch_near_start_is_not_landing() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ended: Array = []
	game.flight_ended.connect(func(k: String, i: Dictionary) -> void: ended.append([k, i]))
	_press(["run"])
	for i in int(15.0 / DT):
		game.tick(DT)
		if game.glider.phase() == "flying":
			break
	_release()
	check(game.glider.phase() == "flying", "взлетел")
	_ticks(game, 1.0)
	# «Чирк» по склону: низко, носом в гору.
	var t := game.glider.get_telemetry()
	var q := t.position
	q.y = game.terrain.height_at(q.x, q.z) + 1.0
	game.glider.reset_in_air(q, t.heading_deg + 180.0)
	var touch_t := -1.0
	for i in int(10.0 / DT):
		game.tick(DT)
		if touch_t < 0.0 and game.glider.get_telemetry().on_ground:
			touch_t = game.sim_time_s
			check(ended.is_empty(), "касание само по себе полёт не завершает")
		if not ended.is_empty():
			break
	check(not ended.is_empty(), "после удержания на земле — итог")
	if not ended.is_empty():
		check(ended[0][0] == "takeoff_failed", "до взведения — «взлёт сорван» (%s)" % ended[0][0])
		check((ended[0][1] as Dictionary).has("flight_time_s"), "и в нём сводка полёта")
	await _close(main)


## Экран итога: «В главное меню» → меню, «Ещё раз» → тот же старт.
func test_result_buttons() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var rs: ResultScreen = main.get_node("UI/ResultScreen")
	main.set("state", 4)
	rs.show_result("landed", {"grade": "soft"})
	rs.restart_requested.emit()
	check(main.get("state") == 2 and not rs.visible, "«Ещё раз» — снова полёт")
	check(game.glider.phase() == "standing", "на старте")
	main.set("state", 4)
	rs.show_result("landed", {"grade": "soft"})
	rs.menu_requested.emit()
	check(main.get("state") == 0, "«В главное меню» — меню")
	check((main.get_node("UI/StartMenu") as Control).visible, "меню видно")
	await _close(main)
