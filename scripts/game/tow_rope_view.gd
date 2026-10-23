class_name TowRopeView
extends Node3D
## Вид троса (TW-10): тонкая линия по TowLine.points(n), обновляется каждый кадр. Трос выбран полностью —
## скрыт. Точки — в мире игры (узел в начале координат, без поворота).

const POINTS := 16
const COLOR := Color(0.85, 0.45, 0.1)

var _mi := MeshInstance3D.new()
var _mesh := ImmediateMesh.new()


func _init() -> void:
	name = "TowRopeView"
	_mi.mesh = _mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = COLOR
	_mi.material_override = m
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = 16384.0
	add_child(_mi)
	_mi.visible = false


## pts — TowLine.points(POINTS); пусто — скрыть.
func update(pts: PackedVector3Array) -> void:
	_mesh.clear_surfaces()
	if pts.size() < 2:
		_mi.visible = false
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in pts:
		_mesh.surface_add_vertex(p)
	_mesh.surface_end()
	_mi.visible = true


func is_shown() -> bool:
	return _mi.visible
