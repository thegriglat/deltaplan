extends TestCase
## SL-20: стыки форм дерева на настоящей расстановке (Онгудай).
## Ближний (модель LOD0/1 → LOD2-крест, SL-К4 v2): каждая модель у r1·k — то же дерево, что крест в
## шейдере (клетка и позиция TreeCell), её код растворения не уводит её раньше r1·k, видимости модели и
## креста по формулам шейдера (tree_cell.gdshaderinc, зеркало ниже) в сумме 1, вне дизеринга — ровно одна;
## дыр нет: все деревья клеток К5 ближе r1·k + dither/2 есть среди моделей.
## Дальний (крест → импостер): деревьев на км² леса и площадь силуэтов по обе стороны полосы — числа.

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func _cfg() -> Dictionary:
	return TreePlacer.with_vegetation((Config.get_config("world").get("trees", {}) as Dictionary).duplicate(true))


## Точка в глубине леса маски (лес вокруг на r).
func _forest_point(p: TreePlacer, from: Vector2, r: float) -> Vector2:
	for rr in range(0, 4000, 50):
		for k in 16:
			var q := from + Vector2.from_angle(TAU * k / 16.0) * rr
			var ok := true
			for j in 8:
				var s := q + Vector2.from_angle(TAU * j / 8.0) * r
				ok = ok and p.texel_forest(s.x, s.y)
			if ok and p.texel_forest(q.x, q.y):
				return q
	return from


## Зеркало tc_swap_t (tree_cell.gdshaderinc).
static func _swap_t(d: float, db: float, dither: float) -> float:
	return clampf((d - db) / dither + 0.5, 0.0, 1.0)


## Дерево клетки К5 есть по правилам крестов (без породы): d8 центра, лес в позиции, не просека.
static func _cell_tree(p: TreePlacer, c: Vector2i) -> bool:
	var cm := p.cell_m
	if (TreeCell.hx(TreeCell.hash(c)) & 255) >= p.d8_at((c.x + 0.5) * cm, (c.y + 0.5) * cm):
		return false
	var q := TreeCell.pos(c, cm)
	return p.layer.contains(q.x, q.y) and p.texel_forest(q.x, q.y) and not p.is_cleared(q.x, q.y)


func test_near_seam_one_form() -> void:
	var t := _ongudai()
	var models := t.trees as TerrainTreeModels
	if models == null:
		check(false, "нет моделей")
		return
	var p := models.placer
	var cfg := _cfg()
	var kmin := float(cfg.lod_k_min)
	var kmax := float(cfg.lod_k_max)
	var dither := float(cfg.lod_dither_m)
	var r1 := float(cfg.lod_distances_m[1])
	var c := _forest_point(p, Vector2(_site(t)), 300.0)
	p.build(c)
	var have := {}
	var sampled := 0
	var bad_code := 0
	var not_one := 0
	var not_cross := 0
	for b in p.buffers.size():
		var buf := p.buffers[b]
		for k in p.counts[b]:
			var o := k * TreePlacer.STRIDE
			var q := Vector2(buf[o + 3], buf[o + 11])
			var cell := TreeCell.cell_of(q.x, q.y, p.cell_m)
			have[cell] = true
			var d := q.distance_to(c)
			var kk := TreePlacer.lod_k_at(q.x, q.y, kmin, kmax)
			if absf(d - r1 * kk) > 60.0:
				continue
			sampled += 1
			# у стыка модель только LOD1 без своего растворения (код 1)
			if b % 3 != 1 or buf[o + 15] < 0.99:
				bad_code += 1
			# крест шейдера — то же дерево: клетка К5 и позиция
			if not _cell_tree(p, cell) or TreeCell.pos(cell, p.cell_m).distance_to(q) > 0.01:
				not_cross += 1
			# видимости по шуму: модель n ≥ tm, крест n < tm (дальняя граница крестов далеко)
			var tm := _swap_t(d, r1 * kk, dither)
			for j in 64:
				var n := (j + 0.5) / 64.0
				var vis := int(n >= tm) + int(n < tm)
				if vis != 1:
					not_one += 1
				if absf(d - r1 * kk) >= dither * 0.5:
					var want_model := d < r1 * kk
					if (n >= tm) != want_model:
						not_one += 1
	# дыры: деревья клеток К5 ближе r1·k + dither/2, которых нет среди моделей
	var cm := p.cell_m
	var nr := ceili((r1 * kmax + dither) / cm)
	var ci := Vector2i(floori(c.x / cm), floori(c.y / cm))
	var need := 0
	var miss := 0
	for dj in range(-nr, nr + 1):
		for di in range(-nr, nr + 1):
			var cell := ci + Vector2i(di, dj)
			if not _cell_tree(p, cell):
				continue
			var q := TreeCell.pos(cell, cm)
			if q.distance_to(c) >= r1 * TreePlacer.lod_k_at(q.x, q.y, kmin, kmax) + dither * 0.5:
				continue
			need += 1
			if not have.has(cell):
				miss += 1
	print("SL-20 ближний стык: деревьев у r1·k (±60 м) %d, не LOD1/код≠1 %d, не тот крест %d, не одна форма %d; клеток К5 ближе r1·k+dither/2 %d, нет модели %d" % [
		sampled, bad_code, not_cross, not_one, need, miss])
	check(sampled > 100, "выборка у стыка: %d" % sampled)
	check(bad_code == 0, "у стыка своих уходов LOD нет: %d" % bad_code)
	check(not_cross == 0, "крест — то же дерево: %d" % not_cross)
	check(not_one == 0, "ровно одна форма вне дизеринга, сумма = 1: %d" % not_one)
	# порода < 0 (вне поясов высот) даёт пропуск модели — допускаем ≤ 0,5 %
	check(miss <= maxi(1, need / 200), "дыр нет: без модели %d из %d" % [miss, need])


func _site(t: Terrain) -> Vector2:
	var s: Vector3 = t.get_start_sites()[0].position
	return Vector2(s.x, s.z)


## Средняя доля непрозрачного (альфа) картинки в прямоугольнике.
static func _alpha_fill(img: Image, r: Rect2i) -> float:
	var s := 0.0
	var n := 0
	for y in range(r.position.y, r.end.y, 2):
		for x in range(r.position.x, r.end.x, 2):
			s += img.get_pixel(x, y).a
			n += 1
	return s / maxf(n, 1)


func test_far_seam_density() -> void:
	var t := _ongudai()
	var models := t.trees as TerrainTreeModels
	var imp := t.impostors
	if models == null or imp == null:
		check(false, "нет моделей/импостеров")
		return
	var p := models.placer
	var cfg := _cfg()
	var ic: Dictionary = cfg.impostors
	var kmin := float(cfg.lod_k_min)
	var kmax := float(cfg.lod_k_max)
	var dither := float(cfg.lod_dither_m)
	var rf := float(cfg.get("cross_radius_m", 1100.0))
	var c := _forest_point(p, _site(t), 200.0)
	var a_in := Vector2(rf * kmin - 20.0 - 150.0, rf * kmin - 20.0)   # только кресты
	var a_out := Vector2(rf * kmax + 20.0, rf * kmax + 20.0 + 150.0)  # только импостеры
	# площадь леса в кольцах — сетка 4 м по тому же текселю
	var forest_m2 := [0.0, 0.0]
	var crosses := [0, 0]
	var imps := [0, 0]
	var imps0 := [0, 0]  # без поправки стыка (density, размер 1)
	var size2 := 0.0     # сумма квадратов множителя размера (поправка стыка)
	var inner_end := rf * kmax + 0.5 * dither
	var seam_dens := float(ic.get("seam_density", ic.density))
	var seam_size := float(ic.get("seam_size_k", 1.0))
	var seam_fade := float(ic.get("seam_fade_m", 1000.0))
	var rings := [a_in, a_out]
	for ri in 2:
		var rg: Vector2 = rings[ri]
		var st := 4.0
		var n := ceili(rg.y / st)
		for j in range(-n, n + 1):
			for i in range(-n, n + 1):
				var q := c + Vector2(i, j) * st
				var d := q.distance_to(c)
				if d >= rg.x and d < rg.y and p.texel_forest(q.x, q.y):
					forest_m2[ri] += st * st
		# кресты: клетки К5 в кольце
		var cm := p.cell_m
		var nc := ceili(rg.y / cm) + 1
		var ci := Vector2i(floori(c.x / cm), floori(c.y / cm))
		for dj in range(-nc, nc + 1):
			for di in range(-nc, nc + 1):
				var cell := ci + Vector2i(di, dj)
				var q := TreeCell.pos(cell, cm)
				var d := q.distance_to(c)
				if d >= rg.x and d < rg.y and _cell_tree(p, cell):
					crosses[ri] += 1
		# импостеры: правила forest_impostors.gdshader (кольцо = 1 за inner_end, плотность и опушка)
		var sp := float(ic.spacing_m)
		var ni := ceili(rg.y / sp) + 1
		var gc := Vector2(floorf(c.x / sp), floorf(c.y / sp))
		var dens := float(ic.density)
		var edens := float(cfg.get("edge_density", 1.0))
		var eb := float(cfg.get("edge_band_m", 16.0))
		for dj in range(-ni, ni + 1):
			for di in range(-ni, ni + 1):
				var cell := gc + Vector2(di, dj)
				var q := ForestImpostors.cell_center(cell, sp)
				var d := q.distance_to(c)
				if d < rg.x or d >= rg.y:
					continue
				var u := ForestImpostors.hash12(cell + Vector2(5.7, 5.7))
				var seam := 1.0 - smoothstep(inner_end, inner_end + seam_fade, d)
				var dn := lerpf(dens, maxf(dens, seam_dens), seam)
				var edn := maxf(edens, dn)
				if u >= maxf(dn, edn) or not imp._mask.is_forest(q.x, q.y) or imp._mask.is_cleared(q.x, q.y):
					continue
				var o1 := 0.0
				var o2 := 0.0
				for kk in 4:
					var a := 1.5708 * kk
					o1 += float(not imp._mask.is_forest(q.x + cos(a) * eb * 0.5, q.y + sin(a) * eb * 0.5))
					o2 += float(not imp._mask.is_forest(q.x + cos(a + 0.785) * eb, q.y + sin(a + 0.785) * eb))
				var ek := minf(1.0, 2.0 * maxf(o1 * 0.25, 0.5 * o2 * 0.25))
				if u < lerpf(dn, edn, ek):
					imps[ri] += 1
					var f := lerpf(1.0, seam_size, seam)
					if ri == 1:
						size2 += f * f
				if u < lerpf(dens, edens, ek):
					imps0[ri] += 1
	var rho_c: float = crosses[0] / maxf(forest_m2[0], 1.0) * 1e6
	var rho_i: float = imps[1] / maxf(forest_m2[1], 1.0) * 1e6
	var rho_i0: float = imps0[1] / maxf(forest_m2[1], 1.0) * 1e6
	var f2: float = size2 / maxf(imps[1], 1)
	# силуэт на дерево в долях hh²: крест — карточка W·H варианта / mh² × доля альфы; билборд — 0,5 × доля альфы
	var cross_k := 0.0
	var nk := 0
	for sp_name in TreePlacer.SPECIES:
		for v in 2:
			var lods := TerrainTreeModels._load_lods(String((cfg.models as Dictionary).get(sp_name, "")), v)
			if lods.is_empty():
				continue
			var mh := lods[0].get_aabb().end.y
			var ab := lods[2].get_aabb()
			var std := lods[2].surface_get_material(0) as BaseMaterial3D
			var img := Image.load_from_file(std.albedo_texture.resource_path)
			var fill := _alpha_fill(img, Rect2i(Vector2i.ZERO, img.get_size()))
			cross_k += maxf(ab.size.x, ab.size.z) * ab.size.y / (mh * mh) * fill
			nk += 1
	cross_k /= maxf(nk, 1)
	var atlas := Image.load_from_file(String(ic.atlas))
	var cw := atlas.get_width() / 4
	var chh := atlas.get_height() / 2
	var imp_k := 0.0
	for k in TreePlacer.SPECIES.size():
		imp_k += 0.5 * _alpha_fill(atlas, Rect2i(Vector2i(k % 4 * cw, k / 4 * chh), Vector2i(cw, chh)))
	imp_k /= TreePlacer.SPECIES.size()
	var cov_c: float = rho_c * 1e-6 * cross_k
	var cov_i: float = rho_i * 1e-6 * imp_k * f2
	var cov_i0: float = rho_i0 * 1e-6 * imp_k
	print("SL-20 дальний стык (R = %.0f м): кресты %.0f дер./км² леса (кольцо %.0f–%.0f м, %d шт.), импостеры %.0f дер./км² (было %.0f; кольцо %.0f–%.0f м, %d шт.); ступень по числу %.0f %% (было %.0f %%)" % [
		rf, rho_c, a_in.x, a_in.y, crosses[0], rho_i, rho_i0, a_out.x, a_out.y, imps[1],
		(1.0 - rho_i / maxf(rho_c, 1.0)) * 100.0, (1.0 - rho_i0 / maxf(rho_c, 1.0)) * 100.0])
	print("SL-20 силуэт на дерево (доля hh², одна карточка): крест %.3f, билборд %.3f × размер² %.2f; площадь силуэтов на м² леса /hh²: кресты %.5f, импостеры %.5f (было %.5f); ступень %.0f %% (было %.0f %%)" % [
		cross_k, imp_k, f2, cov_c, cov_i, cov_i0, (1.0 - cov_i / maxf(cov_c, 1e-9)) * 100.0, (1.0 - cov_i0 / maxf(cov_c, 1e-9)) * 100.0])
	check(absf(1.0 - cov_i / maxf(cov_c, 1e-9)) <= 0.3, "ступень площади силуэтов на дальнем стыке ≤ 30 %")
	check(crosses[0] > 100 and imps[1] > 50, "выборки: кресты %d, импостеры %d" % [crosses[0], imps[1]])


## Последним: освободить общий Terrain файла (без него — утечки RID при выходе).
func test_zz_free_terrain() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
	check(true)
