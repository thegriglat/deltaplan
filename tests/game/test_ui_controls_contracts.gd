extends TestCase
## Контракты модуля ui-controls (docs/contracts/ui-controls.md): У1 v5 — крыло — мышь (всегда), стик;
## клавиш трапеции нет (v5), в полёте с клавиатуры по крылу только Shift — pull_full, добор до бёдер (v4);
## У2 v2 — W/S/A/D: пилот на земле, голова в полёте.
## Ломается, если раскладку или смысл действий поменяли без правки контракта.


func _keys(action: String) -> Array:
	return Config.get_config("controls").keys.get(action, [])


func test_u1_pitch_actions_shape() -> void:
	var cfg: Dictionary = Config.get_config("controls")
	check(cfg.has("invert_pitch") and cfg.invert_pitch is bool, "У1: invert_pitch: bool")
	check(cfg.invert_pitch == false, "У1: инверсия по умолчанию выключена")
	check(cfg.gamepad.has("pitch_axis"), "У1: gamepad.pitch_axis")
	check("pitch" in ControlInput.new(), "У1: ControlInput.pitch")
	check(not cfg.mouse.has("mode"), "У1 v3: режима мыши нет (mouse.mode убран) — мышь всегда крыло")
	check(not InputController.new().has_method("mouse_mode"), "У1 v3: InputController.mouse_mode() убран")


func test_u1_v5_no_keyboard_bar() -> void:
	var cfg: Dictionary = Config.get_config("controls")
	for a in ["pitch_push_out", "pitch_pull_in", "roll_left", "roll_right"]:
		check(not cfg.keys.has(a), "У1 v5: действия %s нет" % a)
		check(not InputMap.has_action(a) or InputMap.action_get_events(a).is_empty(), "У1 v5: %s не в InputMap" % a)
	for k in ["pitch_rate_per_s", "pitch_return_per_s", "roll_rate_per_s", "roll_return_per_s", "roll_shift_time_s",
			"roll_center_time_s", "roll_neutral_zone", "sensitivity"]:
		check(not cfg.keyboard.has(k), "У1 v5: keyboard.%s удалён" % k)
	for r: Dictionary in Config.get_config("ui").controls_help:
		check(not String(r.get("action", "")).begins_with("pitch_") and not String(r.get("action", "")).begins_with("roll_"),
				"У1 v5: на экране «Управление» нет строк клавиш трапеции (%s)" % r)


# --- У1 v5: настоящий ввод → InputController → ControlInput (мышь — крыло, стрелки — ничего) ---

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
	ic._cfg = cfg
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


## Стрелки и W/S/A/D в полёте и на земле трапецию не двигают (У1 v5).
func test_u1_v5_keys_not_bar() -> void:
	var ic := _ic(false)
	for ground in [false, true]:
		for code in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_W, KEY_S, KEY_A, KEY_D]:
			ic.reset()
			ic.on_ground = ground
			_key(code, true)
			for i in 60:
				ic.update(DT)
			var c := ic.control
			check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6,
					"У1 v5: %s %s — pitch %.2f, roll %.2f (ждали 0)" % ["земля" if ground else "полёт", OS.get_keycode_string(code), c.pitch, c.roll])
			_key(code, false)
			ic.update(DT)
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


# --- У2 v2: W/S/A/D — пилот на земле, голова в полёте; в трапецию не идут никогда ---


## Есть ли метод у нового узла (узел сразу освобождается).
static func _has(n: Node, method: String) -> bool:
	var r := n.has_method(method)
	n.free()
	return r


func test_u2_shape() -> void:
	check(_keys("look_up") == ["W", "Up"] and _keys("look_down") == ["S", "Down"], "У2: look_up = W+Up, look_down = S+Down")
	check(_keys("look_left") == ["A", "Left"] and _keys("look_right") == ["D", "Right"], "У2: look_left = A+Left, look_right = D+Right")
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
		print("    У2: полёт, захват %s — W %s; S %s; A %s; D %s" % [
			captured, _fmt(res.W), _fmt(res.S), _fmt(res.A), _fmt(res.D)])
		for name in res:
			var c: ControlInput = res[name]
			check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "У2: полёт — %s не двигает трапецию (%s)" % [name, _fmt(c)])
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
	print("    У2: стоя — W %s; A %s" % [_fmt(w), _fmt(a)])
	check(w.walk > 0.5 and absf(w.pitch) < 1e-6, "У2: стоя W — шаг, не трапеция (%s)" % _fmt(w))
	check(a.turn < -0.5 and absf(a.roll) < 1e-6, "У2: стоя A — поворот влево, не крен (%s)" % _fmt(a))
	_key(KEY_SHIFT, true)
	ic.update(DT)
	check(not ic.keys_look(), "У2 v2: разбег (Shift) — keys_look() = false")
	var rw := _hold(ic, [KEY_W])
	var ra := _hold(ic, [KEY_A])
	_key(KEY_SHIFT, false)
	ic.update(DT)
	print("    У2: разбег — W %s; A %s" % [_fmt(rw), _fmt(ra)])
	for c in [rw, ra]:
		check(absf(c.pitch) < 1e-6 and absf(c.roll) < 1e-6, "У2: разбег — W/A не двигают крыло (%s)" % _fmt(c))
		check(c.walk == 0.0 and c.turn == 0.0 and c.run, "У2: разбег — бег Shift, walk/turn 0 (%s)" % _fmt(c))
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


# --- У1 v4: pull_full = [Shift] — добор «на себя» до бёдер (VM-К3 v2) ---

func test_u1_v4_pull_full() -> void:
	var text := FileAccess.get_file_as_string("res://docs/contracts/ui-controls.md")
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://docs/contracts/ui-controls.md"))
	check(text.contains("## У1. Раскладка тангажа и крена — v5"), "У1 v5 в заголовке")
	check(_keys("pull_full") == ["Shift"], "У1 v4: pull_full = [Shift] (%s)" % [_keys("pull_full")])
	check(Config.get_config("controls").keys.has("pull_full_doc"), "У1 v4: pull_full_doc")
	check("pull_full" in ControlInput.new() and ControlInput.new().pull_full == false, "ControlInput.pull_full = false")
	var rows: Array = Config.get_config("ui").controls_help
	var row := {}
	for r: Dictionary in rows:
		if String(r.get("action", "")) == "pull_full":
			row = r
	check(not row.is_empty(), "У1 v4: строка pull_full на экране «Управление»")
	if not row.is_empty():
		var key := String(row.text)
		TranslationServer.set_locale("ru")
		var ru := tr(key)
		TranslationServer.set_locale("en")
		var en := tr(key)
		check(ru != key and en != key and ru != en, "строка %s переведена (ru/en): %s / %s" % [key, ru, en])
	var ic := _ic(false)
	# полёт: Shift — pull_full, отпустил — false; без Shift — false
	ic.update(DT)
	check(not ic.control.pull_full, "без Shift pull_full = false")
	_key(KEY_SHIFT, true)
	ic.update(DT)
	var air := ic.control.pull_full
	var air_run := ic.control.run
	_key(KEY_SHIFT, false)
	ic.update(DT)
	check(air and not air_run, "полёт: Shift — pull_full, не run (%s, %s)" % [air, air_run])
	check(not ic.control.pull_full, "отпустил Shift — pull_full = false")
	# мышь на себя + Shift: тангаж прежний (−1), добор — отдельным полем
	ic._mouse_offset = Vector2(0.0, 1.0)
	_key(KEY_SHIFT, true)
	ic.update(DT)
	var p_full := ic.control.pitch
	check(ic.control.pull_full and is_equal_approx(p_full, -1.0), "мышь на себя + Shift: pitch −1, pull_full (%.2f)" % p_full)
	_key(KEY_SHIFT, false)
	ic._mouse_offset = Vector2.ZERO
	ic.update(DT)
	# земля: Shift — run и pull_full оба (модель берёт pull_full только в полёте)
	ic.reset()
	_key(KEY_SHIFT, true)
	ic.update(DT)
	check(ic.control.run and ic.control.pull_full, "земля: Shift — run (и pull_full)")
	_key(KEY_SHIFT, false)
	ic.update(DT)
	# свободная камера (Shift — быстрее): добора нет
	_air(ic)
	ic.hands_off = true
	_key(KEY_SHIFT, true)
	ic.update(DT)
	check(not ic.control.pull_full, "свободная камера: Shift — не добор")
	_key(KEY_SHIFT, false)
	ic.hands_off = false
	ic.update(DT)
	_free(ic)
