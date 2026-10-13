extends TestCase
## Стадия рельефа DemStage (OA-1) и COG float32: предиктор 3, .webp, паритет с встроенными высотами.
## Паритет — только если на машине есть локальные копии Copernicus/Terrarium (иначе пропуск).
## Полный паритет двух мест — tools/terrain/parity/dem_parity.gd.

const HOME_CACHE := "/.cache/deltaplan_terrain"


## Прямой предиктор 3 (как у libtiff/GDAL): плоскости байт float (старший первым) + разность по строке.
func _encode_predictor3(vals: PackedFloat32Array, tw: int, th: int) -> PackedByteArray:
	var le := vals.to_byte_array()
	var out := PackedByteArray()
	out.resize(le.size())
	for r in th:
		var base := r * tw * 4
		var planes := PackedByteArray()
		planes.resize(tw * 4)
		for k in tw:
			for b in 4:
				planes[b * tw + k] = le[base + k * 4 + (3 - b)]
		for q in range(tw * 4 - 1, 0, -1):
			planes[q] = (planes[q] - planes[q - 1]) & 255
		for q in tw * 4:
			out[base + q] = planes[q]
	return out


func test_predictor3_roundtrip() -> void:
	var tw := 7
	var th := 5
	var vals := PackedFloat32Array()
	for k in tw * th:
		vals.append(412.3125 + 0.03125 * k * (1 if k % 3 else -1) - 700.0 * (k % 2))
	var cog := CogReader.new()
	cog.levels.append({"width": tw, "height": th, "tile_w": tw, "tile_h": th, "compression": 8, "predictor": 3, "float32": true})
	var raw := _encode_predictor3(vals, tw, th).compress(FileAccess.COMPRESSION_DEFLATE)
	var got := cog.decode_tile_f32(0, raw)
	check(got == vals, "float32-тайл с предиктором 3 распаковывается без искажений")
	cog.levels[0].compression = 1
	cog.levels[0].predictor = 1
	check(cog.decode_tile_f32(0, vals.to_byte_array()) == vals, "float32-тайл без сжатия")
	check(cog.decode_tile_f32(0, PackedByteArray()).size() == tw * th, "пустой тайл — нули")


func test_parse_float_predictor_tags() -> void:
	# Минимальный TIFF: один уровень 16×16, тайлы 16×16, float32, Deflate, предиктор 3.
	var tags: Array = [
		[256, 3, 16], [257, 3, 16], [258, 3, 32], [259, 3, 8], [317, 3, 3], [322, 3, 16], [323, 3, 16],
		[324, 4, 200], [325, 4, 10], [339, 3, 3], [33550, 12, 0], [33922, 12, 0],
	]
	var b := PackedByteArray()
	b.resize(600)
	b[0] = 0x49
	b[1] = 0x49
	b.encode_u16(2, 42)
	b.encode_u32(4, 8)
	b.encode_u16(8, tags.size())
	for i in tags.size():
		var e: int = 10 + i * 12
		var t: Array = tags[i]
		b.encode_u16(e, int(t[0]))
		b.encode_u16(e + 2, int(t[1]))
		b.encode_u32(e + 4, 1 if int(t[1]) != 12 else (3 if int(t[0]) == 33550 else 6))
		if int(t[1]) == 12:
			b.encode_u32(e + 8, 300 if int(t[0]) == 33550 else 340)
		else:
			b.encode_u32(e + 8, int(t[2]))
	b.encode_u32(10 + tags.size() * 12, 0)
	b.encode_double(300, 1.0 / 2400.0)
	b.encode_double(308, 1.0 / 3600.0)
	b.encode_double(316, 0.0)
	b.encode_double(340 + 24, 58.0)
	b.encode_double(340 + 32, 54.0)
	var cog := CogReader.parse(b)
	check(cog.is_valid(), "COG float32 с предиктором 3 разбирается: %s" % cog.error)
	if cog.is_valid():
		check(bool(cog.levels[0].float32) and int(cog.levels[0].predictor) == 3, "уровень: float32, предиктор 3")


func _local() -> Dictionary:
	var home := OS.get_environment("HOME")
	return {
		"copernicus_dir": home + HOME_CACHE + "/copernicus",
		"terrarium_dir": home + HOME_CACHE + "/terrarium",
		"terrarium_cache_dir": "user://dem_stage_test_cache",
	}


func _run_stage(spec_layers: Array) -> LocationBuildContext:
	var loc: Dictionary = Config.get_config("locations/askarovo")
	var ctx := LocationBuildContext.new()
	ctx.key = "dem_test"
	ctx.center_lat = float(loc.center_lat)
	ctx.center_lon = float(loc.center_lon)
	ctx.dir = "user://dem_stage_test"
	ctx.offline = true
	ctx.spec = {"dem": {"layers": spec_layers}, "dem_sources": _local()}
	var err: Error = await DemStage.new().run(ctx)
	check(err == OK, "DemStage.run → OK (%s)" % [ctx.log_lines])
	check(ctx.net_requests == 0, "офлайн: без сетевых запросов")
	return ctx


func test_parity_with_builtin_askarovo() -> void:
	var src: Dictionary = _local()
	var loc: Dictionary = Config.get_config("locations/askarovo")
	var cop := "%s/Copernicus_DSM_COG_10_N53_00_E058_00_DEM.tif" % src.copernicus_dir
	if not FileAccess.file_exists(cop) or not DirAccess.dir_exists_absolute(src.terrarium_dir):
		print("  (нет локальных копий исходников — паритет пропущен)")
		return
	var layers: Array = [
		{"id": "detail", "size_km": 2, "spacing_m": 25, "source": "copernicus", "quantize_per_m": 32, "smooth_sigma_cells": 0.8},
		{"id": "far", "size_km": 100, "spacing_m": 1000, "source": "terrarium", "zoom": 10, "quantize_per_m": 32, "smooth_sigma_cells": 0},
	]
	var ctx := await _run_stage(layers)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ctx.dir + "/meta.json"))
	check(meta.layers.size() == 2 and meta.layers[0].file == "detail.webp" and meta.layers[1].water_file == "far_water.webp", "meta.json: слои, .webp, water_file")
	check(meta.attribution.size() == 2, "meta.json: две атрибуции")
	var ref_meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Locations.data_dir("askarovo") + "/meta.json"))
	var ref_d := HeightLayer.load_from_file(Locations.data_dir("askarovo") + "/detail.webp", ref_meta.layers[0])
	var ref_f := HeightLayer.load_from_file(Locations.data_dir("askarovo") + "/far.webp", ref_meta.layers[1])
	var mine_d := HeightLayer.load_from_file(ctx.dir + "/detail.webp", meta.layers[0])
	var mine_f := HeightLayer.load_from_file(ctx.dir + "/far.webp", meta.layers[1])
	check(mine_d != null and mine_f != null, "слои читаются с диска")
	if mine_d == null or mine_f == null:
		return
	# MLK-К1: эталон — стадия smooth (сырые на открытом, σ 0,8 под лесом и застройкой). DemStage один даёт
	# сглаживание везде (w = 1) и сырые в detail_raw.webp: на открытом месте (нет леса/застройки в ±7 узлах
	# эталона) сырые совпадают с эталоном, под лесом сглаженные не дальше полуметра от эталона глубоко в лесу.
	var raw_info: Dictionary = (meta.layers[0] as Dictionary).duplicate()
	raw_info["height_min_m"] = float(raw_info.raw_height_min_m)
	var raw_d := HeightLayer.load_from_file(ctx.dir + "/" + String(raw_info.raw_file), raw_info)
	var cls := Image.load_from_file(Locations.data_dir("askarovo") + "/detail_surface.webp")
	check(raw_d != null and cls != null, "сырые высоты и карта поверхности читаются")
	if raw_d == null or cls == null:
		return
	var half := int((mine_d.width - 1) / 2)
	var fc := int((ref_d.width - 1) / 2)
	var worst_open := 0.0
	var n_open := 0
	var worst_deep := 0.0
	var n_deep := 0
	for j in range(-16, 17):
		for i in range(-16, 17):
			var x := i * 25.0
			var z := j * 25.0
			var near_cover := false
			var deep_forest := true
			for dj in range(-7, 8):
				for di in range(-7, 8):
					var c := int(cls.get_pixel(fc + i + di, fc + j + dj).r * 255.0 + 0.5)
					if c == SurfaceLayer.FOREST or c == SurfaceLayer.BUILT:
						near_cover = true
					if c != SurfaceLayer.FOREST:
						deep_forest = false
			if not near_cover:
				n_open += 1
				worst_open = maxf(worst_open, absf(raw_d.sample(x, z) - ref_d.sample(x, z)))
			elif deep_forest:
				n_deep += 1
				worst_deep = maxf(worst_deep, absf(mine_d.sample(x, z) - ref_d.sample(x, z)))
	check(half == 40 and n_open + n_deep > 0, "есть узлы для сравнения: открытых %d, в глубоком лесу %d" % [n_open, n_deep])
	check(worst_open < 0.5, "сырые detail совпадают с эталоном на открытом (%d узлов): %.3f м" % [n_open, worst_open])
	check(worst_deep < 0.5, "сглаженные detail совпадают с эталоном в глубоком лесу (%d узлов): %.3f м" % [n_deep, worst_deep])
	var worst_f := 0.0
	for p: Vector2 in [Vector2(-30000, -30000), Vector2(40000, 25000), Vector2(0, 30000), Vector2(-25000, 0)]:
		worst_f = maxf(worst_f, absf(mine_f.sample(p.x, p.y) - ref_f.sample(p.x, p.y)))
	check(worst_f < 1.0, "far вне зоны detail совпадает со встроенным: %.3f м" % worst_f)
	# Грубый слой в зоне detail взят из детального.
	check(absf(mine_f.sample(0.0, 0.0) - mine_d.sample(0.0, 0.0)) < 0.5, "far в зоне detail вклеен из detail")
	check(ctx.heights.has("detail") and ctx.layers.has("far"), "ctx.heights/ctx.layers заполнены")
	DirAccess.remove_absolute(ctx.dir + "/detail.webp")
	DirAccess.remove_absolute(ctx.dir + "/detail_raw.webp")
	DirAccess.remove_absolute(ctx.dir + "/far.webp")
	DirAccess.remove_absolute(ctx.dir + "/meta.json")


func test_offline_without_data() -> void:
	var ctx := LocationBuildContext.new()
	ctx.key = "dem_test_none"
	ctx.center_lat = -40.0
	ctx.center_lon = 100.0
	ctx.dir = "user://dem_stage_test_none"
	ctx.offline = true
	ctx.spec = {"dem": {"layers": [{"id": "far", "size_km": 20, "spacing_m": 1000, "source": "terrarium", "zoom": 10}]}, "dem_sources": {"terrarium_cache_dir": "user://dem_stage_test_empty"}}
	var err: Error = await DemStage.new().run(ctx)
	check(err == ERR_UNAVAILABLE, "офлайн без кеша → ERR_UNAVAILABLE")
	check(ctx.net_requests == 0, "офлайн: сеть не тронута")
