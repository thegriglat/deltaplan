extends Node
## Кадр с воздуха над посёлком (NO-2): дома в пятнах застройки. Аргументы: --out=путь --pos=x,z,высота_над_землёй --target=x,z.
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1280x720 \
##     res://tools/shots/villages_shot.tscn -- --out=/path/inspect.png

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""
var _pos := Vector3(-1780.0, 250.0, -7800.0)
var _target := Vector2(-1780.0, -8188.0)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--pos="):
			var q := a.substr(6).split(",")
			_pos = Vector3(float(q[0]), float(q[2]), float(q[1]))
		elif a.begins_with("--target="):
			var q := a.substr(9).split(",")
			_target = Vector2(float(q[0]), float(q[1]))
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
	s.location_id = "askarovo"
	await main.call("_fly", s, false)
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var cam: CameraRig = game.camera
	cam.set_mode("free")
	var ground: float = game.terrain.height_at(_pos.x, _pos.z)
	var eye := Vector3(_pos.x, ground + _pos.y, _pos.z)
	var d := Vector3(_target.x, game.terrain.height_at(_target.x, _target.y), _target.y) - eye
	for i in 240:
		cam.global_position = eye
		cam._free_rot = Vector2(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("villages_shot: saved ", _out)
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)
