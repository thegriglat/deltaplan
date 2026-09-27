extends TestCase
## Тренировки (FR-36): завершение по критериям и оценка.

const H := preload("res://tests/tasks/task_helpers.gd")


func _cfg(name: String) -> Dictionary:
	return Config.get_config("tasks/" + name).duplicate(true)


## Телеметрия с высотой над землёй и вариометром.
func _t(pos: Vector3, time_s: float, vario: float = 0.0, agl: float = 100.0) -> Telemetry:
	var t := H.telem(pos, time_s)
	t.vario = vario
	t.altitude_agl = agl
	return t


func test_thermal_success() -> void:
	var m := TrainingThermalCentering.new()
	m.setup(_cfg("training_thermal_centering"))
	var done := []
	m.finished.connect(func(r: Dictionary) -> void: done.append(r))
	m.update(H.telem(Vector3(0, 1000, 0), 0.0, "running"))
	check(not m.airborne, "на разбеге тренировка не идёт")
	var alt := 1000.0
	var time := 1.0
	while not m.is_finished() and time < 1000.0:
		alt += 2.0 * 0.5  # 2 м/с, шаг 0.5 с
		m.update(_t(Vector3(0, alt, 0), time, 2.0))
		time += 0.5
	check(m.is_finished(), "закончилась")
	var r := m.result()
	check(bool(r.success), "успех")
	check(float(r.gain_m) >= 300.0, "набор ≥ 300 м")
	check(float(r.time_in_lift_s) >= 120.0, "в подъёме ≥ 120 с")
	check(float(r.score) > 90.0, "высокая оценка: %s" % r.score)
	check(done.size() == 1, "сигнал finished один раз")


func test_thermal_time_limit() -> void:
	var m := TrainingThermalCentering.new()
	var c := _cfg("training_thermal_centering")
	c.time_limit_s = 60.0
	m.setup(c)
	for i in 200:
		m.update(_t(Vector3(0, 1000.0 - i * 0.5, 0), float(i), -1.0))
	check(m.is_finished(), "по времени")
	check(not bool(m.result().success), "без набора — неуспех")
	check(String(m.result().reason) == "time", "причина — время")


func test_ridge_success_and_band() -> void:
	var m := TrainingRidgeSoaring.new()
	var c := _cfg("training_ridge_soaring")
	c.duration_s = 100.0
	m.setup(c)
	# 50 с слишком высоко (не считается), потом в полосе
	for i in 51:
		m.update(_t(Vector3(0, 1500, 0), float(i), 0.0, 400.0))
	approx(m.time_in_band_s, 0.0, 0.001, "выше полосы — время не идёт")
	var time := 51.0
	while not m.is_finished() and time < 500.0:
		m.update(_t(Vector3(100, 1200, 0), time, 0.0, 80.0))
		time += 1.0
	check(m.is_finished() and bool(m.result().success), "продержался")
	approx(time, 152.0, 1.01, "ровно 100 с в полосе")
	check(float(m.result().score) < 70.0, "оценка снижена за время вне полосы")


func test_ridge_landing_fails() -> void:
	var m := TrainingRidgeSoaring.new()
	m.setup(_cfg("training_ridge_soaring"))
	m.update(_t(Vector3(0, 1100, 0), 0.0, 0.0, 50.0))
	m.update(_t(Vector3(0, 1100, 0), 30.0, 0.0, 50.0))
	m.update(H.telem(Vector3(0, 900, 0), 31.0, "landed"))
	check(m.is_finished() and not bool(m.result().success), "приземлился — неуспех")


func _landing(pos: Vector3, grade: String) -> Dictionary:
	var m := TrainingSpotLanding.new()
	m.latlon_fn = H.latlon_fn()
	var c := _cfg("training_spot_landing")
	c.location = "altai"  # H.latlon_fn — центр локации «Алтай»
	m.setup(c)
	var tgt := m.target
	m.update(H.telem(tgt + Vector3(0, 800, 3000), 0.0))
	m.update(H.telem(tgt + pos + Vector3(0, 2, 0), 200.0))
	m.on_landed({"grade": grade, "position": tgt + pos})
	check(m.is_finished(), "закончилась посадкой")
	return m.result()


func test_spot_landing_scores() -> void:
	var bull := _landing(Vector3(2, 0, 2), "soft")
	check(bool(bull.success), "в центр")
	approx(float(bull.score), 100.0, 0.01, "мягко в 5 м — 100")
	approx(float(bull.distance_m), sqrt(8.0), 0.01, "расстояние до центра")
	approx(float(_landing(Vector3(20, 0, 0), "soft").score), 60.0, 0.01, "кольцо 30 м")
	approx(float(_landing(Vector3(20, 0, 0), "hard").score), 30.0, 0.01, "жёстко — половина")
	approx(float(_landing(Vector3(2, 0, 0), "crash").score), 0.0, 0.01, "авария — 0")
	var miss := _landing(Vector3(500, 0, 0), "soft")
	check(not bool(miss.success) and float(miss.score) == 0.0, "мимо мишени")


func test_spot_landing_target_from_latlon() -> void:
	var m := TrainingSpotLanding.new()
	m.latlon_fn = H.latlon_fn()
	var c := _cfg("training_spot_landing")
	c.location = "altai"  # H.latlon_fn — центр локации «Алтай»
	m.setup(c)
	check(m.has_target, "мишень из lat/lon")
	var expect := H.latlon_fn().call(51.8296, 85.7792) as Vector2
	approx(Vector2(m.target.x, m.target.z).distance_to(expect), 0.0, 0.5, "координаты мишени")


## Без сигнала landed оценка посадки — по последней скорости в воздухе (LandingJudge).
func test_spot_landing_fallback_grade() -> void:
	var m := TrainingSpotLanding.new()
	m.setup(_cfg("training_spot_landing"))
	m.set_target(Vector3.ZERO)
	var t := H.telem(Vector3(0, 10, 1000), 0.0)
	m.update(t)
	var t2 := H.telem(Vector3(0, 1, 3), 100.0)
	t2.velocity = Vector3(0, -1.0, -3.0)
	m.update(t2)
	m.update(H.telem(Vector3(0, 0, 3), 100.1, "landed"))
	check(m.is_finished(), "закончилась")
	check(String(m.result().grade) == "soft", "мягкая по последней скорости")
