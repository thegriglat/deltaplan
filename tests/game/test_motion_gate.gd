extends Node
## Вывод движения в Game (MR-К1 v3 «Кто зовёт»): автозагрузка MotionRig владеет отправкой; в полёте — live, на паузе и
## осмотре — hold, в меню — neutral; пакеты идут во всех состояниях (60 в секунду), без дублей в одном тике.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _ticks(game: Game, n: int) -> int:
	var out: MotionOutput = MotionRig.output
	var before := out.packets_sent - out.repeats_sent
	for i in n:
		game.tick(DT)
		MotionRig.advance(DT)  # как _physics_process автозагрузки, после Game
	return out.packets_sent - out.repeats_sent - before


func test_packets_in_every_state() -> void:
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
	var out: MotionOutput = MotionRig.output
	var cfg: Dictionary = Config.get_config("motion_rig")
	var saved: Dictionary = cfg.duplicate(true)
	cfg["enabled"] = true
	cfg["port"] = rx.get_local_port()
	cfg["ramp_s"] = 0.0
	MotionRig.set_physics_process(false)  # шагаем сами: без дублей
	out.configure()
	MotionRig.reset()
	check(game.flying_enabled and out.is_attached(), "в полёте сцена присоединена")
	var n_live := _ticks(game, 120)
	check(absi(n_live - 60) <= 1 and out.last_mode == MotionOutput.Mode.LIVE, "в полёте (стоя) ≈60 пакетов, live: %d, режим %d" % [n_live, out.last_mode])
	game.set_paused(true)
	check(absi(_ticks(game, 120) - 60) <= 1 and out.last_mode == MotionOutput.Mode.HOLD, "на паузе 60 пакетов, hold")
	game.set_paused(false)
	check(absi(_ticks(game, 120) - 60) <= 1 and out.last_mode == MotionOutput.Mode.LIVE, "после паузы снова live")
	game.set_flying(false)  # выход в меню
	check(not out.is_attached(), "в меню сцена отсоединена")
	check(absi(_ticks(game, 120) - 60) <= 1 and out.last_mode == MotionOutput.Mode.NEUTRAL, "в меню 60 пакетов, neutral")
	cfg.clear()
	cfg.merge(saved)
	out.configure()
	out.shutdown()
	MotionRig.set_physics_process(true)
	rx.close()
	main.queue_free()


func test_rig_ticks_after_game() -> void:
	check(MotionRig.process_physics_priority > 0, "MotionRig тикает после Game (приоритет)")
	check(MotionRig.process_mode == Node.PROCESS_MODE_ALWAYS, "MotionRig тикает и на паузе дерева")
