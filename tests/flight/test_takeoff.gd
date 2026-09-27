extends TestCase
## Разбег со склона (FR-9) и ходьба по земле.

const Sim := preload("res://tests/flight/flight_sim.gd")


## Склон, спускающийся на север (−Z), уклон 0,3 (~17°).
static func slope(_x: float, z: float) -> float:
	return 1000.0 + 0.3 * z


static func wind_fn(v: Vector3) -> Callable:
	return func(_p: Vector3) -> Vector3: return v


## Разбег с трапецией pitch при ветре wind; возвращает {took_off, failure, time}.
static func attempt(
	w: String, wind: Vector3, pitch: float = 0.0, run_s: float = 12.0
) -> Dictionary:
	var m := Sim.make(w)
	m.reset_on_ground(Vector3(0, 0, 0), 0.0)
	var res := {"took_off": false, "failure": "", "time": 0.0, "model": m}
	var t := 0.0
	var inp := Sim.input(pitch, 0.0, true)
	var af := wind_fn(wind)
	while t < run_s:
		m.step(Sim.DT, inp, af, slope)
		t += Sim.DT
		if m.mode == FlightModel.Mode.AIR:
			res.took_off = true
			res.time = t
			break
		if m.mode == FlightModel.Mode.FAILED:
			res.failure = m.takeoff_failure
			res.time = t
			break
	return res


func test_headwind_launch() -> void:
	for p in Config.list_configs("wings"):
		var w := String(p).get_file()
		var r := attempt(w, Vector3(0, 0, 4.0))
		check(r.took_off, "%s: встречный 4 м/с — взлёт (срыв: %s)" % [w, r.failure])
		var m: FlightModel = r.model
		check(m.phase() == "flying", "фаза после отрыва — flying")


func test_headwind_helps() -> void:
	var strong := attempt("sport", Vector3(0, 0, 5.0))
	var light := attempt("sport", Vector3(0, 0, 1.5))
	check(strong.took_off, "встречный 5 м/с — взлёт")
	check(
		not light.took_off or light.time > strong.time,
		"со слабым ветром разбег дольше: %.1f vs %.1f" % [light.time, strong.time]
	)


func test_tailwind_fails() -> void:
	var r := attempt("sport", Vector3(0, 0, -3.0))
	check(not r.took_off, "попутный 3 м/с — не взлетает")
	check(r.failure == "tailwind", "причина — попутный ветер: " + r.failure)


func test_crosswind_fails() -> void:
	var r := attempt("sport", Vector3(6.0, 0, 1.0))
	check(
		r.failure == "crosswind", "сильный боковой ветер без выравнивания валит крыло: " + r.failure
	)


func test_crosswind_corrected() -> void:
	# ветер слева (воздух на восток) поднимает левую консоль → крен вправо;
	# пилот выравнивает влево
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var af := wind_fn(Vector3(2.5, 0, 4.0))
	var t := 0.0
	while t < 10.0 and m.mode == FlightModel.Mode.GROUND:
		var corr := clampf(-m.telemetry.bank_deg / 5.0, -1.0, 1.0)
		m.step(Sim.DT, Sim.input(0.0, corr, true), af, slope)
		t += Sim.DT
	check(
		m.mode == FlightModel.Mode.AIR,
		"умеренный боковой ветер парируется креном: " + m.takeoff_failure
	)


func test_nose_high_fails() -> void:
	var r := attempt("sport", Vector3(0, 0, 3.0), 1.0)
	check(r.failure == "nose_high", "нос высоко: " + str(r.failure))


func test_nose_low_fails() -> void:
	var r := attempt("sport", Vector3(0, 0, 3.0), -1.0)
	check(r.failure == "nose_low", "нос низко: " + str(r.failure))


func test_weak_run_fails() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var af := wind_fn(Vector3(0, 0, 1.0))
	Sim.run_for(m, 1.0, Sim.input(0.0, 0.0, true), af, slope)
	Sim.run_for(m, 0.5, Sim.input(), af, slope)
	check(
		m.mode == FlightModel.Mode.FAILED and m.takeoff_failure == "weak_run",
		"бросил бежать — слабый разбег: " + m.takeoff_failure
	)


func test_failure_signal() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var got := []
	m.takeoff_failed.connect(func(reason: String) -> void: got.append(reason))
	Sim.run_for(m, 3.0, Sim.input(0.0, 0.0, true), wind_fn(Vector3(0, 0, -3.0)), slope)
	check(got == ["tailwind"], "сигнал takeoff_failed: " + str(got))


func test_walking() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var flat := func(_x: float, _z: float) -> float: return 500.0
	var inp := ControlInput.new()
	Sim.run_for(m, 1.0, inp, Callable(), flat)
	check(m.phase() == "standing", "стоит: " + m.phase())
	approx(m.position.y, 500.0, 0.001, "на земле")
	inp.walk = 1.0
	Sim.run_for(m, 5.0, inp, Callable(), flat)
	check(m.phase() == "walking", "идёт: " + m.phase())
	var walk_speed := float(Config.value("pilot", "walk.speed_ms"))
	approx(-m.position.z, walk_speed * 5.0, 0.5, "прошёл вперёд (на север)")
	# на крутом склоне медленнее
	var m2 := Sim.make("sport")
	m2.reset_on_ground(Vector3.ZERO, 0.0)
	var steep := func(_x: float, z: float) -> float: return 500.0 - 0.6 * z  # в гору на север
	Sim.run_for(m2, 5.0, inp, Callable(), steep)
	check(-m2.position.z < -m.position.z * 0.7, "в крутую гору идёт медленнее")
	approx(m2.position.y, steep.call(m2.position.x, m2.position.z), 0.001, "не уходит под землю")
	# поворот на месте
	inp.walk = 0.0
	inp.roll = 1.0
	var h0 := m.telemetry.heading_deg
	Sim.run_for(m, 1.0, inp, Callable(), flat)
	approx(
		m.telemetry.heading_deg - h0,
		float(Config.value("pilot", "walk.turn_rate_dps")),
		1.0,
		"поворот на месте"
	)
	check(m.mode == FlightModel.Mode.GROUND, "ходьба — не срыв взлёта")
