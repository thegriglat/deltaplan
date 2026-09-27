extends Node3D
## Кадры рук пилота на трапеции (PilotArmIK, flight.json → visual.arms) и тряски трапеции:
## визуал планера на пустой сцене, поза prone (или stand), крен/тангаж заданы, камера из кабины
## (PilotHead + camera.json → cockpit.offset_m и head_follow_body, взгляд вниз на 60°) или
## сзади-сбоку. Запуск (под timeout):
##   godot --path . --fullscreen --resolution 1920x1080 res://tools/shots/arms_shot.tscn -- \
##     --out=<каталог> [--wing=sport]
## Пишет <out>/<крыло>_<вид>_<анимация>_r<крен>_p<тангаж>.png. Код выхода 0.

const COMBOS := [[0, 0], [0, -1], [0, 1], [-1, 0], [1, 0]]

var _out := ""
var _wing := "sport"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
	if _out == "":
		push_error("arms_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _run() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + _wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	var cam := Camera3D.new()
	cam.near = 0.04
	cam.fov = float(Config.get_config("camera").fov_deg)
	add_child(cam)
	cam.current = true
	var cc: Dictionary = Config.get_config("camera").cockpit
	var off: Array = cc.offset_m
	var helmet := v.find_child("Helmet", true, false) as Node3D
	for anim in ["prone", "stand"]:
		ap.play(anim, 0.0)
		ap.advance(0.3)
		ap.pause()
		for c: Array in COMBOS if anim == "prone" else [[0, 0], [1, 0]]:
			for view in ["down", "back"]:
				for i in 4:
					v.set_pose(c[0], c[1], anim == "prone", 1.0e6)
					if view == "down":
						var eye := (
							v.head_marker.global_position
							+ Vector3(float(off[0]), float(off[1]), float(off[2]))
							- v.body_shift * (1.0 - float(cc.get("head_follow_body", 1.0)))
						)
						cam.global_transform = Transform3D(
							Basis(Vector3.RIGHT, deg_to_rad(-60.0)), eye
						)
					else:
						cam.global_position = Vector3(0.9, 1.9, 1.9)
						cam.look_at(Vector3(0, 0.9, -0.5), Vector3.UP)
					helmet.visible = view != "down"
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				var f := (
					"%s/%s_%s_%s_r%+d_p%+d.png" % [_out, _wing, view, anim, int(c[0]), int(c[1])]
				)
				img.save_png(f)
				print("arms_shot: ", f)
	get_tree().quit(0)
