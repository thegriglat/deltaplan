extends Node
## RW-21: присутствие элементов игры на ветке модуля (критерий пользователя 2026-10-30), не совпадение чисел.
## Главная сцена как в test_game_flight: меню -> «Лететь» с настройками по умолчанию на встроенной фикстуре
## (ongudai) -> 60 игровых с шагами Game.tick -> числа по воздуху. Печатает строки `PRESENCE ключ=значение`.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --file=res://tools/smoke/presence_check.gd

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _p(k: String, v: Variant) -> void:
	print("PRESENCE %s=%s" % [k, str(v)])


func test_presence() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var t0 := Time.get_ticks_msec()
	await main.call("load_menu_world")
	_p("menu_world_loaded", game.settings != null)
	_p("menu_visible", main.get_node("UI/StartMenu").visible)
	_p("loading_screen_node", main.get_node_or_null("UI/LoadingScreen") != null)
	check(game.settings != null, "мир за меню загружен")
	if game.settings == null:
		main.queue_free()
		return
	var s := FlightSettings.defaults()
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", s)
	_p("fly_wall_s", (Time.get_ticks_msec() - t0) / 1000.0)
	_p("state", main.get("state"))
	check(main.get("state") == 2, "FLYING после «Лететь»")
	var air: Atmosphere = game.air as Atmosphere
	check(air != null, "атмосфера")
	if air == null:
		main.queue_free()
		return
	_p("air_ready", air.is_ready())
	_p("air_status", air.status())
	game.autopilot = Autopilot.new()
	var t := 0.0
	while t < 60.0:
		game.tick(DT)
		t += DT
	var p: Vector3 = game.get_start().position
	var wind := air.mean_wind_at(p + Vector3(0, 30, 0))
	_p("wind_start_ms", wind.length())
	var bw := air.background_wind(PackedFloat32Array([p.y, p.y + 1000.0]))
	_p("background_wind_ms", Vector2(bw[0], bw[1]).length())
	var th := air.thermals_near(p, 5000.0)
	_p("thermals_5km", th.size())
	var wx := air.weather()
	_p("weather_keys", wx.keys().size())
	_p("weather_cloudbase_agl_m", wx.get("cloudbase_agl_m"))
	_p("weather_wind_from_deg", wx.get("wind_from_deg"))
	_p("cloudbase_msl", air.cloudbase_msl())
	var pts := PackedVector3Array()
	var cb := air.cloudbase_msl()
	for i in 21:
		for j in 21:
			pts.append(Vector3(p.x + (i - 10) * 500.0, cb + 150.0, p.z + (j - 10) * 500.0))
	var dens := air.cloud_density_many(pts)
	var nc := 0
	for d in dens:
		if d > 0.05:
			nc += 1
	_p("cloud_points_of_441", nc)
	_p("turbulence_intensity", air.turbulence_intensity_at(p + Vector3(0, 100, 0)))
	_p("wave_info", air.wave_info())
	_p("vario_state", game.glider.phase())
	check(wind.length() > 0.0 or Vector2(bw[0], bw[1]).length() > 0.0, "ветер не нулевой")
	check(th.size() > 0, "термики есть")
	main.queue_free()
