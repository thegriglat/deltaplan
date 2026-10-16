extends TestCase
## GoalCylinders: число столбов, активный отличается, enabled=false — невидим.

func _pts() -> Array:
	return [
		{"name": "A", "position": Vector3(0, 100, 0), "radius_m": 400.0, "active": false},
		{"name": "B", "position": Vector3(5000, 200, 0), "radius_m": 400.0, "active": true},
	]


func _make(enabled: bool) -> GoalCylinders:
	var c := GoalCylinders.new()
	var cfg: Dictionary = Config.get_config("goals/world")
	cfg["cylinders"]["enabled"] = enabled
	c.set_points(_pts())
	return c


func test_enabled() -> void:
	var c := _make(true)
	check(c.visible, "виден")
	check(c.pillar_count() == 2, "два столба")
	check(not c.is_pillar_active(0) and c.is_pillar_active(1), "активный — второй")
	var m0: StandardMaterial3D = (c.get_child(0) as MeshInstance3D).material_override
	var m1: StandardMaterial3D = (c.get_child(1) as MeshInstance3D).material_override
	check(m1.albedo_color.a > m0.albedo_color.a, "активный заметнее")
	var mi := c.get_child(1) as MeshInstance3D
	var h := float((mi.mesh as CylinderMesh).height)
	check(is_equal_approx(mi.position.y - h * 0.5, 200.0), "столб от земли")
	c.free()
	Config.get_config("goals/world")["cylinders"]["enabled"] = false


func test_disabled() -> void:
	var c := _make(false)
	check(not c.visible, "невидим")
	check(c.pillar_count() == 0, "меши не строятся")
	c.free()
