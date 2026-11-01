extends "res://tools/research/trike-fix/coupling_run.gd"
## TKF-1: кадры «до» (и «после» тем же инструментом, TKF-7). Не headless, под замком cpu:
##   godot --path . --resolution 1280x720 res://tools/research/trike-fix/coupling_shots.tscn -- \
##     --out=/home/greg/deltaplan/build/screenshots/trike-fix/before [--prefix=TKF-1] [--moments=<json>]
## moments (по умолчанию coupling_moments.json): [{"id":"p1","scenario":"turn45_idle","t":12.3}, ...]
## Сценарий проигрывается тем же вводом и тягой, что coupling_run.gd (детерминированно), на нужный момент t
## ставится вид (cart_basis игры) и снимаются три ракурса: side (с правого борта крыла), rear (сзади-сверху), front.

var _prefix := "TKF-1"
var _mom_path := "res://tools/research/trike-fix/coupling_moments.json"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--prefix="):
			_prefix = a.substr(9)
		elif a.begins_with("--moments="):
			_mom_path = a.substr(10)
	DirAccess.make_dir_recursive_absolute(_out)
	_cfg = Config.get_config("tow_tug")
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.current = true
	var moments: Array = JSON.parse_string(FileAccess.get_file_as_string(_mom_path))
	for mo: Dictionary in moments:
		await _shoot(mo, cam)
	get_tree().quit(0)


func _shoot(mo: Dictionary, cam: Camera3D) -> void:
	var name: String = mo.scenario
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	add_child(g)
	g.set_process(false)
	g.set_physics_process(false)
	g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
	_g = g
	_bank_i = 0.0
	var rig := g.trike
	rig.refresh(0.0)
	var ctl := ControlInput.new()
	var n := int(round(float(mo.t) / _dt))
	for i in n:
		var u := _inputs(name, i * _dt)
		ctl.pitch = u[0]
		ctl.roll = u[1]
		rig.thrust_n = _thrust(g.model.telemetry.airspeed, u[2])
		g.model.step(_dt, ctl, Callable(), Callable(self, "_ground"))
		rig.refresh(_dt)
	g._tv_cur = g._trike_state()
	g._tv_prev = g._tv_cur
	g._update_trike_visual(1.0)
	var w := rig.wing_basis
	var c := rig.hang_pos
	var views := {
		"side": [c + w.x * 7.0 + w.y * 0.5, c],
		"rear": [c + w.z * 7.0 + w.y * 3.0, c],
		"front": [c - w.z * 6.0 + w.x * 4.0 + w.y * 1.5, c]}
	for v: String in views:
		cam.global_position = views[v][0]
		cam.look_at(views[v][1], Vector3.UP)
		for k in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var f := "%s/%s_%s_%s.png" % [_out, _prefix, mo.id, v]
		get_viewport().get_texture().get_image().save_png(f)
		print("coupling_shots: ", f)
	remove_child(g)
	g.free()
