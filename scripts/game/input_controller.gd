class_name InputController
extends Node
## Собирает ControlInput из клавиатуры и геймпада (FR-30…FR-33).
## Крен — два режима (controls.roll_control_mode, пункт в настройках):
## "rate" — «как раньше» (по умолчанию): A/D задают скорость крена, отпустил — крен держится;
## "weight_shift" — смещение веса: A/D плавно смещают вес, отпустил — пружиной в центр,
## крыло само выравнивается. X — «в центр» в обоих режимах: трапеция в нейтраль и крыло
## плавно в горизонт. Автопилот (Game.autopilot) всегда управляет в режиме "rate".
## Мышь по умолчанию крутит голову (это делает CameraRig); в режиме "bar" — управляет трапецией,
## а пока зажата правая кнопка — крутит голову (трапеция держит последнее положение).
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
## true — клавиши заняты свободной камерой (WASD двигает её): крыло без рук — трапеция в триме,
## на земле стоим. Защёлка при отрыве продолжает отслеживаться.
var hands_off := false
## Телеметрия планера для автоматического носа на разбеге (LaunchNose): () -> Telemetry.
## Не задана — берётся у соседнего узла Glider (сцена игры); нет и его — нос на нейтрали.
var telemetry_fn: Callable
## Режим крена: "rate" — как раньше, "weight_shift" — смещение веса (из controls.json).
var roll_mode := "rate"

var _cfg: Dictionary
var _nose_trim := 0.0  # подстройка носа на разбеге стрелками
var _auto_nose := 0.0  # автоматический нос по ветру (≤ 0 — ниже нейтрали)
var _launch_nose := LaunchNose.new()
var _was_on_ground := true
var _latched := {}  # действие → true: зажато в момент отрыва, не отпущено
var _mouse_offset := Vector2.ZERO  # режим bar: накопленное смещение мыши, доли полного хода
var _bar_look_held := false  # режим bar: правая кнопка зажата — мышь крутит голову, не трапецию
var _roll_pos := 0.0  # смещение веса: положение пилота поперёк трапеции (до плавной нейтрали)
var _centering := false  # «в центр» (X): трапеция в нейтраль, крыло в горизонт
var _prev_bank := 0.0  # «в центр» в режиме rate: крен прошлого шага, °


func _ready() -> void:
	reload_config()


## Перечитать configs/controls.json (после изменения настроек).
func reload_config() -> void:
	_cfg = Config.get_config("controls")
	register_actions(_cfg)
	roll_mode = String(_cfg.get("roll_control_mode", "rate"))
	_launch_nose.configure(_cfg.get("ground", {}).get("auto_nose", {}))


func mouse_mode() -> String:
	return String(_cfg.mouse.mode)


## Крен в полёте — смещение веса (иначе — скорость крена, как раньше). Автопилот — всегда rate.
func weight_shift() -> bool:
	var game := get_parent()
	var auto := game != null and game.get("autopilot") != null
	return roll_mode == "weight_shift" and not auto


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
	# Кнопки геймпада для действий (gamepad.action_buttons: действие → индекс кнопки).
	var buttons: Dictionary = cfg.get("gamepad", {}).get("action_buttons", {})
	for action in buttons:
		if InputMap.has_action(action):
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(buttons[action]) as JoyButton
			InputMap.action_add_event(action, jb)


func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	_mouse_offset = Vector2(control.roll, -control.pitch)


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event.is_action_pressed("mouse_capture"):
		set_mouse_captured(not mouse_captured)
		return
	# Режим "bar": правая кнопка зажата — осмотреться (CameraRig крутит голову), трапеция
	# держит последнее положение, пока кнопка не отпущена.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_bar_look_held = event.pressed
		return
	if (
		mouse_captured
		and mouse_mode() == "bar"
		and event is InputEventMouseMotion
		and not _bar_look_held
	):
		var h := float(get_viewport().get_visible_rect().size.y) * 0.5
		var k := float(_cfg.mouse.bar_sensitivity) / maxf(h, 1.0)
		_mouse_offset += event.relative * k  # мышь от себя (вверх по экрану) = трапеция от себя
		_mouse_offset = _mouse_offset.clamp(Vector2(-1, -1), Vector2(1, 1))


## Новый полёт: снять защёлки и подстройку носа.
func reset() -> void:
	_latched.clear()
	_nose_trim = 0.0
	_auto_nose = 0.0
	_launch_nose.reset()
	_was_on_ground = true
	on_ground = true
	_roll_pos = 0.0
	_centering = false
	control = ControlInput.new()


## Вызывать каждый шаг физики.
func update(dt: float) -> ControlInput:
	control.weight_shift = weight_shift()
	if not enabled or hands_off:
		if _was_on_ground and not on_ground:
			_latch_pressed()
		_was_on_ground = on_ground
		control.pitch = 0.0
		control.roll = 0.0
		_roll_pos = 0.0
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
## Нос крыла на разбеге держится сам (_run_nose), ↑/↓ — подстройка поверх.
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
	_update_auto_nose(trim_dir, dt)
	var nose := _run_nose()
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
	_roll_pos = control.roll


func _update_air(dt: float) -> void:
	var kb: Dictionary = _cfg.keyboard
	var sens := float(kb.sensitivity)
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	var pitch_dir := -(_strength("pitch_pull_in") - _strength("pitch_push_out")) * inv
	var roll_dir := _strength("roll_right") - _strength("roll_left")
	control.run = false
	control.walk = 0.0
	_nose_trim = 0.0
	_auto_nose = 0.0
	_launch_nose.reset()
	_update_centering(pitch_dir, roll_dir)
	var c_tau := maxf(float(kb.center_time_s), 0.01)
	if mouse_captured and mouse_mode() == "bar":
		var ret := float(_cfg.mouse.bar_return_to_center_per_s)
		if _centering:
			_mouse_offset *= exp(-dt / c_tau)
		elif ret > 0.0:
			_mouse_offset = _mouse_offset.move_toward(Vector2.ZERO, ret * dt)
		var dz := float(_cfg.mouse.bar_deadzone)
		control.roll = _mouse_offset.x if absf(_mouse_offset.x) > dz else 0.0
		control.pitch = -_mouse_offset.y * inv if absf(_mouse_offset.y) > dz else 0.0
		_roll_pos = control.roll
		if _centering and not control.weight_shift:
			control.roll = _level_wing(kb, dt)
		return
	if _centering:
		control.pitch *= exp(-dt / c_tau)
		_roll_pos *= exp(-dt / c_tau)
		control.roll = _soft_center(_roll_pos, float(kb.roll_neutral_zone))
		if not control.weight_shift:
			control.roll = _level_wing(kb, dt)
		return
	var ret_rate := float(kb.pitch_return_per_s)
	if not _latched.is_empty():
		# После отрыва трапеция плавно уходит в трим за takeoff_latch.trim_time_s.
		var tt := float(_cfg.get("takeoff_latch", {}).get("trim_time_s", 0.8))
		ret_rate = maxf(ret_rate, 1.0 / maxf(tt, 0.05))
	control.pitch = _ramp(control.pitch, pitch_dir, float(kb.pitch_rate_per_s) * sens, ret_rate, dt)
	if control.weight_shift:
		_roll_pos = _roll_shift(_roll_pos, roll_dir, kb, sens, dt)
		control.roll = _soft_center(_roll_pos, float(kb.roll_neutral_zone))
	else:
		control.roll = _ramp(
			control.roll,
			roll_dir,
			float(kb.roll_rate_per_s) * sens,
			float(kb.roll_return_per_s),
			dt
		)
		_roll_pos = control.roll


## «В центр» в режиме rate: ручка крена против крена (с упреждением по скорости крена), пока
## крыло не выйдет в горизонт. Без телеметрии — просто нейтраль.
func _level_wing(kb: Dictionary, dt: float) -> float:
	var t := _telemetry()
	if t == null:
		return 0.0
	var rate := (t.bank_deg - _prev_bank) / dt if dt > 0.0 else 0.0
	_prev_bank = t.bank_deg
	var full := maxf(float(kb.center_rate_bank_deg), 1.0)
	return clampf(-(t.bank_deg + rate * 0.3) / full, -1.0, 1.0)


## «В центр» (X): включается нажатием, держится, пока клавиша зажата, а после — пока
## управление не придёт в нейтраль или игрок не нажмёт клавишу тангажа/крена.
func _update_centering(pitch_dir: float, roll_dir: float) -> void:
	var held := InputMap.has_action("center") and Input.is_action_pressed("center")
	if held:
		if not _centering:
			var t := _telemetry()
			_prev_bank = t.bank_deg if t != null else 0.0
		_centering = true
	elif _centering:
		var settled := absf(_roll_pos) < 0.01 and absf(control.pitch) < 0.01
		settled = settled and _mouse_offset.length() < 0.01
		var t := _telemetry()
		if not control.weight_shift and t != null:
			settled = settled and absf(t.bank_deg) < 1.0
		if settled or pitch_dir != 0.0 or roll_dir != 0.0:
			_centering = false


## Смещение веса с клавиатуры: при удержании плавно (за roll_shift_time_s) уходит к краю
## (к силе нажатия: Input.action_press(…, strength) у автопилота — неполное смещение),
## при отпускании пружиной (постоянная времени roll_center_time_s) возвращается в центр.
static func _roll_shift(v: float, dir: float, kb: Dictionary, sens: float, dt: float) -> float:
	if dir != 0.0:
		var rate := sens / maxf(float(kb.roll_shift_time_s), 0.01)
		# от противоположного края через центр — быстрее: пружина помогает
		if v * dir < 0.0:
			rate += 1.0 / maxf(float(kb.roll_center_time_s), 0.01)
		return move_toward(v, clampf(dir, -1.0, 1.0), rate * dt)
	return v * exp(-dt / maxf(float(kb.roll_center_time_s), 0.01))


## Плавная нейтраль: |x| < dz почти не смещает вес (квадратично), дальше — линейно до ±1;
## без ступеньки и излома.
static func _soft_center(x: float, dz: float) -> float:
	var a := absf(x)
	if dz <= 0.0:
		return x
	var y := a * a / (2.0 * dz) if a < dz else a - 0.5 * dz
	return signf(x) * y / (1.0 - 0.5 * dz)


func _apply_gamepad() -> void:
	var gp: Dictionary = _cfg.gamepad
	if not bool(gp.enabled) or Input.get_connected_joypads().is_empty():
		return
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	var dev: int = Input.get_connected_joypads()[0]
	var gx := _stick(Input.get_joy_axis(dev, int(gp.roll_axis)), gp)
	var gy := _stick(Input.get_joy_axis(dev, int(gp.pitch_axis)), gp)
	if gx != 0.0 or gy != 0.0:
		control.roll = gx  # ход стика = ручка крена (смещение веса или скорость крена — по режиму)
		_roll_pos = gx
		if on_ground:
			control.walk = -gy
		else:
			control.pitch = gy * inv  # стик на себя (вниз, +) = трапеция от себя
	if on_ground and Input.is_joy_button_pressed(dev, int(gp.run_button)):
		control.run = true
		control.walk = 0.0
		control.pitch = _run_nose()


## Нос на разбеге: нейтраль + автоматический нос по ветру + подстройка стрелками.
func _run_nose() -> float:
	return float(_cfg.ground.run_nose_neutral) + _auto_nose + _nose_trim


## «Нос держится сам» (G06, ground.auto_nose): стоя пилот чувствует ветер в лицо; в сильный
## ветер нос сам уходит вниз до угла атаки ~18° (как автопилот F01), в слабый — нейтраль.
## Пока игрок подстраивает нос стрелками, автомат замирает — ошибка «нос высоко/низко» возможна.
func _update_auto_nose(trim_dir: float, dt: float) -> void:
	var an: Dictionary = _cfg.ground.get("auto_nose", {})
	if not bool(an.get("enabled", true)):
		_auto_nose = 0.0
		return
	var t := _telemetry()
	if t == null:
		return
	_launch_nose.observe(t)
	if trim_dir != 0.0 or absf(_nose_trim) > 1e-6:
		return
	var dir := _launch_nose.direction(t)
	var rate := float(an.get("rate_per_s", 0.6))
	var rng := float(an.get("range", 0.3))
	_auto_nose = clampf(_auto_nose + dir * rate * dt, -rng, 0.0)


func _telemetry() -> Telemetry:
	if not telemetry_fn.is_valid():
		var g := get_node_or_null("../Glider")
		if g == null or not g.has_method("get_telemetry"):
			return null
		telemetry_fn = g.get_telemetry
	return telemetry_fn.call() as Telemetry


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
