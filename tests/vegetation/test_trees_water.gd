extends TestCase
## Лес не стоит в воде (ошибка «иногда лес рендерится в воде»): на всех локациях ни одна позиция
## дерева — ни модели (TreePlacer), ни импостера (ForestImpostors) — не попадает в воду маски 10 м
## (канал G, реки/озёра OSM, та же вода, что рисует рельеф: G ≥ 0,5), а лес у берега остаётся.
## Проверяются места, где WorldCover зовёт лесом клетки воды (кроны над руслом, острова), — там
## ошибка и была; плюс острова мультиполигонов OSM вычтены из воды (tools/osm/fetch_osm.py).

## Радиус моделей вокруг каждой точки проверки, м (меньше рабочего — быстрее; правило то же).
const MODEL_R := 250.0
## Кольцо импостеров вокруг точки, м.
const IMPOSTOR_R := 400.0
## Точек проверки на локацию (места конфликта «лес по WorldCover ∧ вода по OSM»).
const SPOTS := 6
## «У воды»: вода (G ≥ 0,5) ближе этого, м.
const BANK_M := 15.0


func _locations() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at("res://configs/locations"):
		var id := f.get_basename()
		if f.ends_with(".json") and DirAccess.dir_exists_absolute("res://data/terrain/" + id):
			out.append(id)
	return out


## Центры клеток маски, где R ≥ 0,5 и G ≥ 0,5 (лес WorldCover на воде OSM), равномерно по списку.
func _conflict_spots(sl: SurfaceLayer) -> PackedVector2Array:
	var data := sl.forest_mask_image().get_data()
	var all := PackedInt32Array()
	for k in range(0, data.size(), 2):
		if data[k] >= 128 and data[k + 1] >= 128:
			all.append(k / 2)
	var out := PackedVector2Array()
	for s in mini(SPOTS, all.size()):
		var p := all[(all.size() * s) / SPOTS + all.size() / (2 * SPOTS)]
		out.append(
			Vector2(
				sl.mask_origin_x + (p % sl.mask_width) * sl.mask_spacing,
				sl.mask_origin_z + (p / sl.mask_width) * sl.mask_spacing
			)
		)
	return out


func _near_water(sl: SurfaceLayer, p: Vector2) -> bool:
	for r in [BANK_M * 0.5, BANK_M]:
		for k in 8:
			var q: Vector2 = p + TreePlacer.RING8[k] * r
			if sl.mask_g(q.x, q.y) >= 0.5:
				return true
	return false


func test_no_trees_in_water_all_locations() -> void:
	var locs := _locations()
	check(locs.size() >= 4, "локаций: %d" % locs.size())
	for id in locs:
		var t := Terrain.new()
		t.location_id = ""
		check(t.load_location(id), "загружена %s" % id)
		_check_location(id, t)
		if t.has_method("wait_relief"):
			t.call("wait_relief")  # фоновый расчёт полей рельефа — дождаться перед free
		t.free()


func _check_location(id: String, t: Terrain) -> void:
	var sl := t.surfaces[0]
	check(sl.has_forest_mask(), "%s: маска 10 м" % id)
	check(t.trees is TerrainTreeModels and t.impostors != null, "%s: модели и импостеры" % id)
	if not sl.has_forest_mask() or not t.trees is TerrainTreeModels or t.impostors == null:
		return
	var placer := (t.trees as TerrainTreeModels).placer
	var keep_r := placer.radius
	var keep_fade := placer.fade_start_k
	placer.radius = MODEL_R
	placer.fade_start_k = 0.0
	var spots := _conflict_spots(sl)
	var n_trees := 0
	var in_water := 0
	var worst_g := 0.0
	var bank_trees := 0
	var forest_trees := 0
	var bank_area := 0
	var forest_area := 0
	for c in spots:
		var pos := PackedVector2Array()
		placer.build(c)
		for b in placer.buffers.size():
			var buf := placer.buffers[b]
			for k in placer.counts[b]:
				pos.append(Vector2(buf[k * TreePlacer.STRIDE + 3], buf[k * TreePlacer.STRIDE + 11]))
		var n_models := pos.size()
		pos.append_array(t.impostors.present_positions(c, 0.0, IMPOSTOR_R))
		for k in pos.size():
			var p := pos[k]
			var g := sl.mask_g(p.x, p.y)
			worst_g = maxf(worst_g, g)
			if g >= 0.5:
				in_water += 1
			if k < n_models:
				forest_trees += 1
				if _near_water(sl, p):
					bank_trees += 1
		n_trees += pos.size()
		# площадь леса (R ≥ 0,5, не вода) и её прибрежной части — сеткой 4 м в круге моделей
		for zz in range(-int(MODEL_R), int(MODEL_R), 4):
			for xx in range(-int(MODEL_R), int(MODEL_R), 4):
				if xx * xx + zz * zz > MODEL_R * MODEL_R:
					continue
				var q := c + Vector2(xx, zz)
				if sl.mask_r(q.x, q.y) < 0.5 or sl.mask_g(q.x, q.y) >= 0.5:
					continue
				forest_area += 1
				if _near_water(sl, q):
					bank_area += 1
	placer.radius = keep_r
	placer.fade_start_k = keep_fade
	var bank_k := (
		(float(bank_trees) / maxi(bank_area, 1)) / (float(forest_trees) / maxi(forest_area, 1))
	)
	print(
		(
			"лес/вода %s: точек %d, деревьев %d, в воде %d (макс. G %.2f), у берега ×%.2f плотности"
			% [id, spots.size(), n_trees, in_water, worst_g, bank_k]
		)
	)
	if spots.is_empty():
		return
	check(n_trees > 1000, "%s: деревьев %d" % [id, n_trees])
	check(in_water == 0, "%s: деревьев в воде %d (макс. G %.2f)" % [id, in_water, worst_g])
	# у берега лес остаётся: плотность моделей в прибрежной полосе ≥ половины средней по лесу
	check(bank_area > 100 and bank_trees > 50, "%s: у берега %d / %d" % [id, bank_trees, bank_area])
	check(bank_k >= 0.5, "%s: у берега плотность ×%.2f" % [id, bank_k])


func test_osm_water_rings_closed_islands_cut() -> void:
	# водоёмы OSM — замкнутые кольца (мультиполигоны собраны из участков, а не замкнуты хордой
	# каждый: хорда заливала пойму водой прямо по лесу), острова — дыры
	var holes := 0
	for id in _locations():
		var osm := OsmData.load_file("res://data/osm/%s.json" % id)
		if osm == null:
			continue
		var open := 0
		for lk: Dictionary in osm.lakes:
			var p: Array = lk.p
			if p.size() < 6 or p[0] != p[p.size() - 2] or p[1] != p[p.size() - 1]:
				open += 1
			holes += (lk.get("h", []) as Array).size()
		check(open == 0, "%s: незамкнутых водоёмов %d" % [id, open])
	check(holes > 50, "острова-дыры в водоёмах: %d" % holes)
