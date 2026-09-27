extends TestCase
## Тесты расстановки деревьев-моделей (TreePlacer, TerrainTreeModels).

static var _terrain: Terrain


func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("altai")
	return _terrain


func _placer(t: Terrain) -> TreePlacer:
	var p := TreePlacer.new()
	p.setup(t.layers[0], t.surfaces[0], Config.get_config("world").trees)
	return p


func test_models_loaded() -> void:
	var t := _altai()
	check(t.trees is TerrainTreeModels, "деревья — модели пород, а не конусы")


func test_trees_only_on_forest() -> void:
	var t := _altai()
	var p := _placer(t)
	var c := _forest_point(t)
	p.build(c)
	var total := 0
	for b in p.buffers.size():
		var buf := p.buffers[b]
		for k in p.counts[b]:
			var x := buf[k * TreePlacer.STRIDE + 3]
			var z := buf[k * TreePlacer.STRIDE + 11]
			check(
				t.surfaces[0].class_at(x, z) == SurfaceLayer.FOREST,
				"дерево на лесе (%.0f, %.0f)" % [x, z]
			)
			check(Vector2(x, z).distance_to(c) <= p.radius + 1.0, "в радиусе")
			total += 1
	check(total > 500, "деревьев вокруг старта: %d" % total)
	var lods := PackedInt32Array([0, 0, 0])
	for b in p.counts.size():
		lods[b % 3] += p.counts[b]
	check(lods[0] > 0 and lods[1] > 0 and lods[2] > 0, "все LOD заняты: %s" % lods)
	check(lods[0] < lods[1] and lods[1] < lods[2], "ближе — меньше деревьев: %s" % lods)


## Точка в лесу рядом с первым стартом (там LOD0 не пуст).
func _forest_point(t: Terrain) -> Vector2:
	var site: Dictionary = t.get_start_sites()[0]
	var c := Vector2(site.position.x, site.position.z)
	for r in range(100, 2000, 50):
		for k in 16:
			var q := c + Vector2.from_angle(TAU * k / 16.0) * r
			if _all_forest(t, q, 40.0):
				return q
	return c


func _all_forest(t: Terrain, q: Vector2, r: float) -> bool:
	for k in 9:
		var p := q + Vector2.from_angle(TAU * k / 9.0) * r * float(k > 0)
		if t.surfaces[0].class_at(p.x, p.y) != SurfaceLayer.FOREST:
			return false
	return true


func test_placement_deterministic() -> void:
	# Дерево привязано к клетке: при пересчёте вокруг соседней точки те же деревья там же.
	var t := _altai()
	var p := _placer(t)
	var site: Dictionary = t.get_start_sites()[0]
	var c := Vector2(site.position.x, site.position.z)
	p.build(c)
	var a := _positions(p)
	p.build(c + Vector2(20.0, -12.0))
	var b := _positions(p)
	var common := 0
	for key in a:
		if b.has(key):
			common += 1
	check(common > a.size() * 0.8, "совпадают %d из %d" % [common, a.size()])


func _positions(p: TreePlacer) -> Dictionary:
	var out := {}
	for b in p.buffers.size():
		for k in p.counts[b]:
			var buf := p.buffers[b]
			out[Vector2i(roundi(buf[k * 16 + 3] * 10), roundi(buf[k * 16 + 11] * 10))] = true
	return out


func test_species_rules() -> void:
	var t := _altai()
	var p := _placer(t)
	var n := 2000
	var hist_low := _hist(p, 400.0, 0.0, n)
	var hist_high := _hist(p, 2000.0, 0.0, n)
	var hist_south := _hist(p, 800.0, -1.0, n)
	var hist_north := _hist(p, 800.0, 1.0, n)
	var birch := TreePlacer.SPECIES.find("birch")
	var cedar := TreePlacer.SPECIES.find("cedar")
	var pine := TreePlacer.SPECIES.find("pine")
	var spruce := TreePlacer.SPECIES.find("spruce")
	check(hist_low[birch] > hist_high[birch], "берёза ниже: %s / %s" % [hist_low, hist_high])
	check(hist_high[cedar] > hist_low[cedar], "кедр выше")
	check(hist_south[pine] > hist_north[pine], "сосна на южных сухих склонах")
	check(hist_north[spruce] > hist_south[spruce], "ель на северных")


func test_location_override_larch_ongudai() -> void:
	var world: Dictionary = Config.get_config("world").trees
	var loc: Dictionary = Config.get_config("locations/ongudai").get("trees", {})
	var cfg: Dictionary = Config._deep_merge(world, loc)
	var p := TreePlacer.new()
	p.setup(_altai().layers[0], _altai().surfaces[0], cfg)
	var h := _hist(p, 1300.0, 0.0, 2000)
	var larch := TreePlacer.SPECIES.find("larch")
	for k in TreePlacer.SPECIES.size():
		if k != larch:
			check(h[larch] > h[k], "в Онгудае лиственница преобладает: %s" % h)


func _hist(p: TreePlacer, h: float, north: float, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(TreePlacer.SPECIES.size())
	for k in n:
		var s := p.pick_species(h, north, (k + 0.5) / n)
		if s >= 0:
			out[s] += 1
	return out


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
