extends Node3D
## Крупные планы перчаток пилота на трапеции (pilot.glb, PilotArmIK): визуал планера на пустой
## сцене, поза prone (кисти на базовой штанге) и stand (на стойках), камера у правой кисти —
## сзади-сверху-сбоку и спереди-сбоку. Запуск (под timeout):
##   godot --path . --fullscreen --resolution 1920x1080 res://tools/shots/glove_shot.tscn -- \
##     --out=<каталог> [--wing=training]
## Пишет <out>/<крыло>_<анимация>_<вид>.png. Код выхода 0.

## Вид: смещение камеры от правой кисти в осях визуала (+X вправо, +Y вверх, −Z вперёд).
const VIEWS := {
	"prone": {"back": Vector3(0.3, 0.4, 0.6), "side": Vector3(0.65, 0.05, -0.3)},
	"stand": {"back": Vector3(0.4, 0.25, 0.6), "side": Vector3(0.6, 0.0, -0.5)},
}

var _out := ""
var _wing := "training"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
	if _out == "":
		push_error("glove_shot: нужен --out=")
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
	env.environment.ambient_light_color = Color(0.35, 0.37, 0.42)
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 25, 0)
	sun.light_energy = 1.6
	add_child(sun)
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + _wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	var grip := v.find_child("HandR", true, false) as Node3D
	var cam := Camera3D.new()
	cam.near = 0.02
	cam.fov = 40.0
	add_child(cam)
	cam.current = true
	for anim: String in VIEWS:
		ap.play(anim, 0.0)
		ap.advance(0.3)
		ap.pause()
		var views: Dictionary = VIEWS[anim]
		for view: String in views:
			for i in 4:
				v.set_pose(0.0, 0.0, anim == "prone", 1.0e6)
				await get_tree().process_frame
			var h := grip.global_position
			cam.global_position = h + (views[view] as Vector3)
			cam.look_at(h, Vector3.UP)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var f := "%s/%s_%s_%s.png" % [_out, _wing, anim, view]
			img.save_png(f)
			print("glove_shot: ", f)
	get_tree().quit(0)
