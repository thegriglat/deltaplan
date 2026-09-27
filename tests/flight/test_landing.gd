extends TestCase
## Оценка посадки (FR-10).

const Sim := preload("res://tests/flight/flight_sim.gd")


static func flat(_x: float, _z: float) -> float:
	return 100.0


## Касание с заданной скоростью: возвращает результат посадки.
func touch(vel: Vector3, bank_deg: float = 0.0) -> Dictionary:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 100.02, 0), 0.0)
	m.velocity = vel
	m.bank = deg_to_rad(bank_deg)
	var got := []
	m.landed.connect(func(r: Dictionary) -> void: got.append(r))
	Sim.run_for(m, 0.2, Sim.input(), Callable(), flat)
	check(got.size() == 1, "сигнал landed один раз")
	check(m.mode == FlightModel.Mode.LANDED and m.phase() == "landed", "режим landed")
	return m.landing_result


func test_grades() -> void:
	check(touch(Vector3(0, -1.0, -3.0)).grade == "soft", "мягкая")
	check(touch(Vector3(0, -2.5, -4.0)).grade == "hard", "жёсткая по вертикали")
	check(touch(Vector3(0, -1.0, -8.0)).grade == "hard", "жёсткая по горизонтали")
	check(touch(Vector3(0, -5.0, -3.0)).grade == "crash", "авария по вертикали")
	check(touch(Vector3(0, -1.0, -14.0)).grade == "crash", "авария по горизонтали")
	check(touch(Vector3(0, -1.0, -3.0), 40.0).grade == "crash", "авария в крене")


func test_result_fields() -> void:
	var r := touch(Vector3(0, -1.2, -3.0))
	approx(r.vertical_speed_ms, 1.2, 0.2, "вертикальная скорость")
	approx(r.horizontal_speed_ms, 3.0, 0.3, "горизонтальная скорость")


## Заход на посадку: без выравнивания — на триме; с выравниванием — держим ~0,8 м над землёй,
## пока скорость не упадёт до сваливания, затем трапецию полностью от себя.
static func approach(w: String, flare: bool) -> Dictionary:
	var m := Sim.make(w)
	m.reset_in_air(Vector3(0, 104, 0), 0.0)
	var t := 0.0
	var pushing := false
	while m.mode == FlightModel.Mode.AIR and t < 60.0:
		var agl := m.position.y - 100.0
		var p := 0.0
		if flare and agl < 3.0:
			p = clampf(1.5 * (-0.8 * (agl - 0.8) - m.velocity.y), -1.0, 1.0)
			pushing = pushing or m.telemetry.airspeed < m.stall_speed()
		if pushing:
			p = 1.0
		m.step(Sim.DT, Sim.input(p), Callable(), flat)
		t += Sim.DT
	return m.landing_result


func test_flare_vs_no_flare() -> void:
	for w in ["training", "kingpost", "sport"]:
		var plain := approach(w, false)
		var flared := approach(w, true)
		check(
			plain.grade == "hard",
			"%s: касание на триме без выравнивания — жёсткое: %s" % [w, plain]
		)
		check(flared.grade == "soft", "%s: с выравниванием — мягкое: %s" % [w, flared])
		check(
			flared.horizontal_speed_ms < plain.horizontal_speed_ms - 2.0,
			w + ": выравнивание гасит скорость"
		)


func test_dive_into_ground_crashes() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 130, 0), 0.0)
	Sim.run_for(m, 30.0, Sim.input(-1.0), Callable(), flat)
	check(
		m.landing_result.get("grade", "") == "crash",
		"на полной скорости в землю — авария: " + str(m.landing_result)
	)


func test_slope_landing_uses_normal() -> void:
	# посадка на склон «в гору»: скорость в склон учитывается по нормали
	var m := Sim.make("sport")
	var hill := func(_x: float, z: float) -> float: return 100.0 - 0.5 * z  # поднимается на север
	m.reset_in_air(Vector3(0, 100.3, 0), 0.0)
	m.velocity = Vector3(0, -0.5, -8.0)
	Sim.run_for(m, 0.5, Sim.input(), Callable(), hill)
	check(m.mode == FlightModel.Mode.LANDED, "коснулся склона")
	check(
		m.landing_result.vertical_speed_ms > 3.0,
		"удар в склон считается по нормали: %.1f" % m.landing_result.vertical_speed_ms
	)


func test_walk_after_landing() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 100.02, 0), 0.0)
	m.velocity = Vector3(0, -0.5, -2.0)
	Sim.run_for(m, 0.2, Sim.input(), Callable(), flat)
	var inp := ControlInput.new()
	inp.walk = 1.0
	Sim.run_for(m, 1.0, inp, Callable(), flat)
	check(m.phase() == "walking", "после мягкой посадки можно идти: " + m.phase())
