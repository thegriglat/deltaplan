extends TestCase
## Ткань лагеря (SC-4): шейдер, пресеты, общий материал на палатки разных цветов.


func test_presets() -> void:
	for p in ["tent", "tent_door", "bag", "fabric_dark", "sail", "cloth"]:
		var m := CampFabric.material(p)
		check(m != null and m.shader != null, "пресет %s: материал с шейдером" % p)
		check(CampFabric.material(p) == m, "пресет %s: тот же материал" % p)
		check(m.get_shader_parameter("fabric_normal") != null, "пресет %s: текстура нормали" % p)
	var tex := CampFabric.NORMAL
	check(tex.get_width() <= 512 and tex.get_height() <= 512, "нормаль ткани ≤ 512²")


func test_tents_share_material() -> void:
	var cfg: Dictionary = Config.get_config("world_objects").tents
	var tents: Array = []
	for i in 3:
		tents.append(
			{
				"type": "dome2",
				"position": Vector3(i * 10, 0, 0),
				"basis": Basis.IDENTITY,
				"color": i,
				"radius": 2.0
			}
		)
	var root := TentCamp.build_node(tents, cfg)
	var mats := {}
	var tints := {}
	for mi in root.find_children("LOD0", "MeshInstance3D", true, false):
		var inst := mi as MeshInstance3D
		for s in inst.mesh.get_surface_count():
			var m := inst.get_surface_override_material(s)
			if m is ShaderMaterial:
				mats[m] = true
		tints[inst.get_meta("camp_tint", Vector3.ZERO)] = true
	check(tints.size() == 3, "три палатки — три разных tint (%d)" % tints.size())
	for m in mats:
		check(String(m.resource_name).begins_with("CampFabric_"), "материал палатки — CampFabric")
	check(mats.size() <= 2, "материалов на все палатки ≤ 2 (Fabric, Door): %d" % mats.size())
	root.free()
