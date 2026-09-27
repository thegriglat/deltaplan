extends TestCase
## Тесты карты поверхности (VR-4), источников термиков и дымки (VR-3).
## Запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=terrain

const LOCATION := "altai"

static var _terrain: Terrain


func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location(LOCATION)
	return _terrain


## Ровная (или наклонная) площадка 200×200 м с картой поверхности одного класса.
func _plane(cls: int, ax: float = 0.0, az: float = 0.0) -> Terrain:
	var n := 21
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = 500.0 + ax * (-100.0 + i * 10.0) + az * (-100.0 + j * 10.0)
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("plane", n, n, 10.0, -100.0, -100.0, data)]
	var cls_data := PackedByteArray()
	cls_data.resize(n * n)
	cls_data.fill(cls)
	var s := SurfaceLayer.from_classes("plane", n, n, 10.0, -100.0, -100.0, cls_data)
	var world: Dictionary = Config.get_config("world")
	t.refresh_sun()
	t.set_surfaces([s], world.surface, world.terrain_look)
	return t


func _surface_png(info: Dictionary) -> PackedByteArray:
	var dir: String = Config.get_config("locations/" + LOCATION).data_dir
	var img := Image.new()
	img.load_png_from_buffer(FileAccess.get_file_as_bytes(dir.path_join(info.file)))
	return img.get_data()


func test_surface_loaded_from_worldcover() -> void:
	var t := _altai()
	check(t.surfaces.size() == t.layers.size(), "карта у каждого слоя")
	for s in t.surfaces:
		check(s.source == "worldcover", "слой %s из WorldCover, а не %s" % [s.id, s.source])
	var fr := t.surfaces[0].fractions()
	check(fr[SurfaceLayer.FOREST] > 0.3, "лес на детальном слое: %.2f" % fr[SurfaceLayer.FOREST])
	check(fr[SurfaceLayer.GRASS] > 0.1, "луг: %.2f" % fr[SurfaceLayer.GRASS])
	check(fr[SurfaceLayer.WATER] > 0.002, "вода (Катунь): %.3f" % fr[SurfaceLayer.WATER])
	check(fr[SurfaceLayer.BUILT] > 0.002, "застройка: %.3f" % fr[SurfaceLayer.BUILT])
	check(fr[SurfaceLayer.NONE] < 0.01, "почти нет пустых клеток: %.3f" % fr[SurfaceLayer.NONE])


func test_surface_at_matches_data() -> void:
	var t := _altai()
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(
			String(Config.get_config("locations/" + LOCATION).data_dir).path_join("surface.json")
		)
	)
	var info: Dictionary = meta.layers[0]
	var raw := _surface_png(info)
	var w := int(info.width)
	var step := float(info.spacing_m)
	var rock_cos := cos(deg_to_rad(float(Config.value("world", "terrain_look").rock_slope_deg)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var checked := 0
	for k in 400:
		var i := rng.randi_range(0, w - 1)
		var j := rng.randi_range(0, int(info.height) - 1)
		var x := float(info.origin_x_m) + i * step + rng.randf_range(-0.45, 0.45) * step
		var z := float(info.origin_z_m) + j * step + rng.randf_range(-0.45, 0.45) * step
		var c := raw[j * w + i]
		var got := t.surface_at(x, z)
		if t.normal_at(x, z).y < rock_cos or _near_start(t, x, z):
			continue  # скалы по уклону и поляны у стартов — ожидаемые отличия
		checked += 1
		check(got == c, "узел (%d,%d): surface_at %d, в данных %d" % [i, j, got, c])
	check(checked > 300, "проверено точек: %d" % checked)


func _near_start(t: Terrain, x: float, z: float) -> bool:
	var r := float(t.location.get("start_clearing_radius_m", 0.0)) + 30.0
	for s in t.get_start_sites():
		var p: Vector3 = s.position
		if Vector2(p.x - x, p.z - z).length() < r:
			return true
	return false


func test_real_places() -> void:
	# Горно-Алтайск (центр, 51.958 N 85.960 E) — застройка; Катунь у Манжерока — вода.
	var t := _altai()
	check(_class_near(t, 51.958, 85.960, SurfaceLayer.BUILT, 150.0), "Горно-Алтайск — застройка")
	check(_class_near(t, 51.8235, 85.779, SurfaceLayer.WATER, 300.0), "Катунь у Манжерока — вода")


func _class_near(t: Terrain, lat: float, lon: float, cls: int, r: float) -> bool:
	var p := t.latlon_to_local(lat, lon)
	var n := 6
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			if t.surface_at(p.x + i * r / n, p.y + j * r / n) == cls:
				return true
	return false


func test_start_clearings_have_no_forest() -> void:
	var t := _altai()
	var r := float(t.location.start_clearing_radius_m) * 0.8
	for s in t.get_start_sites():
		var p: Vector3 = s.position
		for k in 16:
			var a := TAU * k / 16.0
			var c := t.surface_at(p.x + cos(a) * r, p.z + sin(a) * r)
			check(c != SurfaceLayer.FOREST, "у старта %s лес на расстоянии %.0f м" % [s.id, r])


func test_thermal_strength_by_class() -> void:
	# Ровная площадка: слабые источники (вода, снег, лес) < луг < поле/скалы.
	var order := [
		SurfaceLayer.WATER,
		SurfaceLayer.SNOW,
		SurfaceLayer.FOREST,
		SurfaceLayer.SHRUB,
		SurfaceLayer.GRASS,
		SurfaceLayer.CROP,
	]
	var prev := -1.0
	for c: int in order:
		var t := _plane(c)
		check(t.surface_at(0, 0) == c, "класс площадки %d" % c)
		var v := t.thermal_source_strength_at(0.0, 0.0)
		check(v >= 0.0 and v <= 1.0, "0..1: %.3f" % v)
		check(
			v > prev,
			"%s (%.3f) сильнее предыдущего (%.3f)" % [SurfaceLayer.CLASS_NAMES[c], v, prev]
		)
		prev = v
		t.free()
	var bare := _plane(SurfaceLayer.BARE)
	check(bare.thermal_source_strength_at(0, 0) >= prev - 1e-6, "скалы не слабее поля")
	bare.free()
	var water := _plane(SurfaceLayer.WATER)
	var sun_min := float(Config.value("atmosphere", "thermal").get("sun_min", 0.35))
	check(water.thermal_source_strength_at(0, 0) < sun_min, "над водой термики не рождаются")
	water.free()
	var field := _plane(SurfaceLayer.CROP)
	check(field.thermal_source_strength_at(0, 0) > 0.75, "ровное поле — сильный источник")
	field.free()


func test_thermal_strength_by_exposure() -> void:
	# Один класс: склон к солнцу > ровно > склон от солнца (монотонно по освещённости).
	for c: int in [SurfaceLayer.GRASS, SurfaceLayer.FOREST]:
		var flat := _plane(c)
		var sun := flat.sun_direction()
		var gx := sun.x / sun.y * 0.4
		var gz := sun.z / sun.y * 0.4
		var toward := _plane(c, -gx, -gz)
		var away := _plane(c, gx, gz)
		var a := away.thermal_source_strength_at(0, 0)
		var f := flat.thermal_source_strength_at(0, 0)
		var w := toward.thermal_source_strength_at(0, 0)
		check(a < f, "%s: от солнца %.3f < ровно %.3f" % [SurfaceLayer.CLASS_NAMES[c], a, f])
		check(f <= w, "%s: ровно %.3f ≤ к солнцу %.3f" % [SurfaceLayer.CLASS_NAMES[c], f, w])
		for t in [flat, toward, away]:
			t.free()


func test_thermal_edge_boost() -> void:
	# Ровная площадка 1×1 км: запад (x < 0) — поле, восток — лес. Граница — триггер отрыва:
	# у неё сила выше, чем в середине поля и в середине леса.
	var n := 101
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	hs.fill(500.0)
	var cls := PackedByteArray()
	cls.resize(n * n)
	for j in n:
		for i in n:
			cls[j * n + i] = SurfaceLayer.CROP if i < 50 else SurfaceLayer.FOREST
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("p", n, n, 10.0, -500.0, -500.0, hs)]
	var world: Dictionary = Config.get_config("world")
	t.refresh_sun()
	t.set_surfaces(
		[SurfaceLayer.from_classes("p", n, n, 10.0, -500.0, -500.0, cls)],
		world.surface,
		world.terrain_look
	)
	var field_mid := t.thermal_source_strength_at(-400.0, 0.0)
	var forest_mid := t.thermal_source_strength_at(400.0, 0.0)
	var field_edge := t.thermal_source_strength_at(-30.0, 0.0)
	var forest_edge := t.thermal_source_strength_at(30.0, 0.0)
	check(
		field_edge > field_mid, "граница поля %.3f > середина поля %.3f" % [field_edge, field_mid]
	)
	check(field_edge > forest_mid, "граница %.3f > середина леса %.3f" % [field_edge, forest_mid])
	check(forest_edge > forest_mid, "опушка %.3f > глубь леса %.3f" % [forest_edge, forest_mid])
	approx(t.edge_proximity(-400.0, 0.0), 0.0, 1e-6, "далеко от границы усиления нет")
	approx(t.edge_proximity(-30.0, 0.0), 1.0, 1e-6, "у границы — полное")
	var mid := t.edge_proximity(-100.0, 0.0)
	check(mid > 0.0 and mid < 1.0, "в полосе 50–150 м — частичное: %.2f" % mid)
	t.free()


func test_thermal_fn_fits_atmosphere() -> void:
	# Годится как sun_fn для Atmosphere.set_ground: Callable (x, z) -> float 0..1.
	var t := _altai()
	var fn := t.thermal_source_strength_at
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var sum := 0.0
	for k in 500:
		var v: float = fn.call(rng.randf_range(-19000, 19000), rng.randf_range(-19000, 19000))
		check(v >= 0.0 and v <= 1.0, "0..1: %f" % v)
		sum += v
	check(sum / 500.0 > 0.2 and sum / 500.0 < 0.9, "среднее разумное: %.2f" % (sum / 500.0))


func test_fallback_classifier() -> void:
	var t := _altai()
	var fb: Dictionary = Config.value("world", "surface").fallback
	var s := SurfaceClassifier.classify(t.layers[0], fb)
	check(s.source == "procedural", "процедурная карта")
	var fr := s.fractions()
	check(fr[SurfaceLayer.FOREST] > 0.1, "есть лес: %.2f" % fr[SurfaceLayer.FOREST])
	check(fr[SurfaceLayer.GRASS] > 0.05, "есть луг: %.2f" % fr[SurfaceLayer.GRASS])
	check(fr[SurfaceLayer.NONE] == 0.0, "нет пустых клеток")
	var s2 := SurfaceClassifier.classify(t.layers[0], fb)
	check(s2.classes == s.classes, "детерминирована")


func test_cog_reader_synthetic() -> void:
	# Тайловый TIFF 40×20, тайл 16×16 (3×2 тайла), без сжатия, геопривязка 0.001°.
	var tags := [
		[256, 3, 1, 40],
		[257, 3, 1, 20],
		[258, 3, 1, 8],
		[259, 3, 1, 1],
		[322, 3, 1, 16],
		[323, 3, 1, 16],
	]
	var h := PackedByteArray()
	h.resize(1024)
	h.encode_u8(0, 0x49)
	h.encode_u8(1, 0x49)
	h.encode_u16(2, 42)
	h.encode_u32(4, 8)
	var n := tags.size() + 4
	h.encode_u16(8, n)
	var e := 10
	for tg: Array in tags:
		h.encode_u16(e, tg[0])
		h.encode_u16(e + 2, tg[1])
		h.encode_u32(e + 4, tg[2])
		h.encode_u16(e + 8, tg[3])
		e += 12
	var extra := 400
	# 324/325 — 6 значений LONG вынесены по адресу extra
	for spec: Array in [[324, 1000], [325, 256]]:
		h.encode_u16(e, spec[0])
		h.encode_u16(e + 2, 4)
		h.encode_u32(e + 4, 6)
		h.encode_u32(e + 8, extra)
		for k in 6:
			h.encode_u32(extra + k * 4, spec[1] + (k * 256 if spec[0] == 324 else 0))
		extra += 24
		e += 12
	h.encode_u16(e, 33550)
	h.encode_u16(e + 2, 12)
	h.encode_u32(e + 4, 3)
	h.encode_u32(e + 8, extra)
	h.encode_double(extra, 0.001)
	h.encode_double(extra + 8, 0.001)
	extra += 24
	e += 12
	h.encode_u16(e, 33922)
	h.encode_u16(e + 2, 12)
	h.encode_u32(e + 4, 6)
	h.encode_u32(e + 8, extra)
	h.encode_double(extra + 24, 85.0)
	h.encode_double(extra + 32, 52.0)
	e += 12
	h.encode_u32(e, 0)
	var cog := CogReader.parse(h)
	check(cog.is_valid(), "разобран: %s" % cog.error)
	check(cog.levels.size() == 1 and int(cog.levels[0].width) == 40, "уровень 40×20")
	approx(cog.origin_lon, 85.0, 1e-9, "долгота угла")
	approx(cog.origin_lat, 52.0, 1e-9, "широта угла")
	var p := cog.pixel_of(0, 52.0 - 0.0175, 85.0 + 0.0335)
	check(p == Vector2i(33, 17), "пиксель %s" % p)
	check(cog.tile_index(0, 2, 1) == 5, "номер тайла")
	check(int(cog.levels[0].offsets[5]) == 1000 + 5 * 256, "смещение тайла")
	var raw := PackedByteArray()
	raw.resize(256)
	raw.fill(40)
	check(cog.decode_tile(0, raw).size() == 256, "тайл без сжатия")
	check(CogReader.parse(PackedByteArray([1, 2, 3])).is_valid() == false, "мусор не разбирается")
	check(WorldCoverLoader.tile_name(51, 84) == "N51E084", "имя файла WorldCover")
	check(WorldCoverLoader.tile_name(-3, -78) == "S03W078", "имя файла на юго-западе")


func test_haze_params_applied() -> void:
	var env := SkyEnvironment.new()
	env.apply_config()
	var hz: Dictionary = Config.get_config("world").haze
	var m := env.haze_material()
	check(m != null, "дымка создана")
	if m == null:
		env.free()
		return
	approx(
		float(m.get_shader_parameter("extinction")),
		3.912 / (float(hz.visibility_km) * 1000.0),
		1e-9,
		"ослабление по видимости"
	)
	approx(env.get_haze_top_msl(), float(hz.default_top_msl_m), 1e-3, "верх по умолчанию")
	env.set_inversion_height_msl(1500.0)
	var top := 1500.0 + float(hz.top_margin_m)
	approx(env.get_haze_top_msl(), top, 1e-3, "верх = инверсия + запас")
	approx(float(m.get_shader_parameter("top_msl")), top, 1e-3, "верх передан в шейдер")
	approx(
		float(m.get_shader_parameter("top_transition_m")),
		float(hz.top_transition_m),
		1e-3,
		"толщина границы"
	)
	check(float(hz.visibility_km) >= 20.0, "видимость в дымке ≥ 20 км (FR-20)")
	env.free()


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
