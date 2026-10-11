extends TestCase
## Пики удельной силы пилота на касании (PD-К6 v1, PD-38), оба режима: ноги гасят вертикальную скорость
## на ходе коленей (PilotLegs), а не за шаг физики. Ровная земля, горизонтальная 2 м/с. Таблица — PD-К6:
## 1 м/с ≤ 2 g; 2 м/с — 1,5–3 g; 3,5 м/с ≤ 6 g; 1 < 2 < 3,5 < 5,5; авария — без NaN. Оценка — по скорости
## первого касания (LandingJudge, пороги не меняются). Стоя после касания |f| → 1 g.

const LP := preload("res://tests/flight/landing_peaks.gd")
const MODES := ["ws", "pend"]


func test_peaks_table() -> void:
	for mode: String in MODES:
		var r1 := LP.run(mode, 1.0)
		var r2 := LP.run(mode, 2.0)
		var r35 := LP.run(mode, 3.5)
		var r55 := LP.run(mode, 5.5)
		for r: Dictionary in [r1, r2, r35, r55]:
			print("    PD38 %s: %s" % [mode, LP.line(mode, "%.1f" % r.vtd, r)])
		check(r1.phys_g <= 2.0, "%s 1 м/с: пик %.2f g ≤ 2" % [mode, r1.phys_g])
		check(r2.g60 >= 1.5 and r2.phys_g <= 3.0, "%s 2 м/с: пик %.2f g (60 Гц %.2f) в 1,5–3" % [mode, r2.phys_g, r2.g60])
		check(r35.phys_g <= 6.0, "%s 3,5 м/с: пик %.2f g ≤ 6" % [mode, r35.phys_g])
		check(r1.phys_g < r2.phys_g and r2.phys_g < r35.phys_g and r35.phys_g < r55.phys_g,
			"%s: монотонно 1 < 2 < 3,5 < 5,5 м/с: %.2f %.2f %.2f %.2f" % [mode, r1.phys_g, r2.phys_g, r35.phys_g, r55.phys_g])
		check(r1.g60 < r2.g60 and r2.g60 < r35.g60 and r35.g60 < r55.g60,
			"%s: монотонно на 60 Гц: %.2f %.2f %.2f %.2f" % [mode, r1.g60, r2.g60, r35.g60, r55.g60])


## Оценка посадки — по скорости первого касания: 1–3,5 м/с мягко, 5,5 — жёстко, 8 — авария.
func test_grades_unchanged() -> void:
	for mode: String in MODES:
		for c: Array in [[1.0, "soft"], [2.0, "soft"], [3.5, "soft"], [5.5, "hard"], [8.0, "crash"]]:
			var r := LP.run(mode, c[0])
			check(r.grade == c[1], "%s %.1f м/с: оценка %s (ждали %s)" % [mode, c[0], r.grade, c[1]])
			approx(r.vtd, c[0], 0.1, "%s: скорость касания = заданной" % mode)


## После касания пилот стоит: |f| → 1 g; ЦМ — снова на прямых ногах.
func test_stands_after() -> void:
	for mode: String in MODES:
		for v: float in [2.0, 3.5]:
			var r := LP.run(mode, v, 2.0, 3.0)
			approx(r.last_g, 1.0, 0.05, "%s %.1f м/с: стоя |f| ≈ 1 g" % [mode, v])
	var ws: FlightModel = LP.run("ws", 3.5, 2.0, 3.0).model
	approx(ws.position.y, LP.GROUND_Y, 0.01, "«Смещение веса»: колени выпрямились, точка — на земле")


## Без NaN при dt 1/30…1/240, в т. ч. авария и жёсткая; пики при 1/240 — как при 1/120 (ход, а не шаг).
func test_dt_range() -> void:
	for mode: String in MODES:
		for dt: float in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 240.0]:
			for v: float in [1.0, 3.5, 5.5, 8.0]:
				var r := LP.run(mode, v, 2.0, 2.0, "sport", dt)
				check(not r.nan, "%s dt %.4f, %.1f м/с: без NaN" % [mode, dt, v])
		var a := LP.run(mode, 3.5)
		var b := LP.run(mode, 3.5, 2.0, 2.0, "sport", 1.0 / 240.0)
		check(absf(a.phys_g - b.phys_g) < 0.5, "%s 3,5 м/с: пик не зависит от шага: %.2f / %.2f g" % [mode, a.phys_g, b.phys_g])
