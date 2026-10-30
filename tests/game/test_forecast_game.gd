extends Node
## Погода из прогноза в игре (docs/archive/plan/weather-by-temperature.md, карточка 3): Game выводит день
## из прогноза и рельефа, ветер — встречный или с румба, опора ветра — высота старта.

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
	check(
		absf(angle_difference(deg_to_rad(float(air.weather().wind_from_deg)),
			deg_to_rad(float(start.heading_deg)))) < 0.01,
		"встречный: ветер с %.0f°, курс %.0f°" % [air.weather().wind_from_deg, start.heading_deg]
	)
	# Опора ветра — старт (W5 Conditions.wind_ref): на высоте старта фоновый ветер идёт по румбу
	# прогноза (на «встречный» — против курса), не слабеет с высотой и не нулевой.
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
	# Пилот: «вечером термиков мало» — в 19 ч в разы меньше, чем в 14 ч (прогрев, солнце низко).
	var n14 := await _count_thermals(main, game, s, 14.0)
	var n19 := await _count_thermals(main, game, s, 19.0)
	print("         термиков в 5 км: 14 ч — %d, 19 ч — %d" % [n14, n19])
	check(n14 >= 3 * maxi(n19, 1), "вечером термиков в 3+ раза меньше (%d и %d)" % [n14, n19])
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
		air.advance_to(t)
		# Термики крейт пересобирает фоном: без реального времени между шагами снимок не успевает.
		await get_tree().create_timer(0.3).timeout
		if i >= 10:
			total += air.thermals_near(p, 5000.0).size()
	return total
