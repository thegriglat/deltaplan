extends Node
## Погода из прогноза в игре (docs/archive/plan/weather-by-temperature.md, карточка 3): Game выводит день
## из прогноза и рельефа, ветер — встречный или с румба, опорная высота ветра — отметка открытой местности места (WF-К1 v3).

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_game_uses_forecast() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	check(game.settings != null, "мир за меню загружен")
	if game.settings == null:
		main.queue_free()
		return
	# Детерминированный режим крейта: advance_to ждёт фоновую пересборку термиков (без реального времени в тесте).
	(game.air as Atmosphere).deterministic = true
	var s := FlightSettings.defaults()
	s.location_id = "altai"
	s.site_id = "sinyukha_west"
	s.temperature_c = 26.0
	s.wind_speed_kmh = 10.8
	s.wind_into_launch = true
	s.start_hour = 14.0
	await main.call("_fly", s)
	var air: Atmosphere = game.air as Atmosphere
	check(air != null, "атмосфера")
	if air == null:
		main.queue_free()
		return
	var start: Dictionary = game.get_start()
	# Румб ветра - курс площадки; курс старта пилот доворачивает к среднему ветру поля у земли (Game._align_start_heading,
	# configs/game.json start_wind_align): рельеф поворачивает поток, поэтому курс старта может отличаться от румба на
	# несколько градусов (после RW-14c поле считается с климатом места по сеткам - 276° и 267° на Синюхе), но не дальше max_turn_deg.
	var wind_from := float(air.weather().wind_from_deg)
	var site := float(game._site_heading)
	check(absf(angle_difference(deg_to_rad(wind_from), deg_to_rad(site))) < 0.01, "встречный: ветер с %.0f°, курс площадки %.0f°" % [wind_from, site])
	var turn_max := float(Config.get_config("game").start_wind_align.max_turn_deg)
	var turn := rad_to_deg(absf(angle_difference(deg_to_rad(site), deg_to_rad(float(start.heading_deg)))))
	check(turn <= turn_max + 0.01, "курс старта %.0f° не дальше %.0f° от курса площадки (%.0f°)" % [start.heading_deg, turn_max, site])
	# Опора ветра — отметка долины места (WF-К1 v3, игра wind_ref не кладёт): ветер прогноза — на 10 м над
	# открытой местностью, на старте (выше долины) он не слабее и идёт по румбу прогноза (на «встречный» —
	# против курса), не нулевой.
	check(not (game._air_conditions() as Dictionary).has("wind_ref"), "игра не кладёт wind_ref в условия")
	var y0 := (start.position as Vector3).y
	var bw := air.background_wind(PackedFloat32Array([y0, y0 + 1000.0]))
	var v0 := Vector2(bw[0], bw[1])
	var v1 := Vector2(bw[2], bw[3])
	var hd := deg_to_rad(float(start.heading_deg))
	check(v0.length() > 0.5, "ветер на высоте старта: %.2f м/с" % v0.length())
	check(
		absf(v0.normalized().angle_to(Vector2(-sin(hd), cos(hd)))) < 0.2 and absf(v0.angle_to(v1)) < 0.5,
		"фоновый ветер на старте идёт по курсу прогноза (против курса старта)"
	)
	check(v1.length() >= v0.length() - 0.01, "ветер с высотой не слабее: %.2f → %.2f" % [v0.length(), v1.length()])
	var ctx := game._weather_context()
	var w := Weather.derive(s.forecast(), ctx, 14.0)
	var cb := float(air.weather().cloudbase_agl_m)
	check(absf(cb - float(w.cloudbase_agl_m)) <= 0.1 * float(w.cloudbase_agl_m), "кромка %.0f" % cb)
	check(cb > 1000.0 and cb < 2800.0, "июль +26 на Алтае: кромка %.0f" % cb)
	s.wind_into_launch = false
	s.wind_from_deg = 225.0
	await main.call("_fly", s)
	check(is_equal_approx(float(air.weather().wind_from_deg), 225.0), "румб ЮЗ")
	# Пилот: «вечером термиков мало» — в 19 ч заметно меньше, чем в 14 ч. Число живых падает вслед за thermal_duty
	# (0,82 -> 0,34, в 2,4 раза), но не полностью: слой перемешивания к вечеру тоньше, плотность потоков Аллена
	# растёт (RW-26: 14 ч - 3676, 19 ч - 1927, в 1,9 раза), поэтому порог 1,5, а не 3.
	var n14 := await _count_thermals(main, game, s, 14.0)
	var n19 := await _count_thermals(main, game, s, 19.0)
	print("         термиков в 5 км: 14 ч — %d, 19 ч — %d" % [n14, n19])
	check(2 * n14 >= 3 * maxi(n19, 1) and n14 > 0, "вечером термиков в 1,5+ раза меньше (%d и %d)" % [n14, n19])
	main.queue_free()


func _count_thermals(main: Node, game: Game, s: FlightSettings, hour: float) -> int:
	s.start_hour = hour
	await main.call("_fly", s)
	game.set_physics_process(false)
	var air: Atmosphere = game.air as Atmosphere
	var p: Vector3 = game.get_start().position
	air.set_focuses(PackedVector3Array([p]), PackedFloat32Array([1.0]))
	var total := 0
	var t := float(air.status().time_s)
	for i in 40:
		t += 15.0
		air.advance_to(t)  # deterministic: снимок термиков готов к возврату
		if i >= 10:
			total += air.thermals_near(p, 5000.0).size()
	return total
