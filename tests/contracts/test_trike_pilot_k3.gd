extends TestCase
## Контракт TP-К3 (docs/contracts/trike-pilot.md): ввод дельталёта — газ, двигатель, руление, тормоз.

const DT := 1.0 / 120.0
const NEW_ACTIONS := ["throttle_up", "throttle_down", "engine_toggle", "trike_brake"]


func _make(vehicle: String, on_ground: bool) -> InputController:
	var ic := InputController.new()
	ic.reload_config()
	ic.vehicle = vehicle
	ic.on_ground = on_ground
	_release_all()
	return ic


func _release_all() -> void:
	for a in NEW_ACTIONS + ["look_up", "look_down", "turn_left", "turn_right", "walk_forward", "walk_back", "run", "pull_full"]:
		if InputMap.has_action(a):
			Input.action_release(a)


func _done(ic: InputController) -> void:
	_release_all()
	ic.vehicle = "glider"
	ic.free()


func test_actions_registered_and_documented() -> void:
	var cfg: Dictionary = Config.get_config("controls")
	InputController.register_actions(cfg)
	for a in NEW_ACTIONS:
		check(InputMap.has_action(a), "%s зарегистрировано" % a)
		check(cfg.keys.has(a) and cfg.keys.has(a + "_doc"), "%s и %s_doc в controls.json" % [a, a])
	# engine_toggle не делит клавиши с другими действиями (кроме ui_accept)
	var codes := {}
	for ev in InputMap.action_get_events("engine_toggle"):
		if ev is InputEventKey:
			codes[ev.physical_keycode] = true
	for a in InputMap.get_actions():
		if a == "engine_toggle" or a == "ui_accept" or String(a).begins_with("ui_"):
			continue
		for ev in InputMap.action_get_events(a):
			if ev is InputEventKey:
				check(not codes.has(ev.physical_keycode), "клавиша engine_toggle занята действием %s" % a)


func test_glider_unchanged() -> void:
	var ic := _make("glider", false)
	Input.action_press("look_up")  # в glider look_up — W
	Input.action_press("throttle_up")
	Input.action_press("engine_toggle")
	Input.action_press("trike_brake")
	var c := ic.update(DT)
	check(c.throttle_axis == 0.0 and not c.engine_toggle and not c.brake, "glider: газ/двигатель/тормоз не читаются")
	_done(ic)
	var g := _make("glider", true)
	Input.action_press("walk_forward")
	Input.action_press("throttle_up")
	var c2 := g.update(DT)
	check(c2.walk == 1.0 and c2.throttle_axis == 0.0, "glider на земле: W — шаг, газа нет")
	_done(g)


func test_trike_throttle() -> void:
	for ground in [true, false]:
		var ic := _make("trike", ground)
		Input.action_press("throttle_up")
		check(ic.update(DT).throttle_axis == 1.0, "W: +1 (ground=%s)" % ground)
		Input.action_press("throttle_down")
		check(ic.update(DT).throttle_axis == 0.0, "W+S: 0")
		Input.action_release("throttle_up")
		check(ic.update(DT).throttle_axis == -1.0, "S: −1")
		Input.action_release("throttle_down")
		check(ic.update(DT).throttle_axis == 0.0, "ничего: 0")
		_done(ic)


func test_trike_ground_no_walk_run() -> void:
	var ic := _make("trike", true)
	Input.action_press("throttle_up")
	Input.action_press("walk_forward")
	Input.action_press("run")
	var c := ic.update(DT)
	check(c.walk == 0.0 and not c.run, "trike на земле: walk 0, run false")
	_done(ic)


func _look_codes() -> Dictionary:
	var d := {}
	for a in ["look_up", "look_down", "look_left", "look_right"]:
		var codes := []
		for ev in InputMap.action_get_events(a):
			if ev is InputEventKey:
				codes.append(ev.physical_keycode)
		d[a] = codes
	return d


## v2 (Q1): в trike клавишного взгляда нет; привязки look_* не зависят от vehicle.
func test_trike_no_key_look() -> void:
	var ic := _make("glider", false)
	var before := _look_codes()
	check(before.look_up == [KEY_W] and before.look_down == [KEY_S], "look_up/down = W/S")
	check(before.look_left == [KEY_A] and before.look_right == [KEY_D], "look_left/right = A/D")
	check(ic.keys_look(), "glider в воздухе: keys_look() true")
	Input.action_press("throttle_up")
	check(ic.update(DT).throttle_axis == 0.0, "glider: W не газ")
	Input.action_release("throttle_up")
	ic.vehicle = "trike"
	check(not ic.keys_look(), "trike в воздухе: keys_look() false")
	check(_look_codes() == before, "trike не меняет InputMap")
	Input.action_press("throttle_up")
	var c := ic.update(DT)
	check(c.throttle_axis == 1.0, "trike: W — газ")
	Input.action_release("throttle_up")
	Input.action_press("turn_left")
	check(ic.update(DT).turn == 0.0, "trike в воздухе: A — turn 0")
	ic.vehicle = "glider"
	check(_look_codes() == before, "обратно в glider: InputMap прежний")
	check(ic.keys_look(), "glider: keys_look() снова true")
	_done(ic)


## Версия раздела контракта: тест написан под TP-К3 v2.
func test_contract_version() -> void:
	var f := FileAccess.open("res://docs/contracts/trike-pilot.md", FileAccess.READ)
	check(f != null, "контракт читается")
	if f == null:
		return
	check(f.get_as_text().contains("## TP-К3 v2."), "в контракте есть раздел TP-К3 v2")


func test_trike_shift_brake_vs_pull_full() -> void:
	var g := _make("trike", true)
	Input.action_press("trike_brake")
	var c := g.update(DT)
	check(c.brake and not c.pull_full and not c.run, "trike на земле: Shift — только тормоз")
	_done(g)
	var a := _make("trike", false)
	Input.action_press("pull_full")
	Input.action_press("trike_brake")
	var c2 := a.update(DT)
	check(c2.pull_full and not c2.brake, "trike в воздухе: Shift — pull_full, не тормоз")
	_done(a)


func test_trike_engine_toggle_once() -> void:
	var ic := _make("trike", true)
	Input.action_press("engine_toggle")
	check(ic.update(DT).engine_toggle, "пробел: engine_toggle true")
	check(not ic.update(DT).engine_toggle, "удержание: дальше false")
	Input.action_release("engine_toggle")
	check(not ic.update(DT).engine_toggle, "отпустили: false")
	Input.action_press("engine_toggle")
	check(ic.update(DT).engine_toggle, "новое нажатие: снова true")
	_done(ic)


func test_trike_turn_and_brake() -> void:
	var g := _make("trike", true)
	Input.action_press("turn_left")
	Input.action_press("trike_brake")
	var c := g.update(DT)
	check(c.turn < 0.0, "A на земле: turn < 0")
	check(c.brake, "тормоз на земле")
	_done(g)
	var a := _make("trike", false)
	Input.action_press("turn_left")
	Input.action_press("trike_brake")
	var c2 := a.update(DT)
	check(c2.turn == 0.0, "A в воздухе: turn 0")
	check(not c2.brake, "в воздухе brake false")
	_done(a)
