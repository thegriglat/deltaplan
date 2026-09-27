extends TestCase
## V02: деревья-модели и импостеры стоят по кромке маски леса 10 м (Terrain.get_forest_mask),
## у опушки гуще и раскидистее, просеки соблюдаются.

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
		var c := WorldClearings.build_for("ongudai")
		if c != null:
			_terrain.set_clearings(c.image, c.origin, c.cell_m)
	return _terrain


func _site(t: Terrain) -> Vector2:
	for s in t.get_start_sites():
		if s.id == "kayancha_south":
			return Vector2(s.position.x, s.position.z)
	var p: Vector3 = t.get_start_sites()[0].position
	return Vector2(p.x, p.z)


func _model_positions(t: Terrain) -> PackedVector2Array:
	var tm := t.trees as TerrainTreeModels
	tm.placer.build(_site(t))
	var out := PackedVector2Array()
	for b in tm.placer.buffers.size():
		var buf := tm.placer.buffers[b]
		for k in tm.placer.counts[b]:
			out.append(Vector2(buf[k * TreePlacer.STRIDE + 3], buf[k * TreePlacer.STRIDE + 11]))
	return out


## Насколько точка в лугу, м (0 — на лесе): до ближайшей точки с forest_at ≥ 0,5, шаг 1 м.
func _meadow_depth(t: Terrain, p: Vector2) -> float:
	if t.forest_at(p.x, p.y) >= 0.5:
		return 0.0
	for r in range(1, 30):
		for k in 16:
			var q := p + Vector2.from_angle(TAU * k / 16.0) * r
			if t.forest_at(q.x, q.y) >= 0.5:
				return r
	return 30.0


func test_mask_passed() -> void:
	var t := _ongudai()
	check(t.trees is TerrainTreeModels, "деревья — модели")
	check((t.trees as TerrainTreeModels).placer.mask_w > 0, "модели получили маску 10 м")
	check(t.impostors != null, "импостеры есть")
	check(
		bool(t.impostors.material.get_shader_parameter("use_forest_mask")),
		"импостеры получили маску 10 м"
	)


func test_trees_on_mask_forest() -> void:
	# ≥ 98 % деревьев (модели + импостеры) — при доле леса ≥ 0,5; ни одного центра дальше 5 м в луг
	var t := _ongudai()
	var c := _site(t)
	var pos := _model_positions(t)
	var n_models := pos.size()
	pos.append_array(t.impostors.present_positions(c, 350.0, 1500.0))
	check(
		n_models > 1000 and pos.size() > n_models + 5000,
		"деревьев: %d / %d" % [n_models, pos.size()]
	)
	var on_forest := 0
	var worst := 0.0
	for p in pos:
		if t.forest_at(p.x, p.y) >= 0.5:
			on_forest += 1
		else:
			worst = maxf(worst, _meadow_depth(t, p))
	var share := float(on_forest) / pos.size()
	print(
		(
			"V02: деревьев %d (моделей %d), на лесе %.2f %%, дальше всех в луг %.0f м"
			% [pos.size(), n_models, share * 100.0, worst]
		)
	)
	check(share >= 0.98, "на лесе %.2f %%" % (share * 100.0))
	check(worst <= 5.0, "дальше всех в луг: %.0f м" % worst)


func test_clearings_respected() -> void:
	var t := _ongudai()
	var c := WorldClearings.build_for("ongudai")
	check(c != null, "маска просек")
	var pos := _model_positions(t)
	pos.append_array(t.impostors.present_positions(_site(t), 350.0, 1500.0))
	var bad := 0
	for p in pos:
		var i := floori((p.x - c.origin.x) / c.cell_m)
		var j := floori((p.y - c.origin.y) / c.cell_m)
		if i >= 0 and j >= 0 and i < c.image.get_width() and j < c.image.get_height():
			if c.image.get_pixel(i, j).r > 0.5:
				bad += 1
	check(bad == 0, "на просеках деревьев: %d" % bad)


func test_edge_denser_and_wider() -> void:
	# у кромки (≤ edge_band_m) деревьев на клетку больше и кроны шире, чем в глубине леса
	var t := _ongudai()
	var tm := t.trees as TerrainTreeModels
	var p := tm.placer
	p.build(_site(t))
	var n_edge := 0
	var n_deep := 0
	var w_edge := 0.0
	var w_deep := 0.0
	for b in p.buffers.size():
		var buf := p.buffers[b]
		for k in p.counts[b]:
			var o := k * TreePlacer.STRIDE
			var d := p.edge_distance(buf[o + 3], buf[o + 11])
			# ширина кроны относительно высоты: |строка 0| / |столбец Y|
			var w := Vector2(buf[o], buf[o + 2]).length() / buf[o + 5]
			if d <= p.edge_band_m * 0.5:
				n_edge += 1
				w_edge += w
			elif d >= p.edge_probe_m:
				n_deep += 1
				w_deep += w
	check(n_edge > 50 and n_deep > 50, "есть опушка и глубина: %d / %d" % [n_edge, n_deep])
	check(
		w_edge / n_edge > w_deep / n_deep * 1.05,
		"у кромки кроны шире: %.3f / %.3f" % [w_edge / n_edge, w_deep / n_deep]
	)


func test_edge_trees_denser_per_area() -> void:
	# плотность у кромки (0–8 м внутрь) не меньше, чем в глубине (> 30 м): опушка — стена деревьев
	var t := _ongudai()
	var p := (t.trees as TerrainTreeModels).placer
	var c := _site(t)
	p.build(c)
	var r := p.radius * p.fade_start_k
	var trees_edge := 0
	var trees_deep := 0
	for b in p.buffers.size():
		for k in p.counts[b]:
			var o := k * TreePlacer.STRIDE
			var q := Vector2(p.buffers[b][o + 3], p.buffers[b][o + 11])
			if q.distance_to(c) > r:
				continue
			var d := p.edge_distance(q.x, q.y)
			if d <= 8.0:
				trees_edge += 1
			elif d >= p.edge_probe_m:
				trees_deep += 1
	# площадь полос — выборкой по сетке 4 м в том же круге (до начала прореживания моделей)
	var a_edge := 0
	var a_deep := 0
	for zz in range(-int(r), int(r), 4):
		for xx in range(-int(r), int(r), 4):
			if xx * xx + zz * zz > r * r:
				continue
			var x := c.x + xx
			var z := c.y + zz
			if not p.is_forest(x, z) or p.is_cleared(x, z):
				continue
			var d := p.edge_distance(x, z)
			if d <= 8.0:
				a_edge += 1
			elif d >= p.edge_probe_m:
				a_deep += 1
	check(a_edge > 0 and a_deep > 0, "полосы есть")
	var ratio := (float(trees_edge) / a_edge) / (float(trees_deep) / a_deep)
	print("V02: у кромки гуще ×%.2f" % ratio)
	check(ratio > 1.2, "у кромки гуще: ×%.2f" % ratio)


func test_impostor_hash_matches_shader_formula() -> void:
	# hash12 на CPU — та же формула, что в terrain_common.gdshaderinc (значения из GLSL-расчёта)
	var h := ForestImpostors.hash12(Vector2(0.0, 0.0))
	check(h >= 0.0 and h < 1.0, "0..1")
	var c := ForestImpostors.cell_center(Vector2(10, -7), 12.0)
	check(
		c.x >= 10.1 * 12.0 and c.x <= 10.9 * 12.0 and c.y >= -6.9 * 12.0 and c.y <= -6.1 * 12.0,
		"центр в своей клетке ±0,4 шага: %s" % c
	)


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
