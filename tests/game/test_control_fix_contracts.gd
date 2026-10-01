extends TestCase
## Контракты модуля control-fix (docs/control-fix_contracts.md): форма стыков С1, С2.
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


func test_c2_input_controller_shape() -> void:
	var s := load("res://scripts/game/input_controller.gd") as Script
	check(_has_method_args(s, "update", 1), "С2: update(dt) -> ControlInput")
	check(_has_method_args(s, "set_mouse_captured", 1), "С2: set_mouse_captured(on)")
	check(_has_method_args(s, "mouse_mode", 0), "С2: mouse_mode()")
	var ic := InputController.new()
	check("on_ground" in ic and "enabled" in ic and "hands_off" in ic, "С2: on_ground/enabled/hands_off")
	check("mouse_captured" in ic, "С2: mouse_captured")
	ic.free()
	var mouse: Dictionary = Config.get_config("controls").mouse
	check(mouse.has("mode") and String(mouse.mode) in ["look", "bar"], "С2: mouse.mode ∈ look|bar")
	for k in ["bar_sensitivity", "bar_deadzone", "capture_on_start"]:
		check(mouse.has(k), "С2: controls.mouse." + k)
