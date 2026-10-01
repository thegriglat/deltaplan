class_name InputController
extends Node
## Собирает ControlInput из клавиатуры и геймпада (FR-30…FR-33).
## Крен — два режима (controls.roll_control_mode, пункт в настройках):
## "rate" — «как раньше» (по умолчанию): A/D задают скорость крена, отпустил — крен держится;
## "weight_shift" — смещение веса: A/D плавно смещают вес, отпустил — пружиной в центр,
## крыло само выравнивается. X — «в центр» в обоих режимах: трапеция в нейтраль и крыло
## плавно в горизонт. Автопилот (Game.autopilot) всегда управляет в режиме "rate".
## Мышь по умолчанию ("bar") управляет трапецией и в полёте, и на земле, а пока зажата правая
## кнопка — крутит голову (трапеция держит последнее положение); в режиме "look" мышь только
## крутит голову (это делает CameraRig). Клавиши регистрируются в InputMap из configs/controls.json.
## На земле (С2 v2): стоя и шагом W/S — шаг, A/D — поворот на месте (ControlInput.turn), нос и крен
## крыла — те же действия «трапеции», что в полёте (стрелки), мышь, стик; клавиши, занятые шагом
## и поворотом, трапецию стоя не двигают. С зажатым Shift (разбег) все органы — нос и крен, как
## в полёте. Трапеция на отрыве непрерывна: одни и те же положения клавиш, мыши и стика.
## Обзор с клавиш (У2 v1): мышь — трапеция (bar) и захвачена, в полёте или на разбеге —
## keys_look() = true: клавиши look_* (W/S/A/D) крутят голову в кабине (CameraRig), а в трапецию
## не вносят ничего; трапеция с клавиш — на других клавишах тех же действий (стрелки).

## Действия шага и поворота на земле: их клавиши стоя не двигают трапецию.
const GROUND_MOVE_ACTIONS: Array[String] = ["walk_forward", "walk_back", "turn_left", "turn_right"]
## Действия обзора головой (У2): их клавиши при keys_look() не двигают трапецию.
const LOOK_ACTIONS: Array[String] = ["look_up", "look_down", "look_left", "look_right"]

var control := ControlInput.new()
var mouse_captured := false
## Фазу сообщает главная сцена по телеметрии: на земле стоя W/S — шаг, A/D — поворот.
var on_ground := true
## false — ввод игнорируется (меню, итог полёта): update() отдаёт нейтральное управление.
var enabled := true
## true — клавиши заняты свободной камерой (WASD двигает её): крыло без рук — трапеция в триме,
## на земле стоим.
var hands_off := false
## Телеметрия планера для «в центр» (X) в режиме rate: () -> Telemetry.
## Не задана — берётся у соседнего узла Glider (сцена игры).
var telemetry_fn: Callable
## Режим крена: "rate" — как раньше, "weight_shift" — смещение веса (из controls.json).
var roll_mode := "rate"
## Разбег заблокирован (сеть, очередь на старт NET-43: не первый в очереди): Shift не бежит.
var run_blocked := false

var _cfg: Dictionary
var _key_pitch := 0.0  # трапеция по тангажу от клавиш, доля хода (мышь и стик — отдельно)
var _mouse_offset := Vector2.ZERO  # режим bar: накопленное смещение мыши, доли полного хода
var _bar_look_held := false  # режим bar: правая кнопка зажата — мышь крутит голову, не трапецию
var _roll_pos := 0.0  # крен от клавиш: смещение веса (до плавной нейтрали) или ручка крена (rate)
var _centering := false  # «в центр» (X): трапеция в нейтраль, крыло в горизонт
var _prev_bank := 0.0  # «в центр» в режиме rate: крен прошлого шага, °


func _ready() -> void:
	reload_config()


## Перечитать configs/controls.json (после изменения настроек).
func reload_config() -> void:
	_cfg = Config.get_config("controls")
	register_actions(_cfg)
	roll_mode = String(_cfg.get("roll_control_mode", "rate"))


func mouse_mode() -> String:
	return String(_cfg.mouse.mode)


## Клавиши look_* сейчас крутят голову, а не трапецию (У2 v1): мышь — трапеция (bar) и
## захвачена, ввод включён, руки на трапеции, и в полёте или на разбеге (зажат run, не заблокирован).
func keys_look() -> bool:
	if not enabled or hands_off or not mouse_captured or mouse_mode() != "bar":
		return false
	if not on_ground:
		return true
	return InputMap.has_action("run") and Input.is_action_pressed("run") and not run_blocked


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


## Захват курсора. Смещение мыши (bar) при этом не меняется: трапеция держит положение.
func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


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
	# Мышь — трапеция и на земле, и в полёте (С2 v2): смещение копится всегда, поэтому на
	# отрыве трапеция непрерывна.
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


## Новый полёт: трапеция в нейтраль.
func reset() -> void:
	_key_pitch = 0.0
	on_ground = true
	_roll_pos = 0.0
	_centering = false
	_mouse_offset = Vector2.ZERO
	control = ControlInput.new()


## Вызывать каждый шаг физики.
func update(dt: float) -> ControlInput:
	control.weight_shift = weight_shift()
	if not enabled or hands_off:
		control.pitch = 0.0
		control.roll = 0.0
		_key_pitch = 0.0
		_roll_pos = 0.0
		control.walk = 0.0
		control.turn = 0.0
		control.run = false
		return control
	if on_ground:
		_update_ground(dt)
	else:
		_update_air(dt)
	_apply_gamepad()
	control.pitch = clampf(control.pitch, -1.0, 1.0)
	control.roll = clampf(control.roll, -1.0, 1.0)
	control.walk = clampf(control.walk, -1.0, 1.0)
	control.turn = clampf(control.turn, -1.0, 1.0)
	return control


## На земле (С2 v2). Стоя и шагом: W/S — шаг (walk), A/D — поворот на месте (turn); трапеция —
## действия pitch_*/roll_* без клавиш шага и поворота (стрелки), мышь, стик. Разбег (зажат Shift,
## W не нужен): все клавиши действий трапеции, мышь, стик — нос и крен крыла, как в полёте.
## Трапеция на земле: pitch — нос крыла (0 — угол разбега крыла launch.alpha_neutral_deg),
## roll — заданный крен руки пилота; клавиши ведут её так же, как в полёте (тот же ход и возврат),
## поэтому на отрыве скачка нет.
func _update_ground(dt: float) -> void:
	var run := Input.is_action_pressed("run") and not run_blocked
	control.run = run
	if run:
		control.walk = 0.0
		control.turn = 0.0
	else:
		control.walk = _strength("walk_forward") - _strength("walk_back")
		control.turn = _strength("turn_right") - _strength("turn_left")
	var only_bar := not run
	_update_bar(dt, _bar_pitch_dir(only_bar), _bar_roll_dir(only_bar), false)


func _update_air(dt: float) -> void:
	control.run = false
	control.walk = 0.0
	control.turn = 0.0
	_update_bar(dt, _bar_pitch_dir(false), _bar_roll_dir(false), true)


## Направление трапеции по тангажу с клавиш: +1 — от себя (нос вверх), −1 — на себя.
## only_bar — стоя на земле: клавиши шага и поворота не считаются.
func _bar_pitch_dir(only_bar: bool) -> float:
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	return (
		-(_bar_strength("pitch_pull_in", only_bar) - _bar_strength("pitch_push_out", only_bar))
		* inv
	)


func _bar_roll_dir(only_bar: bool) -> float:
	return _bar_strength("roll_right", only_bar) - _bar_strength("roll_left", only_bar)


## Трапеция (нос и крен): клавиши + мышь (bar), сумма до упора. Одна и та же на земле и в полёте;
## «в центр» (X) — только в полёте (allow_center).
func _update_bar(dt: float, pitch_dir: float, roll_dir: float, allow_center: bool) -> void:
	var kb: Dictionary = _cfg.keyboard
	var sens := float(kb.sensitivity)
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	if allow_center:
		_update_centering(pitch_dir, roll_dir)
	else:
		_centering = false
	var c_tau := maxf(float(kb.center_time_s), 0.01)
	var bar := mouse_mode() == "bar"
	if bar:
		var ret := float(_cfg.mouse.bar_return_to_center_per_s)
		if _centering:
			_mouse_offset *= exp(-dt / c_tau)
		elif ret > 0.0:
			_mouse_offset = _mouse_offset.move_toward(Vector2.ZERO, ret * dt)
	var dz := float(_cfg.mouse.bar_deadzone)
	var m_roll := _mouse_offset.x if bar and absf(_mouse_offset.x) > dz else 0.0
	var m_pitch := -_mouse_offset.y * inv if bar and absf(_mouse_offset.y) > dz else 0.0
	if _centering:
		_key_pitch *= exp(-dt / c_tau)
		_roll_pos *= exp(-dt / c_tau)
	else:
		_key_pitch = _ramp(
			_key_pitch,
			pitch_dir,
			float(kb.pitch_rate_per_s) * sens,
			float(kb.pitch_return_per_s),
			dt
		)
		if control.weight_shift:
			_roll_pos = _roll_shift(_roll_pos, roll_dir, kb, sens, dt)
		else:
			_roll_pos = _ramp(
				_roll_pos,
				roll_dir,
				float(kb.roll_rate_per_s) * sens,
				float(kb.roll_return_per_s),
				dt
			)
	var k_roll := _roll_pos
	if control.weight_shift:
		k_roll = _soft_center(_roll_pos, float(kb.roll_neutral_zone))
	control.pitch = clampf(_key_pitch + m_pitch, -1.0, 1.0)
	control.roll = clampf(k_roll + m_roll, -1.0, 1.0)
	if _centering and not control.weight_shift:
		control.roll = _level_wing(kb, dt)


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
		# стик — трапеция и в полёте, и на земле (С2 v2): на земле нос и заданный крен крыла
		control.roll = gx  # ход стика = ручка крена (смещение веса или скорость крена — по режиму)
		# стик вперёд (ось < 0) = трапеция от себя (pitch +), как у дельтапланериста (У1 v2)
		control.pitch = -gy * inv
	if on_ground and not run_blocked and Input.is_joy_button_pressed(dev, int(gp.run_button)):
		control.run = true
		control.walk = 0.0
		control.turn = 0.0


func _telemetry() -> Telemetry:
	if not telemetry_fn.is_valid():
		var g := get_node_or_null("../Glider")
		if g == null or not g.has_method("get_telemetry"):
			return null
		telemetry_fn = g.get_telemetry
	return telemetry_fn.call() as Telemetry


func _strength(action: String) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


## Сила действия трапеции. Если действие зажато только клавишами, которые сейчас заняты
## другим, — 0: стоя на земле (only_bar) — шагом и поворотом (GROUND_MOVE_ACTIONS), при
## keys_look() — обзором (LOOK_ACTIONS). Нажатие без физической клавиши (Input.action_press —
## автопилот, тесты) считается.
func _bar_strength(action: String, only_bar: bool) -> float:
	var s := _strength(action)
	var look := keys_look()
	if s <= 0.0 or not (only_bar or look):
		return s
	var any_key := false
	for ev in InputMap.action_get_events(action):
		var k := ev as InputEventKey
		if k == null or not Input.is_physical_key_pressed(k.physical_keycode):
			continue
		any_key = true
		var busy := (only_bar and _key_in(k.physical_keycode, GROUND_MOVE_ACTIONS)) or (
			look and _key_in(k.physical_keycode, LOOK_ACTIONS)
		)
		if not busy:
			return s
	return 0.0 if any_key else s


## Назначена ли физическая клавиша на одно из действий.
static func _key_in(code: Key, actions: Array[String]) -> bool:
	for a in actions:
		if not InputMap.has_action(a):
			continue
		for ev in InputMap.action_get_events(a):
			var k := ev as InputEventKey
			if k != null and k.physical_keycode == code:
				return true
	return false


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
