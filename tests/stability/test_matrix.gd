extends Node
## 02. Стабильность: матрица крылья × локации × погода (все configs/locations/*),
## ветер into_site — старт, автопилот, 5 мин симуляции через Game.tick() в headless-цикле
## (без реального времени). ErrorCatcher — 0 ошибок/предупреждений на сочетание.
## Загрузка мира — через main._fly(s) напрямую (как test_game_flight.gd), без клика по меню.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const FLIGHT_S := 300.0
const MAX_GROUND_S := 20.0
const MAX_LOAD_FRAMES := 1200
const WINGS := ["wings/training", "wings/sport", "wings/kingpost"]
const WEATHERS := ["weather/weak", "weather/medium", "weather/strong"]

var failures: PackedStringArray = []
## Таблица результатов «сочетание → ok/ошибка» — печатается в конце прогона.
var _results: Array[String] = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_matrix_all_combinations() -> void:
	var locations := Config.list_configs("locations")
	check(not locations.is_empty(), "есть локации в configs/locations")
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in MAX_LOAD_FRAMES:
		if game.settings != null:
			break
		await get_tree().process_frame
	check(game.settings != null, "мир за меню загружен")
	if game.settings == null:
		main.queue_free()
		_print_results()
		return
	game.autopilot = Autopilot.new()
	(main.get("opts") as LaunchOptions).autostart = true
	game.process_mode = Node.PROCESS_MODE_DISABLED

	for loc_name in locations:
		var loc_id: String = loc_name.get_file()
		for wing in WINGS:
			for weather in WEATHERS:
				await _run_combo(main, game, loc_id, wing, weather)
	main.queue_free()
	get_tree().paused = false  # итог последнего полёта ставит дерево на паузу — не оставлять
	_print_results()


func _run_combo(main: Node, game: Game, loc_id: String, wing: String, weather: String) -> void:
	var label := "%s × %s × %s × into_site" % [loc_id, wing, weather]
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)

	var s := FlightSettings.new()
	s.location_id = loc_id
	s.wing = wing
	s.weather = weather
	s.wind_mode = "into_site"
	await main.call("_fly", s)  # game.start(s) уже вызывает restart()

	var ok := int(main.get("state")) == 2  # State.FLYING
	check(ok, "%s: состояние FLYING после «Лететь»" % label)
	var took_off := false
	if ok:
		var t := 0.0
		var t_air := 0.0
		var ended: Array = []
		var conn := func(k: String, info: Dictionary) -> void: ended.append([k, info])
		game.flight_ended.connect(conn)
		while t < MAX_GROUND_S + FLIGHT_S + 5.0 and ended.is_empty():
			game.tick(DT)
			t += DT
			if game.glider.phase() == "flying":
				t_air += DT
				if t_air >= FLIGHT_S:
					break
			elif t > MAX_GROUND_S and t_air == 0.0:
				break
		game.flight_ended.disconnect(conn)
		took_off = t_air > 0.0
		check(took_off, "%s: взлетел" % label)
		if not ended.is_empty():
			check(ended[0][0] != "takeoff_failed", "%s: взлёт не провален" % label)
			took_off = took_off and ended[0][0] != "takeoff_failed"
		game.autopilot.release_all()

	await get_tree().process_frame
	OS.remove_logger(catcher)
	var combo_ok := ok and took_off and catcher.errors.is_empty() and catcher.warnings.is_empty()
	for e in catcher.errors:
		failures.append("%s: ошибка в логе: %s" % [label, e])
	for w in catcher.warnings:
		failures.append("%s: предупреждение в логе: %s" % [label, w])
	_results.append("%-60s %s" % [label, ("ok" if combo_ok else "ошибка")])


func _print_results() -> void:
	print("\n== матрица стабильности: %d сочетаний ==" % _results.size())
	for r in _results:
		print("  " + r)
