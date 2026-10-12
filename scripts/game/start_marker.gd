class_name StartMarker
extends Node3D
## Маркер точки старта в осмотре: кружок на земле и стрелка курса (простая геометрия).
## Допустимая точка — зелёный, недопустимая — красный.

const OK_COLOR := Color(0.2, 0.9, 0.3)
const BAD_COLOR := Color(0.95, 0.15, 0.1)
const ARROW_M := 14.0
const RING_M := 3.0

var _mi := MeshInstance3D.new()
var _mat := StandardMaterial3D.new()
var _color := OK_COLOR


func _init() -> void:
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.no_depth_test = true
	_mat.render_priority = 10
	_mat.vertex_color_use_as_albedo = true
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)
	visible = false


## Точка pos (на земле), курс heading_deg (0 = −Z, по часовой), ok — допустима ли.
func show_spot(pos: Vector3, heading_deg: float, ok: bool) -> void:
	_color = OK_COLOR if ok else BAD_COLOR
	global_position = pos + Vector3(0, 0.3, 0)
	_mi.mesh = _build(deg_to_rad(heading_deg))
	visible = true


func _build(h: float) -> ArrayMesh:
	var f := Vector3(sin(h), 0, -cos(h))
	var r := Vector3(cos(h), 0, sin(h))
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	# Кружок (веер из 16 треугольников).
	for i in 16:
		var a0 := TAU * i / 16.0
		var a1 := TAU * (i + 1) / 16.0
		verts.append(Vector3.ZERO)
		verts.append(Vector3(cos(a0), 0, sin(a0)) * RING_M)
		verts.append(Vector3(cos(a1), 0, sin(a1)) * RING_M)
	# Стрелка: древко и наконечник.
	var w := 0.7
	var tail := f * RING_M
	var neck := f * (ARROW_M - 4.0)
	var tip := f * ARROW_M
	verts.append_array([tail - r * w, tail + r * w, neck + r * w])
	verts.append_array([tail - r * w, neck + r * w, neck - r * w])
	verts.append_array([neck - r * 2.5, neck + r * 2.5, tip])
	cols.resize(verts.size())
	cols.fill(_color)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
