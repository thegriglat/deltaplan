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
		absf(angle_difference(deg_to_rad(float(air.weather.wind_from_deg)),
			deg_to_rad(float(start.heading_deg)))) < 0.01,
		"встречный: ветер с %.0f°, курс %.0f°" % [air.weather.wind_from_deg, start.heading_deg]
	)
	check(is_equal_approx(air.wind.ref_msl, (start.position as Vector3).y), "опора ветра — старт")
	var ctx := game._weather_context()
	var w := WeatherModel.derive(s.forecast(), ctx, {}, 14.0)
	var cb := float(air.weather.cloudbase_agl_m)
	check(absf(cb - float(w.cloudbase_agl_m)) <= 0.1 * float(w.cloudbase_agl_m), "кромка %.0f" % cb)
	check(cb > 1000.0 and cb < 2800.0, "июль +26 на Алтае: кромка %.0f" % cb)
	s.wind_into_launch = false
	s.wind_from_deg = 225.0
	await main.call("_fly", s)
	check(is_equal_approx(float(air.weather.wind_from_deg), 225.0), "румб ЮЗ")
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
	air.set_focus(p)
	var total := 0
	for i in 40:
		air.step(15.0)
		if i >= 10:
			total += air.thermals_near(p, 5000.0).size()
	return total
