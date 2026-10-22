extends Node
## BM-К1 (docs/contracts/bar-mouse.md): мышь → штанга в отсчётах мыши. Ход не зависит от окна, частоты шагов
## и look_sensitivity_deg_per_px; мёртвая зона вычитается. Сцена в воздухе, события через вьюпорт, шаги — Game.tick().

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _mouse() -> Dictionary:
	return Config.get_config("controls").mouse


func _open() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--air-start=600,150"])))
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
	game.set_physics_process(false)
	return main


func _close(main: Node) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func _push(rel: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	var p := get_viewport().get_visible_rect().size * 0.5
	ev.position = p
	ev.global_position = p
	ev.relative = rel
	ev.screen_relative = rel
	get_viewport().push_input(ev)


func _restart(game: Game) -> void:
	game.restart()
	game.input_controller.set_mouse_captured(true)
	game.input_controller.roll_input = "body"


func _approx(a: float, b: float, msg: String) -> void:
	check(absf(a - b) < 1e-4, "%s: %.5f ≠ %.5f" % [msg, a, b])


## Ход мыши в px → control по оси; возвращает [pitch, roll] после шага.
func _control_after(game: Game, seq: Array, dt: float) -> Vector2:
	_restart(game)
	for i in 3:
		game.tick(dt)
	for rel in seq:
		_push(rel)
		game.tick(dt)
	var c := game.input_controller.control
	return Vector2(c.pitch, c.roll)


func test_travel_and_half_travel() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var m := _mouse()
	var dz := float(m.bar_deadzone)
	var tr_px := MouseBar.travel_px(m)
	var full := _control_after(game, [Vector2(tr_px, tr_px)], 1.0 / 120.0)
	_approx(full.y, 1.0, "travel_px вправо → roll = 1")
	_approx(full.x, -1.0, "travel_px на себя → pitch = −1")
	var half := _control_after(game, [Vector2(-tr_px * 0.5, -tr_px * 0.5)], 1.0 / 120.0)
	var e := (0.5 - dz) / (1.0 - dz)
	_approx(half.y, -e, "полхода влево → roll")
	_approx(half.x, e, "полхода от себя → pitch")
	var inside := _control_after(game, [Vector2(tr_px * dz * 0.9, 0.0)], 1.0 / 120.0)
	_approx(inside.y, 0.0, "внутри мёртвой зоны → 0")
	await _close(main)


## Размер окна в расчёт не входит: меняем окно (если в headless получится) — control тот же.
func test_window_size_independent() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var tr_px := MouseBar.travel_px(_mouse())
	var a := _control_after(game, [Vector2(tr_px * 0.3, 0.0)], 1.0 / 120.0)
	var w := get_window()
	var old := w.size
	w.size = Vector2i(640, 360) if old.y > 400 else Vector2i(1920, 1080)
	await get_tree().process_frame
	var changed := w.size != old
	var b := _control_after(game, [Vector2(tr_px * 0.3, 0.0)], 1.0 / 120.0)
	w.size = old
	print("BM-3: окно %s → %s (изменилось: %s), roll %.4f / %.4f" % [old, w.size, changed, a.y, b.y])
	_approx(a.y, b.y, "окно другого размера: тот же control")
	await _close(main)


## Одна последовательность px, разбитая на шаги 1/30 и 1/144 с, даёт один control (возврат к центру выключен).
func test_step_rate_independent() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var m := _mouse()
	var saved := float(m.bar_return_to_center_per_s)
	m["bar_return_to_center_per_s"] = 0.0
	var tr_px := MouseBar.travel_px(m)
	var seq: Array = []
	for i in 12:
		seq.append(Vector2(tr_px * 0.02, -tr_px * 0.015))
	var slow := _control_after(game, seq, 1.0 / 30.0)
	var fast := _control_after(game, seq, 1.0 / 144.0)
	m["bar_return_to_center_per_s"] = saved
	_approx(slow.x, fast.x, "pitch: шаги 1/30 и 1/144")
	_approx(slow.y, fast.y, "roll: шаги 1/30 и 1/144")
	check(absf(slow.y) > 0.1, "последовательность что-то сдвинула: %.3f" % slow.y)
	await _close(main)


## look_sensitivity_deg_per_px не меняет штангу ни в кабине, ни в chase.
func test_look_sensitivity_does_not_move_bar() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var m := _mouse()
	var saved: Variant = m.look_sensitivity_deg_per_px
	var tr_px := MouseBar.travel_px(m)
	for cam in ["cockpit", "chase"]:
		game.camera.set_mode(cam)
		var res: Array = []
		for s in [0.02, 0.5]:
			m["look_sensitivity_deg_per_px"] = s
			res.append(_control_after(game, [Vector2(tr_px * 0.4, -tr_px * 0.2)], 1.0 / 120.0))
		_approx(res[0].x, res[1].x, "%s: pitch не зависит от обзора" % cam)
		_approx(res[0].y, res[1].y, "%s: roll не зависит от обзора" % cam)
		check(absf(res[0].y) > 0.1, "%s: штанга двигалась" % cam)
	m["look_sensitivity_deg_per_px"] = saved
	await _close(main)


func test_os_accel_hint_in_locale() -> void:
	for loc in ["ru", "en"]:
		TranslationServer.set_locale(loc)
		var t := TranslationServer.translate("settings_bar_os_accel")
		check(t != "settings_bar_os_accel" and not t.is_empty(), "locale %s: settings_bar_os_accel" % loc)
	TranslationServer.set_locale("ru")
