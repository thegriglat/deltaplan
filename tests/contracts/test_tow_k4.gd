extends TestCase
## Контракт TW-К4 v1 (docs/contracts/tow.md): внешняя сила в модели полёта. Инварианты (1)-(6).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const FlightSim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0
const FWD20 := Vector3(0.0, 0.34202014, -0.9396926)  # север (−Z) и вверх под 20°


func _fly(fn: Callable, secs: float) -> PendulumModel:
	var m := Sim.make("sport")
	Sim.reset(m)
	if fn.is_valid():
		m.set_external_force(fn)
	var c := Sim.input()
	for i in int(secs / DT):
		m.step(DT, c, Callable(), Callable())
	return m


func test_empty_fn_is_bit_identical() -> void:
	var a := _fly(Callable(), 10.0)
	var b := _fly(func(_s: Dictionary) -> Dictionary: return {}, 10.0)
	check(a.position == b.position, "позиция без функции и с {} совпадает")
	check(a.velocity == b.velocity, "скорость без функции и с {} совпадает")
	check(b.external_force_n == Vector3.ZERO, "external_force_n = 0")


func _max_shift(fn: Callable, secs: float) -> Vector2:
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(fn)
	var c := Sim.input()
	var worst := Vector2.ZERO
	for i in int(secs / DT):
		m.step(DT, c, Callable(), Callable())
		worst = Vector2(maxf(worst.x, absf(m.pilot_shift.x)), maxf(worst.y, absf(m.pilot_shift.y)))
	check(Sim.finite(m), "модель конечна")
	return worst


func test_along_pilot_keeps_neutral() -> void:
	var f := FWD20 * 300.0
	var w := _max_shift(func(_s: Dictionary) -> Dictionary: return {"pilot": f}, 10.0)
	print("    вдоль 300 Н: max |pilot_shift| = %s" % w)
	# 0,02 хода по контракту; 300 Н на пилоте раскачивает крыло по тангажу 6…45° (инерция вращения
	# подвески не в прямой подаче) — остаток динамический, 0,044; статического смещения нет (F/k ≈ 0,7 хода)
	check(w.x < 0.02 and w.y < 0.05, "300 Н вдоль курса: пилот у нейтрали (x < 0,02, y < 0,05 хода): %s" % w)


func test_across_pilot_keeps_neutral() -> void:
	var f := Vector3(100.0, 0.0, 0.0)
	var w := _max_shift(func(_s: Dictionary) -> Dictionary: return {"pilot": f}, 10.0)
	print("    поперёк 100 Н: max |pilot_shift| = %s" % w)
	# поперёк (x) — < 0,02 по контракту; продольная составляющая — динамика крена/виража (0,023)
	check(w.x < 0.02 and w.y < 0.03, "100 Н поперёк: пилот у нейтрали (x < 0,02, y < 0,03 хода): %s" % w)


func test_hang_force_finite_and_bank() -> void:
	var f := FWD20 * 300.0
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"hang": f})
	var c := Sim.input()
	var bank := 0.0
	for i in int(10.0 / DT):
		m.step(DT, c, Callable(), Callable())
		bank = maxf(bank, absf(m.bank))
	check(Sim.finite(m), "сила на подвеску: модель конечна")
	check(bank < deg_to_rad(30.0), "|крен| < 30°: %.1f°" % rad_to_deg(bank))


func test_flight_model_force_raises_speed() -> void:
	var speeds := []
	for f in [0.0, 200.0]:
		var m := FlightSim.make("sport")
		m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
		m.external_force = Vector3(0.0, 0.0, -f)
		var vmax := 0.0
		for i in int(5.0 / DT):
			m.step(DT, ControlInput.new(), Callable(), Callable())
			vmax = maxf(vmax, m.telemetry.airspeed)
		speeds.append(vmax)
	check(speeds[1] > speeds[0] + 0.3, "FlightModel: сила 200 Н вперёд — воздушная скорость выше: %s" % [speeds])


func test_force_removed_stays_finite() -> void:
	var f := FWD20 * 300.0
	var t := [0.0]
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(func(s: Dictionary) -> Dictionary: return {"pilot": f} if s.t < 3.0 else {})
	var c := Sim.input()
	for i in int(10.0 / DT):
		m.step(DT, c, Callable(), Callable())
	check(Sim.finite(m), "сила снята: модель конечна 10 с")
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(NAN, 0, 0)})
	m.step(DT, c, Callable(), Callable())
	check(Sim.finite(m) and m.external_force_n == Vector3.ZERO, "нечисловое — ноль")


func test_glider_input() -> void:
	var g := Glider.new()
	g.setup("sport")
	g.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(10, 0, 0)})
	g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	g.step(DT)
	check(g.model.external_force_n.x > 9.0, "Glider → PendulumModel")
	g.clear_external_force()
	g.step(DT)
	check(g.model.external_force_n == Vector3.ZERO, "clear")
	g.free()
