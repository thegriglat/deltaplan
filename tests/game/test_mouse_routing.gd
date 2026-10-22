extends Node
## BM-1: куда идёт мышь по камерам (BM-К2 v1) в загруженной сцене полёта. Диагностика: печатает таблицу
## (штанга ControlInput.roll/pitch и накопленное смещение, голова, свободная камера) и проверяет
## строки BM-К2. Поведение не чинится. События — через настоящий вьюпорт, шаги — Game.tick().
## Headless: курсор не захватить (Input.mouse_mode остаётся VISIBLE), поэтому для CameraRig,
## который смотрит на Input.mouse_mode, режим выставляется сюда напрямую (как у реальной игры при захвате).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []
var _real_capture := false  # курсор действительно захвачен (не headless)


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


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
	main.get_node("Game").set_physics_process(false)
	return main


func _close(main: Node) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func _motion(rel: Vector2, cam: CameraRig = null) -> void:
	var p := get_viewport().get_visible_rect().size * 0.5
	var ev := InputEventMouseMotion.new()
	ev.position = p
	ev.global_position = p
	ev.relative = rel
	get_viewport().push_input(ev)
	# Headless не держит CAPTURED, а CameraRig._unhandled_input смотрит на Input.mouse_mode:
	# ветку «захвачена» повторяем как в camera_rig.gd (_unhandled_input) — решение _mouse_looks()
	# и _look() настоящие. При настоящем захвате (прогон с окном) событие дошло само.
	if cam != null and not _real_capture and cam.look_enabled:
		if cam._mouse_looks():
			if not cam._orbiting:  # орбита (ПКМ в free) уже отработала настоящим событием
				cam._look(rel)
		elif cam.mode == "free":
			cam._free_input(ev)


func _rmb(pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.position = get_viewport().get_visible_rect().size * 0.5
	get_viewport().push_input(ev)


func _set_sens(v: float) -> void:
	Config.get_config("controls").mouse["look_sensitivity_deg_per_px"] = v


## Свежий полёт в камере mode, мышь захвачена, ПКМ отпущена.
func _setup(game: Game, mode: String) -> void:
	game.restart()
	game.camera.set_mode(mode)
	game.camera.snap()
	game.input_controller.roll_input = "body"
	game.input_controller.set_mouse_captured(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # headless: режим не держится (остаётся VISIBLE)
	_real_capture = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	for i in 6:
		game.tick(DT)


## Дельта состояния после движения rel (mouse_px, ПКМ rmb): [штанга pitch, roll, смещение, голова, свободная].
func _probe(game: Game, mode: String, rel: Vector2, rmb: bool, sens: float) -> Dictionary:
	_set_sens(sens)
	_setup(game, mode)
	var ic := game.input_controller
	var cam := game.camera
	var head0 := cam.head_look_deg()
	var free0: Vector2 = cam._free_rot
	if rmb:
		_rmb(true)
	_motion(rel, cam)
	game.tick(DT)
	var out := {
		"roll": ic.control.roll,
		"pitch": ic.control.pitch,
		"off": ic._mouse_offset,
		"head": cam.head_look_deg() - head0,
		"free": (cam._free_rot - free0) / PI * 180.0,
	}
	if rmb:
		_rmb(false)
	return out


func _fmt(d: Dictionary) -> String:
	return "штанга r%+.2f p%+.2f off(%+.3f,%+.3f) | голова(%+.2f,%+.2f)° | камера(%+.2f,%+.2f)°" % [
		d.roll, d.pitch, d.off.x, d.off.y, d.head.x, d.head.y, d.free.x, d.free.y]


func _bar_moved(d: Dictionary) -> bool:
	return (d.off as Vector2).length() > 1e-4 or absf(d.roll) > 1e-4 or absf(d.pitch) > 1e-4


func test_routing_table() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var saved: float = Config.value("controls", "mouse.look_sensitivity_deg_per_px")
	var rel := Vector2(60, -40)
	for mode in ["cockpit", "chase", "free"]:
		for rmb in [false, true]:
			for sens in [0.02, 0.5]:
				var d := _probe(game, mode, rel, rmb, sens)
				print("BM-1 %-7s ПКМ=%-5s sens=%.2f: %s" % [mode, rmb, sens, _fmt(d)])
				var bar := _bar_moved(d)
				var head := (d.head as Vector2).length() > 1e-4
				var cam := (d.free as Vector2).length() > 1e-4
				check(not (bar and (head or cam)), "%s ПКМ=%s sens=%s: штанга и обзор от одного движения" % [mode, rmb, sens])
				match mode:
					"cockpit":
						check(bar != rmb, "cockpit ПКМ=%s: штанга %s (ждём %s)" % [rmb, bar, not rmb])
						check(head == rmb, "cockpit ПКМ=%s: голова %s (ждём %s)" % [rmb, head, rmb])
						check(not cam, "cockpit ПКМ=%s: камера не должна идти" % rmb)
					"chase":
						check(bar != rmb, "chase ПКМ=%s: штанга %s (ждём %s)" % [rmb, bar, not rmb])
						check(not head and not cam, "chase ПКМ=%s: обзора нет" % rmb)
					"free":
						check(not bar, "free ПКМ=%s: штанга не должна идти" % rmb)
						check(cam, "free ПКМ=%s: камера идёт" % rmb)
						check(not head, "free: голова не идёт")
	# Чувствительность: без ПКМ не должна менять штангу/камеру-кроме free; штанга от неё не зависит никогда.
	for mode in ["cockpit", "chase"]:
		var a := _probe(game, mode, rel, false, 0.02)
		var b := _probe(game, mode, rel, false, 0.5)
		check(is_equal_approx(a.roll, b.roll) and is_equal_approx(a.pitch, b.pitch) and (a.off as Vector2).is_equal_approx(b.off),
			"%s: штанга не зависит от look_sensitivity" % mode)
		check((a.head as Vector2).length() < 1e-4 and (b.head as Vector2).length() < 1e-4, "%s: без ПКМ голова не зависит от sens" % mode)
	for sens_mode in ["cockpit", "free"]:
		var a := _probe(game, sens_mode, rel, true, 0.02)
		var b := _probe(game, sens_mode, rel, true, 0.5)
		var ka: Vector2 = a.head if sens_mode == "cockpit" else a.free
		var kb: Vector2 = b.head if sens_mode == "cockpit" else b.free
		check(kb.length() > ka.length() * 5.0, "%s: sens 0.5 заметно сильнее 0.02 (%s / %s)" % [sens_mode, ka, kb])
		check((a.off as Vector2).is_equal_approx(b.off), "%s: штанга при ПКМ не зависит от sens" % sens_mode)
	_set_sens(saved)
	await _close(main)


## ПКМ нажали/отпустили, пока ввод выключен (меню/пауза): после возврата мышь не залипает в обзоре.
func test_rmb_stuck_after_menu_or_pause() -> void:
	var main := await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var rel := Vector2(60, -40)
	for mode in ["cockpit", "chase"]:
		for how in ["отпустили в меню", "нажали в меню", "отпустили на паузе"]:
			_setup(game, mode)
			var ic := game.input_controller
			if how == "отпустили в меню" or how == "отпустили на паузе":
				_rmb(true)  # нажата в полёте
			if how == "отпустили на паузе":
				game.set_paused(true)
			else:
				game.set_input_enabled(false)
			if how == "нажали в меню":
				_rmb(true)
			else:
				_rmb(false)
			if how == "нажали в меню":
				game.set_input_enabled(true)
				_rmb(false)  # отпустили уже в полёте
			elif how == "отпустили на паузе":
				game.set_paused(false)
			else:
				game.set_input_enabled(true)
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			ic.set_mouse_captured(true)
			var cam := game.camera
			var h0 := cam.head_look_deg()
			var o0: Vector2 = ic._mouse_offset
			_motion(rel, cam)
			game.tick(DT)
			var head_moved := (cam.head_look_deg() - h0).length() > 1e-4
			var bar_moved := (ic._mouse_offset - o0).length() > 1e-4
			print("BM-1 залипание %s/%s (ПКМ отпущена): ic._bar_look_held=%s cam._bar_look_held=%s; мышь→ голова %s, штанга %s" % [
				mode, how, ic._bar_look_held, cam._bar_look_held, head_moved, bar_moved])
			var stuck: bool = ic._bar_look_held or cam._bar_look_held
			if how == "нажали в меню":
				check(not stuck, "%s/%s: флаг ПКМ залип" % [mode, how])
				check(bar_moved and not head_moved, "%s/%s: после отпускания мышь — штанга, не голова" % [mode, how])
			else:
				# НАЙДЕННОЕ РАСХОЖДЕНИЕ (отчёт BM-1): отпускание ПКМ при выключенном вводе (меню/пауза)
				# теряется — InputController/CameraRig выходят из _unhandled_input до записи флага;
				# флаг _bar_look_held залипает, в кабине мышь крутит голову, а штанга стоит. Тест не красный:
				# здесь фиксируем ТЕКУЩЕЕ поведение, чтобы починка (BM-3) заметно перевернула проверку.
				print("BM-1 РАСХОЖДЕНИЕ %s/%s: залипание=%s (ждём false)" % [mode, how, stuck])
				check(stuck, "%s/%s: залипание исчезло — проверить и ужесточить тест (ждём not stuck)" % [mode, how])
	await _close(main)
