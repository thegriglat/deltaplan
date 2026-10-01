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


func test_clearings_mask() -> void:
	# Полоса-просека 40 м шириной через лес: на ней деревьев нет, рядом — есть.
	var t := _altai()
	var p := _placer(t)
	var c := _forest_point(t)
	var img := Image.create(100, 100, false, Image.FORMAT_L8)
	img.fill(Color(0, 0, 0))
	img.fill_rect(Rect2i(48, 0, 4, 100), Color(1, 1, 1))  # x ∈ [c.x − 20, c.x + 20)
	p.clear_image = img
	p.clear_origin = c - Vector2(500, 500)
	p.clear_cell = 10.0
	p.build(c)
	var inside := 0
	var near := 0
	for b in p.buffers.size():
		for k in p.counts[b]:
			var x := p.buffers[b][k * TreePlacer.STRIDE + 3]
			if absf(x - c.x) < 19.0:
				inside += 1
			elif absf(x - c.x) < 60.0:
				near += 1
	check(inside == 0, "на просеке деревьев нет: %d" % inside)
	check(near > 0, "рядом с просекой лес есть: %d" % near)


func test_edge_sink_smaller() -> void:
	var t := _altai()
	var p := _placer(t)
	var c := _forest_point(t)
	var site: Dictionary = t.get_start_sites()[0]
	var s: Vector3 = site.position
	approx(p.sink_at(c.x, c.y), p.sink_fraction, 1e-4, "в глубине леса — sink_fraction")
	check(p.sink_at(s.x, s.z) < p.sink_fraction, "у поляны старта утоплены меньше")


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


func test_lod_fade_pairs() -> void:
	# У границы LOD экземпляр в обоих соседних LOD (уходит/проявляется), в стороне — в одном.
	var t := _altai()
	var p := _placer(t)
	var c := _forest_point(t)
	p.build(c)
	var band := p.lod_fade_m * 0.5 + p.fade_margin_m
	var codes := {}  # позиция → [код по LOD0, LOD1, LOD2]
	for b in p.buffers.size():
		var buf := p.buffers[b]
		for k in p.counts[b]:
			var o := k * TreePlacer.STRIDE
			var key := Vector2i(roundi(buf[o + 3] * 10), roundi(buf[o + 11] * 10))
			if not codes.has(key):
				codes[key] = [0.0, 0.0, 0.0]
			codes[key][b % 3] = buf[o + 15]
			var d := Vector2(buf[o + 3], buf[o + 11]).distance_to(c)
			var a := buf[o + 15]
			if a < 0.99:
				var db := p.lod_distances[0] if a < 0.25 else p.lod_distances[1]
				check(absf(d - db) < band + 0.01, "растворение только у границы: %.1f м" % d)
	var pairs := 0
	for key in codes:
		var cs: Array = codes[key]
		if is_equal_approx(cs[0], TreePlacer.FADE_OUT0):
			check(is_equal_approx(cs[1], TreePlacer.FADE_IN0), "пара LOD0→LOD1")
			pairs += 1
		if is_equal_approx(cs[1], TreePlacer.FADE_OUT1):
			check(is_equal_approx(cs[2], TreePlacer.FADE_IN1), "пара LOD1→LOD2")
			pairs += 1
	check(pairs > 20, "пар растворения: %d" % pairs)


func test_variant_by_place() -> void:
	# Вариант модели — хеш клетки: при пересчёте вокруг другой точки то же место — тот же буфер
	# (порода × вариант), и вариантов в ходу больше одного.
	var t := _altai()
	var p := _placer(t)
	var c := _forest_point(t)
	p.build(c)
	var a := _variants(p)
	p.build(c + Vector2(30.0, 25.0))
	var b := _variants(p)
	var same := 0
	var common := 0
	var used := {}
	for key in a:
		used[a[key]] = true
		if b.has(key):
			common += 1
			same += int(a[key] == b[key])
	check(common > 100 and same == common, "тот же вариант: %d из %d" % [same, common])
	check(used.size() > TreePlacer.SPECIES.size(), "вариантов в ходу: %d" % used.size())


func _variants(p: TreePlacer) -> Dictionary:
	var out := {}
	for b in p.buffers.size():
		for k in p.counts[b]:
			var buf := p.buffers[b]
			out[Vector2i(roundi(buf[k * 16 + 3] * 10), roundi(buf[k * 16 + 11] * 10))] = b / 3
	return out


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


func test_wind_passed_to_shaders() -> void:
	var w := TerrainWind.new()
	w.setup(Config.get_config("world").wind_visual)
	var m := ShaderMaterial.new()
	m.shader = preload("res://scripts/terrain/grass.gdshader")
	w.add_materials([m])
	w.ground_fn = func(_x: float, _z: float) -> float: return 500.0
	w.mean_wind_fn = func(p: Vector3) -> Vector3:
		return Vector3(3.0, 0.0, -4.0) * (p.y - 500.0) / 10.0
	w.thermals_fn = func(_p: Vector3, _r: float) -> Array[Dictionary]:
		return [
			{"source": Vector3(900, 0, 0), "radius_m": 80.0, "strength_ms": 3.0, "envelope": 1.0},
			{"source": Vector3(100, 0, 0), "radius_m": 60.0, "strength_ms": 1.5, "envelope": 0.5},
			{"source": Vector3(50, 0, 0), "radius_m": 60.0, "strength_ms": 2.0, "envelope": 0.0},
		]
	w.update_at(Vector3(0, 800, 0))
	check(w.wind.is_equal_approx(Vector2(3.0, -4.0)), "ветер у земли (10 м AGL): %s" % w.wind)
	check(w.thermals.size() == 2, "угасший термик пропущен: %d" % w.thermals.size())
	check(w.thermals[0].x == 100.0, "ближний первым")
	var norm := float(Config.value("world", "wind_visual").thermal_norm_ms)
	approx(w.thermals[0].w, 0.75 / norm, 1e-4, "сила = м/с × огибающая / норма")
	check(Vector2(m.get_shader_parameter("wind_vec")).is_equal_approx(w.wind), "ветер в шейдере")
	check(int(m.get_shader_parameter("wind_thermal_count")) == 2, "термики в шейдере")
	w.free()


func test_grass_and_wind_nodes() -> void:
	var t := _altai()
	check(t.grass != null, "трава создана")
	check(
		t.wind != null and t.wind.materials.size() >= 3,
		"ветер знает материалы рельефа/деревьев/травы"
	)
	check(t.wind.materials.has(t.grass.material), "материал травы получает ветер")


func test_grass_palette_by_location() -> void:
	var t := _altai()
	var p := t.get_grass_palette()
	check(p.grass_color is Color, "цвет травы")
	approx(
		float(p.dryness),
		float(Config.get_config("locations/altai").terrain_look.dryness),
		1e-6,
		"сухость — из локации"
	)


## Последним (порядок — по объявлению): общий Terrain в static var иначе переживает тесты и
## освобождается при выгрузке скриптов — падение 139 при выходе.
func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
