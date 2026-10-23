extends TestCase
## TP-16: текстуры и шейдеры дельталёта как у дельтапланов — Basis Universal + mipmaps у паруса,
## процедурные FrameMetal на трубах/металле/фитингах крыла и тележки.


func _shader_count(root: Node) -> int:
	var n := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_material(i) is ShaderMaterial:
				n += 1
	return n


func test_sail_import_like_other_wings() -> void:
	var cf := ConfigFile.new()
	check(cf.load("res://assets/models/glider_trike_ixess15_glider_trike_ixess15_sail.png.import") == OK, "import-файл паруса читается")
	check(int(cf.get_value("params", "compress/mode", -1)) == 4, "парус: compress/mode=4 (Basis Universal)")
	check(bool(cf.get_value("params", "mipmaps/generate", false)), "парус: mipmaps")


func test_frame_metal_on_cart_and_wing() -> void:
	var v := TowTrikeVisual.new()
	v.setup({}, false)
	check(v.cart != null and v.wing != null, "тележка и крыло загружены")
	if v.cart != null and v.wing != null:
		check(_shader_count(v.wing) >= 3, "крыло: Tube/Steel/Fitting/Wire — процедурные шейдеры")
		check(_shader_count(v.cart) >= 3, "тележка: трубы, сталь, фитинги — процедурные шейдеры")
	v.free()
