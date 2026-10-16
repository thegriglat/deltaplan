extends Node
## Кадр слоя F7 (поток тепла H на рельефе, DebugOverlays). Запуск (временный профиль):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/heat_shot.tscn -- --out=<каталог> [флаги LaunchOptions…]
## Флаги игры (--location, --site, --hour, --wind, --from, --air-start …) передаются как есть,
## --autostart --autopilot добавляются сами. Пишет <out>/f7_*.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""
var _main: Node
var _game: Game
var _cam: Camera3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var game_args := PackedStringArray(["--autostart", "--autopilot"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		else:
			game_args.append(a)
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(game_args))
	add_child(_main)
	_run()


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var f := _out.path_join(name)
	get_viewport().get_texture().get_image().save_png(f)
	print("shot: ", f)


## Своя камера: сбоку от пилота поперёк ветра, выше и дальше — видно склон и сетку стрелок.
func _side_cam(dist: float, up: float, look_ahead: float) -> void:
	var p := _game.glider.global_position
	var w: Vector3 = _game.air.call("mean_wind_at", p)
	var wd := Vector3(w.x, 0, w.z).normalized() if w.length() > 0.1 else Vector3.FORWARD
	var side := wd.cross(Vector3.UP).normalized()
	if _cam == null:
		_cam = Camera3D.new()
		_cam.far = 60000.0
		_cam.fov = 60.0
		add_child(_cam)
	_cam.global_position = p + side * dist + Vector3.UP * up
	_cam.look_at(p + wd * look_ahead, Vector3.UP)
	_cam.current = true


func _run() -> void:
	_game = _main.get_node("Game")
	for i in 3000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	_game.camera.set_mode("chase")
	await _wait(6.0)
	await _shoot("f7_0_без.png")
	_press("debug_heat")
	await _wait(2.0)
	await _shoot("f7_1_погоня.png")
	_side_cam(2500.0, 1200.0, 1500.0)
	await _wait(1.0)
	await _shoot("f7_2_сверху.png")
	_press("debug_heat")
	_main.queue_free()
	for i in 3:
		await get_tree().process_frame
	get_tree().quit(0)
