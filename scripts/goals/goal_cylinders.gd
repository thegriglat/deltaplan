class_name GoalCylinders
extends Node3D
## Столбы-цилиндры пунктов ведущего маршрута в мире (GL-К4, docs/contracts/goals.md).
## Видны только при configs/goals/world.json → cylinders.enabled; активный пункт заметнее.
## Один меш на столб, два общих материала (без записи глубины, двусторонние, без освещения).

const CONFIG := "goals/world"

var _points: Array = []
var _cfg: Dictionary = {}
var _mat := StandardMaterial3D.new()
var _mat_active := StandardMaterial3D.new()


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


func _color(key: String, fallback: Color, alpha: float) -> Color:
	var a: Array = _cfg.get(key, [])
	var c := Color(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else fallback
	c.a = alpha
	return c


func _setup_material(m: StandardMaterial3D, c: Color) -> void:
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_fog = true
	m.albedo_color = c


func _rebuild() -> void:
	_cfg = Config.get_config(CONFIG).get("cylinders", {})
	visible = bool(_cfg.get("enabled", false))
	for ch in get_children():
		remove_child(ch)
		ch.queue_free()
	if not visible:
		return
	_setup_material(_mat, _color("color", Color(0.2, 0.75, 1.0), float(_cfg.get("alpha", 0.12))))
	_setup_material(_mat_active, _color("color_active", Color(1.0, 0.6, 0.1), float(_cfg.get("alpha_active", 0.3))))
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
