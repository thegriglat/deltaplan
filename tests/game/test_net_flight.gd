extends Node
## Сетевой режим полёта (NET-40): правила режима без сети — NetZone/NetPilots подменены.
## Время только ×1, мир — на часах зоны (join, пауза и «На старт» его не сбивают), кнопки итога
## в сети, фазы для PilotState, одиночная игра — как раньше (пауза останавливает дерево).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


## Зона: часы задаёт тест (clock), ключ мира — как у создателя.
class FakeZone:
	extends RefCounted
	var in_zone := true
	var has_clock := true
	var clock := 0.0
	var world_seed := 4711
	var bots_count := 0
	var my_id := "1"
	var peers := {"1": {"id": "1", "name": "Коля", "joinOrder": 1}}
	var zone := {}
	var checked_key := ""

	func zone_time() -> float:
		return clock

	func check_world(key: String) -> bool:
		checked_key = key
		return key == String(zone.get("worldKey", key))


## NetPilots: своё — запоминает, чужих нет.
class FakePilots:
	extends RefCounted
	signal pilot_lost(id: String)
	var local := {}

	func set_local_state(
		pos: Vector3, rot: Quaternion, vel: Vector3, phase: String, wing: String, colors: Variant
	) -> void:
		local = {"pos": pos, "rot": rot, "vel": vel, "phase": phase, "wing": wing, "colors": colors}

	func clear_local_state() -> void:
		local = {}

	func get_pilot_ids() -> Array[String]:
		return []

	func sample(_id: String) -> Dictionary:
		return {}


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


func test_proto_phases() -> void:
	check(NetFlight.proto_phase("standing") == "STAND", "стоит")
	check(NetFlight.proto_phase("walking") == "WALK", "идёт")
	check(NetFlight.proto_phase("running") == "RUN", "бежит")
	check(NetFlight.proto_phase("flying") == "FLY", "летит")
	check(NetFlight.proto_phase("landed") == "LANDED", "сел")
	check(NetFlight.proto_phase("landed", true) == "CRASHED", "авария на касании")
	check(NetFlight.proto_phase("failed") == "CRASHED", "сорванный старт")
	check(NetFlight.proto_phase("flying", true) == "FLY", "в воздухе авария не считается")


func test_world_step_follows_zone_clock() -> void:
	approx(NetFlight.step_for(0.0), 0.0, 1e-9, "вровень — стоим")
	approx(NetFlight.step_for(0.016), 0.016, 1e-9, "кадр")
	approx(NetFlight.step_for(-0.5), 0.0, 1e-9, "мир впереди часов — ждёт")
	approx(NetFlight.step_for(7.0), NetFlight.MAX_STEP_S, 1e-9, "долгий кадр — догоняет шагами")


func test_airborne_friends_for_continue_nearby() -> void:
	var ground := {"is_bot": false, "phase": "landed"}
	var bot_air := {"is_bot": true, "phase": "flying"}
	var friend_air := {"is_bot": false, "phase": "flying"}
	var friend_tow := {"is_bot": false, "phase": "tow"}
	check(NetFlight.count_airborne([]) == 0, "никого")
	check(NetFlight.count_airborne([ground, bot_air]) == 0, "в воздухе только бот")
	check(NetFlight.count_airborne([ground, friend_air]) == 1, "друг в воздухе")
	check(NetFlight.count_airborne([friend_tow, friend_air]) == 2, "на буксире — тоже в воздухе")


func test_colors_stable_by_name() -> void:
	var a: Variant = NetFlight.colors_for("Коля")
	check(a is Dictionary and (a as Dictionary).has("hueDeg"), "расцветка {hueDeg, sat, value}")
	check(str(a) == str(NetFlight.colors_for("Коля")), "та же от полёта к полёту")


func test_world_settings_from_key_own_wing() -> void:
	var host := FlightSettings.defaults()
	host.start_hour = 15.5
	host.sky = "partly"
	var z := FakeZone.new()
	z.zone = {"worldKey": host.world_key(4711, 3)}
	var mine := FlightSettings.defaults()
	mine.wing = "wings/laminar"
	mine.pilot_mass_kg = 93.0
	mine.start_hour = 9.0
	var s := NetFlight.world_settings(z, mine)
	approx(s.start_hour, 15.5, 1e-6, "час — зоны")
	check(s.sky == "partly", "облачность — зоны")
	check(s.wing == "wings/laminar", "крыло своё")
	approx(s.pilot_mass_kg, 93.0, 1e-6, "масса своя")
	check(s.world_key(4711, 3) == host.world_key(4711, 3), "ключ мира совпал с ключом создателя")


func test_result_screen_net_buttons() -> void:
	var rs: ResultScreen = (load("res://scenes/ui/result_screen.tscn") as PackedScene).instantiate()
	add_child(rs)
	var near: Button = rs.get("_near")
	var to_start: Button = rs.get("_to_start")
	var again: Button = rs.get("_again")
	check(not near.visible and not to_start.visible and again.visible, "одиночная: как раньше")
	rs.set_net_mode(true, false)
	check(not near.visible and to_start.visible and not again.visible, "сеть, в воздухе никого")
	rs.set_net_mode(true, true)
	check(near.visible and to_start.visible and rs.is_near_shown(), "сеть, друг в воздухе")
	var got := []
	rs.continue_near_requested.connect(func() -> void: got.append("near"))
	rs.to_start_requested.connect(func() -> void: got.append("start"))
	near.pressed.emit()
	to_start.pressed.emit()
	check(got == ["near", "start"], "сигналы кнопок (%s)" % [got])
	rs.set_net_mode(false, true)
	check(not near.visible and not to_start.visible and again.visible, "снова одиночная")
	rs.queue_free()


## Главная сцена: сетевой полёт на подменённой зоне — часы ×1, мир на часах зоны, пауза и
## «На старт» мир не останавливают и не сбрасывают, итог с кнопками сети, выход — в одиночную.
func test_net_flight_rules_in_main_scene() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	check(game.settings != null, "мир за меню загружен")
	if game.settings == null:
		main.queue_free()
		return
	(main.get("opts") as LaunchOptions).autostart = true  # не запоминать выбор в user://

	# Одиночная игра: пауза останавливает дерево.
	var s := FlightSettings.defaults()
	await main.call("_fly", s)
	main.call("_pause")
	check(get_tree().paused, "одиночная: пауза останавливает мир")
	main.call("_resume")
	check(not get_tree().paused, "одиночная: продолжить")

	var zone := FakeZone.new()
	zone.zone = {"worldKey": s.world_key(zone.world_seed, 0)}
	zone.clock = 100.0
	var pilots := FakePilots.new()
	main.call("_show_menu")
	game.sky.clock.speed = 60.0  # ускорение времени из настроек
	game.enable_net(NetFlight.new(), zone, pilots)
	approx(game.sky.clock.speed, 1.0, 1e-9, "в сети часы ×1")
	await main.call("_fly", s)
	check(main.get("state") == 2, "сетевой полёт начался")
	approx(game.sky.clock.speed, 1.0, 1e-9, "часы ×1 и после старта")
	game.apply_user_settings()
	approx(game.sky.clock.speed, 1.0, 1e-9, "настройки не включают ускорение в сети")
	approx(game.world_time(), 100.0, 1e-6, "мир — на часах зоны")
	approx(game.sky.clock.hour, s.start_hour + 100.0 / 3600.0, 1e-6, "время суток — зоны")
	check(zone.checked_key == s.world_key(zone.world_seed, 0), "ключ мира сверен с зоной")
	check(game.get_node_or_null("RemotePilots") != null, "чужие пилоты — в мире")
	# Дальше шагаем сами (Game.start ждёт поля рельефа из Terrain._process — до него нельзя).
	game.process_mode = Node.PROCESS_MODE_DISABLED

	# Пауза: мир идёт по часам зоны, дерево не стоит.
	main.call("_pause")
	check(not get_tree().paused, "сеть: пауза не останавливает дерево")
	check(main.get("state") == 3, "меню паузы открыто")
	zone.clock = 103.0
	for i in 4:
		game.tick(DT)
	approx(game.world_time(), 103.0, 1e-6, "на паузе мир догнал часы зоны")
	approx(game.sky.clock.hour, s.start_hour + 103.0 / 3600.0, 1e-6, "и время суток")
	await get_tree().process_frame
	check(String(pilots.local.get("phase", "")) != "", "своё состояние уходит и на паузе")
	main.call("_resume")
	approx(game.world_time(), 103.0, 1e-6, "после паузы — без скачка")

	# Долгий кадр: мир догоняет часы зоны, не отстаёт.
	zone.clock = 110.0
	for i in 5:
		game.tick(DT)
	approx(game.world_time(), 110.0, 1e-6, "после долгого кадра — вровень с зоной")

	# «Ещё раз» / «На старт» мир не сбрасывает.
	game.restart()
	approx(game.world_time(), 110.0, 1e-6, "«Ещё раз» не сбрасывает мир")
	approx(game.sky.clock.hour, s.start_hour + 110.0 / 3600.0, 1e-6, "и часы")

	# Итог: окно с кнопками сети, мир не на паузе.
	var rs: ResultScreen = main.get("result_screen")
	main.call("_show_result", "landed", {"grade": "soft"})
	check(not get_tree().paused, "итог в сети: мир идёт")
	check(not rs.is_near_shown(), "в воздухе никого — «Продолжить рядом» нет")
	game.net.remote.upsert({"pilot_id": "2", "name": "Маша", "phase": "FLY", "pos": Vector3.ZERO})
	main.call("_on_net_airborne_changed", game.net.friends_airborne())
	check(rs.is_near_shown(), "друг в воздухе — «Продолжить рядом»")
	main.call("_on_result_to_start")
	check(main.get("state") == 2 and not rs.visible, "«На старт» — снова в полёт")
	approx(game.world_time(), 110.0, 1e-6, "«На старт» не сбрасывает мир")

	# Выход из зоны — одиночная игра.
	main.call("_show_menu")
	check(game.net == null, "сетевой режим выключен")
	var rp := game.get_node_or_null("RemotePilots")
	check(rp == null or rp.is_queued_for_deletion(), "чужие убраны")
	check(pilots.local.is_empty(), "своё больше не шлётся")
	get_tree().paused = false
	main.queue_free()
	await get_tree().process_frame
