extends TestCase
## SL-17 (SL-К4): у каждого дерева своё расстояние смены модель → импостер (множитель k из хеша мировых
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
	var kmin := 0.6
	var kmax := 1.6
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
		var db := 500.0 * TreePlacer.lod_k_at(k * 13.7, -k * 5.1, 0.6, 1.6)
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


func test_placer_models_and_band_share_trees() -> void:
	var t := _ongudai()
	var tm := t.trees as TerrainTreeModels
	var p := tm.placer
	check(p.lod_k_enabled, "SL-17 включён в конфиге")
	var c := _site(t)
	p.build(c)
	var half := p.swap_band()
	var models := {}
	var n_models := 0
	for b in p.buffers.size():
		for r in _rows(p.buffers[b], p.counts[b], TreePlacer.STRIDE):
			var d := Vector2(r.x, r.y).distance_to(c)
			var db := p.radius * TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max)
			n_models += 1
			if b % 3 == 2:
				models[Vector2(r.x, r.y)] = true
			check(d < db + half + 0.01, "модель не дальше границы смены + запас: d %.1f db %.1f" % [d, db])
	var imps := _rows(p.imp_buffer, p.imp_count, TreePlacer.IMP_STRIDE)
	check(imps.size() > 100, "импостеры полосы есть: %d" % imps.size())
	var both := 0
	var worst_far := 0.0
	for r in imps:
		var d := Vector2(r.x, r.y).distance_to(c)
		var db := p.radius * TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max)
		check(d > db - half - 0.01, "импостер не ближе границы − запас: d %.1f db %.1f" % [d, db])
		worst_far = maxf(worst_far, d)
		if absf(d - db) < half:
			# зона смены: дерево есть в обеих формах (у моделей — в LOD2 с кодом растворения)
			check(models.has(Vector2(r.x, r.y)), "в зоне смены модель на той же позиции")
			both += 1
		elif d >= db + half:
			check(not models.has(Vector2(r.x, r.y)), "дальше зоны — только импостер")
		else:
			check(false, "импостер ближе зоны смены")
	check(both > 20, "в зоне смены деревьев в обеих формах: %d" % both)
	check(worst_far <= p.band_end() + 1.0, "полоса кончается у band_end")
	# не зависит от камеры: сдвинули центр — у общих деревьев та же личная граница (чистая функция координат)
	var c2 := c + Vector2(37.0, -21.0)
	p.build(c2)
	var imps2 := _rows(p.imp_buffer, p.imp_count, TreePlacer.IMP_STRIDE)
	var seen := {}
	for r in imps:
		seen[Vector2(r.x, r.y)] = TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max)
	var common := 0
	for r in imps2:
		var key := Vector2(r.x, r.y)
		if seen.has(key):
			common += 1
			approx(seen[key], TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max), 1e-9, "k не зависит от камеры")
	check(common > 100, "общих деревьев при сдвиге камеры: %d" % common)


## Числа для отчёта: доля деревьев в виде модели по расстоянию (сумма видимостей модели «при ровно
## одной форме»), число моделей и band-импостеров, время расстановки.
func test_band_numbers() -> void:
	var t := _ongudai()
	var p := (t.trees as TerrainTreeModels).placer
	var c := _site(t)
	var t0 := Time.get_ticks_usec()
	p.build(c)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var bins_m := PackedFloat64Array()
	var bins_all := PackedFloat64Array()
	bins_m.resize(30)
	bins_all.resize(30)
	for b in p.buffers.size():
		for r in _rows(p.buffers[b], p.counts[b], TreePlacer.STRIDE):
			var d := Vector2(r.x, r.y).distance_to(c)
			var db := p.radius * TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max)
			var bi := mini(int(d / 50.0), 29)
			bins_all[bi] += 1
			bins_m[bi] += 1.0 - TreePlacer.swap_t(d, db, p.lod_dither_m)
	for r in _rows(p.imp_buffer, p.imp_count, TreePlacer.IMP_STRIDE):
		var d := Vector2(r.x, r.y).distance_to(c)
		var db := p.radius * TreePlacer.lod_k_at(r.x, r.y, p.lod_k_min, p.lod_k_max)
		var bi := mini(int(d / 50.0), 29)
		if d >= db + p.swap_band():
			bins_all[bi] += 1
	var line := PackedStringArray()
	for bi in range(4, 24):
		line.append("%d:%.2f" % [bi * 50, bins_m[bi] / maxf(bins_all[bi], 1.0)])
	var counts := p.lod_counts_total()
	print("SL-17: build %.0f мс, моделей %d, band-импостеров %d, k %.2f…%.2f, ramp %.0f…%.0f м" % [
		ms, counts, p.imp_count, p.lod_k_min, p.lod_k_max, p.ramp_start(), p.band_end()])
	print("SL-17: доля моделей по расстоянию (м:доля) %s" % " ".join(line))
	check(counts > 1000, "модели есть")
	# для сравнения: расстановка «как раньше» (общая граница, без полосы)
	p.lod_k_enabled = false
	t0 = Time.get_ticks_usec()
	p.build(c)
	var ms0 := (Time.get_ticks_usec() - t0) / 1000.0
	print("SL-17: без полосы: build %.0f мс, моделей %d" % [ms0, p.lod_counts_total()])
	p.lod_k_enabled = true
	# главный поток: _apply моделей + set_band импостеров (headless, без реальной загрузки в видеопамять)
	var tm := t.trees as TerrainTreeModels
	p.build(c)
	t0 = Time.get_ticks_usec()
	tm._apply()
	t.impostors.set_band(p.imp_buffer, p.imp_count)
	print("SL-17: _apply + set_band на главном потоке: %.2f мс (headless)" % ((Time.get_ticks_usec() - t0) / 1000.0))
	p.lod_k_enabled = true


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
