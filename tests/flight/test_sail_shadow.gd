extends TestCase
## Тень паруса (VR-6): парус отбрасывает тень на землю, но сам тени не принимает —
## иначе своя тень гасит просвечивание нижней обшивки (docs/models.md → «Шейдер паруса»).


func test_sail_casts_shadow_but_keeps_glow() -> void:
	var model := "glider_sport"
	var wing := (load("res://assets/models/%s.glb" % model) as PackedScene).instantiate() as Node3D
	var sail := wing.find_child("Sail", true, false) as MeshInstance3D
	check(sail != null, "в модели есть меш Sail")
	var mat := SailMaterial.apply(sail, model)
	check(mat != null, "шейдер паруса поставлен")
	check(
		sail.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"парус отбрасывает тень на землю"
	)
	check(
		mat.shader.code.contains("shadows_disabled"),
		"парус не принимает тени (просвечивание снизу не гаснет)"
	)
	wing.free()
