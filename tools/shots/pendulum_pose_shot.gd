extends Node3D
## Поза пилота в режиме «Маятник» в вираже 30° (PD-6): 01_вираж (сбоку-сзади), 02_из_глаз.
## Запуск: godot --path . --fullscreen --resolution 1600x900 res://tools/shots/pendulum_pose_shot.tscn -- --out=<каталог> [--wing=sport]

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
var _out := ""
var _wing := "sport"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _run() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.74, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var g: Glider = M.make_glider("pendulum", _wing)
	g.set_ground_fn(func(_x: float, _z: float) -> float: return 0.0)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)
	add_child(g)
	g.set_process(false)
	g.set_physics_process(false)
	g.reset_on_ground(Vector3(0.0, 1000.0, 0.0), 0.0)
	var ap: AnimationPlayer = g.visual.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	var bh := S.BankHold.new(deg_to_rad(30.0), 1.5, 0.8, 0.3)
	for i in 120 * 25:
		g.control.roll = bh.roll(g.model)
		g.step(1.0 / 120.0)
	g.global_transform = g._cur_xform
	for i in 4:
		g._update_pilot(1.0 / 120.0)
		await get_tree().process_frame
	print("bank deg ", rad_to_deg(g.model.bank))
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.fov = 60.0
	add_child(cam)
	cam.current = true
	var hang := g.visual.get_marker("HangPoint").global_position
	var b := g.global_basis
	cam.global_position = hang + b * Vector3(3.2, -1.2, 3.0)
	cam.look_at(hang + b * Vector3(0, -1.2, 0), Vector3.UP)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/01_вираж.png" % _out)
	g.visual.set_cockpit_body("full")
	cam.global_position = g.visual.head_marker.global_position
	cam.global_basis = Basis(Vector3.UP, g.model.heading * -1.0) if false else b
	cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(-25.0))
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/02_из_глаз.png" % _out)
	get_tree().quit(0)
