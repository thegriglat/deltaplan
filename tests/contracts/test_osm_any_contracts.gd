extends TestCase
## Контрактные тесты модуля osm-any (docs/contracts/osm-any.md): OA-К1 папка места, OA-К2 файл OSM,
## OA-К3 API стадий сборки, OA-К4 сборщик/кеш/реестр. Без сети и GPU.
## Правка контракта (версия +1) — вместе с этим файлом. Части, которых ещё нет в коде, падают —
## их делают зелёными задачи-владельцы (OA-1…OA-5). Методы — через call()/список методов, чтобы
## отсутствие метода было падением теста, а не ошибкой разбора файла.

const DOC := "res://docs/contracts/osm-any.md"
const BUILD_DIR := "res://scripts/terrain/build/"


func _doc_line(head: String) -> String:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func _builtin_ids() -> Array:
	var ids: Array = []
	for c: String in Config.list_configs("locations"):
		ids.append(c.get_file())
	return ids


func _methods(path: String) -> Dictionary:
	var out := {}
	if not ResourceLoader.exists(path):
		return out
	var scr: Script = load(path)
	if scr == null:
		return out
	for m in scr.get_script_method_list():
		out[m.name] = m
	return out


func _has_keys(d: Dictionary, keys: Array, what: String) -> void:
	for k: String in keys:
		check(d.has(k), "%s: нет ключа %s" % [what, k])


func test_versions_in_doc() -> void:
	var want := {"OA-К1": 2, "OA-К2": 2, "OA-К3": 1, "OA-К4": 2}
	for id: String in want:
		check(_doc_line("## %s." % id).contains("(v%d)" % want[id]), "%s v%d в документе" % [id, want[id]])


func test_k1_builtin_layout() -> void:
	var ids := _builtin_ids()
	check(ids.size() >= 1, "встроенные места есть")
	for id: String in ids:
		var loc: Dictionary = Config.get_config("locations/" + id)
		var dir := Locations.data_dir(id)
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + "/meta.json"))
		_has_keys(meta, ["location", "center_lat", "center_lon", "earth_radius_m", "layers", "attribution"], id + " meta")
		var layers: Array = meta.get("layers", [])
		check(layers.size() == 2 and layers[0].id == "detail" and layers[1].id == "far", id + ": слои detail, far")
		for l: Dictionary in layers:
			_has_keys(l, ["id", "file", "width", "height", "spacing_m", "origin_x_m", "origin_z_m",
				"min_height_m", "max_height_m", "source", "water_file", "height_min_m", "height_step_m"], id + " слой")
			check(String(l.file) == String(l.id) + ".webp", id + ": высоты встроенного — .webp (no-osm N5)")
			check(FileAccess.file_exists(dir + "/" + String(l.file)), id + ": файл высот")
			var w := Image.load_from_file(dir + "/" + String(l.water_file))
			if w != null:
				w.convert(Image.FORMAT_L8)
			check(w != null and w.get_width() == int(l.width),
				"%s: %s L8 %d" % [id, l.water_file, l.width])
			var s := Image.load_from_file("%s/%s_surface.webp" % [dir, l.id])
			check(s != null and s.get_height() == int(l.height), "%s: %s_surface.webp" % [id, l.id])
		var surf: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + "/surface.json"))
		_has_keys(surf, ["source", "layers", "attribution"], id + " surface")
		var d10: Dictionary = surf.layers[0].get("detail10", {})
		_has_keys(d10, ["file", "width", "height", "spacing_m", "origin_x_m", "origin_z_m", "channels",
			"forest_fraction", "water_fraction"], id + " detail10")
		var img := Image.load_from_file(dir + "/" + String(d10.get("file", "")))
		check(img != null and img.get_width() == int(d10.get("width", 0)), id + ": detail10 (webp)")


func test_k1_no_python_build() -> void:
	check(not DirAccess.dir_exists_absolute("res://data/osm"), "data/osm/ убран (OSM — в папке места)")
	for f in ["res://tools/terrain/fetch_dem.py", "res://tools/terrain/fetch_landcover.py", "res://tools/terrain/rivers.py",
			"res://tools/terrain/osm_water.py", "res://tools/osm/fetch_osm.py"]:
		check(not FileAccess.file_exists(f), "Python-сборка убрана: " + f)
	for id: String in _builtin_ids():
		var loc: Dictionary = Config.get_config("locations/" + id)
		check(FileAccess.file_exists(Locations.data_dir(id) + "/build.json"), id + ": build.json встроенного")


## test_k1_height_zst снят: высоты — WebP 24 бит (no-osm N5), проверка — tests/terrain/test_height_layer.gd.


func test_k3_context() -> void:
	var path := BUILD_DIR + "location_build_context.gd"
	check(ResourceLoader.exists(path), "LocationBuildContext есть")
	if not ResourceLoader.exists(path):
		return
	var ctx: Object = (load(path) as Script).new()
	for p in ["key", "center_lat", "center_lon", "dir", "spec", "host", "offline", "cancelled", "heights",
			"layers", "net_requests", "log_lines"]:
		check(p in ctx, "LocationBuildContext.%s" % p)
	check(ctx.has_signal("progress"), "LocationBuildContext.progress")


func _check_run(f: String) -> Dictionary:
	var m := _methods(BUILD_DIR + f)
	check(m.has("run") and (m.run.args as Array).size() == 1, "%s: run(ctx)" % f)
	return m


func test_k3_dem() -> void:
	_check_run("dem_stage.gd")


func test_k3_river() -> void:
	var m := _check_run("river_stage.gd")
	check(m.has("compute") and (m.compute.args as Array).size() == 3, "RiverStage.compute(heights, layers, cfg)")


func test_k3_surface() -> void:
	_check_run("surface_stage.gd")


func test_k4_config() -> void:
	var lb: Dictionary = Config.get_config("world").get("location_builder", {})
	_has_keys(lb, ["version", "cache_dir", "snap_deg", "builtin_margin_km", "template"], "location_builder")
	_has_keys(lb.get("template", {}), ["dem", "render", "rivers", "surface", "start_clearing_radius_m"], "template")
	var dem: Array = lb.get("template", {}).get("dem", {}).get("layers", [])
	check(dem.size() == 2 and dem[0].id == "detail" and dem[0].source == "copernicus"
		and dem[1].id == "far" and dem[1].source == "terrarium", "шаблон: detail copernicus, far terrarium")


func test_k4_cache_key() -> void:
	var cache := _methods("res://scripts/terrain/build/location_cache.gd")
	check(cache.has("key_for") and cache.has("dir_for"), "LocationCache.key_for/dir_for")
	if not cache.has("key_for"):
		return
	var scr: Script = load("res://scripts/terrain/build/location_cache.gd")
	check(scr.call("key_for", 53.26, 58.54) == "pt_+53.250_+058.550", "key_for(53.26, 58.54)")
	check(scr.call("key_for", -5.51, -0.02) == "pt_-05.500_+000.000", "key_for(-5.51, -0.02)")
	check(scr.call("dir_for", "pt_+53.250_+058.550") == "user://locations/pt_+53.250_+058.550", "dir_for")


func test_k4_registry() -> void:
	var b := _methods("res://scripts/terrain/build/location_builder.gd")
	check(b.has("build") and (b.build.args as Array).size() == 3, "LocationBuilder.build(host, lat, lon)")
	var r := _methods("res://scripts/terrain/build/locations.gd")
	for n in ["config", "is_builtin", "builtin_at"]:
		check(r.has(n), "Locations.%s" % n)
	if r.has("config"):
		var scr: Script = load("res://scripts/terrain/build/locations.gd")
		for id: String in _builtin_ids():
			check(scr.call("is_builtin", id), "is_builtin(%s)" % id)
			check(not (scr.call("config", id) as Dictionary).is_empty(), "config(%s)" % id)
		var al: Dictionary = Config.get_config("locations/altai")
		check(scr.call("builtin_at", float(al.center_lat), float(al.center_lon)) == "altai", "builtin_at(центр altai)")
		check(scr.call("builtin_at", 0.0, -30.0) == "", "builtin_at(океан) пусто")
