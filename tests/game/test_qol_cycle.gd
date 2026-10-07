extends Node
## QL-1 (Q-01…Q-05): цикл «упал — снова». Номер полёта и итог старого полёта, R сразу после касания,
## любая клавиша — итог без ожидания, R в воздухе — удержание, «На старт» без сброса часов,
## кнопки итога в одиночной. Шаги физики — Game.tick() вручную.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _settle() -> void:
	for i in 3:
		await get_tree().process_frame


func _start() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	(main.get_node("Game") as Game).process_mode = Node.PROCESS_MODE_DISABLED
	return main


func _stop(main: Node) -> void:
	get_tree().paused = false
	Input.action_release("restart")
	main.queue_free()
	await _settle()


## Низко над склоном носом в гору: через пару секунд — касание. until_end: шагать до flight_ended.
func _drop(game: Game, until_end: bool) -> Array:
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 3.0
	game.glider.reset_in_air(p, float(st.heading_deg) + 180.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, i: Dictionary) -> void: ended.append([k, i]))
	for i in 120 * 20:
		game.tick(DT)
		if until_end:
			if not ended.is_empty():
				break
		elif game.stats.grounded_pending_s() > 0.6:
			break
	return ended


func _key(main: Node, code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	main.call("_unhandled_input", e)


func _restart_event(main: Node) -> void:
	var e := InputEventAction.new()
	e.action = "restart"
	e.pressed = true
	main.call("_unhandled_input", e)


func test_flight_no_and_info() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var n := game.flight_no
	check(n >= 1, "flight_no после start: %d" % n)
	game.restart()
	check(game.flight_no == n + 1, "restart +1")
	game.continue_on_foot()
	check(game.flight_no == n + 2, "continue_on_foot +1")
	game.set_paused(true)
	check(game.flight_no == n + 2, "пауза номер не меняет")
	game.set_paused(false)
	var ended := _drop(game, true)
	check(ended.size() == 1 and ended[0][0] == "landed", "посадка: %s" % [ended])
	if not ended.is_empty():
		check(int(ended[0][1].get("flight_no", -1)) == game.flight_no, "info.flight_no == flight_no")
	await _stop(main)


## Q-01: R вскоре после касания — итога старого полёта через result_delay_s + 0,5 с нет.
func test_restart_after_touch_discards_old_result() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var rs: Control = main.get_node("UI/ResultScreen")
	var ended := _drop(game, true)
	check(ended.size() == 1, "полёт закончился")
	await get_tree().process_frame  # _on_flight_ended начал ждать
	_restart_event(main)  # на земле — сразу
	check(main.get("state") == 2, "после R — снова в полёте")
	var n := game.flight_no
	await get_tree().create_timer(float(Config.value("game", "result_delay_s")) + 0.5).timeout
	check(not rs.visible, "итога старого полёта нет")
	check(main.get("state") == 2 and not get_tree().paused, "полёт идёт, пауза не включена")
	check(game.flight_no == n, "номер полёта не менялся")
	await _stop(main)


## Q-02: любая клавиша после конца полёта — итог сразу, не через result_delay_s.
func test_key_shows_result_at_once() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var rs: Control = main.get_node("UI/ResultScreen")
	_drop(game, true)
	await get_tree().process_frame
	check(not rs.visible, "сразу после конца итога ещё нет")
	_key(main, KEY_SPACE)
	await _settle()
	check(rs.visible and main.get("state") == 4, "после клавиши итог показан")
	await _stop(main)


## Q-02: касание, 1,5 с подтверждения ещё не прошли — клавиша не ждёт их.
func test_key_skips_landing_confirm() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var rs: Control = main.get_node("UI/ResultScreen")
	var ended := _drop(game, false)
	check(ended.is_empty() and game.stats.grounded_pending_s() > 0.6, "касание, посадка не подтверждена")
	check(game.stats.grounded_pending_s() < 1.5, "1,5 с ещё не прошло")
	_key(main, KEY_SPACE)
	await _settle()
	check(rs.visible, "итог показан без подтверждения посадки")
	await _stop(main)


## Q-03: R в воздухе — только удержание; короткое нажатие полёт не стирает.
func test_hold_r_in_air() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 200.0
	game.glider.reset_in_air(p, float(st.heading_deg))
	game.tick(DT)
	check(game.is_airborne(), "в воздухе")
	var n := game.flight_no
	var hold := float(Config.value("game", "restart_hold_s"))
	# Короткое: нажали и отпустили до срока.
	Input.action_press("restart")
	_restart_event(main)
	await get_tree().create_timer(hold * 0.4).timeout
	check(game.flight_no == n, "R не сработал раньше срока")
	check(main.get("_hold_box") != null and main.get("_hold_box").visible, "ход удержания виден")
	Input.action_release("restart")
	await get_tree().create_timer(hold + 0.3).timeout
	check(game.flight_no == n, "отпустили — полёт не стёрт")
	check(not main.get("_hold_box").visible, "полоска убрана")
	# Длинное.
	Input.action_press("restart")
	_restart_event(main)
	await get_tree().create_timer(hold + 0.5).timeout
	check(game.flight_no == n + 1, "удержание R — новый полёт: %d → %d" % [n, game.flight_no])
	check(game.glider.get_telemetry().on_ground, "снова на старте")
	await _stop(main)


## На земле R — сразу.
func test_r_on_ground_is_immediate() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var n := game.flight_no
	_restart_event(main)
	check(game.flight_no == n + 1, "R на старте — сразу")
	await _stop(main)


## Q-05: «На старт» в одиночной — часы идут дальше; «Ещё раз» сбрасывает на время старта.
func test_to_start_keeps_clock() -> void:
	var main := await _start()
	var game: Game = main.get_node("Game")
	var h0: float = game.sky.clock.hour
	game.sky.clock.set_hour(h0 + 2.0)
	main.call("_on_result_to_start")
	check(absf(game.sky.clock.hour - (h0 + 2.0)) < 0.01, "«На старт»: часы не сброшены (%.2f)" % game.sky.clock.hour)
	check(main.get("state") == 2, "в полёте")
	game.sky.clock.set_hour(h0 + 2.0)
	main.call("_restart")
	check(absf(game.sky.clock.hour - h0) < 0.05, "«Ещё раз»: часы на времени старта (%.2f)" % game.sky.clock.hour)
	await _stop(main)


## Q-04/Q-05: кнопки итога в одиночной.
func test_result_buttons_single() -> void:
	var main := await _start()
	var rs: ResultScreen = main.get_node("UI/ResultScreen")
	var soft := {"grade": "soft"}
	rs.show_result("landed", soft)
	check(rs.is_foot_shown(), "после мягкой посадки — «Продолжить пешком»")
	rs.show_result("landed", {"grade": "hard"})
	check(rs.is_foot_shown(), "после жёсткой — тоже")
	rs.show_result("landed", {"grade": "crash"})
	check(not rs.is_foot_shown(), "после аварии — нет")
	rs.show_result("takeoff_failed", {})
	check(not rs.is_foot_shown(), "после срыва взлёта — нет")
	var hits: Array = []
	rs.continue_on_foot_requested.connect(func() -> void: hits.append("foot"))
	rs.to_start_requested.connect(func() -> void: hits.append("start"))
	rs.show_result("landed", soft)
	for b: Button in rs.find_children("*", "Button", true, false):
		if b.visible and b.text in [tr("result_continue_on_foot"), tr("result_to_start")]:
			b.pressed.emit()
	check(hits.has("foot") and hits.has("start"), "обе кнопки шлют сигналы: %s" % [hits])
	# «Продолжить пешком» из главной сцены: новый отрезок полёта, итог закрыт.
	var game: Game = main.get_node("Game")
	var n := game.flight_no
	main.call("_show_result", "landed", {"grade": "soft", "flight_no": game.flight_no})
	check(rs.visible and main.get("state") == 4, "итог показан")
	rs.continue_on_foot_requested.emit()
	check(not rs.visible and main.get("state") == 2 and game.flight_no == n + 1, "пешком: полёт +1")
	await _stop(main)
