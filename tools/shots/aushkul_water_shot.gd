extends Node
## Скриншот воды/травы по полю у озера Аушкуль (AM-10, дополнение К0): своя камера над озером
## (терраса рельефа читается везде — Terrain грузит все чанки места сразу, не по камере), поле —
## из aushkul_water_field.py (не эталон, один случай для картинки). Нужно окно:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/aushkul_water_shot.tscn -- --autostart --bots=0 --location=aushkul \
##     --site=ridge_west --wind=4 --from=240 \
##     --air-field=tools/research/air3d/fields/game/aushkul_lake_w100_U4.json \
##     --lake-x=-3380 --lake-z=3660 --out=<каталог> --tag=<имя>

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 200.0

var _out := ""
var _tag := "aushkul"
var _lake := Vector2(-3380.0, 3660.0)
var _main: Node = null
var _game: Game = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out":
				_out = v
			"tag":
				_tag = v
			"lake-x":
				_lake.x = float(v)
			"lake-z":
				_lake.y = float(v)
	if _out == "":
		push_error("aushkul_water_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("aushkul_water_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	for i in 4000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = _main.get_node("Game")
	await get_tree().create_timer(2.0, true, false, true).timeout
	var mode := "аналитика"
	if _game.air.has_method("is_air_field_on") and bool(_game.air.call("is_air_field_on")):
		mode = "поле"
	print("aushkul_water_shot: режим ветра — %s, озеро (%.0f, %.0f)" % [mode, _lake.x, _lake.y])
	var terrain := _game.get_node_or_null("Terrain")
	var gh := 0.0
	if terrain != null and terrain.has_method("height_at"):
		gh = float(terrain.call("height_at", _lake.x, _lake.y))
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = 75.0
	var eye := Vector3(_lake.x - 1800.0, gh + 900.0, _lake.y - 1200.0)
	var target := Vector3(_lake.x, gh + 30.0, _lake.y)
	cam.look_at_from_position(eye, target, Vector3.UP)
	for i in 60:
		await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [_out, _tag]
	var img := get_viewport().get_texture().get_image()
	print("aushkul_water_shot: %s (%s)" % [path, error_string(img.save_png(path))])
	print("aushkul_water_shot: OK %s" % _tag)
	await _quit(0)
