extends Node3D
## Кадры трапеции и крыла из кабины и крупные планы узлов (карабин, узел стоек, углы трапеции):
## визуал планера (крыло + pilot.glb + PilotArmIK) на пустой сцене с небом, поза prone.
## Запуск (под timeout, с временным профилем):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --resolution 1600x900 \
##     res://tools/shots/frame_shot.tscn -- --out=<каталог> [--wing=apogee] [--views=F,DF,...]
## Пишет <out>/<крыло>_<вид>.png. Код выхода 0.
## Кабинные виды — из глаз (маркер PilotHead + cockpit.offset_m из configs/camera.json, шлем
## скрыт), поворот головы (рыскание, тангаж °); внешние — камера в осях визуала смотрит на точку.

const COCKPIT := {
	"F": Vector2(0, -2),  # вперёд
	"DF": Vector2(0, -60),  # вниз на штангу
	"U": Vector2(0, 55),  # вверх на парус
	"L": Vector2(75, -15),  # влево на стойку
	"R": Vector2(-75, -15),  # вправо на стойку
	"UB": Vector2(0, 85),  # прямо вверх к подвесу
}
## Внешние: [позиция камеры, точка взгляда, fov] в осях визуала (+X вправо, +Y вверх, −Z вперёд)
## относительно HangPoint.
const EXTERNAL := {
	"XA": [Vector3(0.55, -0.35, 0.35), Vector3(0, -0.05, -0.2), 45.0],  # подвес и узел стоек
	"XC": [Vector3(-0.35, -1.15, -0.35), Vector3(-0.7, -1.6, -0.9), 50.0],  # левый угол
	"XS": [Vector3(2.6, -0.6, -0.4), Vector3(0, -0.8, -0.5), 50.0],  # трапеция сбоку
	"XF": [Vector3(0.3, -0.9, -3.2), Vector3(0, -0.8, -0.4), 50.0],  # трапеция спереди
}

var _out := ""
var _wing := "apogee"
var _views: PackedStringArray = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
		elif a.begins_with("--views="):
			_views = a.substr(8).split(",")
	if _out == "":
		push_error("frame_shot: нужен --out=")
		get_tree().quit(1)
		return
	if _views.is_empty():
		_views = PackedStringArray(COCKPIT.keys() + EXTERNAL.keys())
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _env() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.3, 0.5, 0.85)
	sm.sky_horizon_color = Color(0.7, 0.8, 0.9)
	sm.ground_bottom_color = Color(0.25, 0.3, 0.2)
	sm.ground_horizon_color = Color(0.55, 0.6, 0.5)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 150, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)


func _run() -> void:
	_env()
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + _wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	for ap: AnimationPlayer in v.find_children("*", "AnimationPlayer", true, false):
		if ap.has_animation("prone"):
			ap.play("prone", 0.0)
			ap.advance(0.3)
			ap.pause()
	var cam_cfg: Dictionary = Config.get_config("camera")
	var cc: Dictionary = cam_cfg.cockpit
	var off: Array = cc.offset_m
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	for i in 6:
		v.set_pose(0.0, 0.0, true, 1.0e6)
		await get_tree().process_frame
	var hp := v.get_marker("HangPoint").global_position
	for view: String in _views:
		var helmets := v.find_children("Helmet*", "", true, false)
		if COCKPIT.has(view):
			for h: Node in helmets:
				(h as Node3D).visible = false
			var look: Vector2 = COCKPIT[view]
			var eye := v.head_marker.global_position + Vector3(off[0], off[1], off[2])
			cam.global_position = eye
			cam.global_basis = (
				Basis(Vector3.UP, deg_to_rad(look.x)) * Basis(Vector3.RIGHT, deg_to_rad(look.y))
			)
			cam.fov = float(cam_cfg.fov_deg)
			cam.near = float(cc.near_m)
		elif EXTERNAL.has(view):
			for h: Node in helmets:
				(h as Node3D).visible = true
			var e: Array = EXTERNAL[view]
			cam.global_position = hp + (e[0] as Vector3)
			cam.look_at(hp + (e[1] as Vector3), Vector3.UP)
			cam.fov = float(e[2])
			cam.near = 0.02
		else:
			continue
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var f := "%s/%s_%s.png" % [_out, _wing, view]
		get_viewport().get_texture().get_image().save_png(f)
		print("frame_shot: ", f)
	get_tree().quit(0)
