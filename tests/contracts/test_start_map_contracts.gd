extends TestCase
## Контрактные тесты модуля start-map (docs/contracts/start-map.md): SM-К1 — растровые подложки в
## конфиге, SM-К2 — высота точки по Terrarium и интерфейс MapPicker. Без сети и GPU.
## Правка контракта (версия +1) — вместе с этим файлом. Методы вызываются через call(), чтобы
## отсутствие метода было падением теста, а не ошибкой разбора файла.

const DOC := "res://docs/contracts/start-map.md"


func _doc_line(head: String) -> String:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func test_versions_in_doc() -> void:
	check(_doc_line("## SM-К1.").contains("(v1)"), "SM-К1 v1 в документе")
	check(_doc_line("## SM-К2.").contains("(v1)"), "SM-К2 v1 в документе")


func test_k1_basemaps() -> void:
	var mp: Dictionary = Config.get_config("world").get("map_picker", {})
	var maps: Array = mp.get("basemaps", [])
	check(maps.size() >= 2, "слоёв подложки >= 2: %d" % maps.size())
	var ids := {}
	for m: Dictionary in maps:
		var id := String(m.get("id", ""))
		check(RegEx.create_from_string("^[a-z0-9_]+$").search(id) != null, "id слоя: '%s'" % id)
		check(not ids.has(id), "id уникален: %s" % id)
		ids[id] = true
		var url := String(m.get("url_template", ""))
		for k in ["{z}", "{x}", "{y}"]:
			check(url.contains(k), "%s: %s в url_template" % [id, k])
		var subs: Array = m.get("subdomains", [])
		if url.contains("{s}"):
			check(subs.size() > 0, "%s: {s} без subdomains" % id)
		var mz := int(m.get("max_zoom", 0))
		check(mz >= 1 and mz <= 19, "%s: max_zoom %d" % [id, mz])
		check(String(m.get("attribution", "")).strip_edges() != "", "%s: attribution" % id)
		var key := String(m.get("name_key", ""))
		check(key != "" and tr(key) != key, "%s: перевод %s" % [id, key])
	check(ids.has("opentopomap") and ids.has("osm"), "слои opentopomap и osm: %s" % [ids.keys()])
	if maps.size() > 0:
		check(String(maps[0].get("id", "")) == "opentopomap", "по умолчанию opentopomap")
	check(String(mp.get("tile_cache_dir", "")) != "", "tile_cache_dir")
	check(String(mp.get("user_agent", "")) != "", "user_agent")
	check(int(mp.get("elevation_zoom", 0)) == 12, "elevation_zoom 12")
	for k in ["light_azimuth_deg", "light_elevation_deg", "exaggeration", "low_color", "high_color"]:
		check(not mp.has(k), "ключ отмывки удалён: %s" % k)
	check(not FileAccess.file_exists("res://scripts/terrain/map_hillshade.gdshader"), "нет шейдера отмывки")


func test_k1_assets_attribution() -> void:
	var assets := FileAccess.get_file_as_string("res://ASSETS.md")
	check(assets.contains("OpenTopoMap"), "ASSETS.md: OpenTopoMap")
	check(assets.contains("tile.openstreetmap.org"), "ASSETS.md: тайлы OSM")


func test_k1_raster_loader() -> void:
	var path := "res://scripts/terrain/raster_tile_loader.gd"
	check(FileAccess.file_exists(path), "есть " + path)
	if not FileAccess.file_exists(path):
		return
	var n: Object = load(path).new()
	check(n.has_method("fetch_tile"), "RasterTileLoader.fetch_tile")
	n.free()


func test_k2_decode_height() -> void:
	var tl := TerrariumLoader.new()
	check(tl.has_method("decode_height"), "TerrariumLoader.decode_height")
	check(tl.has_method("height_in_image"), "TerrariumLoader.height_in_image")
	check(tl.has_method("elevation_at"), "TerrariumLoader.elevation_at")
	if tl.has_method("decode_height"):
		# 1000 м: 33768 = 131·256 + 232; 0 м: 32768 = 128·256 + 0
		var h1: float = tl.call("decode_height", Color8(131, 232, 0))
		check(absf(h1 - 1000.0) < 0.01, "decode 1000 м: %.3f" % h1)
		var h0: float = tl.call("decode_height", Color8(128, 0, 128))
		check(absf(h0 - 0.5) < 0.01, "decode 0,5 м: %.3f" % h0)
	if tl.has_method("height_in_image"):
		# два столбца: левый 0 м, правый 1000 м → посередине между центрами 500 м
		var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
		for y in 256:
			for x in 256:
				img.set_pixel(x, y, Color8(128, 0, 0) if x < 128 else Color8(131, 232, 0))
		var hm: float = tl.call("height_in_image", img, Vector2(128.0, 40.0))
		check(absf(hm - 500.0) < 1.0, "билинейно на границе 500 м: %.2f" % hm)
		var hc: float = tl.call("height_in_image", img, Vector2(10.5, 40.5))
		check(absf(hc) < 0.01, "центр пикселя слева 0 м: %.2f" % hc)
		var he: float = tl.call("height_in_image", img, Vector2(256.0, 256.0))
		check(absf(he - 1000.0) < 0.01, "край — зажим 1000 м: %.2f" % he)
	tl.free()


func test_k2_map_picker_interface() -> void:
	var mp := MapPicker.new()
	check(mp.has_signal("point_picked"), "сигнал point_picked")
	check(mp.has_signal("elevation_ready"), "сигнал elevation_ready")
	var v: Variant = mp.get("picked_elevation_m")
	check(v is float and is_nan(v), "picked_elevation_m = NAN до выбора: %s" % v)
	mp.free()
