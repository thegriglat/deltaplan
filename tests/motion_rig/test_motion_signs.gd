extends TestCase
## Знаки и величины MotionSource на манёврах headless FlightModel (MR-К1).

const Sim := preload("res://tests/flight/flight_sim.gd")
const G := Units.G


## Шаги модели + push; sample() каждые every шагов, возвращает последний.
static func run(m: FlightModel, src: MotionSource, secs: float, inp: ControlInput, every: int = 12) -> MotionSample:
	var s: MotionSample = null
	for i in int(round(secs / Sim.DT)):
		m.step(Sim.DT, inp, Callable(), Callable())
		src.push(m.telemetry, Sim.DT)
		if (i + 1) % every == 0:
			s = src.sample()
	return s


static func glider_in_air() -> FlightModel:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	return m


## Кинематическая часть продольной удельной силы: surge минус проекция покоящейся +g на нос.
static func surge_kinematic(s: MotionSample) -> float:
	return s.surge - G * sin(deg_to_rad(s.pitch))


func test_steady_level_flight() -> void:
	var m := glider_in_air()
	var src := MotionSource.new()
	var s := run(m, src, 20.0, Sim.input())
	print("MR2 steady: surge=%.3f sway=%.3f heave=%.3f pitch=%.2f" % [s.surge, s.sway, s.heave, s.pitch])
	check(s.valid, "valid")
	approx(s.heave, G, 0.5, "heave в установившемся полёте")
	approx(s.sway, 0.0, 0.2, "sway")
	# связанная ось пилота наклонена на theta к горизонту: на нос проецируется g·sin(theta), кинематики нет
	approx(s.surge, G * sin(m.theta), 0.2, "surge = g·sin(theta)")
	approx(surge_kinematic(s), 0.0, 0.2, "поступательное ускорение")
	approx(s.roll_rate, 0.0, 0.2, "roll_rate")
	approx(s.pitch_rate, 0.0, 0.2, "pitch_rate")
	approx(s.yaw_rate, 0.0, 0.2, "yaw_rate")
	var srs := MotionPacket.pack_srs(s, "Test")
	approx(srs.decode_float(196), 0.0, 0.05, "srs vertical_acceleration, g")
	approx(srs.decode_float(192), 0.0, 0.05, "srs lateral_acceleration, g")


func test_steady_right_turn() -> void:
	var m := glider_in_air()
	m.bank = deg_to_rad(30.0)
	var src := MotionSource.new()
	var s := run(m, src, 40.0, Sim.input())
	print("MR2 turn30: surge=%.3f sway=%.3f heave=%.3f yaw_rate=%.2f roll=%.1f" % [s.surge, s.sway, s.heave, s.yaw_rate, s.roll])
	check(s.roll > 0.0, "roll > 0 (правое крыло вниз)")
	approx(s.roll, 30.0, 0.5, "roll = bank")
	# координированный вираж: полная удельная сила направлена по U (боковой нет), величина g/cos(bank)
	approx(s.sway, 0.0, 0.3, "sway в координированном вираже")
	approx(s.heave, G / cos(deg_to_rad(30.0)), 0.8, "heave = g/cos(bank)")
	check(s.yaw_rate > 5.0, "yaw_rate > 0 при повороте вправо: %.2f" % s.yaw_rate)


func test_roll_in_rates_and_angles() -> void:
	var m := glider_in_air()
	var src := MotionSource.new()
	run(m, src, 10.0, Sim.input())
	var s := run(m, src, 0.5, Sim.input(0.0, 1.0))
	print("MR2 roll-in: roll_rate=%.2f yaw_rate=%.2f sway=%.3f" % [s.roll_rate, s.yaw_rate, s.sway])
	check(s.roll_rate > 5.0, "roll_rate > 0 при вводе в правый крен: %.2f" % s.roll_rate)
	check(s.yaw_rate > 0.0, "yaw_rate > 0: %.2f" % s.yaw_rate)
	approx(s.roll, m.telemetry.bank_deg, 0.01, "roll = bank модели")
	approx(s.pitch, rad_to_deg(m.theta), 0.01, "pitch = theta модели")
	approx(s.yaw, m.telemetry.heading_deg, 0.01, "yaw = heading модели")
	approx(s.airspeed, m.telemetry.airspeed, 0.01, "airspeed")


func test_pitch_up_and_acceleration() -> void:
	# нос вверх (+1 на ручке): pitch_rate > 0
	var m := glider_in_air()
	var src := MotionSource.new()
	run(m, src, 15.0, Sim.input())
	var s := run(m, src, 0.25, Sim.input(1.0), 6)
	print("MR2 pitch up: pitch_rate=%.2f" % s.pitch_rate)
	check(s.pitch_rate > 5.0, "pitch_rate > 0 при подъёме носа: %.2f" % s.pitch_rate)
	# разгон (ручка от себя, пикирование): продольное ускорение > 0, скорость растёт
	var m2 := glider_in_air()
	var src2 := MotionSource.new()
	run(m2, src2, 15.0, Sim.input())
	var v0 := m2.telemetry.airspeed
	var s2 := run(m2, src2, 0.5, Sim.input(-1.0), 60)
	print("MR2 accel: surge=%.3f kin=%.3f pitch_rate=%.2f dv=%.2f" % [s2.surge, surge_kinematic(s2), s2.pitch_rate, m2.telemetry.airspeed - v0])
	check(m2.telemetry.airspeed > v0, "скорость растёт")
	check(surge_kinematic(s2) > 0.1, "surge (без проекции g) > 0 при разгоне: %.3f" % surge_kinematic(s2))
	check(s2.pitch_rate < 0.0, "pitch_rate < 0 при пикировании")


func test_reset_and_first_sample() -> void:
	var m := glider_in_air()
	var src := MotionSource.new()
	check(not src.sample().valid, "новый источник: valid = false")
	run(m, src, 3.0, Sim.input())
	src.reset()
	src.push(m.telemetry, Sim.DT)
	var s := src.sample()
	check(not s.valid, "после reset valid = false")
	approx(s.surge, G * sin(m.theta), 0.01, "surge = проекция +g")
	approx(s.sway, 0.0, 1e-6, "sway")
	approx(s.heave, G * cos(m.theta), 0.01, "heave = проекция +g")
	check(s.roll_rate == 0.0 and s.pitch_rate == 0.0 and s.yaw_rate == 0.0, "угловые = 0")
	# шаг после первого push — снова valid
	m.step(Sim.DT, Sim.input(), Callable(), Callable())
	src.push(m.telemetry, Sim.DT)
	check(src.sample().valid, "после второго push valid")


func test_teleport_is_discontinuity() -> void:
	var src := MotionSource.new()
	var t := Telemetry.new()
	var dt := 1.0 / 120.0
	t.pilot_velocity = Vector3(0, 0, -10)
	for i in 5:
		src.push(t, dt)
	check(src.sample().valid, "до скачка valid")
	t.pilot_velocity = Vector3(500, 0, -10)  # +500 м/с за шаг = 60 000 м/с² > 50 g
	src.push(t, dt)
	var s := src.sample()
	check(not s.valid, "скачок > 50 g — разрыв (valid = false)")
	approx(s.surge, 0.0, 1e-6, "surge = 0")
	approx(s.sway, 0.0, 1e-6, "sway = 0")
	for i in 3:
		src.push(t, dt)
	s = src.sample()
	check(s.valid, "дальше работает")
	approx(s.surge, 0.0, 1e-4, "surge после скачка")


func test_synthetic_kinematics() -> void:
	# прямолинейный разгон 3 м/с² вперёд (север), без вращения
	var src := MotionSource.new()
	var t := Telemetry.new()
	t.pilot_basis = Basis.IDENTITY  # вперёд = −Z = север
	var v := Vector3.ZERO
	var dt := 1.0 / 120.0
	for i in 121:
		t.pilot_velocity = v
		src.push(t, dt)
		v += Vector3(0, 0, -3.0) * dt
	var s := src.sample()
	approx(s.surge, 3.0, 1e-3, "surge")
	approx(s.sway, 0.0, 1e-3, "sway")
	approx(s.heave, G, 1e-3, "heave")
	approx(s.pitch, 0.0, 1e-3, "pitch")
	approx(s.yaw, 0.0, 1e-3, "yaw (север)")
	# вращение: нос вправо 10 град/с вокруг Y вниз-по-часовой: Godot-поворот на −10°/с вокруг Y
	src.reset()
	var ang := 0.0
	for i in 121:
		t.pilot_basis = Basis(Vector3.UP, -ang)
		src.push(t, dt)
		ang += deg_to_rad(10.0) * dt
	s = src.sample()
	approx(s.yaw_rate, 10.0, 0.01, "yaw_rate")
	approx(s.pitch_rate, 0.0, 0.01, "pitch_rate")
	approx(s.roll_rate, 0.0, 0.01, "roll_rate")
	check(s.yaw > 5.0 and s.yaw < 30.0, "yaw растёт к востоку (по часовой): %.2f" % s.yaw)
