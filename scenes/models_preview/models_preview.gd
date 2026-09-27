extends Node3D
## Просмотр моделей из assets/models (docs/models.md): три крыла с пилотом и прибором,
## собранные так же, как это делает обёртка: pilot.glb — в HangPoint, instrument.glb — в
## InstrumentMount (центр штанги), vario_90s.glb — в VarioMount (левая стойка). Запуск со снимком:
##   xvfb-run -a godot --path . --rendering-method gl_compatibility \
##     res://scenes/models_preview/models_preview.tscn -- --view=iso --shot=/путь/кадр.png
## Виды: iso (все три крыла), below (снизу), cockpit (глаза пилота спортивного крыла), side.

const WINGS := ["glider_training", "glider_kingpost", "glider_sport"]
const SPACING := 13.0

var _args := {}
var _frames := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
	for i in WINGS.size():
		_add_glider(WINGS[i], Vector3((i - 1) * SPACING, 0, 0))
	_place_camera(String(_args.get("view", "iso")))


func _process(_dt: float) -> void:
	_frames += 1
	if _args.has("shot") and _frames == 8:
		var img := get_viewport().get_texture().get_image()
		img.save_png(String(_args.shot))
		print("SHOT ", _args.shot)
		get_tree().quit()


func _add_glider(model: String, pos: Vector3) -> void:
	var wing := _load("res://assets/models/%s.glb" % model)
	wing.name = model
	wing.position = pos
	add_child(wing)
	var hang := wing.find_child("HangPoint", true, false) as Node3D
	var pilot := _load("res://assets/models/pilot.glb")
	hang.add_child(pilot)
	var mount := wing.find_child("InstrumentMount", true, false) as Node3D
	mount.add_child(_load("res://assets/models/instrument.glb"))
	var vario := wing.find_child("VarioMount", true, false) as Node3D
	vario.add_child(_load("res://assets/models/vario_90s.glb"))


func _load(path: String) -> Node3D:
	var ps := load(path) as PackedScene
	if ps == null:
		push_error("нет модели " + path)
		return Node3D.new()
	return ps.instantiate() as Node3D


func _place_camera(view: String) -> void:
	var cam := $Camera3D as Camera3D
	match view:
		"below":
			cam.position = Vector3(0, -24, 2)
			cam.look_at(Vector3(0, 0, 0), Vector3.FORWARD)
			cam.fov = 70
		"side":
			cam.position = Vector3(SPACING + 9, -0.5, 0)
			cam.look_at(Vector3(SPACING, -0.6, 0))
		"cockpit":
			var wing := get_node(WINGS[2]) as Node3D
			var head := wing.find_child("Head", true, false) as Node3D
			# рекомендация docs/models.md: глаза = Head, взгляд вперёд с наклоном вверх,
			# вертикальный FOV ~100°; параметры --pitch=, --fov=, --wing=0..2
			wing = get_node(WINGS[int(_args.get("wing", "2"))]) as Node3D
			head = wing.find_child("Head", true, false) as Node3D
			(wing.find_child("Helmet", true, false) as Node3D).visible = false
			cam.global_transform = head.global_transform
			cam.translate_object_local(Vector3(0, float(_args.get("up", "0.08")),
				float(_args.get("back", "0.25"))))
			cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(float(_args.get("pitch", "8"))))
			cam.fov = float(_args.get("fov", "100"))
			cam.near = 0.02
		_:
			cam.position = Vector3(-14, 7, -16)
			cam.look_at(Vector3(0, -0.5, 0))
			cam.fov = 60
