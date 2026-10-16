extends TestCase
## GoalEstimator (GL-К2): детерминизм, порядок уровней, монотонность, честность, weather_for.

const DISTANCE_KINDS := ["height", "duration", "distance", "return", "triangle"]
const STEP := {
	"height": 50.0, "duration": 300.0, "distance": 1000.0, "return": 1000.0,
	"triangle": 1000.0, "speed": 60.0, "landing": 5.0,
}


func _wx(thermal: float, base: float, hours: float, wind := 3.0) -> Dictionary:
	return {
		"cloudbase_agl_m": base, "thermal_ms": thermal, "wind_ms": wind,
		"wind_from_deg": 270.0, "sky": "clear", "hours_left": hours, "start_hour": 13.0,
	}


func _grid() -> Array:
	var out := []
	for th in [0.3, 0.8, 1.5, 2.5, 3.5, 5.0]:
		for base in [300.0, 800.0, 1500.0, 2500.0, 3800.0]:
			for hrs in [0.0, 1.0, 3.0, 6.0, 9.0]:
				for wind in [0.0, 4.0, 10.0]:
					out.append(_wx(th, base, hrs, wind))
	return out


func test_deterministic() -> void:
	var wx := _wx(2.2, 1800.0, 6.0)
	var a := GoalEstimator.suggest_all(wx, 25000.0)
	var b := GoalEstimator.suggest_all(wx.duplicate(), 25000.0)
	check(a == b, "одни входы — одни числа")
	var s := FlightSettings.defaults()
	check(GoalEstimator.weather_for(s) == GoalEstimator.weather_for(s), "weather_for детерминирован")


func test_all_kinds_and_rounding() -> void:
	var all := GoalEstimator.suggest_all(_wx(2.2, 1800.0, 6.0), 25000.0)
	check(not all.has("route"), "route не оценивается")
	for k in GoalEstimator.KINDS:
		check(all.has(k), "есть %s" % k)
		for lv in ["easy", "medium", "hard"]:
			var v := float(all[k][lv])
			check(v > 0.0, "%s.%s > 0" % [k, lv])
			approx(fmod(v, STEP[k]), 0.0, 1e-6, "%s.%s кратно %s" % [k, lv, STEP[k]])


func test_level_order_on_grid() -> void:
	var bad := 0
	for wx in _grid():
		var all := GoalEstimator.suggest_all(wx, 30000.0)
		for k in GoalEstimator.KINDS:
			var e := float(all[k].easy)
			var m := float(all[k].medium)
			var h := float(all[k].hard)
			var ok := (e > m and m > h) if k in ["speed", "landing"] else (e < m and m < h)
			if not ok:
				bad += 1
				if bad < 5:
					check(false, "порядок %s %s: %s" % [k, wx, all[k]])
	check(bad == 0, "порядок уровней на сетке, нарушений %d" % bad)


func test_monotonic() -> void:
	var bad := 0
	var axes := {
		"thermal_ms": [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0],
		"cloudbase_agl_m": [300.0, 600.0, 1000.0, 1500.0, 2200.0, 3000.0, 3800.0],
		"hours_left": [0.0, 0.5, 1.5, 2.5, 4.0, 6.0, 8.0, 12.0],
	}
	for base_wx in _grid():
		for key in axes:
			var prev := {}
			for x in axes[key]:
				var wx: Dictionary = base_wx.duplicate()
				wx[key] = x
				for k in DISTANCE_KINDS:
					for lv in ["easy", "medium", "hard"]:
						var v := GoalEstimator.suggest(k, lv, wx)
						var id := "%s.%s" % [k, lv]
						if prev.has(id) and v < float(prev[id]) - 1e-6:
							bad += 1
							if bad < 5:
								check(false, "%s убывает по %s=%s (%s)" % [id, key, x, base_wx])
						prev[id] = v
	check(bad == 0, "монотонность, нарушений %d" % bad)


func _ongudai(temp: float, wind_kmh: float, sky: String) -> Dictionary:
	var s := FlightSettings.defaults()
	s.location_id = "ongudai"
	s.month = 7
	s.day = 15
	s.start_hour = 13.0
	s.temperature_c = temp
	s.wind_speed_kmh = wind_kmh
	s.sky = sky
	return GoalEstimator.weather_for(s)


func _avail(wx: Dictionary) -> float:
	var hc: Dictionary = Config.get_config("goals/estimate").height
	return float(wx.cloudbase_agl_m) - float(hc.start_above_mean_m)


## GL-К2 v2: в слабую/пасмурную погоду пороги уровней больше доступного — трудное недостижимо.
func test_honesty_weak_weather() -> void:
	var c := Config.get_config("goals/estimate")
	for wx in [_wx(0.5, 800.0, 6.0), _wx(1.0, 1200.0, 6.0), _wx(0.8, 1300.0, 4.0)]:
		var h := GoalEstimator.suggest("height", "hard", wx)
		check(h > _avail(wx), "hard height %s > запас до базы %s" % [h, _avail(wx)])
	var wx := _ongudai(22.0, 10.0, "overcast")
	var h := GoalEstimator.suggest("height", "hard", wx)
	check(h > _avail(wx), "пасмурно на Онгудае: hard height %s > запас %s (%s)" % [h, _avail(wx), wx])
	# Маршрутные и время — порог уровня, а не погода (погода даёт меньше).
	var keys := {"distance": "floor_m", "return": "floor_m", "triangle": "floor_m", "duration": "floor_s"}
	for k in keys:
		var floor_hard := float(c[k][keys[k]].hard)
		approx(GoalEstimator.suggest(k, "hard", wx), floor_hard, 1e-6, "пасмурно: %s.hard = порог" % k)


## GL-К2 v2: в «ясно, сильные» трудное достижимо без облака и задаётся погодой, а не порогом.
func test_good_weather_reachable() -> void:
	var c := Config.get_config("goals/estimate")
	var wx := _ongudai(30.0, 5.0, "clear")
	var h := GoalEstimator.suggest("height", "hard", wx)
	check(h <= _avail(wx), "ясно: hard height %s ≤ запас до базы %s" % [h, _avail(wx)])
	check(h > float(c.height.floor_m.hard), "ясно: hard height по погоде, не порог")
	var keys := {"distance": "floor_m", "triangle": "floor_m", "duration": "floor_s"}
	for k in keys:
		check(
			GoalEstimator.suggest(k, "hard", wx) > float(c[k][keys[k]].hard),
			"ясно: %s.hard выше порога" % k
		)


func test_rules() -> void:
	var wx := _wx(2.5, 2000.0, 6.0)
	check(GoalEstimator.suggest("route", "easy", wx) == 0.0, "route → 0")
	check(GoalEstimator.suggest("speed", "hard", wx, 0.0) == 0.0, "speed без маршрута → 0")
	check(GoalEstimator.suggest("speed", "hard", wx, -5.0) == 0.0, "speed route_m < 0 → 0")
	check(GoalEstimator.suggest("nope", "easy", wx) == 0.0, "неизвестный kind → 0")
	for k in GoalEstimator.KINDS:
		check(
			GoalEstimator.suggest(k, "custom", wx, 20000.0)
			== GoalEstimator.suggest(k, "medium", wx, 20000.0),
			"custom как medium: %s" % k
		)
	# Пустой wx — значения по умолчанию из конфига, без ошибок.
	var d := GoalEstimator.suggest_all({}, 20000.0)
	check(float(d.height.hard) > 0.0 and float(d.distance.easy) > 0.0, "пустой wx: %s" % d)
	# Посадка от погоды не зависит.
	check(
		GoalEstimator.suggest_all(_wx(0.3, 300.0, 0.0)).landing
		== GoalEstimator.suggest_all(_wx(5.0, 3500.0, 8.0)).landing,
		"посадка не зависит от погоды"
	)
	# Скорость: длиннее маршрут — больше время.
	check(
		GoalEstimator.suggest("speed", "medium", wx, 40000.0)
		> GoalEstimator.suggest("speed", "medium", wx, 20000.0),
		"предел растёт с длиной маршрута"
	)


func _check_wx(wx: Dictionary, what: String) -> void:
	for key in [
		"cloudbase_agl_m", "thermal_ms", "wind_ms", "wind_from_deg", "sky", "hours_left",
		"start_hour",
	]:
		check(wx.has(key), "%s: ключ %s" % [what, key])
	check(float(wx.cloudbase_agl_m) > 0.0, "%s: база > 0 (%s)" % [what, wx])
	check(float(wx.thermal_ms) >= 0.0, "%s: термики ≥ 0" % what)
	check(float(wx.hours_left) >= 0.0, "%s: hours_left ≥ 0" % what)


func test_weather_for_builtin() -> void:
	var s := FlightSettings.defaults()
	s.location_id = "ongudai"
	s.month = 7
	s.day = 15
	s.start_hour = 13.0
	s.wind_speed_kmh = 18.0
	var wx := GoalEstimator.weather_for(s)
	_check_wx(wx, "ongudai")
	approx(float(wx.wind_ms), 5.0, 1e-4, "ветер 18 км/ч → 5 м/с")
	approx(float(wx.start_hour), 13.0, 1e-6, "start_hour")
	# Закат в июле на 50,8° с. ш. (UTC+7, 86° в. д.) ≈ 21:10 по поясу → предел — max_hour 21.
	var max_hour := float(Config.value("world", "time.max_hour", 21.0))
	check(float(wx.hours_left) <= max_hour - 13.0 + 1e-6, "hours_left ≤ max_hour − старт")
	check(float(wx.hours_left) > 6.0, "летом с 13 ч больше 6 ч светлого (%s)" % wx.hours_left)
	s.start_hour = 22.0
	check(float(GoalEstimator.weather_for(s).hours_left) == 0.0, "после max_hour — 0")
	# Утро слабее полудня.
	s.start_hour = 8.0
	var morning := GoalEstimator.weather_for(s)
	check(float(morning.thermal_ms) < float(wx.thermal_ms), "в 8 ч термики слабее, чем в 13 ч")


func test_weather_for_map_point() -> void:
	var s := FlightSettings.defaults()
	s.location_id = "pick_test_not_cached"
	s.pick_lat = 46.6
	s.pick_lon = 8.0
	s.month = 6
	s.day = 21
	s.start_hour = 12.0
	var wx := GoalEstimator.weather_for(s)
	_check_wx(wx, "точка с карты")
	# Альпы, 21 июня: закат по поясу UTC+1 (по долготе) ≈ 20:30 → 8,5 ч.
	approx(float(wx.hours_left), 8.5, 0.6, "часы до заката в Альпах")
	var all := GoalEstimator.suggest_all(wx, 30000.0)
	check(float(all.distance.hard) > float(all.distance.easy), "числа для точки с карты")
