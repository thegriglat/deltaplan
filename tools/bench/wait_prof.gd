extends Node
const MAIN_SCENE := preload("res://scenes/main.tscn")
func _ready() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.opts = LaunchOptions.new()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	var s := FlightSettings.defaults()
	s.start_hour = 12.0
	await main.call("_fly", s)
	game.set_physics_process(false)
	game._cfg["wait_refresh_s"] = float(OS.get_environment("WR")) if OS.get_environment("WR") != "" else 10.0
	game._cfg["wait_speed"] = float(OS.get_environment("WS")) if OS.get_environment("WS") != "" else 60.0
	game.start_wait()
	var ts: PackedFloat32Array = []
	for i in 1200:
		var a := Time.get_ticks_usec()
		game.tick(1.0 / 60.0)
		ts.append(float(Time.get_ticks_usec() - a) / 1000.0)
		if i % 4 == 3:
			await get_tree().process_frame
	var big := []
	for i in ts.size():
		if ts[i] > 20.0:
			big.append("%d:%.0f" % [i, ts[i]])
	var sum := 0.0
	for x in ts:
		sum += x
	ts.sort()
	print("PROF tick mean=%.2f p50=%.2f p99=%.1f max=%.1f; >20ms: %s" % [sum / ts.size(), ts[ts.size() / 2], ts[int(ts.size() * 0.99)], ts[-1], str(big)])
	get_tree().quit()
