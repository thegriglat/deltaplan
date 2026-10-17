extends TestCase
## Контракт VI-К1, часть «данные» (docs/contracts/volcano-island.md): встроенное место volcano_island —
## папка формата 4 в res://data/locations/volcano_island/ (реальные данные, собраны обычным сборщиком) и конфиг
## configs/locations/volcano_island.json. Часть «код» (is_training_only, osm_root, OSM из папки) — ниже (VI-2).

const ID := "volcano_island"
const DIR := "res://data/locations/volcano_island"
const FILES := [
	"meta.json", "surface.json", "build.json", "osm_tiles.json", "built_patches.json", "detail.webp", "far.webp",
	"detail_surface.webp", "far_surface.webp", "detail_water.webp", "far_water.webp", "detail_detail10.webp", "detail_built10.webp",
]
const STEP := 0.03125


func _json(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(DIR.path_join(name)))


func _dict(name: String) -> Dictionary:
	var d: Variant = _json(name)
	return d if d is Dictionary else {}


func _img(name: String) -> Image:
	var img := Image.new()
	var bytes := FileAccess.get_file_as_bytes(DIR.path_join(name))
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		return null
	return img


func _layer(meta: Dictionary, id: String) -> Dictionary:
	for l: Dictionary in meta.get("layers", []):
		if String(l.get("id", "")) == id:
			return l
	return {}


func _h(img: Image, info: Dictionary, i: int, j: int) -> float:
	var c := img.get_pixel(i, j)
	return float(info.height_min_m) + float(info.height_step_m) * float((c.r8 << 16) | (c.g8 << 8) | c.b8)


func test_volcano_island_files() -> void:
	for f: String in FILES:
		check(FileAccess.file_exists(DIR.path_join(f)), "есть %s" % f)
	check(not FileAccess.file_exists(DIR.path_join("location.json")), "нет location.json")
	check(not FileAccess.file_exists(DIR.path_join("detail_raw.webp")), "нет detail_raw.webp")
	var b := _dict("build.json")
	check(int(b.get("format_version", 0)) == Locations.FORMAT_VERSION, "build.json: формат %s" % b.get("format_version"))
	check(String(b.get("key", "")) == ID, "build.json: key")
	check(b.get("complete", false) == true and Array(b.get("missing", [1])).is_empty(), "build.json: complete, missing []")
	var src: Array = b.get("sources", [])
	check(src.has("copernicus") and src.has("worldcover") and not src.has("synthetic"), "build.json: реальные источники %s" % [src])
	var s := _dict("surface.json")
	check(Array(s.get("attribution", [])).size() >= 1, "surface.json: атрибуция")
	var meta := _dict("meta.json")
	check(Array(meta.get("attribution", [])).size() >= 1, "meta: атрибуция")


func test_volcano_island_osm_tiles() -> void:
	var tiles: Array = _dict("osm_tiles.json").get("tiles", [])
	var ok_n := 0
	for t: Array in tiles:
		var st := String(t[2])
		var f := DIR.path_join("osm").path_join(str(int(t[0]))).path_join("%d.dpt" % int(t[1]))
		check(st == "ok" or st == "none", "тайл %s/%s: статус %s (ok/none)" % [t[0], t[1], st])
		if st == "ok":
			ok_n += 1
			check(FileAccess.file_exists(f), "тайл %s/%s: есть .dpt" % [t[0], t[1]])
			check(FileAccess.get_file_as_bytes(f).size() > 0, "тайл %s/%s: не пуст" % [t[0], t[1]])
		else:
			check(not FileAccess.file_exists(f), "тайл %s/%s: none — файла нет" % [t[0], t[1]])
	check(ok_n >= 1, "хоть один тайл OSM (%d)" % ok_n)


func test_volcano_island_layers() -> void:
	var meta := _dict("meta.json")
	check(String(meta.get("location", "")) == ID, "meta: location")
	check(is_equal_approx(float(meta.get("earth_radius_m", 0)), 6371008.8), "meta: радиус Земли")
	var want := {"detail": [1601, 25.0, -20000.0], "far": [1601, 100.0, -80000.0]}
	for id: String in want:
		var l := _layer(meta, id)
		var w: Array = want[id]
		check(int(l.get("width", 0)) == w[0] and int(l.get("height", 0)) == w[0], "%s: %d²" % [id, w[0]])
		check(is_equal_approx(float(l.get("spacing_m", 0)), w[1]), "%s: шаг %s" % [id, l.get("spacing_m")])
		check(
			is_equal_approx(float(l.get("origin_x_m", 0)), w[2]) and is_equal_approx(float(l.get("origin_z_m", 0)), w[2]),
			"%s: начало %s" % [id, w[2]]
		)
		check(is_equal_approx(float(l.get("height_step_m", 0)), STEP), "%s: height_step 1/32" % id)
		check(String(l.get("file", "")) == id + ".webp" and String(l.get("water_file", "")) == id + "_water.webp", "%s: файлы" % id)
		for f: String in [id + ".webp", id + "_surface.webp", id + "_water.webp"]:
			var img := _img(f)
			check(img != null and img.get_width() == w[0] and img.get_height() == w[0], "%s: %d²" % [f, w[0]])
	var m := _img("detail_detail10.webp")
	check(m != null and m.get_width() == 4001 and m.get_height() == 4001, "detail_detail10: 4001²")


func test_volcano_island_centre() -> void:
	var meta := _dict("meta.json")
	var dl := _layer(meta, "detail")
	var h := _img("detail.webp")
	var cls := _img("detail_surface.webp")
	var m10 := _img("detail_detail10.webp")
	if h == null or cls == null or m10 == null or dl.is_empty():
		check(false, "слои не прочитаны")
		return
	var hc := _h(h, dl, 800, 800)
	check(hc > 0.5, "центр: %.2f м > 0,5" % hc)
	check(cls.get_pixel(800, 800).r8 != 6 and m10.get_pixel(2000, 2000).a8 < 128, "центр: не вода")
	# остров целиком внутри detail с запасом ≥ 5 км: край квадрата — море (0 м)
	for p: Vector2i in [Vector2i(0, 0), Vector2i(800, 0), Vector2i(1600, 800), Vector2i(800, 1600), Vector2i(0, 1600)]:
		check(_h(h, dl, p.x, p.y) < 0.5, "край %s: море (%.2f м)" % [p, _h(h, dl, p.x, p.y)])


func test_volcano_island_config() -> void:
	var cfg := Config.get_config("locations/" + ID)
	check(cfg.get("bundled", false) == true and cfg.get("training_only", false) == true, "конфиг: bundled, training_only")
	check(not cfg.has("synthetic"), "конфиг: без synthetic")
	check(String(cfg.get("country", "x")) == "", "конфиг: country пусто")
	check(String(cfg.get("name", "")) == "loc_volcano_island", "конфиг: name")
	check(int(cfg.get("utc_offset_h", 0)) == -6, "конфиг: UTC−6")
	var meta := _dict("meta.json")
	check(
		is_equal_approx(float(cfg.get("center_lat", 0)), float(meta.center_lat)) and is_equal_approx(float(cfg.get("center_lon", 0)), float(meta.center_lon)),
		"центр конфига = центр meta.json"
	)
	var ids: Array = []
	for s: Dictionary in cfg.get("start_sites", []):
		ids.append(String(s.id))
		check(String(s.name) == "site_volcano_island_" + String(s.id), "старт %s: имя-ключ" % s.id)
		check(not StartWeather.parse(s.get("weather"), "volcano_island/" + String(s.id)).is_empty(), "старт %s: weather (TI-К2 v2, VI-5)" % s.id)
	for want_id: String in ["east_cliffs", "crater_ridge", "plateau_landing"]:
		check(ids.has(want_id), "старт %s" % want_id)
	check(ids.size() >= 3 and ids.size() <= 4, "3–4 старта: %s" % [ids])
	var lands: Array = []
	for l: Dictionary in cfg.get("landing_sites", []):
		lands.append(String(l.id))
	check(lands.has("landing_target"), "посадка-мишень landing_target")
	var wo := Config.get_config("world_objects")
	var wl: Array = wo.get("landing", {}).get("sites", {}).get(ID, [])
	var wl_ids: Array = []
	for l: Dictionary in wl:
		wl_ids.append(String(l.id))
	for id: String in lands:
		check(wl_ids.has(id), "world_objects: посадка %s" % id)
	# имена только словами локализации, без топонимов
	var txt := FileAccess.get_file_as_string("res://configs/locations/%s.json" % ID).to_lower()
	for bad: String in ["пасх", "рапа", "rapa", "easter", "poike", "поике", "хангаро", "hanga", "terevaka", "теревак", "anakena", "анакен", "рано"]:
		check(not txt.contains(bad), "конфиг без топонима «%s»" % bad)


func test_volcano_island_loads_from_res() -> void:
	check(Locations.is_bundled(ID), "bundled")
	check(Locations.data_dir(ID) == DIR, "data_dir: res://data/locations/volcano_island")
	var cache := Locations.cache_dir().path_join(ID)
	var cache_before := DirAccess.dir_exists_absolute(cache)
	var t := Terrain.new()
	t.location_id = ""
	await t.load_builtin(ID)
	check(t.location_id == ID and not t.layers.is_empty(), "остров загружен из res://")
	check(t._builder == null, "LocationBuilder не создавался")
	check(DirAccess.dir_exists_absolute(cache) == cache_before, "в кеш user:// ничего не писалось")
	if not t.layers.is_empty():
		check(t.height_at(0.0, 0.0) > 0.5, "точка (0,0) — суша (%.1f м)" % t.height_at(0.0, 0.0))
		check(t.surface_at(0.0, 0.0) != SurfaceLayer.WATER, "точка (0,0): не вода")
		check(not Terrain.is_sea(t.layers[0], t.surfaces[0], 0.0), "центр не море (is_sea)")
		var sites := t.get_start_sites()
		check(sites.size() >= 3, "старты загружены: %d" % sites.size())
		var tgt := false
		for l in t.get_landing_sites():
			tgt = tgt or String(l.id) == "landing_target"
		check(tgt, "landing_target загружена")
	t.free()


func test_volcano_island_git_files() -> void:
	var out: Array = []
	var root := ProjectSettings.globalize_path("res://")
	var code := OS.execute("git", ["-C", root, "ls-files", "data/locations/" + ID], out, true)
	if code != 0:
		return  # нет git — проверка пропущена
	var lines := String(out[0]).split("\n", false)
	check(lines.size() > 10, "в git есть файлы места (%d)" % lines.size())
	for f: String in lines:
		check(not f.ends_with(".remap") and not f.ends_with("location.json"), "в git нет служебного: %s" % f)
		if f.ends_with(".import"):
			check(f.ends_with(".webp.import") and lines.has(f.trim_suffix(".import")), "в git .import только у .webp: %s" % f)
	# VI-К1 v2: у каждого .webp — .webp.import с importer="keep" (сырой файл в экспорт, не текстура)
	for f: String in lines:
		if not f.ends_with(".webp"):
			continue
		var imp := f + ".import"
		check(lines.has(imp), "%s: .webp.import в git" % f)
		var txt := FileAccess.get_file_as_string("res://" + imp)
		check(txt.contains("importer=\"keep\"") and not txt.contains("importer=\"texture\""), "%s: importer=\"keep\"" % imp)


## Часть «код» (VI-2): training_only, builtin_at, каталог, корень тайлов OSM, last_flight.
func test_volcano_island_training_only_code() -> void:
	check(Locations.is_training_only(ID), "volcano_island: training_only")
	check(not Locations.is_training_only("training_island"), "training_island: не training_only")
	check(not Locations.is_training_only("altai") and not Locations.is_training_only("nope"), "altai/неизвестное: не training_only")
	check(Locations.builtin_at(-27.12, -109.35) == "", "builtin_at над островом — пусто")
	check(Locations.builtin_at(-27.1, -109.35) == "", "builtin_at в центре острова — пусто")
	var cat: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/places/hg_takeoffs.json"))
	var n := 0
	for t: Dictionary in (cat as Dictionary).get("takeoffs", []):
		n += 1 if String(t.get("location", "")) == ID else 0
	check(n == 0, "в каталоге «Популярные места» острова нет (%d)" % n)
	# last_flight с таким местом — место по умолчанию
	var dir := OS.get_cache_dir().path_join("dp_vi2_last")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("last_flight.json")
	var s := FlightSettings.defaults()
	s.location_id = ID
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(s.to_dict()))
	f.close()
	var back := UserSettings.load_last_flight(path)
	check(back.location_id == FlightSettings.defaults().location_id, "last_flight с volcano_island → место по умолчанию (%s)" % back.location_id)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)


func test_volcano_island_osm_from_place_dir() -> void:
	check(Locations.osm_root(ID) == DIR + "/osm", "osm_root острова = папка места/osm (%s)" % Locations.osm_root(ID))
	check(Locations.osm_root("training_island") == "res://data/locations/training_island/osm", "osm_root training_island — в его папке")
	check(Locations.osm_root("altai") == OsmTilesStage.cache_root(), "osm_root небандл-места — кеш тайлов")
	var cfg := Locations.config(ID)
	var d := OsmData.load_for(DIR, float(cfg.center_lat), float(cfg.center_lon), 20000.0, Locations.osm_root(ID))
	check(d.tiles_missing == 0, "тайлы острова все прочитаны (нет missing: %d)" % d.tiles_missing)
	check(d.tiles_ok >= 1, "тайлов найдено: %d" % d.tiles_ok)
	check(not d.is_empty(), "OsmData острова не пуст (дороги/дома из тайлов папки)")
