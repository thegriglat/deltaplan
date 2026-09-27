extends TestCase
## Логика звуков полёта: монотонность слоёв по скорости, затухание окружения с высотой, события.


func _mix() -> FlightSoundMix:
	var m := FlightSoundMix.new()
	m.setup(Config.get_config("audio").flight, 12345)
	return m


func _levels_at(m: FlightSoundMix, v_kmh: float) -> Dictionary:
	m.airspeed_kmh = v_kmh
	return m.compute()


func test_airflow_layers_monotonic_in_speed() -> void:
	var m := _mix()
	for layer in ["rush", "rumble", "wires", "fast", "wing"]:
		var prev := -1000.0
		var prev_pitch := -1000.0
		for v in range(0, 101, 5):
			var lv: Vector2 = _levels_at(m, float(v))[layer]
			check(
				lv.x >= prev - 1e-6,
				"%s: громкость не падает (%d км/ч: %.1f < %.1f)" % [layer, v, lv.x, prev]
			)
			check(lv.y >= prev_pitch - 1e-6, "%s: тон не падает на %d км/ч" % [layer, v])
			prev = lv.x
			prev_pitch = lv.y
	var lo := _levels_at(m, 30.0)
	var hi := _levels_at(m, 80.0)
	check(hi.rush.x > lo.rush.x + 6.0, "шум обтекания заметно громче на 80 км/ч")
	check(hi.lp_cutoff_hz > lo.lp_cutoff_hz, "ФНЧ открывается со скоростью")


func test_total_airflow_energy_monotonic() -> void:
	# С учётом кроссфейда записанных слоёв общая громкость потока растёт со скоростью.
	var m := _mix()
	var prev := 0.0
	for v in range(10, 101, 5):
		var lv := _levels_at(m, float(v))
		var e := 0.0
		for layer in FlightSoundMix.AIRFLOW_LOOPS:
			e += pow(db_to_linear(lv[layer].x), 2.0)
		check(e >= prev * 0.97, "энергия потока растёт (%d км/ч)" % v)
		prev = e


func test_caps_respected() -> void:
	var m := _mix()
	var lv := _levels_at(m, 150.0)
	var air: Dictionary = Config.get_config("audio").flight.airflow
	check(lv.rush.x <= float(air.rush_max_db) + 1e-6, "предел шума обтекания")
	check(lv.lp_cutoff_hz <= float(air.lp_max_hz), "предел ФНЧ")


func test_ambient_fades_with_altitude() -> void:
	var m := _mix()
	for layer in ["meadow", "birds", "cowbells", "grass", "gusts"]:
		var prev := 1000.0
		for agl in [0.0, 10.0, 30.0, 80.0, 150.0, 300.0, 500.0]:
			m.agl_m = agl
			var db: float = m.compute()[layer].x
			check(db <= prev + 1e-6, "%s затухает с высотой (%.0f м)" % [layer, agl])
			prev = db
		check(prev <= -79.0, "%s не слышно на 500 м" % layer)
	m.agl_m = 100.0
	var mid := m.compute()
	check(
		mid.cowbells.x > mid.birds.x - 30.0 and mid.cowbells.x > -80.0,
		"колокольчики слышны выше птиц"
	)


func test_ground_wind_louder_gusts() -> void:
	var m := _mix()
	m.ground_wind_ms = 2.0
	var calm: float = m.compute().gusts.x
	m.ground_wind_ms = 8.0
	check(m.compute().gusts.x > calm, "сильнее ветер — громче порывы")


func test_sideslip_pan() -> void:
	var m := _mix()
	m.sideslip_deg = 10.0
	check(m.compute().pan > 0.0, "скольжение вправо — ветер справа")
	m.sideslip_deg = -40.0
	approx(m.compute().pan, -0.6, 1e-6, "панорама ограничена")


func test_luff_and_snaps_near_stall() -> void:
	var m := _mix()
	m.phase = "flying"
	m.airspeed_kmh = 50.0
	check(m.luff_amount() < 0.01, "на 50 км/ч парус не трепещет")
	m.airspeed_kmh = 25.0
	check(m.luff_amount() > 0.9, "у сваливания трепещет")
	m.airspeed_kmh = 45.0
	m.stall_amount = 1.0
	check(m.luff_amount() > 0.9, "сваливание на скорости — трепещет")
	var snaps := 0
	for i in 1200:
		for ev in m.advance(1.0 / 120.0):
			if ev.type == "snap":
				snaps += 1
	# Натянутый парус не хлопает (audio.json → snap_rate_hz = 0, слова мамы-пилота);
	# при ненулевой частоте — ~rate хлопков в секунду.
	var rate := float(Config.value("audio", "flight.sail.snap_rate_hz", 0.0))
	if rate <= 0.0:
		check(snaps == 0, "хлопков нет: %d" % snaps)
	else:
		check(
			snaps >= rate * 3.0 and snaps <= rate * 20.0,
			"хлопки ~%.0f Гц за 10 с: %d" % [rate, snaps]
		)


func test_steps_follow_running_pace() -> void:
	var m := _mix()
	m.phase = "running"
	m.groundspeed_ms = 5.6
	var steps := 0
	for i in 1200:
		for ev in m.advance(1.0 / 120.0):
			if ev.type == "step":
				steps += 1
				check(ev.surface == "grass", "по умолчанию трава")
	# 5,6 м/с / 1,4 м = 4 шага/с.
	check(steps >= 38 and steps <= 41, "бег: ~40 шагов за 10 с, получили %d" % steps)
	m.groundspeed_ms = 0.0
	var none := 0
	for i in 240:
		none += (
			m
			. advance(1.0 / 120.0)
			. filter(func(e: Dictionary) -> bool: return e.type == "step")
			. size()
		)
	check(none == 0, "стоим — шагов нет")


func test_breath_and_pant() -> void:
	var m := _mix()
	m.phase = "running"
	m.groundspeed_ms = 5.0
	var early: float = m.compute().breath.x
	for i in 600:
		m.advance(1.0 / 120.0)
	check(m.compute().breath.x > early, "дыхание нарастает на бегу")
	m.phase = "standing"
	var pants := m.advance(1.0 / 120.0).filter(func(e: Dictionary) -> bool: return e.type == "pant")
	check(pants.size() == 1, "после 5 с бега и остановки — одышка")
	check(m.compute().breath.x <= -79.0, "не бежим — дыхание (луп) выключено")


func test_creaks_under_load() -> void:
	var m := _mix()
	m.phase = "flying"
	m.load_factor = 1.0
	var calm := 0
	for i in 1200:
		calm += m.advance(1.0 / 120.0).size()
	check(calm == 0, "ровный полёт без болтанки — без скрипов")
	m.load_factor = 2.0
	m.turbulence = 0.5
	var creaks := 0
	for i in 1200:
		creaks += m.advance(1.0 / 120.0).size()
	check(creaks > 3, "перегрузка и болтанка — скрипы (%d)" % creaks)


func test_landing_gain_by_grade() -> void:
	var m := _mix()
	var soft := m.landing_gain_db({"grade": "soft", "vertical_speed_ms": 1.0})
	var hard := m.landing_gain_db({"grade": "hard", "vertical_speed_ms": 3.0})
	var crash := m.landing_gain_db({"grade": "crash", "vertical_speed_ms": 6.0})
	check(soft < hard and hard <= crash, "мягкая тише жёсткой, жёсткая не громче аварии")
