class_name Vario90s3D
extends Node3D
## Корпус вариометра 1990-х в 3D (хомут левой стойки трапеции, docs/models.md → VarioMount).
## Модель — vario90s.mount_3d.model_path (.glb, делает агент models): в ней ищется меш «Screen»
## (круглый циферблат) с UV 0..1 на весь экран, на него кладётся текстура VarioDisplay90s.
## Нет модели или меша — корпус из примитивов: экран смотрит в локальную +Z (к пилоту), верх — +Y.
## Размеры и материалы — configs/instruments.json → vario90s.mount_3d.

var screen_mesh: MeshInstance3D
var _screen_mat: StandardMaterial3D

@onready var vario90s: VarioDisplay90s = $VarioDisplay90s


func _ready() -> void:
	var cfg: Dictionary = Config.get_config("instruments").get("vario90s", {})
	var m: Dictionary = cfg.get("mount_3d", {})
	_screen_mat = _make_screen_material(m)
	if not _load_model(m):
		_build(m)
	use_instrument(vario90s)


## Модель ли загружена (иначе — примитивы).
func has_model() -> bool:
	return get_node_or_null("Model") != null


## Загрузить .glb и найти меш экрана. false — модели нет или в ней нет меша экрана.
func _load_model(m: Dictionary) -> bool:
	var path := String(m.get("model_path", ""))
	if path == "" or not ResourceLoader.exists(path):
		return false
	var ps := load(path) as PackedScene
	if ps == null:
		return false
	var model := ps.instantiate()
	var mesh_name := String(m.get("screen_mesh_name", "Screen"))
	var screen := model.find_child(mesh_name, true, false) as MeshInstance3D
	if screen == null:
		push_warning("Vario90s3D: в %s нет меша %s — корпус из примитивов" % [path, mesh_name])
		model.free()
		return false
	model.name = "Model"
	# Экран должен смотреть в +Z (к пилоту); если в модели он смотрит назад — разворачиваем.
	if _screen_normal(screen, model).z < 0.0:
		model.rotate_y(PI)
	add_child(model)
	screen.material_override = _screen_mat
	screen_mesh = screen
	return true


## Средняя нормаль меша экрана в координатах модели.
static func _screen_normal(screen: MeshInstance3D, model: Node) -> Vector3:
	var n := Vector3.ZERO
	if screen.mesh and screen.mesh.get_surface_count() > 0:
		var arr := screen.mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for v in normals:
			n += v
	var xf := Transform3D.IDENTITY
	var node: Node = screen
	while node != null and node != model:
		if node is Node3D:
			xf = (node as Node3D).transform * xf
		node = node.get_parent()
	return (xf.basis * n).normalized()


func _make_screen_material(m: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = float(m.get("screen_roughness", 0.5))
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var emission := float(m.get("screen_emission", 0.0))
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = Color.WHITE
		mat.emission_energy_multiplier = emission
	return mat


## Проброс: данные полёта в прибор.
func update(t: Telemetry, dt: float = -1.0) -> void:
	vario90s.update(t, dt)


## Показывать экран другого VarioDisplay90s (если понадобится общий прибор на несколько корпусов).
## Свой встроенный прибор при этом отключается, чтобы не рисовать экран дважды.
func use_instrument(vd: VarioDisplay90s) -> void:
	if vd != vario90s and vario90s != null:
		vario90s.process_mode = Node.PROCESS_MODE_DISABLED
		vario90s.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vario90s = vd
	_screen_mat.albedo_texture = vd.get_texture()
	if _screen_mat.emission_enabled:
		_screen_mat.emission_texture = vd.get_texture()


func _build(m: Dictionary) -> void:
	var body_size := _vec3(m.get("body_size_m", [0.08, 0.09, 0.05]))
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = body_size
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(String(m.get("body_color", "#2a2a28")))
	body_mat.roughness = 0.6
	box.material = body_mat
	body.mesh = box
	add_child(body)
	# Экран круглый (циферблат); примитив — квадрат, вписанный в диаметр.
	var diameter := float(m.get("screen_diameter_m", 0.066))
	screen_mesh = MeshInstance3D.new()
	screen_mesh.name = "ScreenSurface"
	var quad := QuadMesh.new()
	quad.size = Vector2(diameter, diameter)
	screen_mesh.mesh = quad
	screen_mesh.position = Vector3(0.0, 0.0, body_size.z * 0.5 + 0.0005)
	quad.material = _screen_mat
	add_child(screen_mesh)


static func _vec3(a: Variant) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ONE * 0.1
