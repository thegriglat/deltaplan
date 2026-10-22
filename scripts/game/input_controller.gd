class_name InputController
extends Node
## Собирает ControlInput из клавиатуры, мыши и геймпада (FR-30…FR-33).
## Крыло (трапеция) — всегда мышь, стик геймпада, самодельная трапеция; клавиатура — пилот (У1 v5): тангажа и
## крена с клавиатуры нет ни в полёте, ни на земле. Крен — режимы controls.roll_control_mode (rate — ход ручки
## задаёт скорость крена; weight_shift/pendulum — положение пилота), источник — мышь/стик.
## X — «в центр»: трапеция в нейтраль и крыло плавно в горизонт. Автопилот (Game.autopilot) пишет
## тангаж и крен в ControlInput напрямую (pitch_command/roll_command).
## Мышь — всегда трапеция (и в полёте, и на земле), пока она захвачена (M); не захвачена —
## трапецию не двигает, трапеция держит последнее положение мыши. Пока зажата правая кнопка —
## мышь крутит голову (это делает CameraRig), трапеция держит положение.
## Клавиши регистрируются в InputMap из configs/controls.json.
## На земле (С2 v4, У2 v2): стоя и шагом W/S — шаг, A/D — поворот на месте (ControlInput.turn);
## с зажатым Shift (разбег) W/S/A/D ничего не делают. Нос и крен крыла на земле — мышь, стик,
## как в полёте; трапеция на отрыве непрерывна.
## В полёте (У2 v2) keys_look() = true: клавиши look_* (W/S/A/D) крутят голову в кабине (CameraRig).
## Добор «на себя» до бёдер (VM-К3 v3, У1 v5, CB-К1 v4): ControlInput.pull_full — пока зажат pull_full (Shift),
## кнопка gamepad.pull_full_button или тангаж идёт с выбранной самодельной трапеции (BarAxis.is_bar).

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
## Режим крена: "rate" — как раньше, "weight_shift" — смещение веса, "pendulum" — то же
## положение пилота, но физика маятника (из controls.json).
var roll_mode := "pendulum"
## Разбег заблокирован (сеть, очередь на старт NET-43: не первый в очереди): Shift не бежит.
var run_blocked := false
## Разбег нажат кнопкой геймпада (не Shift): старт буксировки на джойстике (TW-10).
var pad_run := false
## Направление крена (PV1): "bar" — устройство двигает трапецию (вправо = крен влево),
## "body" — тело (вправо = крен вправо). Только в полёте в weight_shift.
var roll_input := "body"

var _cfg: Dictionary
var _mouse_offset := Vector2.ZERO  # накопленное смещение мыши, доли полного хода
var _bar_look_held := false  # правая кнопка зажата — мышь крутит голову, не трапецию
var _center_down := false  # X нажата в прошлом шаге (фронт нажатия, в т.ч. короче шага физики)
var _centering := false  # «в центр» (X): трапеция в нейтраль, крыло в горизонт
var _prev_bank := 0.0  # «в центр» в режиме rate: крен прошлого шага, °


func _ready() -> void:
	reload_config()


## Перечитать configs/controls.json (после изменения настроек).
func reload_config() -> void:
	_cfg = Config.get_config("controls")
	register_actions(_cfg)
	roll_mode = String(_cfg.get("roll_control_mode", "pendulum"))
	if roll_mode != "weight_shift" and roll_mode != "rate":
		roll_mode = "pendulum"  # PMD-К1: неизвестное значение → маятник
	roll_input = String(_cfg.get("roll_input", "body"))


## Клавиши look_* (W/S/A/D) сейчас крутят голову (У2 v2): ввод включён, руки на трапеции
## (не свободная камера), в полёте. От мыши не зависит; на земле — шаг и поворот.
func keys_look() -> bool:
	return enabled and not hands_off and not on_ground


## Крен в полёте — смещение веса (иначе — скорость крена, как раньше). Автопилот — всегда rate.
func weight_shift() -> bool:
	if roll_mode == "pendulum":
		return true  # положение пилота (маятник); автопилот задаёт его сам (Autopilot.roll_command)
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


## Захват курсора. Смещение мыши при этом не меняется: трапеция держит положение.
func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event.is_action_pressed("mouse_capture"):
		set_mouse_captured(not mouse_captured)
		return
	# Правая кнопка зажата — осмотреться (CameraRig крутит голову), трапеция
	# держит последнее положение, пока кнопка не отпущена.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_bar_look_held = event.pressed
		return
	# Мышь — трапеция и на земле, и в полёте (У1 v3): смещение копится всегда (при захвате),
	# поэтому на отрыве трапеция непрерывна. Свободная камера (hands_off) — мышь крутит её, трапеция
	# держит положение (иначе после возврата в кабину трапеция стояла бы, куда вела камера).
	if mouse_captured and event is InputEventMouseMotion and not _bar_look_held and not hands_off:
		var h := float(get_viewport().get_visible_rect().size.y) * 0.5
		var k := float(_cfg.mouse.bar_sensitivity) / maxf(h, 1.0)
		_mouse_offset += event.relative * k  # мышь от себя (вверх по экрану) = трапеция от себя
		_mouse_offset = _mouse_offset.clamp(Vector2(-1, -1), Vector2(1, 1))


## Новый полёт: трапеция в нейтраль.
func reset() -> void:
	on_ground = true
	_centering = false
	_mouse_offset = Vector2.ZERO
	control = ControlInput.new()


## Вызывать каждый шаг физики.
func update(dt: float) -> ControlInput:
	pad_run = false
	control.weight_shift = weight_shift()
	if not enabled or hands_off:
		control.pitch = 0.0
		control.roll = 0.0
		control.walk = 0.0
		control.turn = 0.0
		control.run = false
		control.pull_full = false
		return control
	control.pull_full = _strength("pull_full") > 0.5
	if on_ground:
		_update_ground(dt)
	else:
		_update_air(dt)
	_apply_gamepad()
	_apply_autopilot()
	control.pitch = clampf(control.pitch, -1.0, 1.0)
	control.roll = clampf(control.roll, -1.0, 1.0)
	control.walk = clampf(control.walk, -1.0, 1.0)
	control.turn = clampf(control.turn, -1.0, 1.0)
	return control


## На земле (С2 v3). Стоя и шагом: W/S — шаг (walk), A/D — поворот на месте (turn). Разбег (зажат
## Shift, W не нужен): walk = turn = 0. Трапеция и стоя, и на бегу — мышь, стик — нос и крен крыла,
## как в полёте (pitch — нос крыла, 0 — угол разбега launch.alpha_neutral_deg; roll — крен руки пилота),
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
	_update_bar(dt, false)


func _update_air(dt: float) -> void:
	control.run = false
	control.walk = 0.0
	control.turn = 0.0
	_update_bar(dt, true)


## Знак крена от устройства (PV1): −1 при roll_input = bar, в полёте и на земле при weight_shift (PV1 v2).
func _roll_sign() -> float:
	if roll_input == "bar" and control.weight_shift:
		return -1.0
	return 1.0


## Трапеция (нос и крен) от мыши. Одна и та же на земле и в полёте; «в центр» (X) — только в полёте
## (allow_center).
func _update_bar(dt: float, allow_center: bool) -> void:
	var kb: Dictionary = _cfg.keyboard
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	if allow_center:
		_update_centering()
	else:
		_centering = false
	var c_tau := maxf(float(kb.center_time_s), 0.01)
	var ret := float(_cfg.mouse.bar_return_to_center_per_s)
	if _centering:
		_mouse_offset *= exp(-dt / c_tau)
	elif ret > 0.0:
		_mouse_offset = _mouse_offset.move_toward(Vector2.ZERO, ret * dt)
	var dz := float(_cfg.mouse.bar_deadzone)
	var m_roll := _mouse_offset.x * _roll_sign() if absf(_mouse_offset.x) > dz else 0.0
	var m_pitch := -_mouse_offset.y * inv if absf(_mouse_offset.y) > dz else 0.0
	control.pitch = clampf(m_pitch, -1.0, 1.0)
	control.roll = clampf(m_roll, -1.0, 1.0)
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
## управление не придёт в нейтраль или игрок не сдвинет мышь.
func _update_centering() -> void:
	var has := InputMap.has_action("center")
	var held := has and Input.is_action_pressed("center")
	var down := held or (has and Input.is_action_just_pressed("center"))
	var edge := down and not _center_down
	_center_down = down
	if edge or held:
		if not _centering:
			var t := _telemetry()
			_prev_bank = t.bank_deg if t != null else 0.0
		# PV2: одно нажатие обнуляет накопленное положение мыши по обеим осям
		_mouse_offset = Vector2.ZERO
		_centering = true
	elif _centering:
		# мышь сдвинули после X — трапеция снова слушается (PV2)
		if _mouse_offset.length() > 0.005:
			_centering = false
			return
		var settled := absf(control.pitch) < 0.01 and absf(control.roll) < 0.01
		var t := _telemetry()
		if not control.weight_shift and t != null:
			settled = absf(control.pitch) < 0.01 and absf(t.bank_deg) < 1.0  # roll — выравнивание крыла
		if settled:
			_centering = false


func _apply_gamepad() -> void:
	var gp: Dictionary = _cfg.gamepad
	if not bool(gp.enabled):
		return
	# выбранного устройства нет — ввода с джойстика нет (не подменять другим: другая калибровка)
	var dev := BarAxis.find_device(String(gp.get("device_guid", "")))
	if dev < 0:
		return
	# полный ход до бёдер без кнопки — только у самодельной трапеции: выбрана и без известной раскладки (CB-К1 v4)
	var is_bar := String(gp.get("device_guid", "")) != "" and BarAxis.is_bar(dev)
	apply_stick(Input.get_joy_axis(dev, int(gp.roll_axis)), Input.get_joy_axis(dev, int(gp.pitch_axis)), is_bar)
	if Input.is_joy_button_pressed(dev, int(gp.get("pull_full_button", JOY_BUTTON_RIGHT_SHOULDER))):
		control.pull_full = true
	if on_ground and not run_blocked and Input.is_joy_button_pressed(dev, int(gp.run_button)):
		control.run = true
		pad_run = true
		control.walk = 0.0
		control.turn = 0.0


## Сырые значения осей джойстика → control.roll/pitch (CB-К2). Отдельно от устройства — для тестов.
func apply_stick(raw_roll: float, raw_pitch: float, is_bar := false) -> void:
	var gp: Dictionary = _cfg.gamepad
	var inv := -1.0 if bool(_cfg.invert_pitch) else 1.0
	var gx := BarAxis.axis_value(raw_roll, BarAxis.cal_of(gp, "roll"), bool(gp.get("invert_roll", false)), gp)
	var gy := BarAxis.axis_value(raw_pitch, BarAxis.cal_of(gp, "pitch"), bool(gp.get("invert_pitch", false)), gp)
	if gx != 0.0 or gy != 0.0:
		# стик — трапеция и в полёте, и на земле (С2 v3): на земле нос и заданный крен крыла
		control.roll = gx * _roll_sign()  # ход стика = ручка крена (смещение веса или скорость крена — по режиму)
		# стик вперёд (ось < 0) = трапеция от себя (pitch +), как у дельтапланериста (У1 v3)
		control.pitch = -gy * inv
		# самодельная трапеция (CB-К1 v4, вариант «б»): полный ход устройства — штанга у бёдер, без модификатора;
		# обычный геймпад — до груди, до бёдер только с pull_full_button
		if is_bar:
			control.pull_full = true


func _telemetry() -> Telemetry:
	if not telemetry_fn.is_valid():
		var g := get_node_or_null("../Glider")
		if g == null or not g.has_method("get_telemetry"):
			return null
		telemetry_fn = g.get_telemetry
	return telemetry_fn.call() as Telemetry


func _strength(action: String) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


## Автопилот (Game.autopilot, тесты и --autopilot): тангаж и крен — в ControlInput напрямую (У1 v5: клавиш
## трапеции нет). Крен в режиме pendulum Game ставит сам (roll_command), здесь — тот же.
func _apply_autopilot() -> void:
	var game := get_parent()
	var auto: Variant = game.get("autopilot") if game != null else null
	if auto == null:
		return
	control.pitch = float(auto.pitch_command)
	control.roll = float(auto.roll_command)
