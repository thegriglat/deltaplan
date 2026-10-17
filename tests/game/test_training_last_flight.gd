extends Node
## TI-16: полёт из «Тренировки» не перезаписывает last_flight пилота.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_save_rule() -> void:
	var main_script: GDScript = load("res://scenes/main.gd")
	check(main_script.saves_last_flight(false, false, false), "обычный полёт запоминается")
	check(not main_script.saves_last_flight(false, false, true), "тренировка — нет")
	check(not main_script.saves_last_flight(true, false, false), "autostart — нет")
	check(not main_script.saves_last_flight(false, true, false), "сеть — нет")


func test_menu_training_signal_wired() -> void:
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var m: StartMenu = main.get("start_menu")
	check(m.training_requested.get_connections().size() == 1, "training_requested подключён к main")
	check(m.fly_requested.get_connections().size() >= 1, "fly_requested по-прежнему подключён")
	main.queue_free()
