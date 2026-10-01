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
	ic._was_on_ground = false


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
