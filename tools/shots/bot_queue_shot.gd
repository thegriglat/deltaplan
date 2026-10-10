extends Node3D
## Кадр «очередь ботов на старте»: 8 ботов, склон 10° с ровной площадкой; игрок давно взлетел —
## часть ботов ушла, один идёт на старт, остальные ждут на своих местах. Вид сверху и сбоку.
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --path . --resolution 1280x720 \
##   res://tools/shots/bot_queue_shot.tscn -- --out=<каталог>

const START := Vector3(0.0, 300.0, 0.0)


static func hill(_x: float, z: float) -> float:
	return 300.0 if z > -2.0 else 300.0 + (z + 2.0) * tan(deg_to_rad(10.0))


func _ready() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.6, 0.75, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.8)
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 150, 0)
	add_child(sun)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	g.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.5, 0.25)
	g.material_override = mat
	g.position = Vector3(0, 300, 40)
	add_child(g)
	var b := BotPilots.new()
	add_child(b)
	b.setup(
		{
			"air_fn": func(_p: Vector3) -> Vector3: return Vector3(0, 0, 2.0),
			"ground_fn": hill,
			"start": START,
			"heading_deg": 0.0,
			"count": 8,
			"seed": 3,
		}
	)
	var fly := Telemetry.new()
	fly.phase = "flying"
	fly.position = Vector3(0, 500, -800)
	fly.velocity = Vector3(0, -1, -10)
	var dt := 1.0 / 60.0
	for i in int(75.0 / dt):
		b.tick(dt, fly)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.fov = 60.0
	for k in 2:
		if k == 0:
			cam.global_position = Vector3(0, 380, 30)
			cam.look_at(Vector3(0, 300, 28), Vector3(0, 0, -1))
		else:
			cam.global_position = Vector3(55, 312, 70)
			cam.look_at(Vector3(0, 300, 25), Vector3.UP)
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_jpg("%s/queue_%d.jpg" % [out, k], 0.85)
	print("bot_queue_shot: states ", b.state_counts())
	get_tree().quit(0)
