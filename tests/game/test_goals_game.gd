extends Node
## GL-4: цели в игре (GL-К1, GL-К3) — GoalTracker создаётся при старте с целями (не в сети), ведёт
## его телеметрия и посадка, «Ещё раз» сбрасывает; итог — info.goals и новые рекорды.
## Главная сцена, шаги — Game.tick вручную (как tests/game/test_game_flight.gd).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const RECORDS := "user://test_goals_game_records.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _boot() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.records_path = RECORDS
	if FileAccess.file_exists(RECORDS):
		DirAccess.remove_absolute(RECORDS)
	return [main, game]


func _end(main: Node) -> void:
	get_tree().paused = false
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	if FileAccess.file_exists(RECORDS):
		DirAccess.remove_absolute(RECORDS)


func _start_with(game: Game, goals: Array) -> void:
	var s := game.settings.duplicate()
	s.goals = goals
	await game.start(s)


func test_tracker_created_only_with_goals() -> void:
	var b := await _boot()
	var main: Node = b[0]
	var game: Game = b[1]
	check(main.get("state") == 2, "автостарт — в полёте")
	check(game.goals == null, "без целей трекера нет")
	check(not game.goal_list.is_shown(), "список целей скрыт без целей")
	var goals := [GoalSpec.make("height", "easy", 100.0), GoalSpec.make("landing", "easy", 50.0)]
	await _start_with(game, goals)
	check(game.goals != null, "с целями трекер создан")
	if game.goals != null:
		check(game.goals.items().size() == 2, "две цели")
		check(game.goal_list.lines().size() == 2, "две строки списка: %s" % [game.goal_list.lines()])
		check(game.goal_list.is_shown(), "список виден в полёте")
	# неверный список (повтор вида) — пропущен
	await _start_with(game, [GoalSpec.make("height", "easy", 100.0), GoalSpec.make("height", "easy", 50.0)])
	check(game.goals == null, "неверный список пропущен")
	# сеть — целей нет
	game.settings.goals = goals
	game.net = NetFlight.new()
	game._goals_setup()
	check(game.goals == null, "в сети трекера нет")
	game.net.free()
	game.net = null
	await _start_with(game, [])
	check(game.goals == null, "пустой список — трекера нет")
	await _end(main)


func test_landing_result_and_restart() -> void:
	var b := await _boot()
	var main: Node = b[0]
	var game: Game = b[1]
	await _start_with(game, [GoalSpec.make("duration", "custom", 0.5), GoalSpec.make("height", "custom", 5000.0)])
	check(game.goals != null, "трекер создан")
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 12.0
	game.glider.reset_in_air(p, float(st.heading_deg) + 180.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, i: Dictionary) -> void: ended.append([k, i]))
	for i in 120 * 20:
		game.tick(DT)
		if not ended.is_empty():
			break
	check(not ended.is_empty() and ended[0][0] == "landed", "посадка: %s" % [ended.map(func(e): return e[0])])
	if not ended.is_empty():
		var info: Dictionary = ended[0][1]
		check(info.has("goals"), "в итоге есть goals")
		var g: Dictionary = info.get("goals", {})
		check(int(g.get("total", 0)) == 2, "две доступные цели")
		var items: Array = g.get("goals", [])
		if items.size() == 2:
			check(items[0].status == "done", "время в воздухе засчитано: %s" % items[0].status)
			check(items[1].status == "failed", "высота не взята: %s" % items[1].status)
		check(int(g.get("done", -1)) == 1, "выполнена одна")
		var lines := ResultScreen.lines_for("landed", info)
		check("\n".join(lines).contains(TranslationServer.translate("goals_kind_duration")), "цели — в строках итога")
	game.restart()
	for it: Dictionary in game.goals.items():
		check(it.status == "pending", "после restart все pending: %s" % it.kind)
	check(game.goal_list.lines().size() == 2, "список после restart")
	await _end(main)


func test_new_records() -> void:
	var b := await _boot()
	var main: Node = b[0]
	var game: Game = b[1]
	await _start_with(game, [GoalSpec.make("duration", "custom", 1.0)])
	game.stats.took_off = true
	var info := {"grade": "soft", "flight_time_s": 120.0, "distance_m": 2500.0, "max_altitude_msl_m": 1800.0}
	game._goals_finish("landed", info)
	var rec: Dictionary = info.get("new_records", {})
	check(rec.has("flight_time_s") and rec.has("distance_m"), "первый полёт — рекорды: %s" % [rec.keys()])
	check(rec.get("flight_time_s", {}).get("previous", 1) == null, "раньше не было")
	var lines := ResultScreen.lines_for("landed", info)
	check("\n".join(lines).contains("120") or "\n".join(lines).contains("2:00"), "рекорд — в строках: %s" % [lines])
	var again := {"grade": "soft", "flight_time_s": 60.0, "distance_m": 100.0, "max_altitude_msl_m": 10.0}
	game._goals_finish("landed", again)
	check((again.new_records as Dictionary).is_empty(), "хуже прошлого — рекордов нет")
	var better := {"grade": "soft", "flight_time_s": 300.0, "distance_m": 100.0, "max_altitude_msl_m": 10.0}
	game._goals_finish("landed", better)
	check((better.new_records as Dictionary).has("flight_time_s"), "лучше — рекорд")
	check(float(better.new_records.flight_time_s.previous) == 120.0, "было 120 с")
	await _end(main)
