extends Node
## Кадры тропы к старту (StartTracks) — до/после смягчения вида (docs/world_objects.md).
## Запуск (окно нужно — настоящий рендер; под timeout 120):
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/tracks_shot.tscn -- --autostart --location=ongudai --site=kayancha_south \
##     --out=/tmp/tracks
## Пишет <out>/<локация>_<старт>_{ground,side,air150,air400}.png: с земли у старта вдоль тропы
## (глаза пилота), сбоку от тропы, сверху с 150 м, сверху с 400 м.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 110.0

var _out := ""
var _main: Node = null


func _ready() -> void:
	var site := ""
	var loc := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--site="):
			site = a.substr(7)
		elif a.begins_with("--location="):
			loc = a.substr(11)
	if _out == "":
		push_error("tracks_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run_world("%s_%s" % [loc, site])


func _fail(why: String) -> void:
	print("tracks_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _run_world(tag: String) -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	for i in 3000:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	var game: Game = main.get_node("Game")
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var wo: WorldObjects = game.world_link.objects as WorldObjects
	var starts: Array = game.terrain.get_start_sites()
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var idx := 0
	var best_d := INF
	for i in starts.size():
		var d: float = Vector3(starts[i].position).distance_to(sp)
		if d < best_d:
			best_d = d
			idx = i
	if wo == null or wo.start_tracks.size() <= idx:
		_fail("нет тропы")
		return
	var pts: PackedVector2Array = wo.start_tracks[idx]
	if pts.size() < 2:
		_fail("тропа пуста")
		return
	print("tracks_shot: %s — тропа из %d точек" % [tag, pts.size()])
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.fov = 60.0
	cam.current = true
	var h := func(p: Vector2) -> Vector3: return Vector3(p.x, game.terrain.height_at(p.x, p.y), p.y)
	# 1. с земли у старта: глаза пилота, взгляд вдоль тропы вниз по склону.
	var p1: Vector2 = pts[mini(3, pts.size() - 1)]
	var eye: Vector3 = h.call(pts[0]) + Vector3.UP * 1.7
	var look: Vector3 = h.call(p1) + Vector3.UP * 1.2
	await _shot(cam, eye, look, "%s/%s_ground.png" % [_out, tag])
	# 2. сбоку от тропы: середина пути, вид поперёк, старт на плане.
	var mid_i := pts.size() / 2
	var mid: Vector2 = pts[mid_i]
	var a: Vector2 = pts[maxi(mid_i - 1, 0)]
	var b: Vector2 = pts[mini(mid_i + 1, pts.size() - 1)]
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x)
	var eye_xz: Vector2 = mid + side * 10.0 - dir * 4.0
	eye = h.call(eye_xz) + Vector3.UP * 2.2
	look = h.call(mid) + Vector3.UP * 0.6
	await _shot(cam, eye, look, "%s/%s_side.png" % [_out, tag])
	# 3. сверху со 150 м над стартом, взгляд вдоль тропы вниз.
	var far_pt: Vector2 = pts[pts.size() - 1]
	eye = sp + Vector3.UP * 150.0
	look = Vector3(far_pt.x, game.terrain.height_at(far_pt.x, far_pt.y), far_pt.y)
	await _shot(cam, eye, look, "%s/%s_air150.png" % [_out, tag])
	# 4. сверху с 400 м.
	eye = sp + Vector3.UP * 400.0
	await _shot(cam, eye, look, "%s/%s_air400.png" % [_out, tag])
	print("tracks_shot: OK %s" % tag)
	await _quit(0)


func _shot(cam: Camera3D, eye: Vector3, target: Vector3, path: String) -> void:
	cam.look_at_from_position(eye, target)
	for i in 20:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("tracks_shot: %s (%s)" % [path, error_string(img.save_png(path))])
