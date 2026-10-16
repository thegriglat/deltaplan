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
	var m0: ShaderMaterial = (c.get_child(0) as MeshInstance3D).material_override
	var m1: ShaderMaterial = (c.get_child(1) as MeshInstance3D).material_override
	for k in ["alpha_near", "alpha_far"]:
		check(float(m1.get_shader_parameter(k)) > float(m0.get_shader_parameter(k)), "активный заметнее: " + k)
	for m in [m0, m1]:
		check(float(m.get_shader_parameter("alpha_far")) > float(m.get_shader_parameter("alpha_near")), "вдали заметнее")
		check(float(m.get_shader_parameter("fade_far_m")) > float(m.get_shader_parameter("fade_near_m")), "fade_far > fade_near")
	approx(float(m0.get_shader_parameter("alpha_near")), 0.12, 1e-6, "вблизи как в v1")
	approx(float(m1.get_shader_parameter("alpha_near")), 0.3, 1e-6, "активный вблизи как в v1")
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
