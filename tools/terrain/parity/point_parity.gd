extends SceneTree
## OA-6: таблица паритета слоёв «после» — собранная точка против встроенного места.
##   godot --headless --path . -s res://tools/terrain/parity/point_parity.gd -- [--point <папка>] [--builtin askarovo]
## По умолчанию папка точки — dir= из build/point_cache.txt. Читает только файлы папок (meta/surface/osm.json, png).
## Пишет build/point_parity.md и печатает те же строки key=value.

const OSM_LAYERS := ["roads", "buildings", "power", "places"]


func _initialize() -> void:
	var point := ""
	var builtin := "askarovo"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--point" and i + 1 < args.size():
			point = args[i + 1]
		elif args[i] == "--builtin" and i + 1 < args.size():
			builtin = args[i + 1]
	if point == "":
		for l in FileAccess.get_file_as_string("res://build/point_cache.txt").split("\n"):
			if l.begins_with("dir="):
				point = l.substr(4)
	if point == "":
		print("нет папки точки: --point или build/point_cache.txt")
		quit(2)
		return
	var cols: Array = [_collect(point, false), _collect("res://data/terrain/" + builtin, true)]
	var names := ["точка", builtin]
	var keys: Array[String] = []
	for c: Dictionary in cols:
		for k: String in c:
			if not keys.has(k):
				keys.append(k)
	keys.sort()
	var md := "| параметр | %s | %s |\n|---|---|---|\n" % names
	for k in keys:
		md += "| %s | %s | %s |\n" % [k, cols[0].get(k, "—"), cols[1].get(k, "—")]
		print("%s: точка=%s %s=%s" % [k, cols[0].get(k, "—"), builtin, cols[1].get(k, "—")])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var f := FileAccess.open(ProjectSettings.globalize_path("res://build/point_parity.md"), FileAccess.WRITE)
	f.store_string(md)
	f.close()
	quit(0)


func _json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _collect(dir: String, builtin: bool) -> Dictionary:
	var r := {}
	var meta: Variant = _json(dir.path_join("meta.json"))
	if meta is Dictionary:
		r["meta.источник_рельефа"] = ""
		for l: Dictionary in meta.layers:
			var id := String(l.id)
			r["сетка.%s" % id] = "%dx%d, шаг %s м" % [l.width, l.height, l.spacing_m]
			r["рельеф.%s.источник" % id] = String(l.source)
			r["рельеф.%s.высоты_м" % id] = "%.0f..%.0f" % [l.min_height_m, l.max_height_m]
			var wf := String(l.get("water_file", ""))
			r["реки_png.%s" % id] = "есть" if wf != "" and FileAccess.file_exists(dir.path_join(wf)) else "нет"
			var hf := String(l.file)
			r["файл_высот.%s" % id] = hf.get_extension() + (" (есть)" if FileAccess.file_exists(dir.path_join(hf)) else " (нет)")
		r.erase("meta.источник_рельефа")
	var sf: Variant = _json(dir.path_join("surface.json"))
	if sf is Dictionary:
		r["покров.источник"] = String(sf.source)
		for l: Dictionary in sf.layers:
			var id := String(l.id)
			r["покров.%s.сетка" % id] = "%dx%d, шаг %s м" % [l.width, l.height, l.spacing_m]
			var cf: Dictionary = l.class_fraction
			var parts: Array[String] = []
			for c: String in cf:
				if float(cf[c]) >= 0.005:
					parts.append("%s:%.0f%%" % [c, float(cf[c]) * 100.0])
			r["покров.%s.классы" % id] = " ".join(parts)
			if l.has("detail10"):
				var d: Dictionary = l.detail10
				r["detail10.сетка"] = "%dx%d, шаг %s м" % [d.width, d.height, d.spacing_m]
				r["detail10.лес_доля"] = "%.3f" % float(d.forest_fraction)
				r["detail10.вода_доля"] = "%.3f" % float(d.water_fraction)
	var osm_path := dir.path_join("osm.json")
	if builtin:
		osm_path = "res://data/osm/%s.json" % dir.get_file()
	var osm: Variant = _json(osm_path)
	if osm is Dictionary:
		for k: String in OSM_LAYERS:
			r["osm.%s" % k] = str(osm.get(k, []).size())
		var w: Dictionary = osm.get("water", {})
		r["osm.реки"] = str(w.get("rivers", []).size())
		r["osm.озёра"] = str(w.get("lakes", []).size())
		var lu: Dictionary = osm.get("landuse", {})
		r["osm.поля"] = str(lu.get("fields", []).size())
		r["osm.заборы"] = str(lu.get("fences", []).size())
	else:
		r["osm.json"] = "нет"
	return r
