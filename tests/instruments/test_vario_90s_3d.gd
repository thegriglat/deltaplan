extends Node
## Корпус вариометра 90-х в 3D (стойка трапеции): сцена грузится, у Screen есть текстура,
## update(t) не падает.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_vario_90s_3d_screen() -> void:
	var v3: Vario90s3D = load("res://scenes/instruments/vario_90s_3d.tscn").instantiate()
	add_child(v3)
	check(v3.screen_mesh != null, "меш экрана найден (модель или примитив)")
	var mat := v3.screen_mesh.material_override as StandardMaterial3D
	if mat == null:
		mat = (v3.screen_mesh.mesh as QuadMesh).material as StandardMaterial3D
	check(mat != null and mat.albedo_texture != null, "текстура экрана назначена")
	var t := Telemetry.new()
	t.vario = 1.5
	for i in 10:
		v3.update(t, 1.0 / 60.0)
	check(true, "update(t) не падает")
	v3.free()
