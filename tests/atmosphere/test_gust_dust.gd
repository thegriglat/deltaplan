extends TestCase
## Клубы пыли от порывов (GustDustModel, GustDust): порог, поверхность, сырость, детерминизм, пул.


func _atmo(w_over: Dictionary = {}, dust_over: Dictionary = {}) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config("weather/strong"), w_over)
	var c := Config._deep_merge(Config.get_config("atmosphere"), {"gust_dust": dust_over})
	a.configure(c, w)
	a.turbulence_enabled = false
	return a


func _model(a: Atmosphere) -> GustDustModel:
	var m := GustDustModel.new()
	m.setup(a.cfg.gust_dust, a.weather, a.wind)
	return m


## Число событий в квадрате 40×40 клеток за 20 слотов.
func _count(m: GustDustModel, surf: Callable) -> int:
	var n := 0
	for s in range(100, 120):
		for i in 40:
			for j in 40:
				if not m.event(i, j, s, surf).is_empty():
					n += 1
	return n


static func _crop(_x: float, _z: float) -> int:
	return 3


static func _forest(_x: float, _z: float) -> int:
	return 1


static func _snow(_x: float, _z: float) -> int:
	return 8


func test_below_threshold_no_dust() -> void:
	var a := _atmo({"wind_speed_kmh": 8.0, "convective_turbulence_ms": 0.5})
	var m := _model(a)
	check(_count(m, _crop) == 0, "слабый ветер: клубов нет")


func test_above_threshold_has_dust_and_grows() -> void:
	var weak := _model(_atmo({"wind_speed_kmh": 30.0}))
	var strong := _model(_atmo({"wind_speed_kmh": 55.0}))
	var cw := _count(weak, _crop)
	var cs := _count(strong, _crop)
	print("gust_dust: событий за 20 слотов на 1600 клеток: 30 км/ч %d, 55 км/ч %d" % [cw, cs])
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		strong.event(i, 3, 5, Callable())
	print("gust_dust: %.1f мкс на клетку" % ((Time.get_ticks_usec() - t0) / 1000.0))
	check(cs > 0, "сильный ветер: клубы есть (%d)" % cs)
	check(cs > cw, "чем сильнее ветер, тем больше клубов: %d > %d" % [cs, cw])
	check(strong.strength(strong.threshold - 0.1) == 0.0, "ниже порога сила 0")
	check(strong.strength(strong.threshold + strong.span) == 1.0, "сила растёт до 1")
	var hmax := 0.0
	var hmin := 1.0e9
	for s in range(100, 110):
		for i in 40:
			for j in 40:
				var e := strong.event(i, j, s, _crop)
				if not e.is_empty():
					hmax = maxf(hmax, e.h)
					hmin = minf(hmin, e.h)
					check(e.life >= 4.0 and e.life <= 19.0, "жизнь 4–19 с: %.1f" % e.life)
	check(hmin >= 2.0 and hmax <= 40.0, "высота клубов 2–40 м: %.1f…%.1f" % [hmin, hmax])


func test_surface_and_wet_exclude() -> void:
	var a := _atmo({"wind_speed_kmh": 55.0})
	var m := _model(a)
	check(_count(m, _crop) > 0, "пашня пылит")
	check(_count(m, _forest) == 0, "лес не пылит")
	check(_count(m, _snow) == 0, "снег не пылит")
	var wet := _model(_atmo({"wind_speed_kmh": 55.0, "wet": true}))
	check(wet.is_wet() and _count(wet, _crop) == 0, "сырая погода: пыли нет")
	var ov := _model(_atmo({"wind_speed_kmh": 55.0, "sky": "overcast"}))
	check(_count(ov, _crop) == 0, "пасмурно (сырой грунт): пыли нет")


func test_deterministic_and_world_not_pilot() -> void:
	var a := _atmo({"wind_speed_kmh": 55.0})
	var m1 := _model(a)
	var m2 := _model(_atmo({"wind_speed_kmh": 55.0}))
	var same := true
	var found := 0
	for i in 40:
		for j in 40:
			var e1 := m1.event(i, j, 105, _crop)
			var e2 := m2.event(i, j, 105, _crop)
			same = same and e1 == e2
			if not e1.is_empty():
				found += 1
	check(same and found > 0, "одинаковые события при одинаковом мире (%d)" % found)


func test_forced_wind_arg() -> void:
	var a := _atmo({"wind_speed_kmh": 5.0}, {"force_wind_ms": 14.0})
	var m := _model(a)
	check(_count(m, _crop) > 0, "force_wind_ms поднимает пыль при слабом прогнозе")


func test_node_scan_fills_pool() -> void:
	var a := _atmo({"wind_speed_kmh": 55.0})
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0, _crop)
	var g := GustDust.new()
	a.add_child(g)
	g.setup(a)
	var t := 400.0
	a.time_s = t
	var eye := Vector3(5000, 100, 5000)
	for k in 200:
		g.step_scan(eye, t, 250)
	var live := g.live_count(t + 3.0)
	check(live > 0, "пул заполнен, живых клубов: %d" % live)
	check(live <= int(g.cfg.events_max), "пул не больше events_max")
	check(g.mm.instance_count == int(g.cfg.events_max) * int(g.cfg.puffs_max), "один MultiMesh фиксированного размера")
	g.free()
	a.free()
