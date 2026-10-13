extends TestCase
## Контракты модуля mountain-look (docs/contracts/mountain-look.md). MLK-К1: сглаживание высот места
## только под кронами и крышами (SmoothStage), на синтетических данных, без сети.

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
