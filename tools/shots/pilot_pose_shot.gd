extends Node3D
## Поза пилота в полёте (нейтраль, руки на базовой штанге): вид сбоку и 3/4 сзади.
## Парус скрыт (виден пилот и трапеция). Запуск (окну нужен дисплей, под timeout):
##   godot --path . --fullscreen --resolution 1600x900 res://tools/shots/pilot_pose_shot.tscn -- \
##     --out=<каталог> [--wing=sport] [--tag=после] [--elbow=0.5]
## Пишет <out>/<тег>_<крыло>_<вид>.jpg (side, rear34). --elbow — flight.json → arms.elbow_height_frac.

var _out := ""
var _wing := "sport"
var _tag := "pose"
var _elbow := -1.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--elbow="):
			_elbow = float(a.substr(8))
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
	var vis: Dictionary = Config.get_config("flight").visual.duplicate(true)
	if _elbow >= 0.0:
		vis.arms.elbow_height_frac = _elbow
	var v := GliderVisual.new()
	add_child(v)
	v.build(Config.get_config("wings/" + _wing), Config.get_config("pilot"), vis)
	var sail := v.wing.find_child("Sail", true, false) as Node3D
	if sail != null:
		sail.visible = false
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.3)
	ap.pause()
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.fov = 55.0
	add_child(cam)
	cam.current = true
	for view in ["side", "rear34"]:
		for i in 6:
			v.set_pose(0, 0, true, 1.0e6)
			await get_tree().process_frame
		var sh := (v.shoulder(-1) + v.shoulder(1)) * 0.5
		var focus := v.global_transform * (sh + Vector3(0, -0.1, -0.15))
		if view == "side":
			cam.global_position = focus + Vector3(1.5, 0.0, 0.0)
		else:
			cam.global_position = focus + Vector3(1.0, 0.7, 1.5)
		cam.look_at(focus, Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var f := "%s/%s_%s_%s.jpg" % [_out, _tag, _wing, view]
		get_viewport().get_texture().get_image().save_jpg(f, 0.92)
		print("pilot_pose_shot: ", f)
	get_tree().quit(0)
