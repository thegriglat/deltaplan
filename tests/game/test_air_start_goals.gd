extends Node
## ASM-К4: старт в воздухе — цели от точки постановки, рекорды и достижения не засчитываются,
## в итоге пометка. Главная сцена, шаги — Game.tick вручную (как test_goals_game.gd).
## Место грузится один раз на файл: сценарии идут подряд в одном тесте.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const RECORDS := "user://test_air_start_goals_records.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_air_start_goals_records_feed() -> void:
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

	# --- старт в воздухе через настройки (ASM-К1)
	var a := game.settings.duplicate()
	a.goals = [GoalSpec.make("height", "custom", 100.0), GoalSpec.make("distance", "custom", 5000.0)]
	a.set_air_start(200.0)
	await game.start(a)
	check(game.is_air_start(), "с настройкой — старт в воздухе")
	if not game.is_air_start() or game.goals == null:
		failures.append("старт в воздухе не состоялся")
		await _end(main)
		return
	var p := game.air_start_position()
	check(game.goals._ctx.start_pos.is_equal_approx(p), "цели: start_pos = точка постановки")
	check(not game.feed.active, "feed не активен после старта")
	for i in 120 * 3:
		game.tick(DT)
	check(not game.feed.active, "feed не активен в полёте")
	var items: Array = game.goals.items()
	check(float(items[0].current) < 30.0, "набор от высоты постановки ≈ 0: %s" % items[0].current)
	check(float(items[1].current) < 400.0, "дальность от проекции точки: %s" % items[1].current)

	# --- посадка: рекорды не пишутся, пометка в итоге
	# Итог посадки собираем напрямую: на склоне с ветром 7 м/с посадку за разумное время не дождаться.
	var ended: Array = []
	game.flight_ended.connect(func(k: String, i: Dictionary) -> void: ended.append([k, i]))
	game.stats.took_off = true
	game._emit_end("landed", {"grade": "soft", "flight_time_s": 120.0, "distance_m": 2500.0, "max_altitude_msl_m": 1800.0})
	check(not ended.is_empty(), "полёт закончился")
	if not ended.is_empty():
		var info: Dictionary = ended[0][1]
		check(bool(info.get("air_start", false)), "info.air_start")
		check((info.get("new_records", {"x": 1}) as Dictionary).is_empty(), "new_records пуст")
		check(not FileAccess.file_exists(RECORDS), "файл рекордов не создан")
		var txt := "\n".join(ResultScreen.lines_for(ended[0][0], info))
		check(txt.contains(TranslationServer.translate("result_air_start_note")), "пометка в строках итога")
	check(not game.feed.active, "feed не активен после итога")

	# --- с земли (флаг сброшен): контекст целей — от наземного старта, всё как раньше
	game.air_start_m = -1.0
	check(not game.is_air_start(), "air_start_m < 0 — не воздух")
	check(game._goals_ctx().start_pos == game._start_pos, "земля: start_pos = _start_pos")
	var gi := {"grade": "soft", "flight_time_s": 120.0, "distance_m": 2500.0, "max_altitude_msl_m": 1800.0}
	game.stats.took_off = true
	game._goals_finish("landed", gi)
	check((gi.get("new_records", {}) as Dictionary).has("flight_time_s"), "земля: рекорды пишутся")
	check(not gi.has("air_start"), "земля: без air_start")

	# --- lines_for без пометки при наземном итоге
	var ground := "\n".join(ResultScreen.lines_for("landed", {"flight_time_s": 10.0}))
	check(not ground.contains(TranslationServer.translate("result_air_start_note")), "земля: без пометки")
	await _end(main)


func _end(main: Node) -> void:
	get_tree().paused = false
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	if FileAccess.file_exists(RECORDS):
		DirAccess.remove_absolute(RECORDS)
