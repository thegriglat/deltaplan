class_name InputController
extends Node
## Собирает ControlInput из клавиатуры и геймпада (FR-30…FR-33).
## Мышь по умолчанию крутит голову (это делает CameraRig); в режиме "bar" — управляет трапецией.
## Клавиши регистрируются в InputMap из configs/controls.json.

var control := ControlInput.new()
var mouse_captured := false
## Фазу сообщает главная сцена по телеметрии: на земле W/S — ходьба, в разбеге — угол носа.
var on_ground := true

var _cfg: Dictionary
var _mouse_offset := Vector2.ZERO  # режим bar: накопленное смещение мыши, доли полного хода


func _ready() -> void:
	_cfg = Config.get_config("controls")
	register_actions(_cfg)
	if bool(_cfg.mouse.capture_on_start):
		set_mouse_captured.call_deferred(true)


func mouse_mode() -> String:
	return String(_cfg.mouse.mode)


static func register_actions(cfg: Dictionary) -> void:
	var keys: Dictionary = cfg.get("keys", {})
	for action in keys:
		if String(action).ends_with("_doc") or String(action).begins_with("_"):
			continue
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action)
		for key_name in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = OS.find_keycode_from_string(key_name)
			InputMap.action_add_event(action, ev)


func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	_mouse_offset = Vector2(control.roll, -control.pitch)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("mouse_capture"):
		set_mouse_captured(not mouse_captured)
	elif mouse_captured and mouse_mode() == "bar" and event is InputEventMouseMotion:
		var h := float(get_viewport().get_visible_rect().size.y) * 0.5
		var k := float(_cfg.mouse.bar_sensitivity) / maxf(h, 1.0)
		_mouse_offset += event.relative * k  # мышь от себя (вверх по экрану) = трапеция от себя
		_mouse_offset = _mouse_offset.clamp(Vector2(-1, -1), Vector2(1, 1))


## Вызывать каждый шаг физики.
func update(dt: float) -> ControlInput:
	var kb: Dictionary = _cfg.keyboard
	var sens := float(kb.sensitivity)
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0

	var fwd := Input.get_action_strength("pitch_pull_in") - Input.get_action_strength("pitch_push_out")
	var pitch_dir := -fwd * inv
	var roll_dir := Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	var run := Input.is_action_pressed("run")

	var pitch := control.pitch
	var roll := control.roll
	var walk := 0.0
	if on_ground and not run:
		# Ходьба с крылом на плечах: W/S — шаг, A/D — поворот, нос держим в нейтрали.
		walk = fwd
		pitch = move_toward(pitch, 0.0, float(kb.pitch_return_per_s) * dt)
		roll = roll_dir
	elif on_ground and run:
		# Разбег: W/S — угол носа, A/D — выравнивание крыла.
		var nose_rate := float(_cfg.ground.nose_pitch_rate_per_s) * sens
		pitch = _ramp(pitch, pitch_dir, nose_rate, 0.0, dt)
		roll = _ramp(roll, roll_dir, float(kb.roll_rate_per_s) * sens, float(kb.roll_return_per_s), dt)
	elif mouse_captured and mouse_mode() == "bar":
		var ret := float(_cfg.mouse.bar_return_to_center_per_s)
		if ret > 0.0:
			_mouse_offset = _mouse_offset.move_toward(Vector2.ZERO, ret * dt)
		var dz := float(_cfg.mouse.bar_deadzone)
		roll = _mouse_offset.x if absf(_mouse_offset.x) > dz else 0.0
		pitch = -_mouse_offset.y * inv if absf(_mouse_offset.y) > dz else 0.0
	else:
		var pitch_rate := float(kb.pitch_rate_per_s) * sens
		pitch = _ramp(pitch, pitch_dir, pitch_rate, float(kb.pitch_return_per_s), dt)
		roll = _ramp(roll, roll_dir, float(kb.roll_rate_per_s) * sens, float(kb.roll_return_per_s), dt)

	var gp: Dictionary = _cfg.gamepad
	if bool(gp.enabled) and not Input.get_connected_joypads().is_empty():
		var dev: int = Input.get_connected_joypads()[0]
		var gx := _stick(Input.get_joy_axis(dev, int(gp.roll_axis)), gp)
		var gy := _stick(Input.get_joy_axis(dev, int(gp.pitch_axis)), gp)
		if gx != 0.0 or gy != 0.0:
			roll = gx
			if on_ground and not run:
				walk = -gy
			else:
				pitch = gy * inv  # стик на себя (вниз, +) = трапеция от себя
		run = run or Input.is_joy_button_pressed(dev, int(gp.run_button))

	control.pitch = clampf(pitch, -1.0, 1.0)
	control.roll = clampf(roll, -1.0, 1.0)
	control.walk = clampf(walk, -1.0, 1.0)
	control.run = run
	return control


static func _ramp(v: float, dir: float, rate: float, ret: float, dt: float) -> float:
	if dir != 0.0:
		return move_toward(v, signf(dir), rate * dt)
	return move_toward(v, 0.0, ret * dt)


static func _stick(v: float, gp: Dictionary) -> float:
	var dz := float(gp.deadzone)
	if absf(v) < dz:
		return 0.0
	var x := (absf(v) - dz) / (1.0 - dz)
	var e := float(gp.expo)
	x = (1.0 - e) * x + e * x * x * x
	return signf(v) * clampf(x * float(gp.sensitivity), 0.0, 1.0)
