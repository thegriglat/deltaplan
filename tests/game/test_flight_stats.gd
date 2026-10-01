extends TestCase
## FlightStats на синтетических треках (FR-27b): взведение полёта, отсечка случайных
## касаний (подскок не завершает полёт), «настоящая» посадка/срыв взлёта, сводные метрики.


func _tick(
	st: FlightStats, phase: String, pos: Vector3, on_ground: bool, vario: float, dt: float
) -> Telemetry:
	var t := Telemetry.new()
	t.phase = phase
	t.position = pos
	t.on_ground = on_ground
	t.altitude_msl = pos.y
	t.altitude_agl = pos.y - 1000.0 if pos.y > 1000.0 else 0.0
	t.vario = vario
	st.update(t, dt)
	return t


## Подскок сразу после отрыва (не поднялся выше ~2 м, не отошёл далеко) — полёт продолжается.
func test_bounce_after_liftoff_does_not_finish() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var dt := 0.1
	# Оторвался, подпрыгнул на пару метров, тут же снова коснулся земли.
	for i in 5:
		_tick(st, "flying", Vector3(0, 1000.0 + 2.0, -float(i)), false, 0.5, dt)
	_tick(st, "flying", Vector3(0, 1000.0, -5.0), true, -0.5, dt)
	check(st.took_off, "взлёт засчитан")
	check(not st.armed, "полёт ещё не взведён — высоты/удаления не хватило")
	check(not st.is_finished(), "короткое касание после подскока не завершает полёт")
	# Оторвался снова и полетел дальше — flight_time_s продолжает расти.
	_tick(st, "flying", Vector3(0, 1001.0, -6.0), false, 1.0, dt)
	check(not st.is_finished(), "полёт продолжается после повторного отрыва")


## Оторвался, но тут же осел обратно и остался стоять — не успел взвестись: взлёт не удался.
func test_settles_back_before_arming_is_takeoff_failed() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var dt := 0.1
	for i in 3:
		_tick(st, "flying", Vector3(0, 1000.0 + 1.0, -float(i)), false, 0.3, dt)
	# Сел и больше не отрывается — держим касание дольше порога подтверждения (1.5 с).
	for i in 20:
		_tick(st, "flying", Vector3(0, 1000.0, -3.0), true, 0.0, dt)
	check(st.is_finished(), "долгое касание без взведения — конец")
	check(st.finish_reason() == "takeoff_failed", "не взвёлся — это срыв взлёта, не посадка")


## Нормальный полёт: взвёлся (высота/удаление), затем сел и остался на земле — посадка.
func test_normal_flight_then_landing() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var dt := 0.5
	# 20 c ровного набора высоты и удаления от старта — взводит полёт.
	for i in 40:
		_tick(st, "flying", Vector3(0, 1000.0 + i * 1.0, -float(i) * 3.0), false, 2.0, dt)
	check(st.armed, "полёт взведён (высота/удаление превышены)")
	check(not st.is_finished(), "в воздухе — не закончен")
	# Короткое касание после взведения (чиркнул колесом) — не конец, но отмечено.
	_tick(st, "flying", Vector3(0, 1000.0, -120.0), true, -0.2, dt)
	check(st.touched, "короткое касание после взведения отмечено в статистике")
	check(not st.is_finished(), "но полёт ещё не завершён — вернулся в воздух")
	_tick(st, "flying", Vector3(0, 1002.0, -123.0), false, 0.5, dt)
	# Снижение и посадка, остаётся на земле.
	for i in 5:
		_tick(st, "flying", Vector3(0, 1000.0, -120.0), true, -1.0, dt)
	check(st.is_finished(), "после взведения удержанное касание — посадка")
	check(st.finish_reason() == "landed", "причина — посадка")
	var sm := st.summary(Vector3(0, 1000.0, -120.0))
	check(float(sm.flight_time_s) > 0.0, "время полёта > 0")
	check(float(sm.avg_speed_ms) > 0.0, "средняя путевая скорость > 0")
	check(float(sm.max_climb_ms) > 0.0, "макс. набор фиксируется")


## Регрессия (нашёл агент сквозного теста): scripts/flight/landing_flare.gd кладёт своё
## "flight_time_s" (модельное m.time_s, сбивается после reset_in_air посреди полёта) в result
## ДО info.merge(stats.summary(...)) в scripts/game/game.gd:411,443. Dictionary.merge без
## overwrite=true оставляет старый (заниженный) ключ — экран итога врёт про время полёта.
## FlightStats — источник истины; game.gd должен звать merge(..., true). Один тест на контракт:
## overwrite=true отдаёт значение FlightStats, без него — старое (чужое) остаётся, что и есть баг.
func test_summary_must_overwrite_stray_flight_time_from_landing_flare() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var dt := 0.5
	for i in 40:
		_tick(st, "flying", Vector3(0, 1000.0 + i, -float(i) * 3.0), false, 2.0, dt)
	var real_time := st.flight_time_s
	check(real_time > 15.0, "в FlightStats накопилось настоящее время полёта")

	# Как в landing_flare.gd:88 — стороннее (заниженное) время уже лежит в result до merge.
	var result := {"grade": "soft", "flight_time_s": 0.1}
	var wrong := result.duplicate()
	wrong.merge(st.summary(Vector3(0, 1000.0 + 39.0, -117.0)))  # overwrite=false — баг
	var fixed := result.duplicate()
	fixed.merge(st.summary(Vector3(0, 1000.0 + 39.0, -117.0)), true)  # overwrite=true — фикс

	check(
		float(wrong.flight_time_s) < 1.0, "без overwrite=true остаётся чужое заниженное время (баг)"
	)
	approx(
		float(fixed.flight_time_s),
		real_time,
		0.01,
		"с overwrite=true время полёта — из FlightStats (правильное)"
	)


## Кружение (постоянный разворот) с набором высоты — фиксируется как термик.
func test_circling_tracks_best_thermal() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var dt := 0.2
	var track := 0.0
	for i in 60:
		track = wrapf(track + 20.0 * dt, 0.0, 360.0)  # ~20 °/с — уверенное кружение
		var t := Telemetry.new()
		t.phase = "flying"
		var r := deg_to_rad(track)
		t.position = Vector3(sin(r) * 30.0, 1000.0 + i * 0.3, cos(r) * 30.0)
		t.on_ground = false
		t.altitude_msl = t.position.y
		t.altitude_agl = 200.0
		t.vario = 1.5
		t.track_deg = track
		st.update(t, dt)
	check(st.circling_time_s > 0.0, "время в кружении накоплено")
	var sm := st.summary(Vector3(0, 1000.0 + 60 * 0.3, 0))
	check(float(sm.best_thermal_climb_ms) > 0.0, "лучший термик — положительный набор")
	check(float(sm.circling_fraction) > 0.5, "почти весь полёт в кружении")
