extends Node
## Кадры лагеря палаток у старта (TentCamp, WorldObjects.place_camp).
## Запуск (окно нужно — настоящий рендер; под timeout 120):
##   godot --path . --audio-driver Dummy --resolution 1920x1080 res://tools/shots/tents_shot.tscn \
##     -- --autostart --location=ongudai --site=kayancha_south --bots=4 --out=/tmp/tents
##   godot --path . --audio-driver Dummy --resolution 1920x1080 res://tools/shots/tents_shot.tscn \
##     -- --models --out=/tmp/tents
## Пишет <out>/<локация>_<старт>_{ground_back,ground_near,side,close,air}.png — с глаз пилота на
## старте назад на лагерь, с земли в 35 м от лагеря со стороны старта, сбоку от лагеря (старт на
## заднем плане), вблизи, сверху сразу после взлёта; с --models —
## <out>/models.png (все типы × все цвета на ровной площадке, ближний LOD) и models_lod1.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 110.0

var _out := ""
var _models := false
var _main: Node = null


func _ready() -> void:
	var site := ""
	var loc := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a == "--models":
			_models = true
		elif a.begins_with("--site="):
			site = a.substr(7)
		elif a.begins_with("--location="):
			loc = a.substr(11)
	if _out == "":
		push_error("tents_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	if _models:
		_run_models()
	else:
		_run_world("%s_%s" % [loc, site])


func _fail(why: String) -> void:
	print("tents_shot: FAIL (%s)" % why)
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
	if wo == null or wo.camp.is_empty():
		_fail("лагеря нет")
		return
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	var c := Vector3.ZERO
	for t in wo.camp:
		c += t.position
	c /= wo.camp.size()
	print(
		(
			"tents_shot: %s — палаток %d, центр лагеря в %.0f м от старта"
			% [tag, wo.camp.size(), Vector2(c.x - sp.x, c.z - sp.z).length()]
		)
	)
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.fov = 60.0
	cam.current = true
	var h := func(p: Vector3) -> Vector3: return Vector3(p.x, game.terrain.height_at(p.x, p.z), p.z)
	# 1. с земли у старта: глаза пилота, чуть позади и сбоку от крыла, взгляд на лагерь
	var to_c := Vector3(c.x - sp.x, 0, c.z - sp.z).normalized()
	var eye: Vector3 = h.call(sp) + Vector3.UP * 1.7
	print(
		(
			"tents_shot: с глаз пилота на старте лагерь %s"
			% ["виден" if _sees(game.terrain, eye, c + Vector3.UP) else "за перегибом склона"]
		)
	)
	await _shot(cam, eye, c + Vector3.UP * 0.8, "%s/%s_ground_back.png" % [_out, tag])
	# 1б. с тропы / от старта ближе к лагерю: 35 м от центра лагеря в сторону старта
	eye = h.call(c - to_c * 35.0) + Vector3.UP * 1.7
	await _shot(cam, eye, c + Vector3.UP * 0.6, "%s/%s_ground_near.png" % [_out, tag])
	# 2. сбоку от лагеря: с дальней от старта стороны (старт на заднем плане), не в лесу
	var side := to_c
	var best := INF
	for k in 16:
		var d := to_c.rotated(Vector3.UP, k * TAU / 16.0)
		var q: Vector3 = c + d * 22.0
		var score := (
			game.terrain.forest_at(q.x, q.z) * 10.0
			+ absf(angle_difference(atan2(d.x, d.z), atan2(to_c.x, to_c.z)))
		)
		if score < best:
			best = score
			side = d
	eye = h.call(c + side * 22.0) + Vector3.UP * 5.0
	await _shot(cam, eye, c.lerp(sp, 0.3) + Vector3.UP * 1.0, "%s/%s_side.png" % [_out, tag])
	# 3. вблизи
	var t0: Vector3 = wo.camp[0].position
	eye = h.call(t0 + side.rotated(Vector3.UP, 0.5) * 9.0) + Vector3.UP * 1.7
	await _shot(cam, eye, t0 + Vector3.UP * 0.6, "%s/%s_close.png" % [_out, tag])
	# 4. сверху сразу после взлёта: 60 м впереди старта, 35 м над ним, оглянуться на старт и лагерь
	eye = sp + fwd * 60.0 + Vector3.UP * 35.0
	await _shot(cam, eye, sp.lerp(c, 0.6), "%s/%s_air.png" % [_out, tag])
	print("tents_shot: OK %s" % tag)
	await _quit(0)


func _sees(terrain: Terrain, a: Vector3, b: Vector3) -> bool:
	for k in range(1, 16):
		var q := a.lerp(b, k / 16.0)
		if terrain.height_at(q.x, q.z) > q.y:
			return false
	return true


func _shot(cam: Camera3D, eye: Vector3, target: Vector3, path: String) -> void:
	cam.look_at_from_position(eye, target)
	for i in 20:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("tents_shot: %s (%s)" % [path, error_string(img.save_png(path))])


## Все типы × цвета на ровной площадке.
func _run_models() -> void:
	var cfg: Dictionary = WorldObjects.load_config().tents
	var root := Node3D.new()
	add_child(root)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.72, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.6, 0.7)
	env.environment.ambient_light_energy = 0.8
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -40, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.45, 0.24)
	ground.material_override = gm
	root.add_child(ground)
	var tents: Array = []
	var types := ["dome2", "tunnel3", "tarp"]
	for ti in types.size():
		for ci in (cfg.colors as Array).size():
			(
				tents
				. append(
					{
						"type": types[ti],
						"position": Vector3((ci - 2.5) * 5.0, 0, (ti - 1) * 7.0),
						"basis": Basis(Vector3.UP, deg_to_rad(20.0 * ci - 30.0)),
						"color": ci,
					}
				)
			)
	var node := TentCamp.build_node(tents, cfg)
	root.add_child(node)
	var cam := Camera3D.new()
	cam.fov = 45.0
	root.add_child(cam)
	cam.current = true
	await _shot(cam, Vector3(4, 13, -26), Vector3(0, 0, -1), "%s/models.png" % _out)
	for t in node.get_children():
		(t.get_node("LOD0") as MeshInstance3D).visible = false
		var l1 := t.get_node("LOD1") as MeshInstance3D
		l1.visibility_range_begin = 0.0
	await _shot(cam, Vector3(4, 13, -26), Vector3(0, 0, -1), "%s/models_lod1.png" % _out)
	await _quit(0)
