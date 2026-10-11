extends Node
## Вывод движения в Game (MR-К1 v2): в полёте и в итоге после посадки пакеты идут; в меню (flying выключен)
## и на паузе — нет; после паузы поток начинается с reset().

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _ticks(game: Game, n: int) -> int:
	var before := game.motion.packets_sent
	for i in n:
		game.tick(DT)
	return game.motion.packets_sent - before


func test_no_packets_in_menu_and_pause() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	if game.settings == null:
		check(false, "мир за меню загружен")
		main.queue_free()
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", FlightSettings.defaults())
	var rx := PacketPeerUDP.new()
	check(rx.bind(0, "127.0.0.1") == OK, "bind")
	game.motion.enabled = true
	game.motion.host = "127.0.0.1"
	game.motion.port = rx.get_local_port()
	game.motion.every_n = 2
	game.motion.reset()
	check(game.flying_enabled, "в полёте")
	check(_ticks(game, 120) >= 55, "в полёте (стоя на земле) пакеты идут")
	game.set_paused(true)
	check(_ticks(game, 120) == 0, "на паузе пакетов нет")
	game.set_paused(false)
	check(_ticks(game, 120) >= 55, "после паузы пакеты снова идут")
	game.set_flying(false)  # выход в меню
	check(_ticks(game, 120) == 0, "в меню пакетов нет")
	rx.close()
	main.queue_free()
