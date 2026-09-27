extends TestCase
## Оценка ветра по сносу и глиссада до цели.


func _est() -> WindEstimator:
	var w := WindEstimator.new()
	w.setup()
	return w


## Полёт с воздушной скоростью va_ms, курс меняется со скоростью turn_dps; ветер wind (x, z).
func _fly(
	w: WindEstimator, wind: Vector2, va_ms: float, turn_dps: float, seconds: float, hdg0: float
) -> float:
	var t := Telemetry.new()
	t.on_ground = false
	t.airspeed = va_ms
	var dt := 1.0 / 120.0
	var hdg := hdg0
	for i in int(seconds / dt):
		hdg = fposmod(hdg + turn_dps * dt, 360.0)
		var a := deg_to_rad(hdg)
		var vg := Vector2(sin(a), -cos(a)) * va_ms + wind
		t.heading_deg = hdg
		t.velocity = Vector3(vg.x, -1.0, vg.y)
		t.groundspeed = vg.length()
		w.update(t, dt)
	return hdg


func test_fit_circle_exact() -> void:
	var pts := PackedVector2Array()
	for k in 24:
		var a := TAU * float(k) / 24.0
		pts.append(Vector2(3.0, -2.0) + Vector2(cos(a), sin(a)) * 10.0)
	var fit := WindEstimator.fit_circle(pts)
	check(fit.ok, "окружность найдена")
	approx(fit.center.x, 3.0, 1e-3, "центр x")
	approx(fit.center.y, -2.0, 1e-3, "центр y")
	approx(fit.radius, 10.0, 1e-3, "радиус")


func test_circling_wind() -> void:
	var w := _est()
	# Только GPS: воздушную скорость «портим», чтобы метод по курсу врал, а круги — нет.
	var wind := Vector2(3.0, -2.0)
	_fly(w, wind, 10.0, 20.0, 60.0, 0.0)
	check(w.circles >= 2, "учтено кругов: %d" % w.circles)
	check(w.method == WindEstimator.METHOD_CIRCLING, "метод — круги")
	check(w.wind.distance_to(wind) < 0.4, "ветер по кругам: %s" % str(w.wind))


func test_heading_wind_on_straight() -> void:
	var w := _est()
	var wind := Vector2(0.0, 4.0)  # дует на юг (северный ветер)
	_fly(w, wind, 11.0, 0.0, 200.0, 90.0)
	check(w.method == WindEstimator.METHOD_HEADING, "на прямой — по курсу")
	check(w.wind.distance_to(wind) < 0.3, "ветер по курсу: %s" % str(w.wind))
	approx(wrapf(w.direction_from_deg(), -180.0, 180.0), 0.0, 3.0, "северный ветер — откуда 0°")


func test_direction_and_headwind() -> void:
	var w := _est()
	w.wind = Vector2(5.0, 0.0)  # дует на восток — западный ветер
	w.method = WindEstimator.METHOD_HEADING
	w.age_s = 0.0
	approx(w.direction_from_deg(), 270.0, 1e-3, "западный ветер")
	approx(w.headwind_ms(270.0), 5.0, 1e-3, "летим на запад — встречный")
	approx(w.headwind_ms(90.0), -5.0, 1e-3, "на восток — попутный")


func test_no_estimate_on_ground() -> void:
	var w := _est()
	var t := Telemetry.new()
	t.on_ground = true
	t.velocity = Vector3(3, 0, 0)
	for i in 600:
		w.update(t, 1.0 / 120.0)
	check(not w.is_valid(), "на земле оценки нет")


func test_required_glide() -> void:
	var task := InstrumentTask.new()
	task.setup()
	check(task.required_glide(Vector3.ZERO, 2000.0) == INF, "без цели — прочерк")
	check(is_nan(task.arrival_height(Vector3.ZERO, 2000.0, 10.0)), "без цели высоты прибытия нет")
	var tp := {"name": "Цель", "position": Vector3(0, 1000, -10400), "radius_m": 400.0}
	task.set_points([tp])
	var safety := task.safety_height_m
	var req := task.required_glide(Vector3(0, 2000, 0), 2000.0)
	approx(req, 10000.0 / (1000.0 - safety), 1e-3, "требуемое качество")
	approx(task.arrival_height(Vector3(0, 2000, 0), 2000.0, 20.0), 500.0, 1e-3, "высота прибытия")
	check(task.required_glide(Vector3.ZERO, 1100.0) == INF, "ниже цели с запасом — не долететь")


func test_race_state() -> void:
	var task := InstrumentTask.new()
	task.setup()
	var pts := [
		{"name": "Старт", "position": Vector3(0, 1000, -3000), "radius_m": 3000.0},
		{"name": "ТП1", "position": Vector3(5000, 1100, -3000), "radius_m": 400.0},
		{"name": "Гоул", "position": Vector3(9000, 900, 0), "radius_m": 400.0},
	]
	task.set_points(pts, 0)
	check(not task.is_race(), "без состояния — не гонка")
	var state := {
		"phase": "racing",
		"instrument_active": 1,
		"next_name": "ТП1",
		"remaining_distance_m": 12000.0,
		"required_glide": 9.5,
	}
	task.race = state
	task.active = 1
	check(task.is_race(), "гонка")
	check(task.is_passed(0) and not task.is_passed(1), "пройденные — до активного")
	approx(
		task.distance_for_glide(Vector3.ZERO),
		12000.0,
		1e-3,
		"дистанция — оптимизированная до гоула"
	)
	approx(task.glide_needed(Vector3.ZERO, 2000.0), 9.5, 1e-6, "требуемое качество от трекера")
	approx(
		task.arrival_for_glide(Vector3.ZERO, 2000.0, 10.0),
		2000.0 - 900.0 - 1200.0,
		1e-3,
		"прибытие на гоул"
	)
	task.race = {"phase": "goal", "required_glide": NAN}
	check(task.is_passed(2), "в гоуле пройдено всё")
	check(task.glide_needed(Vector3.ZERO, 2000.0) == INF, "NAN от трекера — прочерк")
