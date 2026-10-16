extends TestCase
## Слой судов (ShipLayer, SEA-4): без судов — ни одного узла; LOD с дальностями видимости, тени только у LOD0,
## материал с вершинными цветами, ватерлиния y = 0, курс.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=ship_layer


func _rp() -> Dictionary:
	return {"lod_m": [6000, 25000], "cast_shadow_lod0": true, "roughness": 0.6}


func test_no_sea_no_nodes() -> void:
	var l := ShipLayer.new()
	l.build([], _rp())
	check(l.get_child_count() == 0 and l.ship_count == 0, "без судов узлов нет")
	check(not l.is_processing() and not l.is_physics_processing(), "без _process")
	l.build(ShipPlacer.ships_for({}, 0.0, 0.0, ShipPlacer.params_from_config()), _rp())
	check(l.get_child_count() == 0, "нет маски — узлов нет")
	l.free()


func test_lod_nodes() -> void:
	var l := ShipLayer.new()
	l.build([{"type": "tanker", "x": 1000.0, "z": -2000.0, "heading_rad": PI / 2.0, "cell": Vector2i(1, 2)}], _rp())
	check(l.ship_count == 1 and l.get_child_count() == 3, "судно — 3 узла LOD: %d" % l.get_child_count())
	var far := float(Config.value("world", "rendering.camera_far_m", 110000.0))
	var want := [[0.0, 6000.0], [6000.0, 25000.0], [25000.0, far]]
	for k in 3:
		var mi := l.get_child(k) as MeshInstance3D
		check(mi != null and mi.mesh != null, "LOD%d: сетка" % k)
		check(is_equal_approx(mi.visibility_range_begin, want[k][0]) and is_equal_approx(mi.visibility_range_end, want[k][1]),
			"LOD%d: видимость %.0f…%.0f" % [k, mi.visibility_range_begin, mi.visibility_range_end])
		var sh := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if k == 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		check(mi.cast_shadow == sh, "LOD%d: тень %d" % [k, mi.cast_shadow])
		var mat := mi.material_override as StandardMaterial3D
		check(mat != null and mat.vertex_color_use_as_albedo and mat.albedo_texture == null, "LOD%d: вершинные цвета, без текстур" % k)
		check(mi.position.is_equal_approx(Vector3(1000, 0, -2000)), "LOD%d: ватерлиния y = 0" % k)
		var nose := mi.transform.basis * Vector3(0, 0, -1)
		check(nose.is_equal_approx(Vector3(1, 0, 0)), "курс 90° — нос на восток (+X): %s" % nose)
	check(l.get_child(1).mesh.get_faces().size() < l.get_child(0).mesh.get_faces().size(), "LOD1 проще LOD0")
	l.build([{"type": "tanker", "x": 0.0, "z": 0.0, "heading_rad": 0.0, "cell": Vector2i.ZERO}], {"lod_m": [6000, 25000], "cast_shadow_lod0": false})
	for c in l.get_children():
		if not c.is_queued_for_deletion():
			check((c as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "cast_shadow_lod0 false — без теней")
	l.free()


func test_missing_model_skipped() -> void:
	var l := ShipLayer.new()
	l.build([{"type": "no_such_kind", "x": 0.0, "z": 0.0, "heading_rad": 0.0, "cell": Vector2i.ZERO}], _rp())
	check(l.ship_count == 0 and l.skipped == 1 and l.get_child_count() == 0, "вид без .glb пропущен")
	l.free()


func test_tanker_model_lods() -> void:
	var ms := ShipLayer.load_meshes("tanker")
	check(ms.size() == 3, "танкер: 3 LOD")
	if ms.size() == 3:
		var aabb: AABB = ms[0].get_aabb()
		check(absf(aabb.size.z - 250.0) < 5.0, "длина 250 м (масштаб 1 = 1 м): %.1f" % aabb.size.z)
