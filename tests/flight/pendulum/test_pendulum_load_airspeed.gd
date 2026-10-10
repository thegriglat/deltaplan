extends TestCase
## «Маятник» (PD-10): перегрузка усредняется по подшагам (вираж ≈ 1/cos φ, прямой ≈ 1);
## после reset_in_air до первого step воздушная скорость — без ветра.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func test_load_straight_and_turn() -> void:
	for w: String in ["training", "laminar", "sport"]:
		var m := S.make(w)
		S.reset(m)
		for i in int(40.0 / S.DT):
			m.step(S.DT, S.input(), Callable(), Callable())
		approx(m.telemetry.load_factor, 1.0, 0.05, "%s: прямой полёт, n" % w)
		for deg in [30.0, 45.0]:
			var bh := S.BankHold.new(deg_to_rad(deg), 6.0, 2.5, 1.0)
			var inp := S.input()
			var sum := 0.0
			var cnt := 0
			for i in int(40.0 / S.DT):
				inp.roll = bh.roll(m)
				m.step(S.DT, inp, Callable(), Callable())
				if i > int(30.0 / S.DT):
					sum += m.telemetry.load_factor
					cnt += 1
			var phi: float = m.bank
			var want := 1.0 / cos(phi)
			print("    %s: крен %.1f°, n %.3f (1/cos φ %.3f)" % [
				w, rad_to_deg(phi), sum / cnt, want])
			approx(sum / cnt, want, want * 0.10, "%s: вираж %d°, n" % [w, int(deg)])


func test_airspeed_after_reset_with_wind() -> void:
	var m := S.make("sport")
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 30.0, 12.0, Vector3(5.0, 0.0, 2.0))
	approx(m.telemetry.airspeed, 12.0, 0.1, "airspeed после reset_in_air с ветром")
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 30.0, 0.0, Vector3(-4.0, 0.0, 3.0))
	var m2 := S.make("sport")
	m2.reset_in_air(Vector3(0.0, 1000.0, 0.0), 30.0)
	approx(m.telemetry.airspeed, m2.telemetry.airspeed, 0.1, "трим-скорость не зависит от ветра")
