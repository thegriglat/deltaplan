class_name WindIndicator
extends Node3D
## Ветроуказатель-конус или вешка с лентой (VR-7). Визуал — сцена из конфига (scene_path) с
## маркером Pivot (ось вращения по ветру) и мешем-тканью Sock или Ribbon, вытянутым вдоль −Z.
## Логика — WindClothModel; ткань гнёт wind_cloth.gdshader (параметры экземпляра).
## Ветер подаёт родитель (WorldObjects): update_wind(dt, air_velocity_at(pivot_position())).
## Нет файла визуала — процедурная заглушка (мачта-цилиндр + конус) и предупреждение в лог.

const CLOTH_NAMES: PackedStringArray = ["Sock", "Ribbon"]
const SHADER := preload("res://scripts/world_objects/wind_cloth.gdshader")

## "windsock" или "streamers" — раздел configs/world_objects.json.
var kind: String = "windsock"
var model: WindClothModel
var pivot: Node3D
var cloth: Array[MeshInstance3D] = []
var materials: Array[ShaderMaterial] = []

var _cfg: Dictionary = {}


## cfg — раздел конфига (windsock / streamers) с учётом пресета качества.
func setup(kind_name: String, cfg: Dictionary, scale_k: float = 1.0) -> void:
	kind = kind_name
	_cfg = cfg
	model = WindClothModel.new(cfg)
	var visual := _load_visual(String(cfg.get("scene_path", "")))
	visual.scale = Vector3.ONE * scale_k
	add_child(visual)
	pivot = _find(visual, "Pivot") as Node3D
	if pivot == null:
		push_warning("WindIndicator: в визуале нет маркера Pivot — ткань не будет вращаться")
		pivot = visual
	_setup_cloth(visual)
	_set_visibility(
		visual, float(cfg.get("visibility_m", 0.0)), bool(cfg.get("cast_shadows", true))
	)


## Где спрашивать ветер (вертлюг), мир.
func pivot_position() -> Vector3:
	if is_inside_tree():
		return pivot.global_position
	var xf := Transform3D.IDENTITY
	var n: Node = pivot
	while n != null and n != self:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return (transform * xf).origin


## Шаг анимации по локальному воздуху у вертлюга, м/с.
func update_wind(dt: float, air: Vector3) -> void:
	model.step(dt, air)
	apply()


## Поставить сразу в равновесие (при создании).
func reset_wind(air: Vector3) -> void:
	model.reset(air)
	apply()


func apply() -> void:
	pivot.rotation = Vector3(model.pitch, model.yaw, 0.0)
	for m in materials:
		m.set_shader_parameter(&"fill", model.fill)
		m.set_shader_parameter(&"flutter_amp", model.flutter_amp)
		m.set_shader_parameter(&"flutter_phase", model.flutter_phase)


func _load_visual(path: String) -> Node3D:
	if path != "" and ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			return ps.instantiate() as Node3D
	push_warning("WindIndicator: нет визуала '%s' — процедурная заглушка" % path)
	return WindIndicator.build_placeholder(_cfg)


func _setup_cloth(visual: Node) -> void:
	for n in CLOTH_NAMES:
		var mi := _find(visual, n) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		cloth.append(mi)
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, _cloth_material(mi.mesh.surface_get_material(i)))
		# Ткань гнётся шейдером — расширяем AABB, чтобы не отсекалась при провисании.
		var len_m := _cloth_length()
		mi.custom_aabb = AABB(
			Vector3(-len_m, -len_m * 1.2, -len_m * 1.3), Vector3.ONE * len_m * 2.5
		)
	if cloth.is_empty():
		push_warning("WindIndicator: в визуале нет меша Sock/Ribbon")


func _cloth_length() -> float:
	return float(_cfg.get("sock_length_m", _cfg.get("ribbon_length_m", 1.0)))


func _cloth_material(src: Material) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	var col := Color(1.0, 0.4, 0.05)
	var rough := 0.8
	if src is BaseMaterial3D:
		col = (src as BaseMaterial3D).albedo_color
		rough = (src as BaseMaterial3D).roughness
	m.set_shader_parameter(&"albedo", col)
	m.set_shader_parameter(&"roughness", rough)
	m.set_shader_parameter(&"cloth_length", _cloth_length())
	m.set_shader_parameter(&"root_offset", float(_cfg.get("root_offset_m", 0.0)))
	m.set_shader_parameter(&"droop_root", deg_to_rad(float(_cfg.get("droop_root_deg", 70.0))))
	m.set_shader_parameter(&"droop_tip", deg_to_rad(float(_cfg.get("droop_tip_deg", 89.0))))
	m.set_shader_parameter(&"collapse", float(_cfg.get("collapse", 0.5)))
	m.set_shader_parameter(&"wave_count", float(_cfg.get("wave_count", 1.2)))
	materials.append(m)
	return m


func _set_visibility(root: Node, range_m: float, shadows: bool) -> void:
	for gi in root.find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		if range_m > 0.0:
			g.visibility_range_end = range_m
		if not shadows:
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _find(root: Node, node_name: String) -> Node:
	if root.name == node_name:
		return root
	return root.find_child(node_name, true, false)


## Заглушка: мачта-цилиндр и конус-ткань вдоль −Z (если модель не найдена).
static func build_placeholder(cfg: Dictionary) -> Node3D:
	var root := Node3D.new()
	var len_m := float(cfg.get("sock_length_m", cfg.get("ribbon_length_m", 1.0)))
	var root_off := float(cfg.get("root_offset_m", 0.0))
	var height := float(cfg.get("placeholder_height_m", 4.0))
	var mast := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.03
	cyl.bottom_radius = 0.04
	cyl.height = height
	mast.mesh = cyl
	mast.position.y = height * 0.5
	root.add_child(mast)
	var pv := Node3D.new()
	pv.name = "Pivot"
	pv.position.y = height
	root.add_child(pv)
	var sock := MeshInstance3D.new()
	sock.name = "Sock"
	sock.mesh = _cone_mesh(len_m, len_m * 0.1, len_m * 0.05, root_off)
	pv.add_child(sock)
	return root


## Усечённый конус вдоль −Z от root до root + len (открытые концы), 8 колец × 12 сторон.
static func _cone_mesh(len_m: float, r0: float, r1: float, root: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 8
	var sides := 12
	for i in rings:
		for j in sides:
			var quad: Array[Vector3] = []
			for c in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var t := float(c[0]) / rings
				var a := TAU * float(c[1]) / sides
				var r := lerpf(r0, r1, t)
				quad.append(Vector3(r * cos(a), r * sin(a), -(root + t * len_m)))
			for k in [0, 1, 2, 0, 2, 3]:
				st.add_vertex(quad[k])
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.36, 0.04)
	mesh.surface_set_material(0, mat)
	return mesh
