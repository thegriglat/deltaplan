extends Node
## Сид мира в одиночной игре: «Лететь» из меню — новый случайный сид (другие термики), «Ещё раз»
## — тот же день, --seed=N — заданный день; --autostart без --seed — сид atmosphere.json (тесты и
## кадры не меняют раскладку). Сид — в ключе мира (Game.world_key): по нему день повторяется.
## Отпечаток мира — AtmoFingerprint.capture у настоящей атмосферы полёта в момент T_FP.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const T_FP := 60.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Главная сцена в меню + мир (load_menu_world); args — флаги запуска без --autostart.
func _open_menu(args: Array[String]) -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(args)))
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	check(game.settings != null, "мир за меню загружен")
	# не запоминать выбор «Полёт…» в user:// (как test_game_flight)
	(main.get("opts") as LaunchOptions).autostart = true
	return main


## «Лететь» из меню (сигнал кнопки) — до полёта.
func _menu_fly(main: Node) -> bool:
	var sm: StartMenu = main.get_node("UI/StartMenu")
	sm.fly_requested.emit(FlightSettings.defaults())
	for i in 900:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "«Лететь» — в полёте")
	return main.get("state") == 2


## Отпечаток мира полёта: атмосфера в момент T_FP (чистая функция ключа мира).
func _fp(game: Game) -> Dictionary:
	game.air.call("start_at", T_FP)
	return AtmoFingerprint.capture(game.air)


## Отпечаток эталонного мира по ключу (AtmoFingerprint.make_world) в момент T_FP.
func _key_fp(key: String) -> Dictionary:
	var a := AtmoFingerprint.make_world(key)
	a.start_at(T_FP)
	var fp := AtmoFingerprint.capture(a)
	a.free()
	return fp


func _close(main: Node) -> void:
	get_tree().paused = false
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func test_launch_option() -> void:
	check(LaunchOptions.parse(PackedStringArray([])).seed < 0, "без --seed — не задан")
	check(LaunchOptions.parse(PackedStringArray(["--seed=777"])).seed == 777, "--seed=777")
	var o := LaunchOptions.parse(PackedStringArray(["--net-host"]))
	check(not o.net_seed_set, "без --net-seed — зона со случайным сидом")
	check(LaunchOptions.parse(PackedStringArray(["--net-seed=5"])).net_seed_set, "--net-seed задан")


## Два «Лететь» — разные сиды и термики; «Ещё раз» — тот же сид и тот же мир.
func test_menu_fly_new_day_restart_same() -> void:
	var main: Node = await _open_menu([])
	var game: Game = main.get_node("Game")
	if not await _menu_fly(main):
		await _close(main)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var s1 := game.world_seed
	var k1 := game.world_key()
	var fp1 := _fp(game)
	check(s1 >= 0, "«Лететь» — сид выбран (%d)" % s1)
	check(k1.contains("seed=%d" % s1), "сид — в ключе мира: %s" % k1)
	check((fp1.thermals as Array).size() > 3, "термики есть (%d)" % (fp1.thermals as Array).size())
	# «Ещё раз» (R): тот же сид, тот же ключ мира — по нему тот же день (воздух идёт дальше, как
	# и раньше; день целиком повторяет ключ: эталонный мир ключа совпадает).
	main.call("_restart")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.world_seed == s1, "«Ещё раз» — тот же сид (%d / %d)" % [game.world_seed, s1])
	check(int(game.air.get("seed_value")) == s1, "атмосфера — на том же сиде")
	check(game.world_key() == k1, "«Ещё раз» — тот же ключ мира")
	var d_same := AtmoFingerprint.diff(_key_fp(k1), _key_fp(game.world_key()), 1.0e-3)
	check(d_same == "", "«Ещё раз» — тот же мир по ключу:\n%s" % d_same)
	# В меню и снова «Лететь»: новый день.
	game.process_mode = Node.PROCESS_MODE_INHERIT
	await main.call("_show_menu")
	if not await _menu_fly(main):
		await _close(main)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var s2 := game.world_seed
	check(s2 >= 0 and s2 != s1, "второй «Лететь» — новый сид (%d / %d)" % [s2, s1])
	check(game.world_key() != k1, "другой ключ мира")
	check(AtmoFingerprint.diff(fp1, _fp(game), 1.0e-3) != "", "другой сид — другие термики")
	var d_key := AtmoFingerprint.diff(_key_fp(k1), _key_fp(game.world_key()), 1.0e-3)
	check(d_key != "", "и по ключу мира — другой день")
	await _close(main)


## --seed=N: «Лететь» из меню каждый раз — тот же день.
func test_seed_option_fixes_day() -> void:
	var main: Node = await _open_menu(["--seed=777"])
	var game: Game = main.get_node("Game")
	if not await _menu_fly(main):
		await _close(main)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.world_seed == 777, "--seed=777 — сид 777 (%d)" % game.world_seed)
	check(game.world_key().contains("seed=777"), "в ключе мира: %s" % game.world_key())
	var fp1 := _fp(game)
	game.process_mode = Node.PROCESS_MODE_INHERIT
	await main.call("_show_menu")
	if not await _menu_fly(main):
		await _close(main)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.world_seed == 777, "второй «Лететь» — снова 777 (%d)" % game.world_seed)
	var d := AtmoFingerprint.diff(fp1, _fp(game), 1.0e-3)
	check(d == "", "тот же день:\n%s" % d)
	await _close(main)


## --autostart без --seed — сид atmosphere.json (раскладка тестов и кадров не меняется).
func test_autostart_uses_config_seed() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 900:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	check(game.world_seed < 0, "--autostart — сид не случайный (%d)" % game.world_seed)
	var cfg_seed := int(Config.value("atmosphere", "seed", 0))
	check(game.world_key().contains("seed=%d" % cfg_seed), "в ключе мира: %s" % game.world_key())
	await _close(main)
