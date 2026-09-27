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
	# пороги (ответ пилотов): вертикальная ≥ 5 м/с — жёсткая; горизонтальная > 3 — жёсткая
	check(touch(Vector3(0, -3.5, -2.0)).grade == "soft", "мягкая: 3,5 м/с вертикально")
	check(touch(Vector3(0, -5.5, -1.0)).grade == "hard", "жёсткая по вертикали (≥ 5 м/с)")
	check(touch(Vector3(0, -1.0, -8.0)).grade == "hard", "жёсткая по горизонтали")
	check(touch(Vector3(0, -8.0, -1.0)).grade == "crash", "авария по вертикали")
	check(touch(Vector3(0, -1.0, -14.0)).grade == "crash", "авария по горизонтали")
	check(touch(Vector3(0, -1.0, -2.0), 40.0).grade == "crash", "авария в крене")


func test_result_fields() -> void:
	var r := touch(Vector3(0, -1.2, -3.0))
	approx(r.vertical_speed_ms, 1.2, 0.2, "вертикальная скорость")
	approx(r.horizontal_speed_ms, 3.0, 0.3, "горизонтальная скорость")


## Заход на посадку на ровное поле (100 м). flare_h < 0 — без выравнивания, на триме;
## иначе держим ноги на высоте flare_h, пока воздушная скорость не упадёт до push_k·V_св,
## (выравнивание начинается у этой высоты)
## затем трапецию от себя до упора (выравнивание). wind — встречный ветер, м/с.
## Возвращает {result, model}.
static func approach(
	w: String, flare_h: float, push_k: float = 1.2, wind: float = 0.0
) -> Dictionary:
	var m := Sim.make(w)
	var air := func(_p: Vector3) -> Vector3: return Vector3(0, 0, wind)
	m.reset_in_air(Vector3(0, 100.0 + maxf(flare_h, 0.0) + 5.0, 0), 0.0, 0.0, Vector3(0, 0, wind))
	var t := 0.0
	var pushing := false
	while m.mode == FlightModel.Mode.AIR and t < 60.0:
		var agl := m.position.y - 100.0
		var p := 0.0
		if flare_h >= 0.0 and agl < flare_h + 3.0:
			p = clampf(1.5 * (-0.8 * (agl - flare_h) - m.velocity.y), -1.0, 1.0)
			var slow := m.telemetry.airspeed < m.stall_speed() * push_k
			pushing = pushing or (slow and agl < flare_h + 0.3)
		if pushing:
			p = 1.0
		m.step(Sim.DT, Sim.input(p), air, flat)
		t += Sim.DT
	return {"result": m.landing_result, "model": m}


func test_flare_vs_no_flare() -> void:
	for w in ["training", "kingpost", "sport"]:
		var plain: Dictionary = approach(w, -1.0).result
		var flared: Dictionary = approach(w, 0.6).result
		check(plain.grade == "hard", "%s: на триме без выравнивания — жёсткая: %s" % [w, plain])
		check(flared.grade == "soft", "%s: с выравниванием — мягкая: %s" % [w, flared])
		check(
			flared.vertical_speed_ms <= 1.5 and flared.horizontal_speed_ms <= 1.5,
			"%s: крыло «подвешивается», пилот встаёт на ноги: %s" % [w, flared]
		)


func test_flare_slightly_off() -> void:
	for w in ["training", "kingpost", "sport"]:
		var r: Dictionary = approach(w, 1.6).result
		check(
			r.grade == "soft" and r.vertical_speed_ms <= 3.0,
			"%s: выровнял на 1 м выше — всё ещё мягкая: %s" % [w, r]
		)


func test_runout_stops_pilot() -> void:
	var r := approach("sport", 0.6)
	var m: FlightModel = r.model
	var p0 := m.position
	Sim.run_for(m, 2.0, Sim.input(), Callable(), flat)
	check(m.telemetry.groundspeed < 0.05, "пилот встал на ноги: %.2f" % m.telemetry.groundspeed)
	var d := p0.distance_to(m.position)
	check(d < 1.5, "пробежка 0–2 шага: %.1f м" % d)


func test_flare_too_high() -> void:
	for w in ["training", "kingpost", "sport"]:
		var high: Dictionary = approach(w, 3.6).result
		check(
			high.grade == "hard" and high.vertical_speed_ms >= 5.0,
			"%s: выровнял на 3 м выше — «плюх», жёсткая: %s" % [w, high]
		)


func test_flare_headwind() -> void:
	for w in ["training", "kingpost", "sport"]:
		var r: Dictionary = approach(w, 0.6, 0.9, 4.0).result
		check(r.grade == "soft", "%s: встречный 4 м/с — мягкая: %s" % [w, r])
		var h: float = r.horizontal_speed_ms
		check(h < 1.5, "%s: путевая почти 0: %.1f" % [w, h])


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
