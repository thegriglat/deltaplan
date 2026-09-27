extends Node
## G06. «Нос держится сам» на разбеге учитывает ветер (FR-30, docs/flight.md → «Старт в сильный
## ветер»). Игрок (синтетический ввод: только W+Shift через InputMap, без стрелок, без
## автопилота) взлетает на всех локациях × крыльях × погоде weak/medium/strong на 10 сидах часов
## атмосферы — 0 срывов. Стрелка «нос вверх» до упора в сильный ветер — срыв nose_high.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAX_GROUND_S := 20.0
## Сколько игрок стоит перед разбегом, с (чувствует ветер в лицо).
const STAND_S := 0.5
const WINGS := ["wings/training", "wings/sport", "wings/kingpost"]
const WEATHERS := ["weather/weak", "weather/medium", "weather/strong"]
## Моменты на часах атмосферы при старте (фаза порывов и термиков); 2415 и 4110 — из F01.
const SEEDS := [0.0, 300.0, 600.0, 1100.0, 1500.0, 2000.0, 2415.0, 3000.0, 3600.0, 4110.0]
const RUN_KEYS := ["walk_forward", "pitch_pull_in", "run"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_player_launch_all_combos() -> void:
	var main := await _open_main()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var locations := Config.list_configs("locations")
	check(locations.size() >= 4, "4 локации (%d)" % locations.size())
	var total := 0
	var fails := 0
	for loc_name in locations:
		for wing: String in WINGS:
			for weather: String in WEATHERS:
				var s := _settings(loc_name.get_file(), wing, weather)
				await main.call("_fly", s)
				var label := "%s × %s × %s" % [s.location_id, wing, weather]
				if int(main.get("state")) != 2:
					failures.append("%s: состояние не FLYING" % label)
					continue
				for sd: float in SEEDS:
					total += 1
					var r := _launch(game, sd, false)
					if r != "air":
						fails += 1
						failures.append("%s, сид %.0f: взлёт сорван (%s)" % [label, sd, r])
	print("         игрок W+Shift: %d взлётов, %d срывов" % [total, fails])
	check(
		total == locations.size() * WINGS.size() * WEATHERS.size() * SEEDS.size(), "все сочетания"
	)
	_release()
	main.queue_free()


func test_nose_up_full_strong_wind_stalls() -> void:
	var main := await _open_main()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	for wing: String in ["wings/sport", "wings/kingpost"]:
		await main.call("_fly", _settings("altai", wing, "weather/strong"))
		var r := _launch(game, 0.0, true)
		check(r == "nose_high", "%s: ↑ до упора в сильный ветер — %s (ждали nose_high)" % [wing, r])
	_release()
	main.queue_free()


func _open_main() -> Node:
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
		return null
	check(game.autopilot == null, "управляет игрок, не автопилот")
	(main.get("opts") as LaunchOptions).autostart = true
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return main


func _settings(loc: String, wing: String, weather: String) -> FlightSettings:
	var s := FlightSettings.new()
	s.location_id = loc
	s.wing = wing
	s.weather = weather
	s.wind_mode = "into_site"
	return s


## Разбег игрока с того же старта при часах атмосферы sd: "air" | причина срыва | "none".
## nose_up — всё время держать ↑ (подстройка носа вверх до упора).
func _launch(game: Game, sd: float, nose_up: bool) -> String:
	game.restart()
	game.air.set("time_s", sd)
	var m: FlightModel = game.glider.model
	var t := 0.0
	var out := "none"
	_release()
	while t < MAX_GROUND_S:
		var run := t >= STAND_S
		for a: String in RUN_KEYS:
			_press(a, run)
		_press("nose_up", nose_up)
		game.tick(DT)
		t += DT
		if m.mode == FlightModel.Mode.AIR:
			out = "air"
			break
		if m.mode == FlightModel.Mode.FAILED:
			out = m.takeoff_failure
			break
	_release()
	return out


func _press(action: String, on: bool) -> void:
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _release() -> void:
	for a: String in RUN_KEYS + ["nose_up", "nose_down"]:
		Input.action_release(a)
