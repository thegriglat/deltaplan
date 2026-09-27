extends Node
## Погода из прогноза в игре (docs/plan/weather_by_temperature.md, карточка 3): Game выводит день
## из прогноза и рельефа места, ветер — в лоб старту или с румба, опора ветра — высота старта.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_game_uses_forecast() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 1200:
		if game.settings != null:
			break
		await get_tree().process_frame
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
		"в лоб старту: ветер с %.0f°, курс %.0f°" % [air.weather.wind_from_deg, start.heading_deg]
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
	main.queue_free()
