class_name InputController
extends Node
## Собирает ControlInput из клавиатуры и геймпада (FR-30…FR-33).
## Мышь по умолчанию крутит голову (это делает CameraRig); в режиме "bar" — управляет трапецией.
## Клавиши регистрируются в InputMap из configs/controls.json.

## Действия, которые защёлкиваются при отрыве.
const LATCH_ACTIONS: Array[String] = [
	"pitch_pull_in", "pitch_push_out", "roll_left", "roll_right", "walk_forward", "walk_back"
]

var control := ControlInput.new()
var mouse_captured := false
## Фазу сообщает главная сцена по телеметрии: на земле W/S — ходьба, в разбеге — угол носа.
var on_ground := true
## false — ввод игнорируется (меню, итог полёта): update() отдаёт нейтральное управление.
var enabled := true

var _cfg: Dictionary
var _nose_trim := 0.0  # подстройка носа на разбеге стрелками
var _was_on_ground := true
var _latched := {}  # действие → true: зажато в момент отрыва, не отпущено
var _mouse_offset := Vector2.ZERO  # режим bar: накопленное смещение мыши, доли полного хода


func _ready() -> void:
	reload_config()


## Перечитать configs/controls.json (после изменения настроек).
func reload_config() -> void:
	_cfg = Config.get_config("controls")
	register_actions(_cfg)


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
	if not enabled:
		return
	if event.is_action_pressed("mouse_capture"):
		set_mouse_captured(not mouse_captured)
	elif mouse_captured and mouse_mode() == "bar" and event is InputEventMouseMotion:
		var h := float(get_viewport().get_visible_rect().size.y) * 0.5
		var k := float(_cfg.mouse.bar_sensitivity) / maxf(h, 1.0)
		_mouse_offset += event.relative * k  # мышь от себя (вверх по экрану) = трапеция от себя
		_mouse_offset = _mouse_offset.clamp(Vector2(-1, -1), Vector2(1, 1))


## Новый полёт: снять защёлки и подстройку носа.
func reset() -> void:
	_latched.clear()
	_nose_trim = 0.0
	_was_on_ground = true
	on_ground = true
	control = ControlInput.new()


## Вызывать каждый шаг физики.
func update(dt: float) -> ControlInput:
	if not enabled:
		control.pitch = 0.0
		control.roll = 0.0
		control.walk = 0.0
		control.run = false
		return control
	# Отрыв: зажатые сейчас клавиши тангажа/крена не действуют, пока их не отпустят.
	if _was_on_ground and not on_ground:
		_latch_pressed()
	_was_on_ground = on_ground
	_release_latches()
	if on_ground:
		_update_ground(dt)
	else:
		_update_air(dt)
	_apply_gamepad()
	control.pitch = clampf(control.pitch, -1.0, 1.0)
	control.roll = clampf(control.roll, -1.0, 1.0)
	control.walk = clampf(control.walk, -1.0, 1.0)
	return control


## Клавиши, зажатые в момент отрыва, до отпускания (защёлка).
func is_latched(action: String) -> bool:
	return _latched.has(action)


## На земле (FR-30): W — идти, W+Shift — разбег, S — назад, A/D — поворот.
## Нос крыла на разбеге держится сам (ground.run_nose_neutral), ↑/↓ — подстройка.
func _update_ground(dt: float) -> void:
	var kb: Dictionary = _cfg.keyboard
	var g: Dictionary = _cfg.ground
	var sens := float(kb.sensitivity)
	var fwd := _strength("walk_forward") - _strength("walk_back")
	var roll_dir := _strength("roll_right") - _strength("roll_left")
	var run := Input.is_action_pressed("run") and fwd > 0.0
	var trim_dir := _strength("nose_up") - _strength("nose_down")
	var rng := float(g.nose_trim_range)
	_nose_trim = clampf(
		_nose_trim + trim_dir * float(g.nose_pitch_rate_per_s) * sens * dt, -rng, rng
	)
	var nose := float(g.run_nose_neutral) + _nose_trim
	control.run = run
	if run:
		control.walk = 0.0
		control.pitch = nose
		control.roll = _ramp(
			control.roll,
			roll_dir,
			float(kb.roll_rate_per_s) * sens,
			float(kb.roll_return_per_s),
			dt
		)
	else:
		# Ходьба с крылом на плечах: нос держим под углом разбега, чтобы сразу бежать.
		control.walk = fwd
		control.pitch = move_toward(control.pitch, nose, float(kb.pitch_return_per_s) * dt)
		control.roll = roll_dir


func _update_air(dt: float) -> void:
	var kb: Dictionary = _cfg.keyboard
	var sens := float(kb.sensitivity)
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	var pitch_dir := -(_strength("pitch_pull_in") - _strength("pitch_push_out")) * inv
	var roll_dir := _strength("roll_right") - _strength("roll_left")
	control.run = false
	control.walk = 0.0
	_nose_trim = 0.0
	if mouse_captured and mouse_mode() == "bar":
		var ret := float(_cfg.mouse.bar_return_to_center_per_s)
		if ret > 0.0:
			_mouse_offset = _mouse_offset.move_toward(Vector2.ZERO, ret * dt)
		var dz := float(_cfg.mouse.bar_deadzone)
		control.roll = _mouse_offset.x if absf(_mouse_offset.x) > dz else 0.0
		control.pitch = -_mouse_offset.y * inv if absf(_mouse_offset.y) > dz else 0.0
		return
	var ret_rate := float(kb.pitch_return_per_s)
	if not _latched.is_empty():
		# После отрыва трапеция плавно уходит в трим за takeoff_latch.trim_time_s.
		var tt := float(_cfg.get("takeoff_latch", {}).get("trim_time_s", 0.8))
		ret_rate = maxf(ret_rate, 1.0 / maxf(tt, 0.05))
	control.pitch = _ramp(control.pitch, pitch_dir, float(kb.pitch_rate_per_s) * sens, ret_rate, dt)
	control.roll = _ramp(
		control.roll, roll_dir, float(kb.roll_rate_per_s) * sens, float(kb.roll_return_per_s), dt
	)


func _apply_gamepad() -> void:
	var gp: Dictionary = _cfg.gamepad
	if not bool(gp.enabled) or Input.get_connected_joypads().is_empty():
		return
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	var dev: int = Input.get_connected_joypads()[0]
	var gx := _stick(Input.get_joy_axis(dev, int(gp.roll_axis)), gp)
	var gy := _stick(Input.get_joy_axis(dev, int(gp.pitch_axis)), gp)
	if gx != 0.0 or gy != 0.0:
		control.roll = gx
		if on_ground:
			control.walk = -gy
		else:
			control.pitch = gy * inv  # стик на себя (вниз, +) = трапеция от себя
	if on_ground and Input.is_joy_button_pressed(dev, int(gp.run_button)):
		control.run = true
		control.walk = 0.0
		control.pitch = float(_cfg.ground.run_nose_neutral) + _nose_trim


## Сила действия с учётом защёлки.
func _strength(action: String) -> float:
	return 0.0 if _latched.has(action) else Input.get_action_strength(action)


func _latch_pressed() -> void:
	for a in LATCH_ACTIONS:
		if InputMap.has_action(a) and Input.is_action_pressed(a):
			_latched[a] = true


func _release_latches() -> void:
	for a: String in _latched.keys():
		if not Input.is_action_pressed(a):
			_latched.erase(a)


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
