extends Node
## Разбег игрока через InputMap (С2 v2, docs/guide/flight.md → «Старт в сильный ветер»): Shift — разбег,
## трапеция «от себя» до упора в сильный ветер — нос за срывом, отрыва нет (отдельного срыва
## по носу нет, К3 v3).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAX_GROUND_S := 20.0
## Сколько игрок стоит перед разбегом, с (чувствует ветер в лицо).
const STAND_S := 0.5
const WINGS := ["wings/training", "wings/sport", "wings/laminar"]
## Прогноз [°C, км/ч] (встречный ветер на старте): слабый, средний, сильный день.
const WEATHERS := {"weak": [20.0, 7.0], "medium": [26.0, 11.0], "strong": [31.0, 18.0]}
## Моменты на часах атмосферы при старте (фаза порывов и термиков); 2415 и 4110 — из F01.
const SEEDS := [0.0, 300.0, 600.0, 1100.0, 1500.0, 2000.0, 2415.0, 3000.0, 3600.0, 4110.0]
const RUN_KEYS := ["run"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_nose_up_full_strong_wind_stalls() -> void:
	var main := await _open_main()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	for wing: String in ["wings/sport", "wings/laminar"]:
		await main.call("_fly", _settings("altai", wing, "strong"))
		var r := _launch(game, 0.0, true)
		# сорванное крыло не несёт; в порывах его может и опрокинуть на консоль (wingtip) — тоже не взлёт
		check(r != "air", "%s: от себя до упора в сильный ветер — %s (ждали: не взлетел)" % [wing, r])
	_release()
	main.queue_free()


func _open_main() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	if not menu.visible:
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
	s.temperature_c = float(WEATHERS[weather][0])
	s.wind_speed_kmh = float(WEATHERS[weather][1])
	return s


## Разбег игрока с того же старта при часах атмосферы sd: "air" | причина срыва | "none".
## nose_up — на бегу всё время держать «от себя» (pitch_push_out: нос вверх до упора).
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
		_press("pitch_push_out", nose_up and run)
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
	for a: String in RUN_KEYS + ["pitch_push_out", "pitch_pull_in"]:
		Input.action_release(a)
