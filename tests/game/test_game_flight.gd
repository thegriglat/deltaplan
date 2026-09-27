extends Node
## Интеграция: главная сцена грузится, синтетический пилот (Autopilot жмёт клавиши InputMap)
## стоит → разбегается (Shift) → взлетает → летит 30 с. В логе нет ошибок.
## Шаги физики — Game.tick() вручную (тот же порядок, что в игре), поэтому тест быстрый.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const FLIGHT_S := 30.0
const MAX_GROUND_S := 15.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_main_scene_autopilot_flight() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	# Меню поднимает мир за собой асинхронно — дождаться.
	for i in 600:
		if game.settings != null:
			break
		await get_tree().process_frame
	check(game.settings != null, "мир за меню загружен")
	check(main.get_node("UI/StartMenu").visible, "меню видно")
	if game.settings == null:
		_finish(main, catcher)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	var s := FlightSettings.defaults()
	s.wing = "wings/sport"
	s.site_id = "sinyukha_west"
	s.wind_mode = "into_site"
	(main.get("opts") as LaunchOptions).autostart = true  # не запоминать выбор в user://
	await main.call("_fly", s)
	check(main.get("state") == 2, "состояние FLYING после «Лететь»")
	check(game.air is Atmosphere, "настоящая атмосфера (%s)" % game.air.get_script())
	check(not game.mounted.is_empty() and game.mounted[0].is_inside_tree(), "прибор на трапеции")
	game.autopilot = Autopilot.new()
	game.restart()

	var phases := {}
	var ended: Array = []
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))
	var t_air := 0.0
	var t := 0.0
	while t < MAX_GROUND_S + FLIGHT_S + 5.0 and ended.is_empty():
		game.tick(DT)
		t += DT
		var ph := game.glider.phase()
		phases[ph] = true
		if ph == "flying":
			t_air += DT
			if t_air >= FLIGHT_S:
				break
		elif t > MAX_GROUND_S and t_air == 0.0:
			break
	var tel := game.glider.get_telemetry()
	print(
		(
			"         фазы %s, в воздухе %.1f с, AGL %.0f м, V %.0f км/ч, от старта %.0f м"
			% [
				phases.keys(),
				t_air,
				tel.altitude_agl,
				Units.to_kmh(tel.airspeed),
				game.stats.distance_from_takeoff(tel.position)
			]
		)
	)
	check(phases.has("standing"), "стоял на старте")
	check(phases.has("running"), "разбегался")
	check(ended.is_empty(), "полёт не закончился раньше времени: %s" % [ended])
	check(t_air >= FLIGHT_S, "летел %.0f с (нужно %.0f)" % [t_air, FLIGHT_S])
	check(game.stats.took_off, "статистика увидела взлёт")
	check(game.instrument.get_vario().in_flight, "прибор считает полёт")
	check(game.stats.distance_from_takeoff(tel.position) > 150.0, "улетел от старта")
	game.autopilot.release_all()
	_finish(main, catcher)


func test_landing_shows_result_screen() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	(main as Node).set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	# Низко над склоном, носом в гору: через пару секунд — касание.
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 3.0
	game.glider.reset_in_air(p, float(st.heading_deg) + 180.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, _i: Dictionary) -> void: ended.append(k))
	for i in 120 * 20:
		game.tick(DT)
		if not ended.is_empty():
			break
	check(ended == ["landed"], "посадка: %s" % [ended])
	await get_tree().create_timer(float(Config.value("game", "result_delay_s")) + 0.3).timeout
	var rs: Control = main.get_node("UI/ResultScreen")
	check(rs.visible, "экран итога показан")
	check(get_tree().paused, "игра на паузе под экраном итога")
	main.call("_restart")
	check(not get_tree().paused and not rs.visible, "«Ещё раз» — снова в полёте")
	check(game.glider.phase() == "standing", "на старте")
	get_tree().paused = false
	main.queue_free()


func _finish(main: Node, catcher: ErrorCatcher) -> void:
	main.queue_free()
	OS.remove_logger(catcher)
	for e in catcher.errors:
		failures.append("ошибка в логе: " + e)
