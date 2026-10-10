extends TestCase
## Контрактные тесты клиента osm-tiles (docs/contracts/osm-tiles.md): O1 сетка по золотой таблице
## (bands, points, neighbors), O2/O3 разбор sample_v1.dpt против sample_v1.json (вид — `osmtiles dump`, O5),
## O9 конфиг, стадия, OsmData. Без сети и GPU.

const DIR := "res://tests/contracts/osm_tiles/"


func _json(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(DIR + name))


# ---------- O1 ----------

func test_o1_bands() -> void:
	var g: Dictionary = _json("grid_golden.json")
	var bands: Array = g.bands
	check(bands.size() == 1000, "1000 поясов: %d" % bands.size())
	var bad := 0
	for b: Dictionary in bands:
		var j := int(b.j)
		if OsmGrid.n_of(j) != int(b.n) or absf(OsmGrid.dlon(j) - float(b.dlon)) > 1e-12 \
				or absf(OsmGrid.kx(j) - float(b.kx)) > 1e-6:
			bad += 1
	check(bad == 0, "поясов с расхождением: %d" % bad)


func test_o1_points() -> void:
	var g: Dictionary = _json("grid_golden.json")
	var pts: Array = g.points
	check(pts.size() >= 300, "точек ≥ 300: %d" % pts.size())
	var bad := 0
	for p: Dictionary in pts:
		var lat := float(p.lat)
		var lon := float(p.lon)
		var t := OsmGrid.tile_of(lat, lon)
		var xy := OsmGrid.to_tile(t.x, t.y, lat, lon)
		if t.x != int(p.j) or t.y != int(p.i) or absf(xy.x - float(p.x)) > 1e-3 or absf(xy.y - float(p.y)) > 1e-3:
			bad += 1
			if bad <= 3:
				failures.append("точка %s,%s: ожидалось %d,%d (%s,%s), получено %d,%d (%s)" % [
					p.lat, p.lon, p.j, p.i, p.x, p.y, t.x, t.y, str(xy)])
	check(bad == 0, "точек с расхождением: %d" % bad)


func test_o1_neighbors() -> void:
	var g: Dictionary = _json("grid_golden.json")
	var items: Array = g.neighbors
	check(items.size() >= 20, "соседей ≥ 20: %d" % items.size())
	var bad := 0
	for e: Dictionary in items:
		var got := OsmGrid.neighbors(float(e.lat), float(e.lon))
		var want: Array = e.tiles
		var ok := got.size() == want.size()
		if ok:
			for k in got.size():
				if got[k].x != int(want[k][0]) or got[k].y != int(want[k][1]):
					ok = false
		if not ok:
			bad += 1
			if bad <= 3:
				failures.append("соседи %s,%s: ожидалось %s, получено %s" % [e.lat, e.lon, str(want), str(got)])
	check(bad == 0, "точек с другими соседями: %d" % bad)


# ---------- O2 / O3 ----------

## Словарь OsmTileReader → вид `osmtiles dump` (потоки списком {kind, count, objects}).
static func as_dump(tile: Dictionary) -> Dictionary:
	var kinds := OsmTileReader.KIND_NAMES.keys()
	kinds.sort()
	var streams: Array = []
	for k: int in kinds:
		var name: String = OsmTileReader.KIND_NAMES[k]
		if not (tile.streams as Dictionary).has(name):
			continue
		var objs: Array = tile.streams[name]
		var out_objs: Array = []
		for o: Variant in objs:
			if o is Dictionary:
				var d: Dictionary = (o as Dictionary).duplicate()
				if d.has("pts"):
					var pts: Array = []
					for q: Vector2 in d.pts:
						pts.append([int(q.x), int(q.y)])
					d["pts"] = pts
				out_objs.append(d)
			else:
				out_objs.append(o)
		streams.append({"kind": name, "count": objs.size(), "ids": [], "objects": out_objs})
	return {"format_version": tile.format_version, "header": tile.header, "i": tile.i, "j": tile.j, "n": tile.n,
		"osm_timestamp": tile.osm_timestamp, "sources": tile.sources, "streams": streams}


## Нормализация чисел JSON/GDScript (всё — float) для сравнения.
static func norm(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k: Variant in (v as Dictionary).keys():
			d[k] = norm(v[k])
		return d
	if v is Array:
		var a: Array = []
		for x: Variant in v:
			a.append(norm(x))
		return a
	if v is int:
		return float(v)
	return v


func test_o2_o3_sample() -> void:
	var bytes := FileAccess.get_file_as_bytes(DIR + "sample_v1.dpt")
	check(not bytes.is_empty(), "sample_v1.dpt читается")
	var tile := OsmTileReader.read(bytes)
	check(not tile.is_empty(), "тайл разобран")
	if tile.is_empty():
		return
	var got := norm(as_dump(tile)) as Dictionary
	var want := norm(_json("sample_v1.json")) as Dictionary
	for key: String in want.keys():
		if key == "streams":
			continue
		check(got.get(key) == want[key], "поле %s: %s ≠ %s" % [key, str(got.get(key)), str(want[key])])
	var gs: Array = got.streams
	var ws: Array = want.streams
	check(gs.size() == ws.size(), "потоков %d, ожидалось %d" % [gs.size(), ws.size()])
	for k in mini(gs.size(), ws.size()):
		check(gs[k] == ws[k], "поток %s: %s" % [ws[k].kind, str(gs[k]).substr(0, 200)])


func test_o2_rejects_bad_files() -> void:
	var bytes := FileAccess.get_file_as_bytes(DIR + "sample_v1.dpt")
	check(OsmTileReader.read(PackedByteArray()).is_empty(), "пустой файл")
	var bad := bytes.duplicate()
	bad[0] = 0x58
	check(OsmTileReader.read(bad).is_empty(), "не та магия")
	var ver := bytes.duplicate()
	ver.encode_u16(4, 2)
	check(OsmTileReader.read(ver).is_empty(), "версия контейнера 2")
	var frag := FileAccess.get_file_as_bytes(DIR + "sample_frag_v1.dpt")
	check(OsmTileReader.read(frag).is_empty(), "фрагмент (флаг бит 0) клиент не читает")
	check(OsmTileReader.read(bytes.slice(0, bytes.size() - 40)).is_empty(), "обрезан кадр zstd")
	var rot := bytes.duplicate()
	rot[rot.size() - 12] ^= 0xFF
	check(OsmTileReader.read(rot).is_empty(), "испорчено тело кадра")


# ---------- O9 ----------

func test_o9_config() -> void:
	var c: Dictionary = Config.get_config("osm_tiles")
	for k: String in ["base_url", "timeout_s", "enabled", "max_parallel", "height_rule"]:
		check(c.has(k), "configs/osm_tiles.json: " + k)
	check(float(c.get("timeout_s", 0.0)) == 5.0, "таймаут 5 с")
	check(int(c.get("max_parallel", 0)) == 9, "до 9 запросов")
	check(OsmTilesStage.cache_root() == "user://osm_tiles/v1", "кеш user://osm_tiles/v1")


func test_o9_api() -> void:
	var data := OsmData.new()
	for f: String in ["roads", "rivers", "rail", "buildings", "power", "towers", "aerialways", "aeroways",
			"verticals", "peaks", "passes", "attribution", "tiles_ok", "tiles_missing", "load_time_s"]:
		check(f in data, "OsmData." + f)
	check(data.attribution == "", "пустой OsmData без атрибуции")
	var e := OsmData.load_for("user://no_such_place_dir", 46.0, 14.0, 20000.0)
	check(e != null and e.is_empty(), "load_for без тайлов — пустой OsmData, не null")
	var st := OsmTilesStage.new()
	check(st.has_method("run"), "OsmTilesStage.run")
	var last: Array = LocationBuilder.default_stages()
	check(last.size() > 0 and last[last.size() - 1].name == "osm_tiles", "osm_tiles — последняя стадия")
	var b := OsmBuildings.build(data, {}, Callable(), null)
	check(b == null, "заглушка OsmBuildings возвращает null")
