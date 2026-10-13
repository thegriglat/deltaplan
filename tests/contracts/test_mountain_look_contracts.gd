extends TestCase
## Контрактные тесты mountain-look (docs/contracts/mountain-look.md). MLK-К3 (зонд силуэта) без теста:
## прогон зонда на ongudai в тесте ел память без предела (21 ГБ). MLK-К2 v2 — дальняя форма
## рельефа (владелец MLK-3): инварианты ReliefLook.dh (CPU-зеркало vertex() terrain.gdshader) на синтетике.
## MLK-К1 (владелец MLK-2) — сглаживание высот места только под кронами и крышами (SmoothStage), test_k1_*.


# ---------------------------------------------------------------- MLK-К2 v2

const K2_N := 641
const K2_SP := 25.0
const K2_LOD := [1500.0, 3500.0, 7000.0, 14000.0]


func _k2_look() -> Dictionary:
	return (Config.get_config("world").terrain_look as Dictionary).duplicate(true)


## Синтетический хребет с пиками (конусы на шаге не кратном LOD) и долинами, 16 × 16 км, шаг 25 м.
func _k2_layer() -> HeightLayer:
	var hs := PackedFloat32Array()
	hs.resize(K2_N * K2_N)
	var half := (K2_N - 1) * K2_SP * 0.5
	for j in K2_N:
		for i in K2_N:
			var x := i * K2_SP - half
			var z := j * K2_SP - half
			var h := 2000.0 + 400.0 * sin(x / 1300.0) * cos(z / 1700.0)
			for c in [Vector3(1237.0, 3311.0, 900.0), Vector3(-2763.0, -1187.0, 700.0), Vector3(4013.0, -4987.0, 1100.0)]:
				var d := Vector2(x - c.x, z - c.y).length()
				h += maxf(0.0, c.z - d * 1.2)
			hs[j * K2_N + i] = h
	return HeightLayer.from_heights("t", K2_N, K2_N, K2_SP, -half, -half, hs)


func _k2_surface(cls: int) -> SurfaceLayer:
	var c := PackedByteArray()
	c.resize(K2_N * K2_N)
	c.fill(cls)
	var half := (K2_N - 1) * K2_SP * 0.5
	return SurfaceLayer.from_classes("t", K2_N, K2_N, K2_SP, -half, -half, c)


func test_k2_relief_keys_are_uniforms() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/terrain/terrain.gdshader")
	for key: String in _k2_look():
		if not key.begins_with("relief_") or key.ends_with("_doc"):
			continue
		var re := RegEx.create_from_string("uniform\\s+\\w+\\s+%s\\b" % key)
		check(re.search(src) != null, "k2: ключ terrain_look.%s — uniform шейдера" % key)


func test_k2_zero_near_camera_and_on_closed_surfaces() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var near: Array = look.relief_near_m
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var worst_near := 0.0
	var worst_closed := 0.0
	var any_far := 0.0
	for k in 400:
		var i := 3 + (k * 37) % (K2_N - 6)
		var j := 3 + (k * 91) % (K2_N - 6)
		var x := L.origin_x + i * K2_SP
		var z := L.origin_z + j * K2_SP
		var cam_near := Vector3(x + float(near[0]) * 0.9, L.node(i, j) + 300.0, z)
		worst_near = maxf(worst_near, absf(ReliefLook.dh(L, open, x, z, cam_near, look, lod)))
		var cam_far := Vector3(x + 15000.0, L.node(i, j), z)
		for cls in [SurfaceLayer.FOREST, SurfaceLayer.WATER, SurfaceLayer.BUILT]:
			worst_closed = maxf(worst_closed, absf(ReliefLook.dh(L, _k2_surface(cls), x, z, cam_far, look, lod)))
		any_far = maxf(any_far, absf(ReliefLook.dh(L, open, x, z, cam_far, look, lod)))
	check(worst_near == 0.0, "k2: dh = 0 при d_cam ≤ relief_near_m.x (было %.3f)" % worst_near)
	check(worst_closed == 0.0, "k2: dh = 0 на лесе/воде/застройке (было %.3f)" % worst_closed)
	check(any_far > 1.0, "k2: вдали на открытом dh есть (%.2f м)" % any_far)


func test_k2_bounded_and_smooth_in_distance() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var lim := ReliefLook.dh_limit_m(look)
	var worst := 0.0
	var worst_step := 0.0
	for p: Vector2i in [Vector2i(320, 320), Vector2i(373, 452), Vector2i(209, 271), Vector2i(480, 120)]:
		var x := L.origin_x + p.x * K2_SP
		var z := L.origin_z + p.y * K2_SP
		var prev := NAN
		var d := 0.0
		while d < 50000.0:
			var cam := Vector3(x - d, L.node(p.x, p.y) + 200.0, z)
			var v := ReliefLook.dh(L, open, x, z, cam, look, lod)
			worst = maxf(worst, absf(v))
			if not is_nan(prev):
				worst_step = maxf(worst_step, absf(v - prev))
			prev = v
			d += 10.0
	check(worst <= lim, "k2: |dh| ≤ предела конфига (%.1f ≤ %.1f м)" % [worst, lim])
	# переход по дальности гладкий: за 10 м — не больше 2 м (ступенька LOD дала бы десятки)
	check(worst_step <= 2.0, "k2: dh по дальности без ступенек (скачок за 10 м %.2f м)" % worst_step)


## Пик между вершинами LOD: меш с шагом 16 узлов (400 м) на 20 км теряет меньше половины прежнего;
## на дне долин (вогнутые узлы) подъёма нет.
func test_k2_peak_restored_valleys_not_inflated() -> void:
	var L := _k2_layer()
	var look := _k2_look()
	var lod := PackedFloat32Array(K2_LOD)
	var open := _k2_surface(SurfaceLayer.BARE)
	var cam := Vector3(L.origin_x - 20000.0, 3500.0, 0.0)
	var s := 16
	var apex := L.max_h
	var best_v1 := -INF
	var best_v2 := -INF
	var valley_sum := 0.0
	var valley_n := 0
	for j in range(0, K2_N, s):
		for i in range(0, K2_N, s):
			var x := L.origin_x + i * K2_SP
			var z := L.origin_z + j * K2_SP
			var h := L.node(i, j)
			var dh := ReliefLook.dh(L, open, x, z, cam, look, lod)
			best_v1 = maxf(best_v1, h)
			best_v2 = maxf(best_v2, h + dh)
			var lap := (L.node(i + 4, j) + L.node(i - 4, j) + L.node(i, j + 4) + L.node(i, j - 4) - 4.0 * h) / 400.0
			if lap > 0.05:
				valley_sum += dh
				valley_n += 1
	var loss1 := apex - best_v1
	var loss2 := apex - best_v2
	check(loss1 > 20.0, "k2: синтетика — пик между вершинами (потеря без подъёма %.1f м)" % loss1)
	check(loss2 <= 0.5 * loss1, "k2: потеря пика ≤ половины (%.1f → %.1f м)" % [loss1, loss2])
	check(valley_n > 10, "k2: есть вогнутые узлы (%d)" % valley_n)
	check(valley_sum / maxf(valley_n, 1) <= 2.0, "k2: долины не надуваются (средний dh %.2f м)" % (valley_sum / maxf(valley_n, 1)))


const N := 81
const STEP := 25.0
const Q := 32.0
const SIGMA := 0.8
const TOL := 1.0 / 32.0 + 1e-4


## Синтетика: гребень вдоль строки j = 40 (острый, 30 м на узел), в левой половине (i < 40) лес с
## «кронами» ±3 м. Возвращает {r: сырые (квантованные), surf: карта поверхности}.
func _synthetic() -> Dictionary:
	var r := PackedFloat32Array()
	var surf := PackedByteArray()
	r.resize(N * N)
	surf.resize(N * N)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for j in N:
		for i in N:
			var h := 2000.0 - 30.0 * absf(j - 40)
			var forest := i < 40
			if forest:
				h += rng.randf_range(-3.0, 3.0)
			r[j * N + i] = roundf(h * Q) / Q
			surf[j * N + i] = 1 if forest else 3
	return {"r": r, "surf": surf}


func _gauss(r: PackedFloat32Array) -> PackedFloat32Array:
	var d := DemStage.new()
	d._tree = Engine.get_main_loop() as SceneTree
	var r64 := PackedFloat64Array()
	for v in r:
		r64.append(v)
	return await d._finish(r64, N, SIGMA, Q)


func test_k1_format_version() -> void:
	check(Locations.FORMAT_VERSION == 4, "К1: Locations.FORMAT_VERSION = 4, сейчас %d" % Locations.FORMAT_VERSION)


func test_k1_weight_smooth_and_heights() -> void:
	var s := _synthetic()
	var st := SmoothStage.new()
	var w := await st.weight(N, STEP, 0.0, 0.0, [1, 7], s.surf, {}, {}, 50.0)
	check(w.size() == N * N, "К1: w — по узлу")
	var wmax_step := 0.0
	for j in N:
		for i in N - 1:
			wmax_step = maxf(wmax_step, absf(w[j * N + i + 1] - w[j * N + i]))
	check(wmax_step <= 0.5, "К1: w гладкая, соседние узлы ≤ 0,5: %.3f" % wmax_step)
	check(wmax_step > 0.0, "К1: w меняется на опушке")
	var h := await st.apply(s.r, w, N, SIGMA, Q)
	var g := await _gauss(s.r)
	var worst_open := 0.0
	var worst_deep := 0.0
	var n_open := 0
	var n_deep := 0
	for j in N:
		for i in N:
			var k := j * N + i
			if w[k] == 0.0:
				n_open += 1
				worst_open = maxf(worst_open, absf(h[k] - s.r[k]))
			elif w[k] == 1.0:
				n_deep += 1
				worst_deep = maxf(worst_deep, absf(h[k] - g[k]))
	check(n_open > 500 and n_deep > 500, "К1: есть узлы w = 0 (%d) и w = 1 (%d)" % [n_open, n_deep])
	check(worst_open <= TOL, "К1: w = 0 → h = сырые до 1/32 м: %.4f" % worst_open)
	check(worst_deep <= TOL, "К1: глубоко в лесу h = G_σ(r) до 1/32 м: %.4f" % worst_deep)
	# вдали от леса (≥ 3σ маски = 6 клеток) w = 0, острый гребень цел
	var k_crest := 40 * N + 70
	check(w[k_crest] == 0.0 and h[k_crest] == s.r[k_crest], "К1: гребень на скалах не просел")
	check(h[k_crest] > g[k_crest] + 1.0, "К1: сглаженный гребень был бы ниже (%.2f против %.2f)" % [g[k_crest], h[k_crest]])


func test_k1_no_mask_is_gaussian() -> void:
	var s := _synthetic()
	var st := SmoothStage.new()
	var h := await st.apply(s.r, PackedFloat32Array(), N, SIGMA, Q)
	var g := await _gauss(s.r)
	var worst := 0.0
	for k in h.size():
		worst = maxf(worst, absf(h[k] - g[k]))
	check(worst <= TOL, "К1: без маски h = G_σ(r) везде: %.4f" % worst)


## Папка слоя: сырые, карта поверхности, surface.json, meta.json. Возвращает ctx.
func _stage_ctx(dir: String, with_cover: bool) -> LocationBuildContext:
	var s := _synthetic()
	DirAccess.make_dir_recursive_absolute(dir)
	var r: PackedFloat32Array = s.r
	var mm := DemStage._min_max(r)
	var info := {"id": "detail", "file": "detail.webp", "width": N, "height": N, "spacing_m": STEP,
			"origin_x_m": 0.0, "origin_z_m": 0.0, "source": "copernicus", "height_step_m": DemStage.HEIGHT_STEP_M,
			"height_min_m": mm.x, "min_height_m": mm.x, "max_height_m": mm.y,
			"raw_file": "detail_raw.webp", "raw_height_min_m": mm.x}
	var img := HeightLayer.encode_rgb24(r, N, N, mm.x, DemStage.HEIGHT_STEP_M)
	img.save_webp(dir.path_join("detail_raw.webp"), false)
	# как собрал DemStage: сглаживание везде
	var g := await _gauss(r)
	var gm := DemStage._min_max(g)
	info.height_min_m = gm.x
	info.min_height_m = gm.x
	info.max_height_m = gm.y
	HeightLayer.encode_rgb24(g, N, N, gm.x, DemStage.HEIGHT_STEP_M).save_webp(dir.path_join("detail.webp"), false)
	var f := FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"layers": [info]}))
	f.close()
	if with_cover:
		Image.create_from_data(N, N, false, Image.FORMAT_L8, s.surf).save_webp(dir.path_join("detail_surface.webp"), false)
		f = FileAccess.open(dir.path_join("surface.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify({"layers": [{"id": "detail", "file": "detail_surface.webp", "width": N, "height": N}]}))
		f.close()
	var ctx := LocationBuildContext.new()
	ctx.dir = dir
	ctx.layers = {"detail": info}
	ctx.heights = {"detail": g}
	ctx.spec = {"dem": {"layers": [{"id": "detail", "smooth_sigma_cells": SIGMA, "quantize_per_m": Q,
			"smooth_mask_sigma_m": 50.0, "smooth_mask_classes": [1, 7]}]},
			"surface": {"layers": {"detail": {}}}}
	return ctx


func test_k1_stage_writes_layer() -> void:
	var dir := "user://mlk_k1_stage"
	LocationCache.remove_dir(dir)
	var ctx := await _stage_ctx(dir, true)
	var err: Error = await SmoothStage.new().run(ctx)
	check(err == OK, "К1: стадия сглаживания → OK, а не %d" % err)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	var info: Dictionary = meta.layers[0]
	check(not info.has("raw_file") and not FileAccess.file_exists(dir.path_join("detail_raw.webp")), "К1: _raw удалён")
	var l := HeightLayer.load_from_file(dir.path_join("detail.webp"), info)
	check(l != null, "К1: слой читается")
	if l == null:
		return
	var worst := 0.0
	for k in l.heights.size():
		worst = maxf(worst, absf(l.heights[k] - ctx.heights["detail"][k]))
	check(worst <= TOL, "К1: файл слоя = ctx.heights (height_at в узлах = слой): %.4f" % worst)
	var k_crest := 40 * N + 70
	check(absf(l.heights[k_crest] - _synthetic().r[k_crest]) <= TOL, "К1: на скалах слой = сырые")
	# повтор без _raw — ничего не меняет
	check(await SmoothStage.new().run(ctx) == OK, "К1: повторный запуск без _raw → OK")
	LocationCache.remove_dir(dir)


func test_k1_no_cover_keeps_gaussian() -> void:
	var dir := "user://mlk_k1_nocover"
	LocationCache.remove_dir(dir)
	var ctx := await _stage_ctx(dir, false)
	var before: PackedFloat32Array = ctx.heights["detail"].duplicate()
	var err: Error = await SmoothStage.new().run(ctx)
	check(err == ERR_UNAVAILABLE, "К1: нет покрова → ERR_UNAVAILABLE (досборка позже)")
	check(ctx.heights["detail"] == before, "К1: нет покрова → w = 1, высоты как у DemStage")
	check(FileAccess.file_exists(dir.path_join("detail_raw.webp")), "К1: _raw остаётся для досборки")
	LocationCache.remove_dir(dir)
