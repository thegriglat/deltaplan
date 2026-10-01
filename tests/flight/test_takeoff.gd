extends TestCase
## Разбег со склона (FR-9) и ходьба по земле.

const Sim := preload("res://tests/flight/flight_sim.gd")


## Склон, спускающийся на север (−Z), уклон 0,3 (~17°).
static func slope(_x: float, z: float) -> float:
	return 1000.0 + 0.3 * z


static func wind_fn(v: Vector3) -> Callable:
	return func(_p: Vector3) -> Vector3: return v


## Разбег с трапецией pitch при ветре wind; возвращает {took_off, failure, time}.
## level_k > 0 — пилот выравнивает крыло рукой: roll = −крен/level_k° (полный ход руки при крене level_k°) (К3 v3: на бегу курс от
## крена, крен от ветра без поправки уводит в дугу по ветру).
static func attempt(
	w: String, wind: Vector3, pitch: float = 0.0, run_s: float = 12.0, level_k: float = 0.0
) -> Dictionary:
	var m := Sim.make(w)
	m.reset_on_ground(Vector3(0, 0, 0), 0.0)
	var res := {"took_off": false, "failure": "", "time": 0.0, "model": m}
	var t := 0.0
	var inp := Sim.input(pitch, 0.0, true)
	var af := wind_fn(wind)
	while t < run_s:
		if level_k > 0.0:
			inp.roll = clampf(-m.telemetry.bank_deg / level_k, -1.0, 1.0)
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


## Попутный ветер — отдельного срыва нет (К3 v3): воздушная скорость = бег − попутный, крыло
## набирает подъёмную силу позже или не набирает вовсе — это и есть «не взлетел».
func test_tailwind_no_liftoff() -> void:
	var calm := attempt("sport", Vector3.ZERO)
	var r := attempt("sport", Vector3(0, 0, -3.0))
	print("    штиль: %s за %.2f с; попутный 3 м/с: %s %.2f с '%s'" % [calm.took_off, calm.time, r.took_off, r.time, r.failure])
	check(r.failure == "", "попутный — не срыв по порогу: '%s'" % r.failure)
	check(not r.took_off or r.time > calm.time + 0.5, "попутный 3 м/с — отрыв позже или нет")


func test_crosswind_fails() -> void:
	# сильный ветер под 45° к курсу, пилот стоит лицом не в ветер: момент от скольжения
	# (∝ встречная × боковая) больше предела «руки пилота» — крыло опрокидывает и стоя
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	Sim.run_for(m, 10.0, Sim.input(), wind_fn(Vector3(4.24, 0, 4.24)), slope)
	check(
		m.mode == FlightModel.Mode.FAILED and m.takeoff_failure == "wingtip",
		"сильный ветер под 45° валит крыло: " + m.takeoff_failure
	)
	check(m.bank > 0.0, "ветер слева поднимает левую консоль — крен вправо")


func test_crosswind_light_all_wings() -> void:
	# Решение пользователя (control-fix, вариант В): на земле пилот сам управляет креном, поэтому
	# здесь он выравнивает крыло рукой; без ввода — test_ground_bank::test_light_crosswind_holds.
	# слабый боковой ветер (2,5 м/с при встречном 4): рука пилота держит, пилот выравнивает крыло
	# креном руки (К3 v3: без поправки крен от ветра к отрыву уводит бег в дугу по ветру, и у
	# крупных крыльев, долго бегущих почти разгруженными, — ww_cross_country, ww_ultra_sport —
	# крен растёт за 20°; без ввода крена — test_ground_bank::test_light_crosswind_holds);
	# крыло, которое и во встречный 4 м/с срывается по носу (atlas, nose_high), — не про крен
	for p in Config.list_configs("wings"):
		var w := String(p).get_file()
		var r := attempt(w, Vector3(2.5, 0, 4.0), 0.0, 12.0, 5.0)
		check(r.failure != "wingtip", "%s: слабый боковой ветер не валит крыло" % w)
		if attempt(w, Vector3(0, 0, 4.0)).took_off:
			check(r.took_off, "%s: слабый боковой ветер — взлёт (срыв: %s)" % [w, r.failure])


## Нос высоко / низко — отдельных срывов нет (К3 v3): сорванное крыло (нос за срывом) или
## крыло с отрицательным углом атаки подъёмной силы не набирает — отрыва нет, пилот бежит.
func test_nose_high_no_liftoff() -> void:
	var r := attempt("sport", Vector3(0, 0, 3.0), 1.0)
	var m: FlightModel = r.model
	check(not r.took_off and r.failure == "", "нос высоко — не взлетает, без срыва: %s '%s'" % [r.took_off, r.failure])
	check(m.stalled, "крыло сорвано")


func test_nose_low_no_liftoff() -> void:
	var r := attempt("sport", Vector3(0, 0, 3.0), -1.0)
	var m: FlightModel = r.model
	check(not r.took_off and r.failure == "", "нос низко — не взлетает, без срыва: %s '%s'" % [r.took_off, r.failure])
	check(m.alpha < 0.0, "угол атаки отрицательный — подъёмная сила вниз: %.1f°" % rad_to_deg(m.alpha))


## Срыва «слабый разбег» нет (К3 v3): бросил бежать — снова стоит (подробно — test_liftoff_physics).
func test_stop_running_stands() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var af := wind_fn(Vector3(0, 0, 1.0))
	Sim.run_for(m, 1.0, Sim.input(0.0, 0.0, true), af, slope)
	Sim.run_for(m, 3.0, Sim.input(), af, slope)
	check(
		m.mode == FlightModel.Mode.GROUND and m.phase() == "standing",
		"бросил бежать — стоит, без срыва: %s %s" % [m.phase(), m.takeoff_failure]
	)


func test_failure_signal() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var got := []
	m.takeoff_failed.connect(func(reason: String) -> void: got.append(reason))
	Sim.run_for(m, 10.0, Sim.input(), wind_fn(Vector3(4.24, 0, 4.24)), slope)
	check(got == ["wingtip"], "сигнал takeoff_failed: " + str(got))


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
	inp.turn = 1.0
	var h0 := m.telemetry.heading_deg
	Sim.run_for(m, 1.0, inp, Callable(), flat)
	approx(
		m.telemetry.heading_deg - h0,
		float(Config.value("pilot", "walk.turn_rate_dps")),
		1.0,
		"поворот на месте"
	)
	check(m.mode == FlightModel.Mode.GROUND, "ходьба — не срыв взлёта")
