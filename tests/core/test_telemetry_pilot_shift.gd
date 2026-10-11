extends TestCase
## Телеметрия: поле pilot_shift (FB-К1) доходит из обеих моделей через сигнал/поле telemetry.

const FS := preload("res://tests/flight/flight_sim.gd")
const PS := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func test_telemetry_pilot_shift_flight_model() -> void:
	var m := FS.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	FS.run_for(m, 1.0, FS.input(-0.5, 0.5))
	var s: Vector2 = m.telemetry.pilot_shift
	check(is_equal_approx(s.x, 0.5) and is_equal_approx(s.y, 0.5), "x = roll, y = −pitch: %s" % s)


func test_telemetry_pilot_shift_pendulum() -> void:
	var m := PS.make("sport")
	PS.reset(m)
	for i in int(2.0 / PS.DT):
		m.step(PS.DT, PS.input(0.0, -1.0), Callable(), Callable())
	check(m.telemetry.pilot_shift.x < -0.3, "влево — x<0: %s" % m.telemetry.pilot_shift)
	check(m.telemetry.pilot_shift == m.pilot_shift, "телеметрия = поле модели")
