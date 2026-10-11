extends TestCase
## Авария без «деревянного» контакта (PD-К6 v2, PD-39): «на брюхо» 8 м/с вниз + 2 м/с вперёд гасится с
## постоянным замедлением landing.crash_decel_g, а не за шаг: пик удельной силы ≤ 21 g на 1/120 и 1/240,
## не зависит от шага; оценка (crash) и момент — прежние; скорость доходит до нуля, NaN нет.

const LP := preload("res://tests/flight/landing_peaks.gd")


func test_crash_peak_bounded() -> void:
	for mode: String in ["ws", "pend"]:
		for dt: float in [1.0 / 120.0, 1.0 / 240.0]:
			var r := LP.run(mode, 8.0, 2.0, 2.0, "sport", dt)
			var tag := "%s %d Гц" % [mode, roundi(1.0 / dt)]
			check(r.grade == "crash", "%s: оценка crash" % tag)
			check(not r.nan, "%s: без NaN" % tag)
			check(r.phys_g <= 21.0, "%s: пик %.2f g ≤ 21" % [tag, r.phys_g])
			check(r.phys_g >= 15.0, "%s: пик %.2f g — гашение, а не пауза" % [tag, r.phys_g])
			approx(r.last_g, 1.0, 0.05, "%s: в конце стоит, |f| ≈ 1 g" % tag)
			var v: Vector3 = r.model.telemetry.pilot_velocity
			check(v.length() < 0.01, "%s: скорость погашена" % tag)


## Крыло не «замирает» на шаге аварии: сразу после касания скорость ещё ненулевая, а до нуля — ≈ v/a.
func test_crash_takes_time() -> void:
	for mode: String in ["ws", "pend"]:
		var r := LP.run(mode, 8.0, 2.0, 0.02)
		var v: Vector3 = r.model.telemetry.pilot_velocity
		check(v.length() > 3.0, "%s: через 0,02 с скорость %.2f м/с ещё велика" % [mode, v.length()])
