extends TestCase
## Перегрузка n = подъёмная сила / вес.

const Sim := preload("res://tests/flight/flight_sim.gd")


func test_straight_glide_about_one_g() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 20.0, Sim.input())
	approx(m.load.load_factor, 1.0, 0.02, "прямолинейное планирование — ~1 g")


func test_turn_load_factor() -> void:
	for bank_deg in [30.0, 45.0, 60.0]:
		var m := Sim.make("kingpost")
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		m.bank = deg_to_rad(bank_deg)
		Sim.run_for(m, 25.0, Sim.input())
		var n := 1.0 / cos(deg_to_rad(m.telemetry.bank_deg))
		approx(m.load.load_factor, n, n * 0.03, "вираж %.0f°: n = 1/cos(крен)" % bank_deg)


func test_pullout_from_dive() -> void:
	# разгон «на себя» до ~85 км/ч и резкое «от себя» — заметная перегрузка
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 20.0, Sim.input(-0.85))
	check(m.telemetry.airspeed > Units.kmh(80.0), "разогнался")
	m.load.reset()
	Sim.run_for(m, 6.0, Sim.input(1.0))
	check(m.load.load_max > 3.0, "выход из пикирования: %.2f g" % m.load.load_max)


func test_filter_smooths_spike() -> void:
	var l := LoadMeter.new()
	l.update(10.0 * 1000.0, 1000.0, 0.15, 1.0 / 120.0)
	check(
		l.load_raw > 9.9 and l.load_factor < 2.0, "один шаг-пик сглаживается: %.2f" % l.load_factor
	)
