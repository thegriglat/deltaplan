extends TestCase
## Контракты модуля ui-controls (docs/ui-controls_contracts.md): У1 v3 — раскладка трапеции
## (стрелки, мышь — всегда крыло, стик), У2 v2 — W/S/A/D: пилот на земле, голова в полёте.
## Ломается, если раскладку или смысл действий поменяли без правки контракта.


func _keys(action: String) -> Array:
	return Config.get_config("controls").keys.get(action, [])


func test_u1_pitch_actions_shape() -> void:
	var cfg: Dictionary = Config.get_config("controls")
	check(cfg.keys.has("pitch_push_out") and cfg.keys.has("pitch_pull_in"), "У1: действия тангажа есть")
	check(cfg.has("invert_pitch") and cfg.invert_pitch is bool, "У1: invert_pitch: bool")
	check(cfg.invert_pitch == false, "У1: инверсия по умолчанию выключена")
	check(cfg.gamepad.has("pitch_axis"), "У1: gamepad.pitch_axis")
	check("pitch" in ControlInput.new(), "У1: ControlInput.pitch")
	check(not cfg.mouse.has("mode"), "У1 v3: режима мыши нет (mouse.mode убран) — мышь всегда крыло")
	check(not InputController.new().has_method("mouse_mode"), "У1 v3: InputController.mouse_mode() убран")


func test_u1_default_keys_arrows() -> void:
	check(_keys("pitch_push_out") == ["Up"], "У1 v3: от себя — только ↑ (%s)" % [_keys("pitch_push_out")])
	check(_keys("pitch_pull_in") == ["Down"], "У1 v3: на себя — только ↓ (%s)" % [_keys("pitch_pull_in")])
	check(_keys("roll_left") == ["Left"], "У1 v3: крен влево — только ← (%s)" % [_keys("roll_left")])
	check(_keys("roll_right") == ["Right"], "У1 v3: крен вправо — только → (%s)" % [_keys("roll_right")])
	for a in ["pitch_push_out", "pitch_pull_in", "roll_left", "roll_right"]:
		for k in ["W", "S", "A", "D"]:
			check(not (k in _keys(a)), "У1 v3: %s не на %s" % [k, a])


# --- У1 v3: настоящий ввод → InputController (полёт) → ControlInput.pitch → угол атаки ---

const Sim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0


## InputController в дереве (для _unhandled_input мыши), в воздухе, на копии конфига по умолчанию
## (без правок пилота из user://), инверсия — как задано, мышь захвачена — как задано.
## Освобождать через _free().
static func _ic(invert: bool, captured: bool = true) -> InputController:
	var ic := InputController.new()
	# в узел раннера (корень дерева занят его _ready): _ready → reload_config
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(ic)
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = invert
	cfg.keyboard.sensitivity = 1.0
	ic._cfg = cfg
	ic.roll_mode = "rate"
	ic.mouse_captured = captured
	_air(ic)
	return ic


static func _air(ic: InputController) -> void:
	ic.reset()
	ic.on_ground = false


static func _free(ic: InputController) -> void:
	ic.get_parent().remove_child(ic)
	ic.free()


## Физическое нажатие/отпускание клавиши (как с клавиатуры), сразу в состояние Input.
static func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## ControlInput.pitch после удержания клавиши seconds в полёте (с нейтрали).
static func _pitch_after_key(ic: InputController, code: Key, seconds: float = 0.5) -> float:
	_air(ic)
	_key(code, true)
	for i in int(round(seconds / DT)):
		ic.update(DT)
	var p := ic.control.pitch
	_key(code, false)
	ic.update(DT)
	return p


func test_u1_keys_pitch_sign_in_flight() -> void:
	var ic := _ic(false)
	var up := _pitch_after_key(ic, KEY_UP)
	var down := _pitch_after_key(ic, KEY_DOWN)
	print("    У1: pitch за 0,5 с — ↑ %.2f, ↓ %.2f" % [up, down])
	check(up > 0.0, "У1: ↑ — от себя, pitch > 0 (%.2f)" % up)
	check(down < 0.0, "У1: ↓ — на себя, pitch < 0 (%.2f)" % down)
	_free(ic)
	ic = _ic(true)
	var upi := _pitch_after_key(ic, KEY_UP)
	var downi := _pitch_after_key(ic, KEY_DOWN)
	print("    У1: инверсия — ↑ %.2f, ↓ %.2f" % [upi, downi])
	check(upi < 0.0, "У1: инверсия — ↑ на себя (%.2f)" % upi)
	check(downi > 0.0, "У1: инверсия — ↓ от себя (%.2f)" % downi)
	_free(ic)


## Мышь (всегда крыло): от себя (курсор вверх, relative.y < 0) → pitch > 0; инверсия — наоборот.
## Без захвата мышь трапецию не двигает.
static func _pitch_after_mouse(invert: bool, dy: float, captured: bool = true) -> float:
	var ic := _ic(invert, captured)
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(0.0, dy)
	ic._unhandled_input(ev)
	ic.update(DT)
	var p := ic.control.pitch
	_free(ic)
	return p


func test_u1_mouse_bar_pitch_sign() -> void:
	var out := _pitch_after_mouse(false, -40.0)
	var inn := _pitch_after_mouse(false, 40.0)
	var out_inv := _pitch_after_mouse(true, -40.0)
	var free := _pitch_after_mouse(false, -40.0, false)
	print("    У1: мышь — от себя %.2f, на себя %.2f, от себя с инверсией %.2f, без захвата %.2f" % [
		out, inn, out_inv, free])
	check(out > 0.0, "У1: мышь от себя — pitch > 0 (%.2f)" % out)
	check(inn < 0.0, "У1: мышь на себя — pitch < 0 (%.2f)" % inn)
	check(out_inv < 0.0, "У1: инверсия — мышь от себя даёт на себя (%.2f)" % out_inv)
	check(absf(free) < 1e-6, "У1 v3: без захвата мышь трапецию не двигает (%.2f)" % free)


## Физика: в полёте ↑ (держать) — угол атаки больше трима, ↓ — меньше. Учебное крыло, штиль.
static func _alpha_with_key(m: FlightModel, ic: InputController, code: Key) -> float:
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	_air(ic)
	var steps := func(seconds: float) -> float:
		var sum := 0.0
		var n := int(round(seconds / DT))
		for i in n:
			m.step(DT, ic.update(DT), Callable(), Callable())
			sum += m.alpha
		return rad_to_deg(sum / n)
	steps.call(20.0)  # установиться в триме
	if code != KEY_NONE:
		_key(code, true)
	steps.call(4.0)
	var a: float = steps.call(2.0)
	if code != KEY_NONE:
		_key(code, false)
	return a


func test_u1_keys_change_alpha() -> void:
	var ic := _ic(false)
	var m := Sim.make("training")
	var trim := _alpha_with_key(m, ic, KEY_NONE)
	var a_up := _alpha_with_key(m, ic, KEY_UP)
	var a_down := _alpha_with_key(m, ic, KEY_DOWN)
	_free(ic)
	print("    У1: угол атаки (training) — трим %.2f°, ↑ %.2f°, ↓ %.2f°" % [trim, a_up, a_down])
	check(a_up > trim + 0.5, "У1: ↑ — угол атаки больше трима (%.2f° > %.2f°)" % [a_up, trim])
	check(a_down < trim - 0.5, "У1: ↓ — угол атаки меньше трима (%.2f° < %.2f°)" % [a_down, trim])


# --- У2 v2: W/S/A/D — пилот на земле, голова в полёте; в трапецию не идут никогда ---


## Есть ли метод у нового узла (узел сразу освобождается).
static func _has(n: Node, method: String) -> bool:
	var r := n.has_method(method)
	n.free()
	return r


func test_u2_shape() -> void:
	check(_keys("look_up") == ["W"] and _keys("look_down") == ["S"], "У2: look_up = W, look_down = S")
	check(_keys("look_left") == ["A"] and _keys("look_right") == ["D"], "У2: look_left = A, look_right = D")
	check(_keys("walk_forward") == ["W"] and _keys("walk_back") == ["S"], "У2: walk_forward = W, walk_back = S")
	check(_keys("turn_left") == ["A"] and _keys("turn_right") == ["D"], "У2: turn_left = A, turn_right = D")
	var rate: Variant = Config.value("camera", "cockpit.head.key_rate_deg_s")
	check(rate != null and float(rate) > 0.0, "У2: camera.json → cockpit.head.key_rate_deg_s > 0")
	check(_has(InputController.new(), "keys_look"), "У2: InputController.keys_look()")
	var cam := CameraRig.new()
	check("keys_look_fn" in cam and cam.has_method("head_look_deg"), "У2: CameraRig.keys_look_fn, head_look_deg()")
	cam.free()


## ControlInput после удержания клавиш seconds (с текущего состояния); фаза — как задана в ic.
static func _hold(ic: InputController, codes: Array, seconds: float = 0.5) -> ControlInput:
	for c in codes:
		_key(c, true)
	for i in int(round(seconds / DT)):
		ic.update(DT)
	var r := ControlInput.new()
	r.pitch = ic.control.pitch
	r.roll = ic.control.roll
	r.walk = ic.control.walk
	r.turn = ic.control.turn
	r.run = ic.control.run
	for k in codes:
		_key(k, false)
	ic.update(DT)
	return r


static func _fmt(c: ControlInput) -> String:
	return "p %.2f r %.2f w %.2f t %.2f" % [c.pitch, c.roll, c.walk, c.turn]


func test_u2_wasd_not_bar_in_flight() -> void:
	for captured in [true, false]:
		var ic := _ic(false, captured)
		check(ic.keys_look(), "У2 v2: полёт (захват %s) — keys_look() = true" % captured)
		var res := {}
		for name in ["W", "S", "A", "D"]:
			_air(ic)
			res[name] = _hold(ic, [OS.find_keycode_from_string(name)])
		_air(ic)
		var up := _hold(ic, [KEY_UP])
		_air(ic)
		var right := _hold(ic, [KEY_RIGHT])
		_air(ic)
		Input.action_press("pitch_push_out")
		for i in 60:
			ic.update(DT)
		var auto := ic.control.pitch
		Input.action_release("pitch_push_out")
		print("    У2: полёт, захват %s — W %s; S %s; A %s; D %s; ↑ %.2f, → %.2f, action_press %.2f" % [
			captured, _fmt(res.W), _fmt(res.S), _fmt(res.A), _fmt(res.D), up.pitch, right.roll, auto])
		for name in res:
			var c: ControlInput = res[name]
			check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "У2: полёт — %s не двигает трапецию (%s)" % [name, _fmt(c)])
		check(up.pitch > 0.0, "У2: ↑ — от себя (%.2f)" % up.pitch)
		check(right.roll > 0.0, "У2: → — крен вправо (%.2f)" % right.roll)
		check(auto > 0.0, "У2: действие без клавиши (автопилот) считается (%.2f)" % auto)
		ic.hands_off = true
		check(not ic.keys_look(), "У2: свободная камера (hands_off) — keys_look() = false")
		_free(ic)


func test_u2_ground_keys_pilot() -> void:
	var ic := _ic(false)
	ic.reset()  # на земле
	check(not ic.keys_look(), "У2 v2: стоя на земле — keys_look() = false")
	var w := _hold(ic, [KEY_W])
	ic.reset()
	var a := _hold(ic, [KEY_A])
	ic.reset()
	var up := _hold(ic, [KEY_UP])
	ic.reset()
	print("    У2: стоя — W %s; A %s; ↑ %s" % [_fmt(w), _fmt(a), _fmt(up)])
	check(w.walk > 0.5 and absf(w.pitch) < 1e-6, "У2: стоя W — шаг, не трапеция (%s)" % _fmt(w))
	check(a.turn < -0.5 and absf(a.roll) < 1e-6, "У2: стоя A — поворот влево, не крен (%s)" % _fmt(a))
	check(up.pitch > 0.0, "У2: стоя ↑ — нос крыла вверх (%.2f)" % up.pitch)
	_key(KEY_SHIFT, true)
	ic.update(DT)
	check(not ic.keys_look(), "У2 v2: разбег (Shift) — keys_look() = false")
	var rw := _hold(ic, [KEY_W])
	var ra := _hold(ic, [KEY_A])
	var rup := _hold(ic, [KEY_UP])
	_key(KEY_SHIFT, false)
	ic.update(DT)
	print("    У2: разбег — W %s; A %s; ↑ %s" % [_fmt(rw), _fmt(ra), _fmt(rup)])
	for c in [rw, ra]:
		check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "У2: разбег — W/A не двигают крыло (%s)" % _fmt(c))
		check(c.walk == 0.0 and c.turn == 0.0 and c.run, "У2: разбег — бег Shift, walk/turn 0 (%s)" % _fmt(c))
	check(rup.pitch > 0.0, "У2: разбег ↑ — нос вверх (%.2f)" % rup.pitch)
	# отрыв с зажатой W: трапеция 0 и до, и после, клавиша сразу — обзор
	ic.reset()
	_key(KEY_W, true)
	for i in 30:
		ic.update(DT)
	var p_ground := ic.control.pitch
	ic.on_ground = false
	ic.update(DT)
	var p_air := ic.control.pitch
	var look_air := ic.keys_look()
	_key(KEY_W, false)
	ic.update(DT)
	print("    У2: отрыв с W — трапеция до %.2f, после %.2f, обзор %s" % [p_ground, p_air, look_air])
	check(absf(p_ground) < 1e-6 and absf(p_air) < 1e-6, "У2: отрыв с W — скачка трапеции нет")
	check(look_air, "У2: после отрыва W — обзор")
	_free(ic)


## CameraRig в кабине, keys_look_fn — как задано; поворот головы после удержания клавиши.
static func _head_after(keys_look: bool, code: Key, seconds: float = 0.5) -> Vector2:
	var root := (Engine.get_main_loop() as SceneTree).root
	var host := root.get_child(root.get_child_count() - 1)
	var target := Node3D.new()
	host.add_child(target)
	var cam := CameraRig.new()
	host.add_child(cam)
	cam.target = target
	cam.set_mode("cockpit")
	cam.keys_look_fn = func() -> bool: return keys_look
	_key(code, true)
	for i in int(round(seconds / DT)):
		cam._process(DT)
	var h: Vector2 = cam.head_look_deg()
	_key(code, false)
	cam.queue_free()
	target.queue_free()
	return h


func test_u2_cockpit_head_from_keys() -> void:
	if not _has(CameraRig.new(), "head_look_deg"):
		check(false, "У2: нет CameraRig.head_look_deg() — до UC-3")
		return
	var rate := float(Config.value("camera", "cockpit.head.key_rate_deg_s"))
	var a := _head_after(true, KEY_A)
	var d := _head_after(true, KEY_D)
	var w := _head_after(true, KEY_W)
	var s := _head_after(true, KEY_S)
	var off := _head_after(false, KEY_A)
	print("    У2: голова за 0,5 с (%.0f°/с) — A %s, D %s, W %s, S %s, без обзора A %s" % [rate, a, d, w, s, off])
	var want := minf(rate * 0.5, float(Config.value("camera", "cockpit.head.yaw_limit_deg")))
	check(absf(a.x - want) < 0.1 * want + 1.0, "У2: A — голова влево ≈ %.0f° (%.1f°)" % [want, a.x])
	check(d.x < -0.5 * want, "У2: D — голова вправо (%.1f°)" % d.x)
	check(w.y > 0.0 and s.y < 0.0, "У2: W — вверх, S — вниз (%.1f°, %.1f°)" % [w.y, s.y])
	check(off.length() < 1e-3, "У2: keys_look_fn = false — голова на месте (%s)" % off)
