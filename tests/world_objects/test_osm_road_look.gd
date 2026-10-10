extends TestCase
## Вид дорог и земля города (L7, L8, OL-5): UV вдоль ленты в метрах, код вида в UV2, маска города по плотности домов.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=osm_road_look


static func _flat(_x: float, _z: float) -> float:
	return 10.0


func _cfg() -> Dictionary:
	return WorldObjects.load_config()


func test_strip_uv_meters_and_style() -> void:
	var cfg := _cfg()
	var rc: Dictionary = cfg.roads
	# прямая дорога 400 м, шаг 12 м: UV.y — расстояние вдоль, UV2 — (код вида, ширина)
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(400, 0)])
	var out := RoadMesher.build([{"t": "primary", "p": pts}, {"t": "track", "p": pts}, {"t": "residential", "p": pts}], rc, _flat)
	check(not out.is_empty(), "ленты построены")
	var styles := {}
	for k in out:
		var arrays: Array = out[k].arrays
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		check(uv.size() == uv2.size() and uv.size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "UV и UV2 на каждую вершину")
		var vmax := 0.0
		for i in uv.size():
			vmax = maxf(vmax, uv[i].y)
			check(uv[i].x == 0.0 or uv[i].x == 1.0, "UV.x — край ленты 0/1")
			styles[uv2[i].x] = true
		check(absf(vmax - 400.0) < 0.01, "UV.y вдоль — метры: %f" % vmax)
	check(styles.has(1.0) and styles.has(4.0) and styles.has(0.0), "коды вида: пунктир+края, грунтовка, асфальт: %s" % [styles.keys()])


func test_uv_continuous_across_tiles() -> void:
	var rc: Dictionary = _cfg().roads
	# ломаная пересекает границу тайла (tile_m): v не обнуляется
	var tile := float(rc.tile_m)
	var pts := PackedVector2Array([Vector2(tile - 200.0, 5.0), Vector2(tile + 200.0, 5.0)])
	var out := RoadMesher.build([{"t": "secondary", "p": pts}], rc, _flat)
	check(out.size() == 2, "лента в двух тайлах: %d" % out.size())
	var vmax := 0.0
	for k in out:
		for u: Vector2 in out[k].arrays[Mesh.ARRAY_TEX_UV]:
			vmax = maxf(vmax, u.y)
	check(absf(vmax - 400.0) < 0.01, "v сквозной вдоль всей дороги: %f" % vmax)


func test_roads_use_road_shader_water_not() -> void:
	var d := OsmData.new()
	d.roads.append({"t": "primary", "p": PackedVector2Array([Vector2(0, 0), Vector2(300, 0)]), "tunnel": false})
	d.rivers.append({"t": "canal", "p": PackedVector2Array([Vector2(0, 50), Vector2(300, 50)])})
	var node := OsmRoads.build(d, _cfg(), _flat, ObstacleIndex.new())
	check(node != null, "узел построен")
	if node == null:
		return
	var roads := node.get_node("Roads").get_child(0) as MeshInstance3D
	check((roads.material_override as ShaderMaterial).shader == OsmRoads.ROAD_SHADER, "дороги — road.gdshader")
	var riv := node.get_node("Rivers").get_child(0) as MeshInstance3D
	check((riv.material_override as ShaderMaterial).shader == OsmRoads.DRAPED_SHADER, "реки — draped.gdshader")
	node.free()


func test_city_ground_mask() -> void:
	var d := OsmData.new()
	# плотный квартал 1000×1000 м (дом 20×20 м через 30 м, доля ~0,18) и одиночные дома далеко
	for i in 33:
		for j in 33:
			d.buildings.append([float(i) * 30.0, float(j) * 30.0, 10.0, 10.0, 0.0, 9.0, 0])
	for i in 60:
		d.buildings.append([8000.0 + i * 200.0, 8000.0, 6.0, 6.0, 0.0, 4.0, 1])
	var cfg := _cfg()
	var node := OsmCityGround.build(d, cfg, _flat)
	check(node != null, "земля города построена")
	if node == null:
		return
	var st: Dictionary = node.get_meta(&"stats")
	check(int(st.tiles) >= 1 and int(st.tiles) <= 4, "тайлов немного (город — один квартал): %s" % st)
	# все вершины — вокруг квартала, не у далёких одиночных домов
	var far := false
	for mi: MeshInstance3D in node.get_children():
		if mi.position.x > 6000.0:
			far = true
		var cols: PackedColorArray = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		var amax := 0.0
		for c in cols:
			amax = maxf(amax, c.a)
		check(amax > 0.99, "в центре города подложка непрозрачная")
	check(not far, "сёла вдали остаются с травой")
	node.free()
	cfg.city_ground.enabled = false
	check(OsmCityGround.build(d, cfg, _flat) == null, "enabled=false — слоя нет")
