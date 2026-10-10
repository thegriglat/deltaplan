extends TestCase
## SurfaceStage (OA-3): синтетический COG (локальный файл, без сети) и режим offline.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=surface_stage

const TW := 128


## Мини-COG 256×256, тайлы 128, без сжатия, пиксель 1/12000°, угол (57°N, 57°E) — файл N54E057.
## Левее столбца 120 — код 10 (лес), правее — 30 (луг).
func _write_cog(path: String) -> void:
	var b := StreamPeerBuffer.new()
	b.put_data("II".to_utf8_buffer())
	b.put_u16(42)
	b.put_u32(8)
	var n := 9
	b.put_u16(n)
	var blob := 8 + 2 + n * 12 + 4  # смещение блоков за IFD
	var ents := [
		[256, 4, 1, 256], [257, 4, 1, 256], [259, 3, 1, 1], [322, 4, 1, TW], [323, 4, 1, TW],
		[324, 4, 4, blob], [325, 4, 4, blob + 16], [33550, 12, 3, blob + 32], [33922, 12, 6, blob + 56],
	]
	for e: Array in ents:
		b.put_u16(e[0])
		b.put_u16(e[1])
		b.put_u32(e[2])
		b.put_u32(e[3])
	b.put_u32(0)
	var data0 := blob + 104
	for t in 4:
		b.put_u32(data0 + t * TW * TW)
	for t in 4:
		b.put_u32(TW * TW)
	for v in [1.0 / 12000.0, 1.0 / 12000.0, 0.0]:
		b.put_double(v)
	for v in [0.0, 0.0, 0.0, 57.0, 57.0, 0.0]:
		b.put_double(v)
	for ty in 2:
		for tx in 2:
			for y in TW:
				for x in TW:
					b.put_u8(10 if tx * TW + x < 120 else 30)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b.data_array)
	f.close()


func _ctx(dir: String) -> LocationBuildContext:
	var ctx := LocationBuildContext.new()
	ctx.center_lat = 56.99
	ctx.center_lon = 57.01
	ctx.dir = dir
	ctx.spec = {"surface": {"layers": {"detail": {"level": 0, "subsamples": 3}}}}
	ctx.layers = {"detail": {"id": "detail", "width": 9, "height": 9, "spacing_m": 25.0,
		"origin_x_m": -100.0, "origin_z_m": -100.0}}
	return ctx


func test_local_cog_classes_and_forest() -> void:
	var tmp := OS.get_user_data_dir().path_join("surface_stage_test")
	DirAccess.make_dir_recursive_absolute(tmp)
	_write_cog(tmp.path_join("wc_N54E057.tif"))
	var stage := SurfaceStage.new()
	stage.url_template = tmp.path_join("wc_{tile}.tif")
	stage.cache_dir = tmp.path_join("cache")
	var ctx := _ctx(tmp.path_join("out"))
	ctx.offline = true
	var err: int = await stage.run(ctx)
	check(err == OK, "run: %s %s" % [error_string(err), ctx.log_lines])
	if err != OK:
		return
	check(ctx.net_requests == 0, "без сети")
	var s := Image.load_from_file(tmp.path_join("out/detail_surface.webp"))
	s.convert(Image.FORMAT_L8)
	check(s != null and s.get_format() == Image.FORMAT_L8 and s.get_width() == 9, "surface L8 9×9")
	check(s.get_data()[4 * 9 + 0] == 1, "запад — лес")
	check(s.get_data()[4 * 9 + 8] == 2, "восток — луг")
	var d := SurfaceLayer.decode_detail10(tmp.path_join("out/detail_detail10.webp"))
	check(d != null and d.get_format() == Image.FORMAT_LA8 and d.get_width() == 21, "detail10 LA8 21×21")
	var px := d.get_data()
	check(px[2 * (10 * 21 + 0)] == 255 and px[2 * (10 * 21 + 20)] == 0, "L: лес слева, нет справа")
	check(px[2 * (10 * 21 + 0) + 1] == 0, "A = 0")
	var js: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(tmp.path_join("out/surface.json")))
	var d10: Dictionary = js.layers[0].detail10
	check(d10.water_fraction == 0.0 and d10.forest_fraction > 0.3 and d10.forest_fraction < 0.7, "surface.json detail10")
	check(js.layers[0].class_fraction["1"] > 0.3, "class_fraction леса")


func test_offline_empty_cache_unavailable() -> void:
	var tmp := OS.get_user_data_dir().path_join("surface_stage_test2")
	var stage := SurfaceStage.new()
	stage.url_template = "https://example.invalid/{tile}.tif"
	stage.cache_dir = tmp.path_join("cache")
	var ctx := _ctx(tmp.path_join("out"))
	ctx.offline = true
	var err: int = await stage.run(ctx)
	check(err == ERR_UNAVAILABLE, "offline без кеша: %s" % error_string(err))
	check(ctx.net_requests == 0, "offline: запросов нет")
