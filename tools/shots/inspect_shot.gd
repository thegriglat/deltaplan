extends Node
## Кадр режима «Осмотр карты» со стрелками ветра (упрощённый воздух — решатель на GPU не нужен).
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1280x720 \
##     res://tools/shots/inspect_shot.tscn -- --out=/path/inspect.png

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	get_tree().create_timer(120.0, true, false, true).timeout.connect(get_tree().quit.bind(1))
	_run()


func _run() -> void:
	Config.get_config("atmosphere").air_model["enabled"] = "off"
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	(main.get("opts") as LaunchOptions).autostart = true
	var s := FlightSettings.defaults()
	s.wind_speed_kmh = 25.0
	await main.call("_fly", s, true)
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var sp: Vector3 = game.get_start().position
	game.camera.global_position = sp + Vector3(0, 120, 0) + Vector3(300, 0, 300)
	for i in 240:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("inspect_shot: saved ", _out)
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)
