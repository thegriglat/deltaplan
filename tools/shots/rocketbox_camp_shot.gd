extends Node
## Кадры людей лагеря (EggPeople, модели Rocketbox) на настоящем старте.
##   godot --path . --audio-driver Dummy --resolution 1920x1080 res://tools/shots/rocketbox_camp_shot.tscn \
##     -- --autostart --location=ongudai --site=kayancha_south --bots=4 --egg=people:0 --out=/tmp/rb
## Пишет <out>/<n>_<что>.png: со старта (глаза пилота) и погоня (сзади-сверху) на лагерь; человек вблизи 5 и
## 10 м; лагерь с 25 и 45 м. Печатает расстояние, модель и анимацию ближайшего к камере человека.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 300.0

var _out := ""
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		push_error("rocketbox_camp_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("rocketbox_camp_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _find_people(n: Node) -> EggPeople:
	if n is EggPeople:
		return n
	for c in n.get_children():
		var r := _find_people(c)
		if r != null:
			return r
	return null


func _run() -> void:
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
	var people: EggPeople = null
	for i in 600:
		people = _find_people(main)
		if people != null and people.person_count() > 0:
			break
		await get_tree().process_frame
	if people == null or people.person_count() == 0:
		_fail("людей нет")
		return
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var h := func(p: Vector3) -> Vector3: return Vector3(p.x, game.terrain.height_at(p.x, p.z), p.z)
	var c := Vector3.ZERO
	for i in people.person_count():
		var q := people.person_pos(i)
		c += Vector3(q.x, 0, q.y)
	c = h.call(c / people.person_count())
	print("rocketbox_camp_shot: людей %d, лагерь в %.0f м от старта" % [
		people.person_count(), Vector2(c.x - sp.x, c.z - sp.z).length()])
	var game_cam := get_viewport().get_camera_3d()
	# 1. кабина: игровая камера как есть, взгляд на лагерь
	if game_cam != null:
		var eye := game_cam.global_position
		var cam0 := game_cam.global_transform
		game_cam.look_at(c + Vector3.UP * 1.0)
		await _snap(people, game_cam, "%s/1_start_cockpit.png" % _out)
		game_cam.global_transform = cam0
		print("rocketbox_camp_shot: камера игры на высоте %.1f м над землёй" % (eye.y - h.call(eye).y))
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.fov = 70.0
	cam.current = true
	var to_c := Vector3(c.x - sp.x, 0, c.z - sp.z).normalized()
	# 2. погоня: 7 м за стартом (от лагеря) и 3,5 м над землёй
	await _shot(people, cam, h.call(sp - to_c * 7.0) + Vector3.UP * 3.5, c + Vector3.UP, "2_start_chase")
	# 3. вблизи: человек 0 с 5 и 10 м (с его стороны к старту)
	var pi := 0
	var pp := people.person_pos(pi)
	var p3: Vector3 = h.call(Vector3(pp.x, 0, pp.y))
	var away := Vector3(sp.x - p3.x, 0, sp.z - p3.z).normalized()
	cam.fov = 50.0
	await _shot(people, cam, h.call(p3 + away * 5.0) + Vector3.UP * 1.6, p3 + Vector3.UP * 1.1, "3_person_5m")
	await _shot(people, cam, h.call(p3 + away * 10.0) + Vector3.UP * 1.6, p3 + Vector3.UP * 1.0, "4_person_10m")
	# 4. лагерь с 25 и 45 м
	cam.fov = 60.0
	await _shot(people, cam, h.call(c - to_c * 25.0) + Vector3.UP * 1.7, c + Vector3.UP * 0.9, "5_camp_25m")
	await _shot(people, cam, h.call(c - to_c * 45.0) + Vector3.UP * 1.7, c + Vector3.UP * 0.9, "6_camp_45m")
	print("rocketbox_camp_shot: OK")
	await _quit(0)


func _shot(people: EggPeople, cam: Camera3D, eye: Vector3, target: Vector3, name: String) -> void:
	cam.look_at_from_position(eye, target)
	await _snap(people, cam, "%s/%s.png" % [_out, name])


func _snap(people: EggPeople, cam: Camera3D, path: String) -> void:
	for i in 30:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var best := -1
	var bd := INF
	for i in people.person_count():
		var q := people.person_pos(i)
		var d := Vector2(cam.global_position.x, cam.global_position.z).distance_to(q)
		if d < bd:
			bd = d
			best = i
	print("rocketbox_camp_shot: %s (%s) ближайший %.1f м: %s, %s, ближних %d" % [
		path, error_string(img.save_png(path)), bd, people.person_model(best), people.near_anim(best),
		people.near_count()])
