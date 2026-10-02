extends TestCase
## Контракты модуля control-fix (docs/contracts/control-fix.md): форма стыков С1 v2, С2 v2, К3 v3.
## Ломается, если формат поменяли без правки контракта.


func _has_method_args(script: Script, method: String, n_args: int) -> bool:
	for m in script.get_script_method_list():
		if String(m.name) == method:
			return (m.args as Array).size() == n_args
	return false


func test_c1_control_input_shape() -> void:
	var c := ControlInput.new()
	check(c.pitch is float and c.pitch == 0.0, "С1: pitch: float, 0")
	check(c.roll is float and c.roll == 0.0, "С1: roll: float, 0")
	check(c.walk is float and c.walk == 0.0, "С1: walk: float, 0")
	check(c.run is bool and not c.run, "С1: run: bool, false")
	check(c.weight_shift is bool, "С1: weight_shift: bool")
	check("turn" in c and c.turn is float and c.turn == 0.0, "С1 v2: turn: float, 0 (курс стоя/шагом)")


func test_c2_input_controller_shape() -> void:
	var s := load("res://scripts/game/input_controller.gd") as Script
	check(_has_method_args(s, "update", 1), "С2: update(dt) -> ControlInput")
	check(_has_method_args(s, "set_mouse_captured", 1), "С2: set_mouse_captured(on)")
	check(not _has_method_args(s, "mouse_mode", 0), "С2 v3: mouse_mode() убран — мышь всегда крыло")
	var ic := InputController.new()
	check("on_ground" in ic and "enabled" in ic and "hands_off" in ic, "С2: on_ground/enabled/hands_off")
	check("mouse_captured" in ic, "С2: mouse_captured")
	ic.free()
	var mouse: Dictionary = Config.get_config("controls").mouse
	check(not mouse.has("mode"), "С2 v3: mouse.mode убран — мышь всегда крыло")
	check(not Config.get_config("controls").has("takeoff_latch"), "С2 v2: защёлки при отрыве нет")
	check(not _has_method_args(s, "is_latched", 1), "С2 v2: is_latched убран")
	for k in ["bar_sensitivity", "bar_deadzone", "capture_on_start"]:
		check(mouse.has(k), "С2: controls.mouse." + k)


func test_k3v3_ground_roll_is_bank_command() -> void:
	# К3 v3: на земле input.roll — заданный крен руки пилота, курс стоя — input.turn.
	var m := FlightModel.new()
	m.setup(Config.get_config("wings/sport"), Config.get_config("pilot"), {})
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var gr := GroundRun.new()
	var air := func(_p: Vector3) -> Vector3: return Vector3.ZERO
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var inp := ControlInput.new()
	inp.roll = 1.0
	for i in 600:
		gr.step(m, 1.0 / 120.0, inp, air, ground)
	check(absf(rad_to_deg(m.bank)) > 3.0, "К3 v3: roll на земле кренит крыло (штиль, стоя)")
	check(absf(rad_to_deg(m.heading)) < 1.0, "К3 v3: roll на земле не поворачивает курс")
	gr.reset()
	m.reset_on_ground(Vector3.ZERO, 0.0)
	inp = ControlInput.new()
	inp.turn = 1.0
	for i in 600:
		gr.step(m, 1.0 / 120.0, inp, air, ground)
	check(absf(rad_to_deg(m.heading)) > 30.0, "К3 v3: turn стоя поворачивает курс")
	check(absf(rad_to_deg(m.bank)) < 0.5, "К3 v3: turn стоя не кренит крыло")
