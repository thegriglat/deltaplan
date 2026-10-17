extends TestCase
## Контракт TI-К1 (docs/contracts/training-island.md): встроенное синтетическое место training_island —
## папка формата 4 в res://data/locations/training_island/ (файлы читаются напрямую, загрузчик bundled — TI-2)
## и конфиг configs/locations/training_island.json.

const DIR := "res://data/locations/training_island"
const FILES := [
	"meta.json", "surface.json", "build.json", "osm_tiles.json", "detail.webp", "far.webp",
	"detail_surface.webp", "far_surface.webp", "detail_water.webp", "far_water.webp", "detail_detail10.webp",
]
const STEP := 0.03125


func _json(name: String) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR.path_join(name)))
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


func test_training_island_files() -> void:
	for f: String in FILES:
		check(FileAccess.file_exists(DIR.path_join(f)), "есть %s" % f)
	var b := _json("build.json")
	check(int(b.get("format_version", 0)) == Locations.FORMAT_VERSION, "build.json: формат %s" % b.get("format_version"))
	check(String(b.get("key", "")) == "training_island", "build.json: key")
	check(b.get("complete", false) == true and Array(b.get("missing", [1])).is_empty(), "build.json: complete, missing []")
	check(Array(b.get("sources", [])) == ["synthetic"] and int(b.get("net_requests", -1)) == 0, "build.json: synthetic, 0 запросов")
	check(Array(_json("osm_tiles.json").get("tiles", [1])).is_empty(), "osm_tiles.json: пусто")
	var s := _json("surface.json")
	check(Array(s.get("attribution", [])) == ["Synthetic surface map: Deltaplan project"], "surface.json: attribution")


func test_training_island_layers() -> void:
	var meta := _json("meta.json")
	check(String(meta.get("location", "")) == "training_island", "meta: location")
	check(is_equal_approx(float(meta.get("earth_radius_m", 0)), 6371008.8), "meta: радиус Земли")
	check(Array(meta.get("attribution", [])) == ["Synthetic terrain: Deltaplan project"], "meta: attribution")
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
		check(String(l.get("source", "")) == "synthetic", "%s: source synthetic" % id)
		check(is_equal_approx(float(l.get("height_step_m", 0)), STEP), "%s: height_step 1/32" % id)
		check(String(l.get("file", "")) == id + ".webp" and String(l.get("water_file", "")) == id + "_water.webp", "%s: файлы" % id)
		for f: String in [id + ".webp", id + "_surface.webp", id + "_water.webp"]:
			var img := _img(f)
			check(img != null and img.get_width() == w[0] and img.get_height() == w[0], "%s: %d²" % [f, w[0]])
	var m := _img("detail_detail10.webp")
	check(m != null and m.get_width() == 4001 and m.get_height() == 4001, "detail_detail10: 4001²")
	check(m != null and m.detect_alpha() != Image.ALPHA_NONE, "detail_detail10: есть альфа (вода)")


func test_training_island_sea_and_centre() -> void:
	var meta := _json("meta.json")
	var dl := _layer(meta, "detail")
	var fl := _layer(meta, "far")
	var h := _img("detail.webp")
	var cls := _img("detail_surface.webp")
	var wat := _img("detail_water.webp")
	var m10 := _img("detail_detail10.webp")
	var hf := _img("far.webp")
	if h == null or cls == null or wat == null or m10 == null or hf == null or dl.is_empty() or fl.is_empty():
		check(false, "слои не прочитаны")
		return
	# море на краю detail: 0 м, класс 6, вода 255, A = 255
	for p: Vector2i in [Vector2i(0, 0), Vector2i(800, 0), Vector2i(1600, 800), Vector2i(800, 1600), Vector2i(0, 1600)]:
		check(_h(h, dl, p.x, p.y) == 0.0, "край %s: высота 0 м (%.3f)" % [p, _h(h, dl, p.x, p.y)])
		check(cls.get_pixel(p.x, p.y).r8 == 6, "край %s: класс 6" % p)
		check(wat.get_pixel(p.x, p.y).r8 == 255, "край %s: вода 255" % p)
	for p: Vector2i in [Vector2i(0, 0), Vector2i(2000, 0), Vector2i(4000, 4000)]:
		check(m10.get_pixel(p.x, p.y).a8 == 255, "detail10 %s: A = 255" % p)
	# центр (0, 0) — суша выше 0,5 м и не вода (Terrain.is_sea)
	var hc := _h(h, dl, 800, 800)
	check(hc > 0.5, "центр: %.2f м > 0,5" % hc)
	check(cls.get_pixel(800, 800).r8 != 6 and m10.get_pixel(2000, 2000).a8 < 128, "центр: не вода")
	# far: море 0 м по краю, detail вклеен (узел far 600 + k = узел detail 4k)
	check(_h(hf, fl, 0, 0) == 0.0 and hf.get_pixel(0, 0) == hf.get_pixel(1600, 1600), "far: море 0 м")
	for k: int in [100, 180, 200, 230, 300]:
		check(
			is_equal_approx(_h(hf, fl, 600 + k, 600 + k), _h(h, dl, 4 * k, 4 * k)),
			"far ⊃ detail в узле %d: %.3f = %.3f" % [k, _h(hf, fl, 600 + k, 600 + k), _h(h, dl, 4 * k, 4 * k)]
		)


func test_training_island_config() -> void:
	var cfg := Config.get_config("locations/training_island")
	check(cfg.get("bundled", false) == true and cfg.get("synthetic", false) == true, "конфиг: bundled, synthetic")
	check(String(cfg.get("country", "x")) == "", "конфиг: country пусто")
	check(String(cfg.get("name", "")) == "loc_training_island", "конфиг: name")
	check(int(cfg.get("utc_offset_h", 0)) == 3, "конфиг: UTC+3")
	check(not cfg.has("dem") and not cfg.has("surface") and not cfg.has("rivers"), "конфиг: без dem/surface/rivers")
	var ids: Array = []
	for s: Dictionary in cfg.get("start_sites", []):
		ids.append(String(s.id))
		check(String(s.name) == "site_training_island_" + String(s.id), "старт %s: имя-ключ" % s.id)
	check(ids.size() >= 3 and ids.size() <= 4, "3–4 старта: %s" % [ids])
	for want: String in ["ridge_west", "thermal_plain", "landing_hill"]:
		check(ids.has(want), "старт %s" % want)
	var lands: Array = []
	for l: Dictionary in cfg.get("landing_sites", []):
		lands.append(String(l.id))
	check(lands.has("landing_target"), "посадка-мишень landing_target")
	check(Locations.builtin_at(float(cfg.center_lat), float(cfg.center_lon)) == "", "точка с карты — не остров")


## TI-2: загрузчик bundled-места — файлы из res://, без LocationBuilder, сети и записи в кеш.
func test_training_island_loader() -> void:
	check(Locations.is_bundled("training_island") and Locations.is_synthetic("training_island"), "bundled + synthetic")
	check(Locations.data_dir("training_island") == DIR, "data_dir: res://data/locations/training_island (при fixtures_root тоже)")
	check(not Locations.is_bundled("altai"), "altai не bundled")
	check("training_island" in Locations.builtin_ids(), "остров в реестре встроенных")
	var cache := Locations.cache_dir().path_join("training_island")
	var cache_before := DirAccess.dir_exists_absolute(cache)
	var t := Terrain.new()
	t.location_id = ""
	await t.load_builtin("training_island")
	check(t.location_id == "training_island" and not t.layers.is_empty(), "остров загружен из res://")
	check(t._builder == null, "LocationBuilder не создавался")
	check(DirAccess.dir_exists_absolute(cache) == cache_before, "в кеш user:// ничего не писалось")
	if not t.layers.is_empty():
		check(t.height_at(0.0, 0.0) > 0.5, "точка (0,0) — суша (%.1f м)" % t.height_at(0.0, 0.0))
		check(t.surface_at(0.0, 0.0) != SurfaceLayer.WATER, "точка (0,0): не вода")
		check(not Terrain.is_sea(t.layers[0], t.surfaces[0], -450.0), "остров не море (is_sea)")
		var edge := 9500.0
		check(t.height_at(-edge, 0.0) == 0.0 and t.surface_at(-edge, 0.0) == SurfaceLayer.WATER, "край: вода, 0 м")
		check(t.surface_at(0.0, edge) == SurfaceLayer.WATER, "край (юг): вода")
	t.free()
	# нет папки — понятная ошибка, а не сборка из сети
	var fails: Array[String] = []
	var t2 := Terrain.new()
	t2.location_id = ""
	t2.load_failed.connect(func(m: String) -> void: fails.append(m))
	check(not t2.load_location("no_such_bundled_place"), "нет конфига — false")
	check(fails.size() == 1, "нет конфига — load_failed")
	t2.free()


## TI-2: сырые файлы острова идут в экспорт — importer="keep" у каждого .webp и фильтр data/**/* в пресетах.
func test_training_island_export() -> void:
	for f: String in FILES:
		if f.ends_with(".webp"):
			var imp := FileAccess.get_file_as_string(DIR.path_join(f + ".import"))
			check(imp.contains('importer="keep"'), "%s.import: importer keep" % f)
	var cfg := ConfigFile.new()
	check(cfg.load("res://export_presets.cfg") == OK, "export_presets.cfg читается")
	var n := 0
	for sec: String in cfg.get_sections():
		if sec.ends_with(".options"):
			continue
		n += 1
		var inc := String(cfg.get_value(sec, "include_filter", ""))
		var exc := String(cfg.get_value(sec, "exclude_filter", ""))
		check(inc.contains("data/**/*"), "%s: include data/**/*" % sec)
		check(not exc.contains("data/locations") and not exc.contains("*.webp"), "%s: данные мест не исключены" % sec)
	check(n >= 1, "пресеты есть")
