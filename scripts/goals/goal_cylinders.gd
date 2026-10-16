class_name GoalCylinders
extends Node3D
## Столбы-цилиндры пунктов ведущего маршрута в мире (GL-К4, docs/contracts/goals.md).
## Видны только при configs/goals/world.json → cylinders.enabled; активный пункт заметнее.
## Один меш на столб, два общих материала (шейдер goal_cylinders.gdshader: альфа растёт с расстоянием до камеры).

const CONFIG := "goals/world"

var _points: Array = []
var _cfg: Dictionary = {}
var _shader: Shader = preload("res://scripts/goals/goal_cylinders.gdshader")
var _mat := ShaderMaterial.new()
var _mat_active := ShaderMaterial.new()


func _ready() -> void:
	Config.reloaded.connect(_on_reloaded)
	_on_reloaded()


## points — формат GoalTracker.world_points(): [{name, position (y — земля), radius_m, active}].
func set_points(points: Array) -> void:
	_points = points.duplicate()
	_rebuild()


## Число построенных столбов.
func pillar_count() -> int:
	return get_child_count()


func is_pillar_active(i: int) -> bool:
	return get_child(i).get_meta("active", false)


func _on_reloaded() -> void:
	_rebuild()


func _color(key: String, fallback: Color) -> Color:
	var a: Array = _cfg.get(key, [])
	return Color(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else fallback


func _setup_material(m: ShaderMaterial, c: Color, a_near: float, a_far: float) -> void:
	m.shader = _shader
	m.set_shader_parameter("color", c)
	m.set_shader_parameter("alpha_near", a_near)
	m.set_shader_parameter("alpha_far", a_far)
	m.set_shader_parameter("fade_near_m", float(_cfg.get("fade_near_m", 500.0)))
	m.set_shader_parameter("fade_far_m", float(_cfg.get("fade_far_m", 4000.0)))


func _rebuild() -> void:
	_cfg = Config.get_config(CONFIG).get("cylinders", {})
	visible = bool(_cfg.get("enabled", false))
	for ch in get_children():
		remove_child(ch)
		ch.queue_free()
	if not visible:
		return
	_setup_material(
		_mat,
		_color("color", Color(0.2, 0.75, 1.0)),
		float(_cfg.get("alpha_near", 0.12)),
		float(_cfg.get("alpha_far", 0.35))
	)
	_setup_material(
		_mat_active,
		_color("color_active", Color(1.0, 0.6, 0.1)),
		float(_cfg.get("alpha_active_near", 0.3)),
		float(_cfg.get("alpha_active_far", 0.6))
	)
	var h := float(_cfg.get("height_m", 2000.0))
	var seg := int(_cfg.get("segments", 32))
	for p: Dictionary in _points:
		var pos: Vector3 = p.get("position", Vector3.ZERO)
		var r := float(p.get("radius_m", 400.0))
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r
		cm.height = h
		cm.radial_segments = seg
		cm.rings = 1
		var active := bool(p.get("active", false))
		var mi := MeshInstance3D.new()
		mi.name = String(p.get("name", "")).validate_node_name()
		mi.mesh = cm
		mi.material_override = _mat_active if active else _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("active", active)
		mi.position = Vector3(pos.x, pos.y + h * 0.5, pos.z)
		add_child(mi)
