extends TestCase
## Контракты модуля ui-controls (docs/ui-controls_contracts.md): У1 — раскладка тангажа.
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


func test_u1_default_keys_hang_glider() -> void:
	check("W" in _keys("pitch_push_out") and "Up" in _keys("pitch_push_out"), "У1 v2: W, ↑ — от себя")
	check("S" in _keys("pitch_pull_in") and "Down" in _keys("pitch_pull_in"), "У1 v2: S, ↓ — на себя")
	check(not ("W" in _keys("pitch_pull_in")), "У1 v2: W не «на себя»")
	check(not ("S" in _keys("pitch_push_out")), "У1 v2: S не «от себя»")


# --- У1 v2: настоящий ввод → InputController (полёт) → ControlInput.pitch → угол атаки ---

const Sim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0


## InputController в дереве (для _unhandled_input мыши), в воздухе, на копии конфига по умолчанию
## (без правок пилота из user://), инверсия — как задано. Освобождать через _free().
static func _ic(invert: bool, mouse_mode: String = "look") -> InputController:
	var ic := InputController.new()
	# в узел раннера (корень дерева занят его _ready): _ready → reload_config
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(ic)
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = invert
	cfg.keyboard.sensitivity = 1.0
	cfg.mouse.mode = mouse_mode
	ic._cfg = cfg
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
	var w := _pitch_after_key(ic, KEY_W)
	var up := _pitch_after_key(ic, KEY_UP)
	var s := _pitch_after_key(ic, KEY_S)
	var down := _pitch_after_key(ic, KEY_DOWN)
	print("    У1: pitch за 0,5 с — W %.2f, ↑ %.2f, S %.2f, ↓ %.2f" % [w, up, s, down])
	check(w > 0.0, "У1 v2: W — от себя, pitch > 0 (%.2f)" % w)
	check(up > 0.0, "У1 v2: ↑ — от себя, pitch > 0 (%.2f)" % up)
	check(s < 0.0, "У1 v2: S — на себя, pitch < 0 (%.2f)" % s)
	check(down < 0.0, "У1 v2: ↓ — на себя, pitch < 0 (%.2f)" % down)
	_free(ic)
	ic = _ic(true)
	var wi := _pitch_after_key(ic, KEY_W)
	var si := _pitch_after_key(ic, KEY_S)
	var upi := _pitch_after_key(ic, KEY_UP)
	print("    У1: инверсия — W %.2f, S %.2f, ↑ %.2f" % [wi, si, upi])
	check(wi < 0.0 and upi < 0.0, "У1: инверсия — W/↑ на себя (%.2f, %.2f)" % [wi, upi])
	check(si > 0.0, "У1: инверсия — S от себя (%.2f)" % si)
	_free(ic)


## Мышь (bar): от себя (курсор вверх, relative.y < 0) → pitch > 0; инверсия — наоборот.
static func _pitch_after_mouse(invert: bool, dy: float) -> float:
	var ic := _ic(invert, "bar")
	ic.mouse_captured = true
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
	print("    У1: мышь bar — от себя %.2f, на себя %.2f, от себя с инверсией %.2f" % [out, inn, out_inv])
	check(out > 0.0, "У1: мышь от себя — pitch > 0 (%.2f)" % out)
	check(inn < 0.0, "У1: мышь на себя — pitch < 0 (%.2f)" % inn)
	check(out_inv < 0.0, "У1: инверсия — мышь от себя даёт на себя (%.2f)" % out_inv)


## Физика: в полёте W (держать) — угол атаки больше трима, S — меньше. Учебное крыло, штиль.
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
	ic.roll_mode = "rate"
	var m := Sim.make("training")
	var trim := _alpha_with_key(m, ic, KEY_NONE)
	var a_w := _alpha_with_key(m, ic, KEY_W)
	var a_s := _alpha_with_key(m, ic, KEY_S)
	_free(ic)
	print("    У1: угол атаки (training) — трим %.2f°, W %.2f°, S %.2f°" % [trim, a_w, a_s])
	check(a_w > trim + 0.5, "У1: W — угол атаки больше трима (%.2f° > %.2f°)" % [a_w, trim])
	check(a_s < trim - 0.5, "У1: S — угол атаки меньше трима (%.2f° < %.2f°)" % [a_s, trim])


# --- У2 v1: при «мышь — трапеция» (bar + захват) WASD — обзор головой, не трапеция ---


## Есть ли метод у нового узла (узел сразу освобождается).
static func _has(n: Node, method: String) -> bool:
	var r := n.has_method(method)
	n.free()
	return r


func test_u2_shape() -> void:
	check(_keys("look_up") == ["W"] and _keys("look_down") == ["S"], "У2: look_up = W, look_down = S")
	check(_keys("look_left") == ["A"] and _keys("look_right") == ["D"], "У2: look_left = A, look_right = D")
	var rate: Variant = Config.value("camera", "cockpit.head.key_rate_deg_s")
	check(rate != null and float(rate) > 0.0, "У2: camera.json → cockpit.head.key_rate_deg_s > 0")
	check(_has(InputController.new(), "keys_look"), "У2: InputController.keys_look()")
	var cam := CameraRig.new()
	check("keys_look_fn" in cam and cam.has_method("head_look_deg"), "У2: CameraRig.keys_look_fn, head_look_deg()")
	cam.free()


## InputController в режиме bar с захваченной мышью (без настоящего захвата курсора).
static func _ic_bar(captured: bool = true) -> InputController:
	var ic := _ic(false, "bar")
	ic.roll_mode = "rate"
	ic.mouse_captured = captured
	return ic


## (pitch, roll) после удержания клавиш seconds (с нейтрали); фаза — как задана в ic.
static func _hold(ic: InputController, codes: Array, seconds: float = 0.5) -> Vector2:
	for c in codes:
		_key(c, true)
	for i in int(round(seconds / DT)):
		ic.update(DT)
	var r := Vector2(ic.control.pitch, ic.control.roll)
	for c in codes:
		_key(c, false)
	ic.update(DT)
	return r


func test_u2_wasd_not_bar_in_flight() -> void:
	if not _has(InputController.new(), "keys_look"):
		check(false, "У2: нет keys_look() — до UC-3")
		return
	var ic := _ic_bar()
	check(ic.keys_look(), "У2: bar + захват, полёт — keys_look() = true")
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
	print("    У2: bar+захват — W %s, S %s, A %s, D %s; ↑ %.2f, → %.2f, action_press %.2f" % [
		res.W, res.S, res.A, res.D, up.x, right.y, auto])
	for name in res:
		var v: Vector2 = res[name]
		check(absf(v.x) < 1e-6 and absf(v.y) < 1e-6, "У2: %s не двигает трапецию (%s)" % [name, v])
	check(up.x > 0.0, "У2: ↑ — по-прежнему от себя (%.2f)" % up.x)
	check(right.y > 0.0, "У2: → — по-прежнему крен вправо (%.2f)" % right.y)
	check(auto > 0.0, "У2: действие без клавиши (автопилот) считается (%.2f)" % auto)
	_free(ic)
	# мышь не захвачена — как раньше (У1 v2)
	ic = _ic_bar(false)
	check(not ic.keys_look(), "У2: без захвата — keys_look() = false")
	var w := _hold(ic, [KEY_W])
	print("    У2: bar без захвата — W %.2f" % w.x)
	check(w.x > 0.0, "У2: без захвата W — от себя (%.2f)" % w.x)
	_free(ic)
	# режим look — как раньше
	ic = _ic(false, "look")
	ic.mouse_captured = true
	check(not ic.keys_look(), "У2: режим look — keys_look() = false")
	_free(ic)


func test_u2_run_as_in_flight() -> void:
	if not _has(InputController.new(), "keys_look"):
		check(false, "У2: нет keys_look() — до UC-3")
		return
	var ic := _ic_bar()
	ic.reset()  # на земле
	check(not ic.keys_look(), "У2: стоя на земле — keys_look() = false")
	_key(KEY_SHIFT, true)
	ic.update(DT)
	check(ic.keys_look(), "У2: разбег (Shift) — keys_look() = true")
	var w := _hold(ic, [KEY_W])
	var up := _hold(ic, [KEY_UP])
	_key(KEY_SHIFT, false)
	ic.update(DT)
	print("    У2: разбег bar+захват — W %.2f, ↑ %.2f" % [w.x, up.x])
	check(absf(w.x) < 1e-6, "У2: на разбеге W не двигает трапецию (%.2f)" % w.x)
	check(up.x > 0.0, "У2: на разбеге ↑ — нос вверх (%.2f)" % up.x)
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
