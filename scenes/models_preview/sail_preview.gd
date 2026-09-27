extends Node3D
## Стенд шейдера паруса (docs/models.md → «Шейдер паруса»): крыло с пилотом, солнце за парусом,
## слайдеры скорости, сваливания и турбулентности. Аргументы (после --):
##   --wing=sport|kingpost|training --airspeed=10 --stall=0 --turb=0 --pose=prone
##   --view=below|keel|te|cockpit|side  (below — снизу против солнца, keel — из-за пилота вверх
##                                      на нижнюю поверхность, te — задняя кромка крупно)
##   --shot=/путь/кадр.png          снимок и выход; --frames=N --dt=0.04 — серия кадров
##                                   /путь/кадр_00.png… с шагом времени шейдера dt, с

var _args := {}
var _mat: ShaderMaterial
var _airspeed := 10.0
var _stall := 0.0
var _turb := 0.0
var _frame := 0
var _shots := 0
var _pilot: Node3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
	_airspeed = float(_args.get("airspeed", "10"))
	_stall = float(_args.get("stall", "0"))
	_turb = float(_args.get("turb", "0"))
	var model := "glider_" + String(_args.get("wing", "sport"))
	var wing := (load("res://assets/models/%s.glb" % model) as PackedScene).instantiate() as Node3D
	add_child(wing)
	var hang := wing.find_child("HangPoint", true, false) as Node3D
	var pilot := (load("res://assets/models/pilot.glb") as PackedScene).instantiate() as Node3D
	hang.add_child(pilot)
	_pilot = pilot
	var anim := pilot.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim != null:
		anim.play(String(_args.get("pose", "prone")))
	var mount := wing.find_child("InstrumentMount", true, false) as Node3D
	mount.add_child((load("res://assets/models/instrument.glb") as PackedScene).instantiate())
	_mat = SailMaterial.apply(wing.find_child("Sail", true, false) as MeshInstance3D, model)
	_place_camera(String(_args.get("view", "below")), pilot)
	if _args.has("shot"):
		$UI.visible = false
	else:
		_build_ui()
	_update()


func _process(_dt: float) -> void:
	_frame += 1
	if _frame == 3:  # кости пилота встали в позу анимации
		_place_camera(String(_args.get("view", "below")), _pilot)
	if not _args.has("shot"):
		return
	var n := int(_args.get("frames", "1"))
	if n > 1:
		_mat.set_shader_parameter("time_override", float(_args.get("dt", "0.04")) * _shots)
	if _frame < 6 or _frame % 2 == 1:
		return
	var path := String(_args.shot)
	if n > 1:
		path = path.get_basename() + "_%02d.png" % _shots
	get_viewport().get_texture().get_image().save_png(path)
	_shots += 1
	if _shots >= n:
		print("SHOT ", _args.shot)
		get_tree().quit()


func _update() -> void:
	SailMaterial.set_flight(_mat, _airspeed, _stall, _turb)


func _place_camera(view: String, pilot: Node3D) -> void:
	var cam := $Camera3D as Camera3D
	match view:
		"te":
			cam.position = Vector3(2.2, -1.2, 2.6)
			cam.look_at(Vector3(2.4, 0.1, 1.3))
			cam.fov = 45
		"keel":
			cam.position = Vector3(0.3, -1.1, 2.0)
			cam.look_at(Vector3(0.0, 0.7, 0.0))
			cam.fov = 85
		"side":
			cam.position = Vector3(9, -1.5, 1.5)
			cam.look_at(Vector3(0, -0.3, 0.3))
		"cockpit":
			var cc := pilot.find_child("CockpitCamera", true, false) as Node3D
			(pilot.find_child("Helmet", true, false) as Node3D).visible = false
			cam.global_transform = cc.global_transform
			cam.fov = 95
			cam.near = 0.02
		_:
			cam.position = Vector3(1.5, -7.5, 3.5)
			cam.look_at(Vector3(0, 0, 0.3))
			cam.fov = 65


func _build_ui() -> void:
	var box := $UI/Panel/Box as VBoxContainer
	for spec: Array in [["Скорость, м/с", 5.0, 30.0, _airspeed, "_airspeed"],
			["Сваливание", 0.0, 1.0, _stall, "_stall"], ["Турбулентность", 0.0, 1.0, _turb, "_turb"]]:
		var label := Label.new()
		label.text = String(spec[0])
		box.add_child(label)
		var s := HSlider.new()
		s.min_value = float(spec[1])
		s.max_value = float(spec[2])
		s.step = 0.01
		s.value = float(spec[3])
		s.custom_minimum_size = Vector2(260, 0)
		var prop := String(spec[4])
		s.value_changed.connect(func(v: float) -> void:
			set(prop, v)
			label.text = "%s: %.2f" % [spec[0], v]
			_update())
		box.add_child(s)
