extends TestCase
## Режим управления «Маятник» (PD-4): Glider выбирает модель по controls.roll_control_mode,
## apparatus доходит до PendulumModel, старт с земли и разбег (PD-3), телеметрия MR-К1 — из маятника,
## перегрузка — по стропе и рукам (PD-К1).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


## Glider в заданном режиме управления креном (режим в кэше Config возвращается обратно).
static func make_glider(mode: String, wing := "sport", apparatus := {}) -> Glider:
	var cfg := Config.get_config("controls")
	var old: Variant = cfg.get("roll_control_mode")
	cfg["roll_control_mode"] = mode
	var g := Glider.new()
	g.setup(wing, 0.0, apparatus)
	cfg["roll_control_mode"] = old
	return g


func test_model_selected_by_setting() -> void:
	for mode in ["rate", "weight_shift"]:
		var g := make_glider(mode)
		check(g.model is FlightModel, "%s → FlightModel" % mode)
		check(not g.is_pendulum(), "%s: is_pendulum = false" % mode)
		g.free()
	var gp := make_glider("pendulum")
	check(gp.model is PendulumModel, "pendulum → PendulumModel")
	check(gp.is_pendulum(), "pendulum: is_pendulum")
	gp.free()


func test_apparatus_reaches_model() -> void:
	var g := make_glider("pendulum", "sport", {"hang_shift_cm": 2.0, "hang_length_m": 1.1})
	var m: PendulumModel = g.model
	approx(float(m.apparatus.hang_shift_cm), 2.0, 1e-9, "hang_shift_cm в модели")
	approx(float(m.apparatus.hang_length_m), 1.1, 1e-9, "hang_length_m в модели")
	approx(float(m.apparatus.sail_flex), 0.2, 1e-9, "пропуск — умолчание PD-К3")
	g.free()


func test_resolved_apparatus_reaches_model() -> void:
	var st := FlightSettings.defaults()
	st.apparatus = {"sport": {"hang_shift_cm": 3.0}, "laminar": {"hang_shift_cm": -2.0}}
	var g := make_glider("pendulum", "sport", st.resolved_apparatus("sport"))
	approx(float(g.model.apparatus.hang_shift_cm), 3.0, 1e-9, "sport: свой сдвиг")
	approx(float(g.model.apparatus.hang_length_m), float(st.resolved_apparatus("sport").hang_length_m), 1e-9, "умолчание в модели")
	g.free()
	var g2 := make_glider("pendulum", "laminar", st.resolved_apparatus("laminar"))
	approx(float(g2.model.apparatus.hang_shift_cm), -2.0, 1e-9, "laminar: свой сдвиг")
	g2.free()


func test_start_on_ground_and_telemetry() -> void:
	var g := make_glider("pendulum")
	var ground := func(_x: float, z: float) -> float: return 0.2 * z  # склон вниз на север
	g.set_ground_fn(ground)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)
	# v2: reset_on_ground — пилот стоит на склоне с крылом на руках
	g.reset_on_ground(Vector3(10.0, 50.0, 20.0), 0.0)
	check(g.phase() == "standing", "после reset_on_ground — стоит (%s)" % g.phase())
	var m: PendulumModel = g.model
	check(m.mode == FlightModel.Mode.GROUND, "режим GROUND")
	approx(m.pilot_position.y - 1.0, 4.0, 0.1, "ступни на земле (высота из ground_fn)")
	g.control.run = true
	var t := 0.0
	while m.mode == FlightModel.Mode.GROUND and t < 20.0:
		g.step(1.0 / 120.0)
		t += 1.0 / 120.0
	check(m.mode == FlightModel.Mode.AIR, "разбег → отрыв за %.1f с" % t)
	g.control.run = false
	for i in 240:
		g.step(1.0 / 120.0)
	var tel := g.get_telemetry()
	check(tel.phase == "flying", "фаза flying")
	check(tel.airspeed > 5.0 and tel.airspeed < 20.0, "скорость %.1f м/с" % tel.airspeed)
	# MR-К1: точка пилота — из маятника, не крыло
	check(tel.pilot_position.is_equal_approx(m.pilot_position), "pilot_position из маятника")
	check(tel.pilot_velocity.is_equal_approx(m.pilot_velocity), "pilot_velocity из маятника")
	check(tel.pilot_basis.is_equal_approx(m.pilot_basis), "pilot_basis из маятника")
	var off := tel.position.distance_to(tel.pilot_position)
	check(off > 0.3 and off < 2.5, "ЦМ пилота в %.2f м от узла Glider, не в нём" % off)
	check(tel.load_factor > 0.5 and tel.load_factor < 1.6, "перегрузка %.2f g" % tel.load_factor)
	approx(tel.load_factor, m.load.load_factor, 1e-9, "load_factor = LoadMeter модели")
	g.free()


func test_set_kinematic_through_model() -> void:
	var g := make_glider("pendulum")
	g.set_kinematic(
		Vector3(0.0, 500.0, 0.0), Vector3(0.0, -1.0, -10.0), 0.0, deg_to_rad(10.0), Basis.IDENTITY
	)
	var m: PendulumModel = g.model
	check(m.mode == FlightModel.Mode.AIR, "после set_kinematic — AIR")
	approx(rad_to_deg(m.bank), 10.0, 0.5, "крен задан")
	check(g.get_telemetry().pilot_position.is_finite(), "pilot_position конечна")
	g.free()


func test_flight_model_telemetry_unchanged() -> void:
	# FlightModel: пилот — точка крыла (как раньше)
	var g := make_glider("weight_shift")
	g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	var t := g.get_telemetry()
	check(t.pilot_position.is_equal_approx(g.model.position), "FlightModel: pilot_position = position")
	g.free()
