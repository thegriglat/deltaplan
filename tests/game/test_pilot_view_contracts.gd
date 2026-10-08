extends TestCase
## Контракты модуля pilot-view (docs/contracts/pilot-view.md): PV1 v1 — направление крена
## (controls.roll_input bar/body), PV2 v1 — X возвращает мышь-трапецию в нейтраль и она там остаётся.

const Sim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0


static func _ic(mode: String, roll_input: String) -> InputController:
	var ic := InputController.new()
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(ic)
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = false
	cfg.keyboard.sensitivity = 1.0
	ic._cfg = cfg
	ic.roll_mode = mode
	ic.roll_input = roll_input
	ic.mouse_captured = true
	ic.reset()
	ic.on_ground = false
	return ic


static func _free(ic: InputController) -> void:
	ic.get_parent().remove_child(ic)
	ic.free()


static func _mouse(ic: InputController, dx: float, dy: float) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(dx, dy)
	ic._unhandled_input(ev)


## Ввод крена устройством «вправо» (kind: mouse | key | stick-имитация не нужна — стик идёт тем же знаком).
static func _roll_right(mode: String, roll_input: String, kind: String) -> float:
	var ic := _ic(mode, roll_input)
	if kind == "mouse":
		_mouse(ic, 4000.0, 0.0)
	else:
		Input.action_press("roll_right")
	var r := 0.0
	for i in 120:
		r = ic.update(DT).roll
	if kind != "mouse":
		Input.action_release("roll_right")
	_free(ic)
	return r


func test_pv1_default_is_bar() -> void:
	check(String(Config.get_config("controls").get("roll_input", "")) == "bar", "PV1: умолчание bar")
	check(Config.get_config("controls").has("roll_input_doc"), "PV1: roll_input_doc")


func test_pv1_sign_by_device() -> void:
	for kind in ["mouse", "key"]:
		var bar := _roll_right("weight_shift", "bar", kind)
		var body := _roll_right("weight_shift", "body", kind)
		check(bar < -0.2, "PV1: bar, %s вправо — roll < 0 (%.2f)" % [kind, bar])
		check(body > 0.2, "PV1: body, %s вправо — roll > 0 (%.2f)" % [kind, body])
		var rb := _roll_right("rate", "bar", kind)
		var ro := _roll_right("rate", "body", kind)
		check(rb > 0.2 and absf(rb - ro) < 1e-6, "PV1: rate — знак не зависит от roll_input (%.2f/%.2f)" % [rb, ro])


func test_pv1_ground_unchanged() -> void:
	var ic := _ic("weight_shift", "bar")
	ic.on_ground = true
	_mouse(ic, 4000.0, 0.0)
	var r := 0.0
	for i in 60:
		r = ic.update(DT).roll
	check(r > 0.2, "PV1: на земле bar не инвертирует (%.2f)" % r)
	_free(ic)


## Физика: bar + мышь вправо → крыло кренится влево за ≤ 3 с.
func test_pv1_wing_banks_left_with_bar() -> void:
	for pair in [["bar", -1.0], ["body", 1.0]]:
		var ic := _ic("weight_shift", pair[0])
		var m := Sim.make("training")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 3.0, Sim.input(0.0, 0.0))
		_mouse(ic, 4000.0, 0.0)
		for i in int(3.0 / DT):
			m.step(DT, ic.update(DT), Callable(), Callable())
		var b := m.telemetry.bank_deg * float(pair[1])
		check(b > 5.0, "PV1: %s, мышь вправо — крен в нужную сторону %.1f°" % [pair[0], m.telemetry.bank_deg])
		_free(ic)


## PV2: мышь на полный ход вбок и вперёд → X одним кадром → через 3 с трапеция в нуле и остаётся.
func test_pv2_center_once() -> void:
	for mode in ["weight_shift", "rate"]:
		await (Engine.get_main_loop() as SceneTree).process_frame  # свежий кадр: just_pressed прошлой итерации сброшен
		var ic := _ic(mode, "bar")
		var m := Sim.make("training")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 3.0, Sim.input(0.0, 0.0))
		_mouse(ic, 4000.0, -4000.0)
		for i in 10:
			m.step(DT, ic.update(DT), Callable(), Callable())
		check(absf(ic.control.roll) > 0.5 and ic.control.pitch > 0.5, "PV2/%s: трапеция отклонена" % mode)
		Input.action_press("center")
		m.step(DT, ic.update(DT), Callable(), Callable())
		Input.action_release("center")
		for i in int(3.0 / DT):
			m.step(DT, ic.update(DT), Callable(), Callable())
		var b3 := m.telemetry.bank_deg
		check(absf(ic.control.roll) < 0.05 and absf(ic.control.pitch) < 0.05,
			"PV2/%s: через 3 с roll %.3f pitch %.3f" % [mode, ic.control.roll, ic.control.pitch])
		check(absf(b3) < 5.0, "PV2/%s: крен %.1f° < 5°" % [mode, b3])
		for i in int(3.0 / DT):
			m.step(DT, ic.update(DT), Callable(), Callable())
		check(absf(ic.control.roll) < 0.05 and absf(m.telemetry.bank_deg) < 5.0,
			"PV2/%s: после отпускания X остаётся (roll %.3f, крен %.1f°)" % [mode, ic.control.roll, m.telemetry.bank_deg])
		_mouse(ic, 4000.0, 0.0)
		for i in 5:
			ic.update(DT)
		check(absf(ic.control.roll) > 0.3, "PV2/%s: мышь после X снова двигает трапецию (%.2f)" % [mode, ic.control.roll])
		_free(ic)
