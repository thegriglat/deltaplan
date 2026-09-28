extends TestCase
## Грозы редкие (решение пилота, 29.09.2026): гроза — событие, которое пилот увидит хоть раз за
## всё время, а не норма. В ясный +26 (погода меню по умолчанию) Cb у старта почти не бывает, с +30
## — изредка, в +34 — где-то в округе, но над стартом в начале полёта — редко. Слияние соседних
## ячеек не складывает их потоки. Мир — эталонный (AtmoFingerprint: рельеф без карты, ход дня);
## полный замер по Онгудаю — tools/weather/storm_rarity.gd.

## Cb ближе этого к фокусу (центр эталонного мира) — «у старта», м. Термики эталонного мира
## живут в 10 км (AtmoFingerprint.GEN_RADIUS_M).
const NEAR_M := 10000.0
## Грозовой ветер у старта: горизонтальный поток бури больше этого, м/с.
const WIND_MS := 2.0


func _key(temp: float, hour: float, seed_v: int, sky := "clear") -> String:
	return (
		AtmoFingerprint
		. DEFAULT_KEY
		. replace("temp=29.0", "temp=%.1f" % temp)
		. replace("hour=11.00", "hour=%.2f" % hour)
		. replace("seed=4242", "seed=%d" % seed_v)
		. replace("sky=clear", "sky=" + sky)
	)


## Прогон сида: [Cb ближе NEAR_M за первый час, ветер бури у центра в t = 0, м/с, наибольший за
## час, м/с]. t = 0 — прыжок (тёплый старт), дальше — обновление раз в 15 мин (Cb живёт дольше).
func _run(temp: float, hour: float, seed_v: int, sky := "clear") -> Array:
	var a := AtmoFingerprint.make_world(_key(temp, hour, seed_v, sky))
	var c := AtmoFingerprint.CENTER
	var p := Vector3(c.x, AtmoFingerprint.height(c.x, c.z) + 2.0, c.z)
	var near := {}
	var wind0 := 0.0
	var wind_max := 0.0
	for k in 5:
		var t := k * 900.0
		if k == 0:
			a.start_at(t)
		else:
			a.time_s = t
			a.refresh_now()
		for id in a.field.thermals:
			var th: AtmoThermal = a.field.thermals[id]
			if th.is_cb and t >= th.t_birth:
				var cc := th.cloud_center(t)
				if Vector2(cc.x - c.x, cc.y - c.z).length() < NEAR_M:
					near[id] = true
		var s := a.storm.sample(p, 2.0, t)
		var h := Vector2(s.x, s.z).length()
		if k == 0:
			wind0 = h
		wind_max = maxf(wind_max, h)
	a.free()
	return [near.size(), wind0, wind_max]


## Запас (верх сухих термиков − конденсация) в эталонном мире при temp и hour, м.
func _margin(temp: float, hour: float) -> float:
	var key := _key(temp, hour, 1)
	AtmoFingerprint.make_world(key).free()  # место и дата эталонного мира
	var fs: FlightSettings = WorldKey.parse(key).settings
	var w := WeatherModel.derive(fs.forecast(), AtmoFingerprint.weather_ctx(), {}, hour)
	return float(w._derived.margin_m)


## Температура эталонного мира с тем же запасом, что в Онгудае (запас решает, будет ли гроза;
## рельеф эталона ниже — там на ~3 °C «холоднее»), °C.
func _temp_for(margin: float, hour: float) -> float:
	var lo := 10.0
	var hi := 45.0
	for i in 20:
		var mid := 0.5 * (lo + hi)
		if _margin(mid, hour) < margin:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


func _row_chance(margin: float) -> float:
	var row := WeatherModel.interp_rows(WeatherModel.config().clouds_by_margin, "margin_m", margin)
	return float(row.cb_thermal_chance)


func _chance(temp: float, hour: float, sky := "clear") -> float:
	var w := WeatherModel.derive(
		{"temperature_c": temp, "wind_speed_kmh": 11.0, "wind_from_deg": 270.0, "sky": sky},
		WeatherModel.reference_context(),
		WeatherModel.config(),
		hour
	)
	return ThermalField.cb_thermal_chance(w)


func test_chance_grows_with_heat() -> void:
	# Запас в Онгудае: +24 → ~550–590 м, +26 → 650–690, +30 → 850–890, +34 → 1050–1090.
	check(_row_chance(600.0) == 0.0, "до +25 гроз нет")
	check(_row_chance(690.0) <= 1.0e-4, "+26 — почти без гроз: %.5f" % _row_chance(690.0))
	check(_row_chance(870.0) > _row_chance(690.0) * 10.0, "+30 — грозы заметно чаще +26")
	check(_row_chance(1070.0) > _row_chance(870.0), "+34 — ещё чаще")
	var prev := 0.0
	for m in range(0, 1500, 50):
		check(_row_chance(m) >= prev, "доля Cb растёт с запасом (%d м)" % m)
		prev = _row_chance(m)
	check(_chance(38.0, 10.0) == 0.0, "утром гроз нет")
	check(_chance(38.0, 15.0) > 0.0, "днём в жару есть")
	check(_chance(38.0, 15.0, "partly") < _chance(38.0, 15.0), "переменная — реже")
	check(_chance(38.0, 15.0, "overcast") == 0.0, "облачно — без гроз")


func test_clear_26_almost_never() -> void:
	var t0 := Time.get_ticks_msec()
	var n := 24
	var with_cb := 0
	var stormy0 := 0
	var temp := _temp_for(650.0, 13.0)  # как +26 в Онгудае в 13 ч
	for s in range(1, n + 1):
		var r := _run(temp, 13.0, s)
		with_cb += 1 if int(r[0]) > 0 else 0
		stormy0 += 1 if float(r[1]) > WIND_MS else 0
	print(
		(
			"    «+26» (%+.1f) ясно 13 ч: Cb ближе 10 км за час — %d/%d, буря в t=0 — %d/%d (%.1f с)"
			% [temp, with_cb, n, stormy0, n, (Time.get_ticks_msec() - t0) / 1000.0]
		)
	)
	check(with_cb <= 1, "+26: Cb у старта в %d полётах из %d" % [with_cb, n])
	check(stormy0 == 0, "+26: буря у старта в начале в %d полётах из %d" % [stormy0, n])


func test_hot_34_occasional() -> void:
	var t0 := Time.get_ticks_msec()
	var n := 10
	var cb := 0
	var stormy0 := 0
	var wind_max := 0.0
	var temp := _temp_for(1090.0, 15.0)  # как +34 в Онгудае в 15 ч
	for s in range(1, n + 1):
		var r := _run(temp, 15.0, s)
		cb += int(r[0])
		stormy0 += 1 if float(r[1]) > WIND_MS else 0
		wind_max = maxf(wind_max, float(r[2]))
	print(
		(
			(
				"    «+34» (%+.1f) ясно 15 ч: Cb ближе 10 км — %d на %d полётов, буря в t=0 — %d, макс %.1f м/с"
				% [temp, cb, n, stormy0, wind_max]
			)
			+ " (%.1f с)" % ((Time.get_ticks_msec() - t0) / 1000.0)
		)
	)
	check(cb >= 1, "в жару грозы бывают: %d Cb на %d полётов" % [cb, n])
	check(stormy0 <= n / 2, "но над стартом в начале — не в большинстве: %d из %d" % [stormy0, n])
	var out := float(Config.get_config("atmosphere").storm.outflow_ms)
	check(wind_max <= out + 1.0e-3, "поток бури не сильнее одной ячейки: %.1f м/с" % wind_max)


func test_overlapping_outflows_do_not_add() -> void:
	var a := Atmosphere.new()
	a.configure(
		Config.get_config("atmosphere"),
		Config._deep_merge(
			Config.get_config("weather/storm"), {"wind_speed_kmh": 0.0, "thermal_mode": "static"}
		)
	)
	a.turbulence_enabled = false
	a.set_ground(
		func(_x: float, _z: float) -> float: return 0.0,
		func(_x: float, _z: float) -> float: return 1.0
	)
	var id := a.add_static_thermal(0.0, 0.0, 4.0, 150.0)
	var th: AtmoThermal = a.field.thermals[id]
	th.is_static = false
	th.is_cb = true
	th.has_cloud = true
	th.t_birth = -2000.0
	th.t_grow = 200.0
	th.t_mature = 3000.0
	th.t_decay = 400.0
	a.time_s = 0.0
	a.step(0.01)
	var c := th.cloud_center(a.time_s)
	var rf := a.storm.front_radius(th, a.time_s)
	var p := Vector3(c.x + rf * 0.6, 50.0, c.y)
	var one := a.storm.sample(p, 50.0, a.time_s)
	a.storm.cells.append_array([th, th, th])
	var four := a.storm.sample(p, 50.0, a.time_s)
	var out := float(Config.get_config("atmosphere").storm.outflow_ms)
	check(one.x > 5.0, "одна ячейка дует: %.1f м/с" % one.x)
	check(
		Vector2(four.x, four.z).length() <= out + 1.0e-3, "четыре — не сильнее одной: %.1f" % four.x
	)
	check(
		four.y >= -float(Config.get_config("atmosphere").storm.downdraft_ms) - 1.0e-3, "ливень тоже"
	)
	a.free()
