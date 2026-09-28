extends Node
## Кадры костра с дымом в лагере у старта (Campfire, WorldObjects.place_camp).
## Запуск (окно нужно — настоящий рендер; профиль — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/campfire_shot.tscn -- --autostart --bots=4 --location=ongudai \
##     --wind=3 --from=launch --hour=13 --out=/tmp/fire --tag=w3 [--wait=8]
## Пишет <out>/<tag>_{launch,close,air300,air500}.png: с глаз пилота на старте на костёр,
## вблизи, с воздуха в 300 м и 500 м (сбоку от ветра — видно, куда сносит дым).

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 150.0

var _out := ""
var _tag := "fire"
var _wait := 8.0
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				_out = v
			"--tag":
				_tag = v
			"--wait":
				_wait = float(v)
	if _out == "":
		push_error("campfire_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("campfire_shot: FAIL (%s)" % why)
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
	var game: Game = _main.get_node("Game")
	for n in _main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	game.overlay.visible = false
	game.set("_crashed", true)
	var wo: WorldObjects = game.world_link.objects as WorldObjects
	if wo == null or wo.campfire == null:
		_fail("костра нет")
		return
	await get_tree().create_timer(_wait, true, false, true).timeout
	var fire: Vector3 = wo.campfire.global_position
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var w: Vector3 = wo.campfire.wind_low
	var wh: Vector3 = wo.campfire.wind_high
	print(
		(
			"campfire_shot: %s — костёр в %.0f м от старта, ветер у костра %.1f м/с (3 м), %.1f м/с (30 м)"
			% [_tag, Vector2(fire.x - sp.x, fire.z - sp.z).length(), w.length(), wh.length()]
		)
	)
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = 60.0
	var hgt := func(p: Vector3) -> Vector3:
		return Vector3(p.x, game.terrain.height_at(p.x, p.z), p.z)
	# сбоку от ветра (в штиль — сбоку от линии старт—костёр)
	var along := Vector3(wh.x, 0, wh.z)
	if along.length() < 0.5:
		along = Vector3(fire.x - sp.x, 0, fire.z - sp.z)
	along = along.normalized()
	var side := along.cross(Vector3.UP).normalized()
	# с площадки старта (в 8 м от точки старта к костру — крыло пилота не заслоняет)
	var to_f := Vector3(fire.x - sp.x, 0, fire.z - sp.z).normalized()
	await _shot(
		cam, hgt.call(sp + to_f * 8.0) + Vector3.UP * 1.7, fire + Vector3.UP * 8.0, "launch"
	)
	# вблизи: со стороны старта (там открыто — лагерь виден со старта)
	var cs := -to_f
	var ce: Vector3 = hgt.call(fire + cs * 11.0) + Vector3.UP * 1.7
	await _shot(cam, ce, fire + Vector3.UP * 3.5, "close")
	await _shot(cam, fire + side * 300.0 + Vector3.UP * 180.0, fire + Vector3.UP * 15.0, "air300")
	var s5 := side.rotated(Vector3.UP, 0.5)
	await _shot(cam, fire + s5 * 500.0 + Vector3.UP * 300.0, fire + Vector3.UP * 15.0, "air500")
	print("campfire_shot: OK %s" % _tag)
	await _quit(0)


func _shot(cam: Camera3D, eye: Vector3, target: Vector3, view: String) -> void:
	cam.look_at_from_position(eye, target)
	for i in 30:
		await RenderingServer.frame_post_draw
	var path := "%s/%s_%s.png" % [_out, _tag, view]
	var img := get_viewport().get_texture().get_image()
	print("campfire_shot: %s (%s)" % [path, error_string(img.save_png(path))])
