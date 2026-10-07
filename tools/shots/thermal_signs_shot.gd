extends Node
## QL-9: кадр ласточек и пуха над источником молодого термика (стенд — atmosphere_preview, плоская земля).
## Запуск: godot --path . res://tools/shots/thermal_signs_shot.tscn -- --out=/path/dir [--dist=140] [--far=900]
## Пишет <out>/near.png (ближе) и far.png (далеко: проверка min_px). Код выхода 0/1.

const PREVIEW := preload("res://scenes/atmosphere/atmosphere_preview.tscn")

var _args: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if String(_args.get("out", "")) == "":
		push_error("thermal_signs_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(String(_args.out))
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	_run()


func _run() -> void:
	var preview: Node = PREVIEW.instantiate()
	add_child(preview)
	var atmo: Atmosphere = preview.get_node("Atmosphere")
	atmo.set_physics_process(false)
	var cam := preview.get_node("Camera3D") as Camera3D
	atmo.cfg.thermal_signs.swallow_chance = 1.0
	atmo.cfg.thermal_signs.fluff_chance = 1.0
	var id := atmo.add_static_thermal(0.0, -300.0, 3.0, 120.0)
	atmo.step(1.0)
	var signs := atmo.get_node("ThermalSigns") as ThermalSigns
	var src: AtmoThermal = atmo.field.thermals[id]
	for i in 30:
		await get_tree().process_frame
	var out := String(_args.out)
	var near := float(_args.get("dist", "140"))
	var far := float(_args.get("far", "900"))
	for pair in [["near", near, 40.0], ["far", far, 60.0]]:
		cam.position = Vector3(0.0, src.src.y + float(pair[2]), -300.0 + float(pair[1]))
		cam.look_at(Vector3(0.0, src.src.y + 70.0, -300.0))
		preview._yaw = cam.rotation.y  # иначе preview каждый кадр возвращает свой поворот
		preview._pitch = cam.rotation.x
		atmo.set_focus(cam.position)
		signs.refresh(cam.position)
		for i in 20:
			atmo.step(0.1)
			await get_tree().process_frame
		await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, pair[0]])
		for d in signs.positions(atmo.time_s):
			print("  ", d.kind, " ", cam.unproject_position(d.pos), " dist=", snappedf(cam.position.distance_to(d.pos), 1.0))
		print("shot ", pair[0], " signs=", signs.positions(atmo.time_s).size(), " entries=", signs._entries.size())
	get_tree().quit(0)
