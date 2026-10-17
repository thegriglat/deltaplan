extends TestCase
## Формы домов по профилю региона (RV-К4, RV-6): без новых ключей — как раньше; вальмовая (H2), плоская с парапетом (H1),
## потолок этажности домов по правилу.

const GOLDEN := "78af03e5515b981b6a2567e98d6e05a32517aa66123d178bbb25f0c860f4ff90"
const KEYS := ["walls", "wall_colors", "roofs", "roof_colors", "chimneys", "chimney_colors", "smoke"]


static func _flat(_x: float, _z: float) -> float:
	return 0.0


func _bc() -> Dictionary:
	return WorldObjects.load_config().buildings.duplicate(true)


## Фиксированный набор: село (двускат, плоская, 7 и 9 полей), город, промзона, разные углы.
func _houses() -> Array:
	var r := []
	for i in 60:
		var a := 30.0 + 7.0 * (i % 5)
		var wd := 6.0 + 1.5 * (i % 4)
		r.append([100.0 + 37.0 * i, 200.0 - 11.0 * i, a * 0.0 + wd, 5.0 + 0.7 * (i % 7), 17.0 * (i % 9), 4.0 + 0.5 * (i % 3), i % 6 == 5, 1, 1])
	for i in 15:
		r.append([2000.0 + 50.0 * i, 100.0, 25.0, 15.0 + i, 20.0 * (i % 4), 9.0 + 3.0 * i, 1, 2, 1])
	r.append([3000.0, 0.0, 40.0, 20.0, 0.0, 15.0, 1, 5, 0])
	r.append([3100.0, 0.0, 12.0, 8.0, 45.0, 6.0, 0, 1, 0])
	for h: Array in r:
		h[6] = int(h[6])
	return r


func _digest(tiles: Dictionary) -> String:
	var keys := tiles.keys()
	keys.sort()
	var s := ""
	for k in keys:
		for f: String in KEYS:
			var v: Variant = tiles[k][f]
			var acc := 0.0
			for e: Variant in v:
				if e is Transform3D:
					var t: Transform3D = e
					acc += t.origin.x * 1.3 + t.origin.y * 2.7 + t.origin.z * 0.9 + t.basis.x.x + t.basis.y.y * 3.1 + t.basis.z.z * 5.3 + t.basis.x.z * 7.7
				elif e is Color:
					acc += (e as Color).r + (e as Color).g * 2.0 + (e as Color).b * 3.0 + (e as Color).a * 4.0
				elif e is Vector3:
					acc += (e as Vector3).x + (e as Vector3).y * 2.0 + (e as Vector3).z * 3.0
			s += "%s %s %d %.2f\n" % [str(k), f, v.size(), acc]
	return s


func test_baseline_unchanged() -> void:
	var tiles := BuildingPlacer.place(_houses(), _bc(), _flat)
	var h := _digest(tiles).sha256_text()
	check(h == GOLDEN, "без новых ключей place() как до правки (эталон снят до RV-6): %s" % h)
	for k in tiles:
		check((tiles[k].hips as Dictionary).is_empty() and (tiles[k].parapets as Array).is_empty(), "форм нет")


func test_hip_roof() -> void:
	var bc := _bc()
	bc.village_roof = "hip"
	var recs := [[0.0, 0.0, 12.0, 8.0, 0.0, 4.0, 0, 1, 1], [100.0, 0.0, 7.0, 7.0, 30.0, 4.0, 0, 1, 1], [200.0, 0.0, 6.0, 14.0, 70.0, 3.0, 0, 1, 1]]
	var tiles := BuildingPlacer.place(recs, bc, _flat)
	var n := 0
	var gable := 0
	var tris := 0
	for k in tiles:
		gable += (tiles[k].roofs as Array).size()
		for bin: int in tiles[k].hips:
			var hp: Dictionary = tiles[k].hips[bin]
			var mesh := BuildingPlacer.hip_mesh(bin)
			tris += (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3 * hp.xf.size()
			for xf: Transform3D in hp.xf:
				n += 1
				var span := minf(xf.basis.x.length(), xf.basis.z.length())
				var rh := xf.basis.y.length()
				var exp_h := span * 0.5 * tan(deg_to_rad(20.0))
				check(absf(rh - exp_h) < 0.01, "высота конька %.3f = %.3f" % [rh, exp_h])
	check(n == 3 and gable == 0, "все три — вальмовые, призм нет: %d/%d" % [n, gable])
	check(tris > 0, "треугольников крыши: %d" % tris)
	# геометрия: единичный куб, конёк на +0.5, грани смотрят наружу и вверх
	for bin in [3, 7, 10]:
		var m := BuildingPlacer.hip_mesh(bin)
		var box := m.get_aabb()
		check(box.size.is_equal_approx(Vector3(1, 1, 1)) and box.position.is_equal_approx(Vector3(-0.5, -0.5, -0.5)), "bin %d: единичный куб %s" % [bin, str(box)])
		var arr := m.surface_get_arrays(0)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var ok := true
		for i in vs.size():
			var c := Vector3(vs[i].x, 0.0, vs[i].z)
			var outward := ns[i].dot(c) >= -0.01 or absf(vs[i].x) < 0.01
			ok = ok and ns[i].y > 0.0 and outward
		check(ok, "bin %d: нормали вверх и наружу" % bin)
	# узлы: вальмовая — свой ArrayMesh, не PrismMesh
	var root := BuildingPlacer.make_nodes(tiles, bc)
	var arr_meshes := 0
	for c in root.get_children():
		var mmi := c as MultiMeshInstance3D
		if mmi:
			check(not (mmi.multimesh.mesh is PrismMesh), "PrismMesh не используется")
			arr_meshes += 1 if mmi.multimesh.mesh is ArrayMesh else 0
	check(arr_meshes > 0, "ArrayMesh крыши есть")
	root.free()


func test_flat_parapet() -> void:
	var bc := _bc()
	bc.village_roof = "flat_parapet"
	bc.city_roof = "flat_parapet"
	var recs := [[0.0, 0.0, 12.0, 8.0, 25.0, 4.0, 0, 1, 1], [100.0, 0.0, 30.0, 20.0, 0.0, 15.0, 1, 2, 1], [200.0, 0.0, 20.0, 20.0, 0.0, 6.0, 1, 5, 1]]
	var obs := ObstacleIndex.new()
	var tiles := BuildingPlacer.place(recs, bc, _flat, obs)
	var par := 0
	var roofs := 0
	var chim := 0
	for k in tiles:
		par += (tiles[k].parapets as Array).size()
		roofs += (tiles[k].roofs as Array).size() + (tiles[k].hips as Dictionary).size()
		chim += (tiles[k].chimneys as Array).size()
		var ph := float(bc.parapet_h_m)
		for xf: Transform3D in tiles[k].parapets:
			check(absf(xf.basis.y.length() - ph) < 1e-4, "высота парапета")
			check(xf.origin.y - ph * 0.5 >= 3.99, "парапет стоит на стенах: %.2f" % (xf.origin.y - ph * 0.5))
	check(par == 8, "парапет (4 коробки) у села и города, не у промзоны: %d" % par)
	check(roofs == 0 and chim == 0, "ни призм, ни труб")
	# высота препятствия = стены + парапет
	var hit := obs.hit(Vector3(0.0, 3.5, -20.0), Vector3(0.0, 3.5, 20.0))
	check(not hit.is_empty(), "дом с парапетом в препятствиях")
	var hit2 := obs.hit(Vector3(0.0, 4.4, -20.0), Vector3(0.0, 4.4, 20.0))
	check(not hit2.is_empty(), "препятствие выше стен на парапет")


func test_max_levels() -> void:
	var bc := _bc()
	bc.max_levels = 2
	bc.level_m = 3.0
	var recs := [
		[0.0, 0.0, 20.0, 12.0, 0.0, 27.0, 1, 2, 1],  # по правилу, 9 этажей
		[100.0, 0.0, 20.0, 12.0, 0.0, 27.0, 1, 2, 0],  # из OSM
		[200.0, 0.0, 10.0, 8.0, 0.0, 4.0, 0, 1, 1],  # по правилу, ниже потолка
		[300.0, 0.0, 10.0, 8.0, 0.0, 12.0, 0, 1],  # 8 полей — процедурный
	]
	var tiles := BuildingPlacer.place(recs, bc, _flat)
	var hs := {}
	for k in tiles:
		for xf: Transform3D in tiles[k].walls:
			hs[roundi(xf.origin.x)] = xf.basis.y.length() - float(bc.sink_m)
	check(absf(hs[0] - 6.0) < 1e-4, "по правилу ≤ 2 · 3 м: %.2f" % hs[0])
	check(absf(hs[100] - 27.0) < 1e-4, "из OSM без изменений: %.2f" % hs[100])
	check(absf(hs[200] - 4.0) < 1e-4, "ниже потолка без изменений: %.2f" % hs[200])
	check(absf(hs[300] - 12.0) < 1e-4, "запись без по_правилу без изменений: %.2f" % hs[300])
	bc.max_levels = 0
	tiles = BuildingPlacer.place(recs, bc, _flat)
	for k in tiles:
		for xf: Transform3D in tiles[k].walls:
			if roundi(xf.origin.x) == 0:
				check(absf(xf.basis.y.length() - float(bc.sink_m) - 27.0) < 1e-4, "max_levels 0 — без потолка")
