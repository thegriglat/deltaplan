extends Node
## Сквозная проверка ачивок (ST-11): настоящий короткий полёт в главной сцене → поток S2 (AchievementFeed)
## → автозагрузка Achievements → user://-прогресс и подставной Steam (setAchievement + storeStats).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const Service := preload("res://scripts/steam/steam_service.gd")
const Fake := preload("res://tests/steam/fake_steam_ach.gd")
const PATH := "user://test_achievements_e2e.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_flight_opens_first_flight() -> void:
	var ach := get_node_or_null("/root/Achievements")
	check(ach != null, "автозагрузка Achievements есть")
	if ach == null:
		return
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
	var old_path: String = ach.progress_path
	var old_service: Node = ach.service
	var fake := Fake.new()
	var svc := Service.new()
	svc.configure(["--steam"], [], true, fake)
	check(svc.is_active(), "подставной Steam активен")
	ach.progress_path = PATH
	ach.service = svc
	ach.start()
	check(not ach.is_unlocked("ACH_FIRST_FLIGHT"), "до полёта не открыта")
	var got: Array = []
	ach.unlocked.connect(func(api: String) -> void: got.append(api))

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
	# Полёт: набор 12 с в воздухе, затем низко носом в гору — посадка.
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 150.0
	game.glider.reset_in_air(p, float(st.heading_deg))
	for i in 120 * 12:
		game.tick(DT)
	# Мягкое касание: у самой земли, почти без скорости относительно неё (как test_landing).
	p.y = game.terrain.height_at(p.x, p.z) + 1.5
	game.glider.reset_in_air(p, float(st.heading_deg))
	game.glider.model.velocity = Vector3(0.0, -1.0, 0.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, _i: Dictionary) -> void: ended.append(k))
	for i in 120 * 20:
		game.tick(DT)
		if not ended.is_empty():
			break
	for i in 240:
		game.tick(DT)
	check(ended.size() == 1 and ended[0] == "landed", "посадка: %s" % [ended])

	check(ach.is_unlocked("ACH_FIRST_FLIGHT"), "ACH_FIRST_FLIGHT открыта")
	check(got.count("ACH_FIRST_FLIGHT") == 1, "сигнал unlocked один раз: %s" % [got])
	check(fake.set_calls.count("ACH_FIRST_FLIGHT") == 1, "setAchievement один раз: %s" % [fake.set_calls])
	check(fake.store_calls >= 1, "storeStats вызван (%d)" % fake.store_calls)
	check(fake.achieved.has("ACH_FIRST_FLIGHT"), "в подставном Steam открыта")

	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	check(data is Dictionary, "user://-файл прогресса читается")
	if data is Dictionary:
		check((data.unlocked as Dictionary).has("ACH_FIRST_FLIGHT"), "unlocked в файле")
		check(int(data.flights) == 1, "flights == 1 (%s)" % data.flights)
		check((data.places as Array).size() == 1 and String((data.places as Array)[0]).contains("/"),
				"places: %s" % [data.places])
		check((data.wings as Array).size() == 1, "wings: %s" % [data.wings])
		check(float(data.airtime_s) > 1.0, "airtime_s %s" % data.airtime_s)

	main.queue_free()
	get_tree().paused = false
	await get_tree().process_frame
	ach.progress_path = old_path
	ach.service = old_service
	svc.free()
	fake.free()
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
