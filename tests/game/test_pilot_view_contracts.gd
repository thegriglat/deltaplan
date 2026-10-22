extends TestCase
## Контракты модуля pilot-view (docs/contracts/pilot-view.md): PV1 v1 — направление крена
## (controls.roll_input bar/body), PV2 v1 — X возвращает мышь-трапецию в нейтраль и она там остаётся.

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0


static func _ic(roll_input: String) -> InputController:
	var ic := InputController.new()
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(ic)
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = false
	ic._cfg = cfg
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


## Ввод крена мышью «вправо» (стик идёт тем же знаком; клавиш трапеции нет, У1 v5).
static func _roll_right(roll_input: String) -> float:
	var ic := _ic(roll_input)
	_mouse(ic, 4000.0, 0.0)
	var r := 0.0
	for i in 120:
		r = ic.update(DT).roll
	_free(ic)
	return r


func test_pv1_default_is_body() -> void:
	check(String(Config.get_config("controls").get("roll_input", "")) == "body", "PV1: умолчание body")
	check(Config.get_config("controls").has("roll_input_doc"), "PV1: roll_input_doc")


func test_pv1_sign_by_device() -> void:
	var bar := _roll_right("bar")
	var body := _roll_right("body")
	check(bar < -0.2, "PV1: bar, мышь вправо — roll < 0 (%.2f)" % bar)
	check(body > 0.2, "PV1: body, мышь вправо — roll > 0 (%.2f)" % body)


func test_pv1_ground_inverts_too() -> void:
	var ic := _ic("bar")
	ic.on_ground = true
	_mouse(ic, 4000.0, 0.0)
	var r := 0.0
	for i in 60:
		r = ic.update(DT).roll
	check(r < -0.2, "PV1 v2: на земле bar инвертирует, как в полёте (%.2f)" % r)
	ic.roll_input = "body"
	ic.update(DT)
	check(ic.update(DT).roll > 0.2, "PV1 v2: на земле body — вправо (%.2f)" % ic.control.roll)
	_free(ic)


## Физика («Маятник»): bar + мышь вправо → крыло кренится влево за ≤ 6 с (штиль).
func test_pv1_wing_banks_left_with_bar() -> void:
	for pair in [["bar", -1.0], ["body", 1.0]]:
		var ic := _ic(pair[0])
		var m := Sim.make("training")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		_run(m, null, 3.0)
		_mouse(ic, 4000.0, 0.0)
		_run(m, ic, 6.0)
		var b := m.telemetry.bank_deg * float(pair[1])
		check(b > 5.0, "PV1: %s, мышь вправо — крен в нужную сторону %.1f°" % [pair[0], m.telemetry.bank_deg])
		_free(ic)


static func _run(m: PendulumModel, ic: InputController, seconds: float) -> void:
	var neutral := ControlInput.new()
	for i in int(seconds / DT):
		m.step(DT, ic.update(DT) if ic != null else neutral, Callable(), Callable())


## PV2: мышь на полный ход вбок и вперёд → X одним кадром → через 3 с трапеция в нуле и остаётся.
func test_pv2_center_once() -> void:
	for mode in ["pendulum"]:
		await (Engine.get_main_loop() as SceneTree).process_frame  # свежий кадр: just_pressed прошлой итерации сброшен
		var ic := _ic("bar")
		var m := Sim.make("training")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		_run(m, null, 3.0)
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


## PV1 v2: мышь вбок через переход земля → воздух не меняет знак roll.
func test_pv1_sign_through_liftoff() -> void:
	for ri in ["bar", "body"]:
		await (Engine.get_main_loop() as SceneTree).process_frame  # just_pressed X прошлых тестов
		var ic := _ic(ri)
		ic.on_ground = true
		ic._mouse_offset = Vector2(0.3, 0.0)
		var ground := 0.0
		for i in 120:
			ground = ic.update(DT).roll
		ic.on_ground = false
		var air := ic.update(DT).roll
		check(signf(ground) == signf(air) and absf(air - ground) < 0.05,
			"PV1 v2: %s, через отрыв roll %.2f -> %.2f" % [ri, ground, air])
		_free(ic)


## PV1: выбор roll_input пишется в пользовательский controls.json и читается обратно.
func test_pv1_saved_to_user_config() -> void:
	var dir := "user://test_pv1_cfg"
	check(UserSettings.save_patch("controls", {"roll_input": "body"}, dir), "PV1: запись roll_input")
	var f := FileAccess.open(dir + "/controls.json", FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
	check(d is Dictionary and d.get("roll_input") == "body", "PV1: roll_input прочитан из user-конфига")
