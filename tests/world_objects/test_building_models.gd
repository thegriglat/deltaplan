extends TestCase
## Модели домов в BuildingPlacer (RV-К6, RV-10): доля кандидатов (село, высота не из OSM, малая площадь) → модели,
## остальное — коробки; детерминизм; нет модели — коробки; share 0 — как раньше.


static func _flat(_x: float, _z: float) -> float:
	return 0.0


func _bc(share: float, with_file: bool = true) -> Dictionary:
	var bc: Dictionary = WorldObjects.load_config().buildings.duplicate(true)
	bc["models"] = {
		"tin_house": {"path": "res://assets/models/houses/_absent_.glb" if with_file else "res://none.glb", "size_m": [8.0, 6.0]},
		"rondavel": {"path": "res://assets/models/houses/_absent2_.glb", "size_m": [5.0, 5.0]},
	}
	bc["village_models"] = [{"name": "tin_house", "weight": 1.0}, {"name": "rondavel", "weight": 1.0}]
	bc["village_model_share"] = share
	return bc


## 40 малых сельских (7 полей), 10 сельских с высотой из OSM (9 полей, не по правилу), город, большой сельский.
func _houses() -> Array:
	var r := []
	for i in 40:
		r.append([100.0 + 37.0 * i, 200.0 - 11.0 * i, 6.0 + (i % 3), 5.0 + (i % 4), 15.0 * (i % 7), 4.0, 0])
	for i in 10:
		r.append([5000.0 + 40.0 * i, 0.0, 7.0, 6.0, 10.0, 5.0, 0, 1, 0])
	for i in 5:
		r.append([2000.0 + 50.0 * i, 100.0, 25.0, 15.0, 0.0, 12.0, 1, 2, 1])
	r.append([3000.0, 0.0, 20.0, 12.0, 0.0, 4.0, 0, 1, 1])  # 240 м² — больше порога
	for h: Array in r:
		h[6] = int(h[6])
	return r


func _setup_models() -> void:
	var box := BoxMesh.new()
	box.material = StandardMaterial3D.new()
	BuildingPlacer.test_models = {
		"tin_house": [box, box, box],
		"rondavel": [box, box, box],
	}


func _count(tiles: Dictionary, field: String) -> int:
	var n := 0
	for k in tiles:
		n += (tiles[k][field] as Array).size()
	return n


func _models(tiles: Dictionary) -> int:
	var n := 0
	for k in tiles:
		for m: String in tiles[k].models:
			n += (tiles[k].models[m].xf as Array).size()
	return n


func test_share_zero_same() -> void:
	_setup_models()
	var a := BuildingPlacer.place(_houses(), _bc(0.0), _flat)
	var base: Dictionary = WorldObjects.load_config().buildings.duplicate(true)
	var b := BuildingPlacer.place(_houses(), base, _flat)
	check(_models(a) == 0 and _models(b) == 0, "share 0 — моделей нет")
	check(_count(a, "walls") == _count(b, "walls") and _count(a, "walls") == 56, "коробок как раньше")
	BuildingPlacer.test_models = {}


func test_share_one_candidates_only() -> void:
	_setup_models()
	var tiles := BuildingPlacer.place(_houses(), _bc(1.0), _flat)
	check(_models(tiles) == 40, "модели — 40 малых сельских: %d" % _models(tiles))
	check(_count(tiles, "walls") == 16, "коробки — остальные 16: %d" % _count(tiles, "walls"))
	var kinds := {}
	for k in tiles:
		for m: String in tiles[k].models:
			kinds[m] = true
	check(kinds.size() == 2, "обе модели по весам использованы")
	BuildingPlacer.test_models = {}


func test_scale_and_obstacles() -> void:
	_setup_models()
	var bc := _bc(1.0)
	bc["village_models"] = [{"name": "tin_house", "weight": 1.0}]
	var obs := ObstacleIndex.new()
	var tiles := BuildingPlacer.place([[0.0, 0.0, 8.0, 6.0, 0.0, 4.0, 0]], bc, _flat, obs)
	var xf: Transform3D = tiles.values()[0].models.tin_house.xf[0]
	approx(xf.basis.get_scale().x, 1.0, 0.001, "масштаб X = w/8")
	approx(xf.basis.get_scale().z, 1.0, 0.001, "масштаб Z = l/6")
	tiles = BuildingPlacer.place([[0.0, 0.0, 4.0, 3.0, 0.0, 4.0, 0]], bc, _flat)
	xf = tiles.values()[0].models.tin_house.xf[0]
	approx(xf.basis.get_scale().y, 0.5, 0.001, "Y — среднее X/Z")
	tiles = BuildingPlacer.place([[0.0, 0.0, 6.0, 8.0, 0.0, 4.0, 0]], bc, _flat)
	xf = tiles.values()[0].models.tin_house.xf[0]
	approx(xf.basis.get_scale().x, 1.0, 0.001, "длинная сторона модели вдоль длинной стороны дома")
	BuildingPlacer.test_models = {}


func test_deterministic() -> void:
	_setup_models()
	var bc := _bc(0.5)
	var a := BuildingPlacer.place(_houses(), bc, _flat)
	var b := BuildingPlacer.place(_houses(), bc, _flat)
	check(_models(a) == _models(b) and _count(a, "walls") == _count(b, "walls"), "повтор даёт то же")
	check(_models(a) > 0 and _models(a) < 40, "доля 0,5 — часть домов: %d" % _models(a))
	BuildingPlacer.test_models = {}


func test_missing_file_boxes() -> void:
	BuildingPlacer.test_models = {}
	var tiles := BuildingPlacer.place(_houses(), _bc(1.0), _flat)
	check(_models(tiles) == 0 and _count(tiles, "walls") == 56, "файла нет — всё коробки")


func test_nodes_lods() -> void:
	_setup_models()
	var bc := _bc(1.0)
	var tiles := BuildingPlacer.place(_houses(), bc, _flat)
	var root := BuildingPlacer.make_nodes(tiles, bc)
	var n0 := 0
	var n2 := 0
	for c in root.get_children():
		var mi := c as MultiMeshInstance3D
		if mi != null and mi.visibility_range_begin == 0.0 and mi.visibility_range_end == 250.0:
			n0 += 1
		if mi != null and mi.visibility_range_begin == 1500.0:
			n2 += 1
			check(mi.visibility_range_end == float(bc.visibility_m), "LOD2 до visibility_m")
	check(n0 > 0 and n2 == n0, "LOD0 и LOD2 на каждую модель × тайл")
	root.free()
	BuildingPlacer.test_models = {}
