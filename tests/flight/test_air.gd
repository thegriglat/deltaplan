extends TestCase
## Воздух (FR-7, FR-8): восходящий поток, ветер и снос, несимметричный подъём.

const Sim := preload("res://tests/flight/flight_sim.gd")


func test_updraft_vario() -> void:
	var m := Sim.make("sport")
	var calm: Vector2 = Sim.settle(m, 0.0)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var up := func(_p: Vector3) -> Vector3: return Vector3(0, 2.0, 0)
	Sim.run_for(m, 30.0, Sim.input(), up)
	approx(m.telemetry.vario, 2.0 - calm.y, 0.03, "вариометр в потоке +2 м/с")
	approx(m.telemetry.airspeed, calm.x, 0.1, "воздушная скорость та же")


func test_wind_drift() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0, 0.0, Vector3(5.0, 0, 0))  # курс на север
	var wind := func(_p: Vector3) -> Vector3: return Vector3(5.0, 0, 0)  # ветер дует на восток
	Sim.run_for(m, 10.0, Sim.input(), wind)
	var x0 := m.position.x
	Sim.run_for(m, 20.0, Sim.input(), wind)
	approx(m.position.x - x0, 100.0, 1.0, "снос 5 м/с × 20 с")
	approx(m.telemetry.heading_deg, 0.0, 0.5, "курс не меняется")
	var tas := m.telemetry.airspeed
	approx(
		m.telemetry.groundspeed,
		sqrt(tas * tas - m.telemetry.vario ** 2 + 25.0),
		0.1,
		"путевая = воздушная + ветер"
	)
	approx(
		m.telemetry.track_deg,
		rad_to_deg(atan2(5.0, sqrt(tas * tas - m.telemetry.vario ** 2))),
		0.5,
		"путевой угол"
	)


func test_headwind_groundspeed() -> void:
	var m := Sim.make("laminar")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0, 0.0, Vector3(0, 0, 4.0))
	# встречный: воздух идёт на юг
	var wind := func(_p: Vector3) -> Vector3: return Vector3(0, 0, 4.0)
	Sim.run_for(m, 20.0, Sim.input(), wind)
	var vh := sqrt(m.telemetry.airspeed ** 2 - m.telemetry.vario ** 2)
	approx(m.telemetry.groundspeed, vh - 4.0, 0.1, "встречный ветер уменьшает путевую")


func test_sudden_crosswind_weathervanes() -> void:
	# внезапный боковой ветер: крыло без скольжения разворачивается носом в поток
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 1.0, Sim.input(), func(_p: Vector3) -> Vector3: return Vector3(5.0, 0, 0))
	check(
		m.telemetry.heading_deg > 300.0,
		"нос развернуло влево, навстречу потоку: %.0f°" % m.telemetry.heading_deg
	)


func test_asymmetric_lift_rolls_wing() -> void:
	# подъём сильнее слева (запад, −X) — крыло кренит вправо, от термика
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var grad := func(p: Vector3) -> Vector3: return Vector3(0, clampf(-0.1 * p.x, -3.0, 3.0), 0)
	Sim.run_for(m, 1.5, Sim.input(), grad)
	check(
		m.telemetry.bank_deg > 3.0,
		"несимметричный подъём кренит вправо: %.1f°" % m.telemetry.bank_deg
	)
	var m2 := Sim.make("sport")
	m2.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var grad2 := func(p: Vector3) -> Vector3: return Vector3(0, clampf(0.1 * p.x, -3.0, 3.0), 0)
	Sim.run_for(m2, 1.5, Sim.input(), grad2)
	check(m2.telemetry.bank_deg < -3.0, "подъём справа кренит влево: %.1f°" % m2.telemetry.bank_deg)


func test_vertical_gust_bumps() -> void:
	# резкий вход в поток: перегрузка и толчок, затем установившийся подъём
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var gust := func(p: Vector3) -> Vector3: return Vector3(0, 3.0 if p.z < -50.0 else 0.0, 0)
	var max_acc := 0.0
	var vy_prev := 0.0
	for i in 1200:
		m.step(Sim.DT, Sim.input(), gust, Callable())
		max_acc = maxf(max_acc, (m.velocity.y - vy_prev) / Sim.DT)
		vy_prev = m.velocity.y
	check(max_acc > 2.0, "порыв даёт толчок вверх: %.1f м/с²" % max_acc)
