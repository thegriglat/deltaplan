extends TestCase
## SL-17/SL-19: у каждого дерева своё расстояние смены модель → импостер (множитель k из хеша мировых
## координат); в каждый момент дерево — ровно одна форма (вне дизеринга), плотность в полосе не
## меняется (модели и импостеры полосы берут одни и те же позиции TreePlacer).

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func _site(t: Terrain) -> Vector2:
	var p: Vector3 = t.get_start_sites()[0].position
	return Vector2(p.x, p.z)


## Позиции деревьев буфера (x, z) и код растворения.
func _rows(buf: PackedFloat32Array, count: int, stride: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for k in count:
		var o := k * stride
		out.append(Vector3(buf[o + 3], buf[o + 11], buf[o + 15] if stride == TreePlacer.STRIDE else 1.0))
	return out


func test_k_range_and_distribution() -> void:
	var kmin := 0.75
	var kmax := 1.2
	var sum := 0.0
	var n := 0
	var lo := 9.0
	var hi := 0.0
	for j in 100:
		for i in 100:
			var k := TreePlacer.lod_k_at(i * 8.3 - 400.0, j * 8.3 - 400.0, kmin, kmax)
			lo = minf(lo, k)
			hi = maxf(hi, k)
			sum += k
			n += 1
	check(lo >= kmin and hi <= kmax, "k в [%.1f, %.1f]: %.3f…%.3f" % [kmin, kmax, lo, hi])
	approx(sum / n, 0.5 * (kmin + kmax), 0.03, "k равномерен: среднее")
	# тот же хеш — одна клетка 4 м одно значение, без зависимости от камеры/кадра
	approx(TreePlacer.lod_k_at(10.1, 20.2, kmin, kmax), TreePlacer.lod_k_at(11.9, 23.9, kmin, kmax), 1e-9, "клетка 4 м")


func test_swap_t_symmetric_and_exact() -> void:
	# доля импостера: 0 ближе db − dither/2, 1 дальше db + dither/2, симметрична (t(db+x) + t(db−x) = 1),
	# монотонна; модель — дополнение (1 − t)
	var dither := 40.0
	for k in 40:
		var db := 500.0 * TreePlacer.lod_k_at(k * 13.7, -k * 5.1, 0.75, 1.2)
		var prev := -1.0
		for step in range(-80, 81, 5):
			var t := TreePlacer.swap_t(db + step, db, dither)
			check(t >= prev, "монотонна")
			prev = t
			approx(t + TreePlacer.swap_t(db - step, db, dither), 1.0, 1e-9, "симметрия")
			if step <= -20:
				check(t == 0.0, "ближе зоны — только модель")
			if step >= 20:
				check(t == 1.0, "дальше зоны — только импостер")


func test_near_models_follow_tree_cell() -> void:
	# SL-19 (SL-К5): каждая модель стоит в позиции TreeCell.pos своей клетки, d8 > хеш; дальше
	# near_reach() моделей нет; band-импостеров на CPU нет.
	var t := _ongudai()
	var p := (t.trees as TerrainTreeModels).placer
	var c := _site(t)
	p.build(c)
	var reach := p.near_reach()
	var n := 0
	for b in p.buffers.size():
		check(b % 3 != 2 or p.counts[b] == 0, "LOD2 на CPU пуст")
		for r in _rows(p.buffers[b], p.counts[b], TreePlacer.STRIDE):
			var q := Vector2(r.x, r.y)
			var cell := TreeCell.cell_of(q.x, q.y, p.cell_m)
			var pos := TreeCell.pos(cell, p.cell_m)
			check(pos.distance_to(q) < 0.01, "позиция = TreeCell.pos: %s" % cell)
			check(p.d8_at((cell.x + 0.5) * p.cell_m, (cell.y + 0.5) * p.cell_m) > (TreeCell.hash(cell).x & 255), "present по d8")
			check(q.distance_to(c) <= reach + 0.01, "не дальше near_reach")
			n += 1
	check(n > 300, "моделей: %d" % n)
	check(p.imp_count == 0 and p.imp_buffer.is_empty(), "CPU-полосы нет")
	# сдвиг камеры не меняет набор деревьев в мире (общая часть кругов)
	var seen := {}
	for b in p.buffers.size():
		for r in _rows(p.buffers[b], p.counts[b], TreePlacer.STRIDE):
			seen[Vector2(r.x, r.y)] = true
	var c2 := c + Vector2(37.0, -21.0)
	p.build(c2)
	var miss := 0
	var common := 0
	for b in p.buffers.size():
		for r in _rows(p.buffers[b], p.counts[b], TreePlacer.STRIDE):
			var q := Vector2(r.x, r.y)
			if q.distance_to(c) < reach - 50.0:
				if seen.has(q):
					common += 1
				else:
					miss += 1
	check(common > 200 and miss == 0, "тот же набор при сдвиге: общих %d, новых внутри круга %d" % [common, miss])


## Числа для отчёта: время перестройки ближнего слоя (цель ≤ ~234 мс), число моделей.
func test_rebuild_numbers() -> void:
	var t := _ongudai()
	var p := (t.trees as TerrainTreeModels).placer
	var c := _site(t)
	p.build(c)  # прогрев
	var best := 1e9
	for k in 5:
		var t0 := Time.get_ticks_usec()
		p.build(c + Vector2(k * 16.0, 0.0))
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
	print("SL-19: rebuild_ms_near %.0f мс (лучший из 5), моделей %d, near_reach %.0f м" % [best, p.lod_counts_total(), p.near_reach()])
	check(best <= 234.0, "перестройка ближнего слоя %.0f мс ≤ 234" % best)
	var tm := t.trees as TerrainTreeModels
	var t1 := Time.get_ticks_usec()
	tm._apply()
	print("SL-19: _apply на главном потоке: %.2f мс (headless)" % ((Time.get_ticks_usec() - t1) / 1000.0))


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
