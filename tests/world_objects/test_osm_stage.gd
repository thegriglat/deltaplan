extends TestCase
## Стадия OSM сборки места (OA-4): godot --headless --path . res://tests/run_tests.tscn -- --filter=osm_stage

const FIXTURE := "res://tests/world_objects/fixtures/overpass_mini.json"
const LAT := 50.0
const LON := 10.0


func _elements() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURE)).elements


func test_osm_stage_pack() -> void:
	var o := OsmStage.pack(_elements(), LAT, LON, 20000.0)
	check(o.roads.size() == 1, "дорог 1 (дубль и footway отброшены): %d" % o.roads.size())
	check(o.roads[0].t == "residential" and o.roads[0].p.size() == 6, "дорога: тип и 3 точки")
	approx(o.roads[0].p[3], -111.2, 0.11, "z точки 2 (север — минус z)")
	check(o.buildings.size() == 1, "зданий 1 (маленькое отброшено): %d" % o.buildings.size())
	var b: Array = o.buildings[0]
	approx(b[2] * b[3], 7.15 * 11.12, 1.5, "площадь дома")
	approx(b[5], 6.0, 0.01, "высота 2 этажа × 3 м")
	check(b[6] == 0, "двускатная крыша")
	check(o.power.size() == 1 and o.power[0].c == 3 and o.power[0].s == [1, 0, 1], "ЛЭП: опоры по узлам")
	approx(o.power[0].v, 110.0, 0.001, "кВ")
	check(o.water.rivers.size() == 1 and o.water.rivers[0].n == "R", "река")
	check(o.water.lakes.size() == 2, "озёр 2 (way + relation): %d" % o.water.lakes.size())
	var rel: Dictionary = o.water.lakes[1]
	check(rel.n == "L" and rel.has("h") and rel.h.size() == 1, "relation: остров-дыра")
	check(o.places.size() == 1 and o.places[0].n == "Вэ" and o.places[0].pop == 1200, "посёлок: %s" % str(o.places))
	check(o.landuse.fields.size() == 1 and o.landuse.fences.size() == 1, "поле и забор")
	check(o.bbox_latlon.size() == 4 and o.bbox_latlon[0] < LAT and o.bbox_latlon[2] > LAT, "bbox")
	check(JSON.parse_string(JSON.stringify(o)) is Dictionary, "сериализуется")


func _info(w: int, h: int, ox: float, oz: float) -> Dictionary:
	return {"width": w, "height": h, "spacing_m": 10.0, "origin_x_m": ox, "origin_z_m": oz}


func test_osm_stage_water_alpha() -> void:
	var osm := {"water": {
		"rivers": [{"t": "river", "n": "", "p": [0.0, 100.0, 400.0, 100.0]}, {"t": "stream", "n": "", "p": [0.0, 300.0, 400.0, 300.0]}],
		"lakes": [{"n": "", "p": [100.0, 400.0, 400.0, 400.0, 400.0, 700.0, 100.0, 700.0],
			"h": [[200.0, 500.0, 300.0, 500.0, 300.0, 600.0, 200.0, 600.0]]}]}}
	var img := OsmStage.water_alpha(osm, _info(50, 80, 0.0, 0.0))
	check(img.get_format() == Image.FORMAT_L8 and img.get_width() == 50 and img.get_height() == 80, "L8 50×80")
	check(img.get_pixel(20, 10).r8 == 255, "река 25 м — залита на оси")
	check(img.get_pixel(20, 12).r8 == 0 and img.get_pixel(20, 8).r8 == 0, "за рекой пусто")
	var stream := img.get_pixel(20, 30).r8
	check(stream > 50 and stream < 100, "ручей 4 м уже клетки: ~0,28 (%d)" % stream)
	check(img.get_pixel(15, 45).r8 == 255, "озеро")
	check(img.get_pixel(25, 55).r8 == 0, "остров — суша")
	check(img.get_pixel(5, 45).r8 == 0 and img.get_pixel(45, 45).r8 == 0, "вне озера")
	var half := OsmStage.water_alpha({"water": {"rivers": [], "lakes": [
		{"n": "", "p": [0.0, 0.0, 15.0, 0.0, 15.0, 10.0, 0.0, 10.0]}]}}, _info(4, 4, 0.0, 0.0))
	check(half.get_pixel(0, 0).r8 == 255 or half.get_pixel(0, 0).r8 > 200, "полная клетка озера")
	var edge := half.get_pixel(1, 0).r8
	check(edge > 100 and edge < 160, "край озера — частичное покрытие (%d)" % edge)


func _tmp_dir() -> String:
	var d := "user://osm_stage_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(d)
	var w := 40
	var h := 40
	var px := PackedByteArray()
	px.resize(w * h * 2)
	for i in w * h:
		px[i * 2] = 100
	Image.create_from_data(w, h, false, Image.FORMAT_LA8, px).save_png(d.path_join("detail_detail10.png"))
	var sj := {"source": "t", "layers": [{"id": "detail", "detail10": {"file": "detail_detail10.png", "width": w, "height": h,
		"spacing_m": 10.0, "origin_x_m": -200.0, "origin_z_m": -200.0, "forest_fraction": 0.4, "water_fraction": 0.0}}]}
	var f := FileAccess.open(d.path_join("surface.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(sj))
	f.close()
	return d


func _ctx(dir: String) -> LocationBuildContext:
	var c := LocationBuildContext.new()
	c.key = "pt_test"
	c.center_lat = LAT
	c.center_lon = LON
	c.dir = dir
	c.spec = {"dem": {"layers": [{"size_km": 0.4}]}}
	return c


func _quiet(stage: OsmStage) -> void:
	stage.client.retry_pause_s = 0.0
	stage.client.layer_pause_s = 0.0
	stage.client.use_status = false


func _ok(body: PackedByteArray) -> Array:
	return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body]


func _bad(code: int) -> Array:
	return [HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(), "overpass timeout".to_utf8_buffer()]


func test_osm_stage_run() -> void:
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	var stage := OsmStage.new()
	_quiet(stage)
	var calls := []
	var body := FileAccess.get_file_as_bytes(FIXTURE)
	stage.client.http_hook = func(url: String, headers: PackedStringArray, form: String) -> Array:
		calls.append([url, form.uri_decode()])
		var ua_ok := false
		for h in headers:
			ua_ok = ua_ok or h.begins_with("User-Agent: deltaplan")
		check(ua_ok and form.begins_with("data="), "User-Agent и тело запроса")
		if calls.size() == 1:
			return _bad(504)
		return _ok(body)
	var err: Error = await stage.run(ctx)
	check(err == OK, "run OK: %d %s" % [err, ctx.log_lines])
	check(ctx.net_requests == 7 and calls.size() == 7, "6 слоёв + 1 повтор после 504: %d" % ctx.net_requests)
	check(calls[0][0] == calls[1][0], "повтор на том же зеркале")
	check(String(calls[1][1]).contains("highway") and not String(calls[1][1]).contains("building"), "запрос слоя roads")
	check(String(calls[2][1]).contains('["building"]') and String(calls[2][1]).contains("maxsize"), "запрос слоя buildings, maxsize")
	check(stage.client.stats.size() == 6, "статистика по слоям")
	var osm: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("osm.json")))
	check(osm is Dictionary and osm.location == "pt_test" and osm.roads.size() == 1, "osm.json записан, дубли слоёв схлопнуты")
	var img := Image.load_from_file(dir.path_join("detail_detail10.png"))
	img.convert(Image.FORMAT_LA8)
	var px := img.get_data()
	var wet := 0
	for i in 1600:
		check(px[i * 2] == 100, "канал L не тронут")
		if px[i * 2 + 1] >= 128:
			wet += 1
	check(wet > 0, "в канале A есть вода (река/озеро)")
	var sj: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("surface.json")))
	approx(sj.layers[0].detail10.water_fraction, float(wet) / 1600.0, 0.0002, "water_fraction")
	check(is_equal_approx(sj.layers[0].detail10.forest_fraction, 0.4), "forest_fraction сохранён")


func test_osm_stage_mirror_and_tiles() -> void:
	var mirrors: int = Config.get_config("world_objects").osm.overpass_urls.size()
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	var stage := OsmStage.new()
	_quiet(stage)
	var body := FileAccess.get_file_as_bytes(FIXTURE)
	var roads_calls := [0]
	var n := [0]
	stage.client.http_hook = func(_u: String, _h: PackedStringArray, form: String) -> Array:
		n[0] += 1
		if form.uri_decode().contains('["highway"]'):
			roads_calls[0] += 1
			if roads_calls[0] <= mirrors:
				return _bad(400)  # без повтора: на каждом зеркале по одному запросу
		return _ok(body)
	var err: Error = await stage.run(ctx)
	check(err == OK, "тайлы: run OK %d %s" % [err, ctx.log_lines])
	check(roads_calls[0] == mirrors + 4, "roads: все зеркала целиком, затем 4 тайла: %d" % roads_calls[0])
	check(ctx.net_requests == n[0] and n[0] == mirrors + 4 + 5, "всего запросов: %d" % n[0])
	check(int(stage.client.stats[0].tiles) == 4, "в статистике roads — 4 тайла")
	var osm: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("osm.json")))
	check(osm.roads.size() == 1, "дубли тайлов схлопнуты")


func test_osm_stage_mirror_retry_after() -> void:
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	var stage := OsmStage.new()
	_quiet(stage)
	var body := FileAccess.get_file_as_bytes(FIXTURE)
	var urls := []
	stage.client.http_hook = func(u: String, _h: PackedStringArray, _f: String) -> Array:
		urls.append(u)
		if urls.size() <= 5:  # первое зеркало: 429 пять раз подряд -> второе
			return [HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: 0"]), PackedByteArray()]
		return _ok(body)
	var err: Error = await stage.run(ctx)
	check(err == OK and urls[0] == urls[1] and urls[4] == urls[0] and urls[5] != urls[0], "429 пять раз -> следующее зеркало: %s" % [urls.slice(0, 6)])


func test_osm_stage_remark_is_refusal() -> void:
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	var stage := OsmStage.new()
	_quiet(stage)
	var body := FileAccess.get_file_as_bytes(FIXTURE)
	var n := [0]
	stage.client.http_hook = func(_u: String, _h: PackedStringArray, _f: String) -> Array:
		n[0] += 1
		if n[0] == 1:
			return _ok('{"remark":"runtime error: Query run out of memory","elements":[]}'.to_utf8_buffer())
		return _ok(body)
	var err: Error = await stage.run(ctx)
	check(err == OK and n[0] == 7, "remark: отказ зеркала без повтора, причина в журнале: %d" % n[0])
	check(str(ctx.log_lines).contains("runtime error"), "причина в ctx.log_lines")


func test_osm_stage_offline_and_failure() -> void:
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	ctx.offline = true
	var stage := OsmStage.new()
	_quiet(stage)
	var n := [0]
	stage.client.http_hook = func(_u: String, _h: PackedStringArray, _f: String) -> Array:
		n[0] += 1
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	check(await stage.run(ctx) == ERR_UNAVAILABLE and ctx.net_requests == 0 and n[0] == 0, "offline: без запросов")
	ctx.offline = false
	var err: Error = await stage.run(ctx)
	var mirrors: int = Config.get_config("world_objects").osm.overpass_urls.size()
	check(err == ERR_CANT_CONNECT, "все зеркала отказали: ошибка")
	check(ctx.net_requests == n[0] and n[0] == 2 * mirrors, "roads целиком и первый тайл, по зеркалу без повторов: %d" % n[0])
	check(not FileAccess.file_exists(dir.path_join("osm.json")), "osm.json не создан при отказе")


func test_osm_stage_slot_status() -> void:
	check(OverpassClient.slot_wait_s("Rate limit: 2\n2 slots available now.\n") == 0.0, "слот есть")
	check(OverpassClient.slot_wait_s("Rate limit: 2\nSlot available after: 2026-10-09T12:00:10Z, in 10 seconds.\nSlot available after: 2026-10-09T12:00:30Z, in 30 seconds.\n") == 11.0, "ждать до ближайшего слота")
	check(OverpassClient.slot_wait_s("что-то непонятное") == 0.0, "непонятный статус — не ждать")
	var dir := _tmp_dir()
	var ctx := _ctx(dir)
	var stage := OsmStage.new()
	_quiet(stage)
	stage.client.use_status = true
	var body := FileAccess.get_file_as_bytes(FIXTURE)
	var urls := []
	stage.client.http_hook = func(u: String, _h: PackedStringArray, _f: String) -> Array:
		urls.append(u)
		return _ok(("2 slots available now.").to_utf8_buffer() if u.ends_with("/status") else body)
	check(await stage.run(ctx) == OK, "run со статусом")
	check(urls[0].ends_with("/status") and urls[1].ends_with("/interpreter"), "сначала status, затем запрос слоя")
	check(ctx.net_requests == 12, "6 слоёв + 6 status: %d" % ctx.net_requests)
