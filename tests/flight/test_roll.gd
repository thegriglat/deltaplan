extends TestCase
## Крен (FR-5): переложение 45→45 за 2–3 с, радиус виража V²/(g·tgφ).

const Sim := preload("res://tests/flight/flight_sim.gd")


## Время переложения из −45° в +45° на скорости трима, с.
static func reversal_time(m: FlightModel) -> float:
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, Sim.input())
	m.bank = deg_to_rad(-45.0)
	m.roll_rate = 0.0
	var inp := Sim.input(0.0, 1.0)
	var t := 0.0
	while m.bank < deg_to_rad(45.0) and t < 10.0:
		m.step(Sim.DT, inp, Callable(), Callable())
		t += Sim.DT
	return t


func test_roll_reversal_time() -> void:
	for w in ["training", "kingpost", "sport"]:
		var t := reversal_time(Sim.make(w))
		check(t >= 2.0 and t <= 3.0, "%s: переложение 45→45 за %.2f с" % [w, t])


func test_bank_holds_with_neutral_input() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	m.bank = deg_to_rad(30.0)
	Sim.run_for(m, 10.0, Sim.input())
	approx(m.telemetry.bank_deg, 30.0, 1.0, "крен держится без управления")


func test_turn_radius() -> void:
	for bank_deg in [20.0, 30.0, 45.0]:
		var m := Sim.make("kingpost")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		m.bank = deg_to_rad(bank_deg)
		Sim.run_for(m, 15.0, Sim.input())
		var h0 := m.heading
		var n := 240
		var vh := 0.0
		for i in n:
			m.step(Sim.DT, Sim.input(), Callable(), Callable())
			vh += m.telemetry.groundspeed
		vh /= n
		var omega := wrapf(m.heading - h0, -PI, PI) / (n * Sim.DT)
		var r_sim := vh / omega
		var r_th := vh * vh / (Units.G * tan(deg_to_rad(m.telemetry.bank_deg)))
		approx(r_sim, r_th, r_th * 0.03, "радиус виража при крене %.0f°" % bank_deg)
		check(omega > 0.0, "крен вправо — поворот вправо (курс растёт)")


func test_turn_increases_speed_and_sink() -> void:
	var m := Sim.make("sport")
	var straight: Vector2 = Sim.settle(m, 0.0)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	m.bank = deg_to_rad(45.0)
	Sim.run_for(m, 30.0, Sim.input())
	var n := 1.0 / cos(deg_to_rad(45.0))
	approx(m.telemetry.airspeed / straight.x, sqrt(n), 0.03, "в вираже скорость ×√n")
	approx(-m.telemetry.vario / straight.y, pow(n, 1.5), 0.1, "в вираже снижение ×n^1,5")
