extends TestCase
## Тесты карты поверхности (VR-4), источников термиков и дымки (VR-3).
## Запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=terrain

const LOCATION := "altai"

static var _terrain: Terrain
static var _ongudai: Terrain
static var _aushkul: Terrain


func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location(LOCATION)
	return _terrain


## Ровная (или наклонная) площадка 200×200 м с картой поверхности одного класса.
## Онгудай — у него маска «деталь 10 м» и DSM с кронами (T02).
func _ong() -> Terrain:
	if _ongudai == null:
		_ongudai = Terrain.new()
		_ongudai.location_id = ""
		_ongudai.load_location("ongudai")
	return _ongudai


## Аушкуль — озеро Аушкуль (U1), маска 10 м с водой из OSM (T03).
func _aush() -> Terrain:
	if _aushkul == null:
		_aushkul = Terrain.new()
		_aushkul.location_id = ""
		_aushkul.load_location("aushkul")
	return _aushkul


## Слой карты поверхности с маской «деталь 10 м» (T02/T03), null — нет маски.
func _mask_layer(t: Terrain) -> SurfaceLayer:
	for sl in t.surfaces:
		if sl != null and sl.has_forest_mask():
			return sl
	return null


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
		var sl := t.surfaces[0]
		if sl.has_forest_mask() and (c == SurfaceLayer.FOREST) != (sl.mask_r(x, z) >= 0.5):
			continue  # лес на опушке — по маске 10 м (test_surface_at_forest_by_mask)
		if sl.has_forest_mask() and (c == SurfaceLayer.WATER) != (sl.mask_g(x, z) >= 0.5):
			continue  # вода — по маске 10 м OSM, точнее карты классов 25 м (T03)
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


## H класса c на площадке t при заданной нормали (SH2 mix_flux, один класс, ясно, m = 0,5) — эталон порядка.
func _h_of(t: Terrain, c: int, normal: Vector3) -> float:
	var fr := PackedFloat32Array()
	fr.resize(SurfaceLayer.CLASS_COUNT)
	fr[c] = 1.0
	var sun := PackedVector3Array()
	sun.resize(SurfaceLayer.CLASS_COUNT)
	sun.fill(t.sun_direction())
	return SurfaceHeat.mix_flux(
		fr, 0, normal, sun, 0.5, {"cover": 0.0, "sky_heat": 1.0}, {}, SurfaceHeat.config()
	)


func test_thermal_strength_by_class() -> void:
	# SH4: на ровном при одном солнце порядок s по классам = порядок H из SurfaceHeat; s = H / H_ref.
	var h_ref := float(SurfaceHeat.config().thermal.h_ref_wm2)
	var classes := [
		SurfaceLayer.SNOW,
		SurfaceLayer.FOREST,
		SurfaceLayer.SHRUB,
		SurfaceLayer.GRASS,
		SurfaceLayer.CROP,
		SurfaceLayer.BARE,
		SurfaceLayer.BUILT,
	]
	var hs := []
	var ss := []
	for c: int in classes:
		var t := _plane(c)
		check(t.surface_at(0, 0) == c, "класс площадки %d" % c)
		var v := t.thermal_source_strength_at(0.0, 0.0)
		var h := _h_of(t, c, Vector3.UP)
		check(v >= 0.0 and v <= 1.0, "0..1: %.3f" % v)
		approx(v, clampf(h / h_ref, 0.0, 1.0), 1e-4, "%s: s = H / H_ref" % SurfaceLayer.CLASS_NAMES[c])
		hs.append(h)
		ss.append(v)
		t.free()
	for i in classes.size():
		for j in classes.size():
			if hs[i] < hs[j] - 1e-3 and ss[j] < 1.0:
				check(
					ss[i] < ss[j],
					"порядок H: %s < %s" % [SurfaceLayer.CLASS_NAMES[classes[i]], SurfaceLayer.CLASS_NAMES[classes[j]]]
				)
	var field := _plane(SurfaceLayer.CROP)
	check(field.thermal_source_strength_at(0, 0) > 0.4, "ровное поле — заметный источник")
	field.free()


func test_thermal_water() -> void:
	# Вода: контекст не задан → 0; днём (T_w < T_a) → 0; вечером/ночью (T_w > T_a) > 0.
	var water := _plane(SurfaceLayer.WATER)
	check(water.thermal_source_strength_at(0, 0) == 0.0, "без контекста воды s = 0")
	water.set_water_heat(12.0, 22.0, 3.0)
	check(water.thermal_source_strength_at(0, 0) == 0.0, "вода днём (T_w < T_a) — не источник")
	water.set_water_heat(18.0, 8.0, 3.0)
	var v := water.thermal_source_strength_at(0, 0)
	check(v > 0.0 and v < 1.0, "вода теплее воздуха — источник: %.3f" % v)
	water.clear_water_heat()
	check(water.thermal_source_strength_at(0, 0) == 0.0, "после clear_water_heat s = 0")
	water.free()


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
		check(f < w or w >= 1.0, "%s: ровно %.3f ≤ к солнцу %.3f" % [SurfaceLayer.CLASS_NAMES[c], f, w])
		for t in [flat, toward, away]:
			t.free()


func test_thermal_edge_boost() -> void:
	# Ровная площадка 1×1 км: запад (x < 0) — поле, восток — лес. Граница — триггер отрыва:
	# у неё сила выше, чем в глубине того же класса (порядок классов теперь по H, не по ручным весам).
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
	check(forest_edge > forest_mid, "опушка %.3f > глубь леса %.3f" % [forest_edge, forest_mid])
	approx(t._edge_proximity(-400.0, 0.0), 0.0, 1e-6, "далеко от границы усиления нет")
	approx(t._edge_proximity(-30.0, 0.0), 1.0, 1e-6, "у границы — полное")
	var mid := t._edge_proximity(-100.0, 0.0)
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


## Точки кромки леса по маске 10 м: [Vector2 точка, Vector2 нормаль в лес] — маска ≈ 0,5, с обеих
## сторон на depth_m чисто (≤ 0,1 снаружи, ≥ 0,9 внутри).
func _forest_edges(t: Terrain, count: int, depth_m: PackedFloat32Array, seed_v: int) -> Array:
	var sl := t.surfaces[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var out := []
	var tries := 0
	while out.size() < count and tries < 400000:
		tries += 1
		var x := rng.randf_range(-18000.0, 18000.0)
		var z := rng.randf_range(-18000.0, 18000.0)
		if absf(sl.mask_r(x, z) - 0.5) > 0.1:
			continue
		var g := Vector2(
			sl.mask_r(x + 10.0, z) - sl.mask_r(x - 10.0, z),
			sl.mask_r(x, z + 10.0) - sl.mask_r(x, z - 10.0)
		)
		if g.length() < 0.03:
			continue
		g = g.normalized()
		var clean := true
		for d in depth_m:
			if (
				sl.mask_r(x + g.x * d, z + g.y * d) < 0.9
				or sl.mask_r(x - g.x * d, z - g.y * d) > 0.1
			):
				clean = false
				break
		if clean:
			out.append([Vector2(x, z), g])
	return out


func test_forest_mask_loaded() -> void:
	var t := _ong()
	var fm := t.get_forest_mask()
	check(fm.size() == 3, "маска леса 10 м есть: %s" % [fm.size()])
	if fm.size() != 3:
		return
	var img: Image = fm[0]
	check(img.get_format() == Image.FORMAT_RG8, "RG8")
	check(img.get_width() == 4001 and img.get_height() == 4001, "4001×4001 на 40 км")
	approx(float(fm[2]), 10.0, 1e-6, "клетка 10 м")
	check((fm[1] as Vector2).distance_to(Vector2(-20005, -20005)) < 1e-3, "угол пикселя (0, 0)")
	# грубая защита от многократной деградации; точный тайминг зависит от нагрузки машины
	check(t.last_load_time_s <= 2.5, "загрузка Онгудая ≤ 2,5 с: %.2f с" % t.last_load_time_s)


func test_forest_at_sharp_edge() -> void:
	# Кромка по маске 10 м: forest_at 0,1 → 0,9 на ≤ 20 м (вдоль нормали) на 20 точках кромки.
	var t := _ong()
	var edges := _forest_edges(t, 20, PackedFloat32Array([30.0]), 7)
	check(edges.size() == 20, "найдено точек кромки: %d" % edges.size())
	var worst := 0.0
	for e: Array in edges:
		var p: Vector2 = e[0]
		var g: Vector2 = e[1]
		var d10 := NAN
		var d90 := NAN
		var d := -30.0
		while d <= 30.0:
			var q := p + g * d
			var f := t.forest_at(q.x, q.y)
			if is_nan(d90) and f >= 0.9:
				d90 = d
			if f <= 0.1:
				d10 = d
				d90 = NAN
			d += 0.25
		var w := d90 - d10
		worst = maxf(worst, w)
		check(not is_nan(w) and w <= 20.0, "кромка %s: 0,1→0,9 за %.1f м" % [p, w])
	print("         кромка леса 0,1→0,9: худшая %.1f м (20 точек)" % worst)


func test_surface_at_forest_by_mask() -> void:
	# surface_at = лес там, где доля леса маски 10 м (данные PNG) ≥ 0,5 — не меньше 95 % точек.
	var t := _ong()
	var dir: String = Config.get_config("locations/ongudai").data_dir
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("surface.json"))
	)
	var info: Dictionary = meta.layers[0].detail10
	var img := Image.new()
	img.load_png_from_buffer(FileAccess.get_file_as_bytes(dir.path_join(info.file)))
	var w := int(info.width)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var n := 0
	var hit := 0
	while n < 500:
		var i := rng.randi_range(1, w - 2)
		var j := rng.randi_range(1, int(info.height) - 2)
		if img.get_pixel(i, j).r < 0.5:
			continue
		var x := float(info.origin_x_m) + i * float(info.spacing_m)
		var z := float(info.origin_z_m) + j * float(info.spacing_m)
		n += 1
		hit += int(t.surface_at(x, z) == SurfaceLayer.FOREST)
	check(hit >= 0.95 * n, "surface_at = лес в %d из %d узлов с R ≥ 0,5" % [hit, n])
	# и наоборот: на лугу у кромки (R < 0,5, а клетка 25 м — «лес») — не лес
	var edges := _forest_edges(t, 20, PackedFloat32Array([30.0]), 3)
	for e: Array in edges:
		var q: Vector2 = e[0] - e[1] * 12.0
		check(t.surface_at(q.x, q.y) != SurfaceLayer.FOREST, "луг в 12 м от кромки %s" % q)


func test_river_axis_is_water() -> void:
	# NO-1: вода в канале A — max(вода WorldCover 10 м, маска рек по рельефу), без OSM. 50 точек на осях рек Онгудая
	# по маске рек detail_water.png (сетка слоя 25 м, значение ≥ 200 — русло) — surface_at = вода ≥ 90 %;
	# те же точки, сдвинутые на 300 м вбок, — не вода в большинстве (не «вся карта — вода»).
	var t := _ong()
	var dir := "res://data/terrain/ongudai/"
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + "meta.json"))
	var info: Dictionary = {}
	for l: Dictionary in meta.layers:
		if String(l.id) == "detail":
			info = l
	var img := Image.load_from_file(dir + "detail_water.png")
	check(img != null, "маска рек читается")
	if img == null:
		return
	var w := img.get_width()
	var data := img.get_data()
	var cells := PackedInt32Array()
	for i in data.size():
		if data[i] >= 200:
			cells.append(i)
	check(cells.size() >= 500, "русел в маске рек: %d клеток" % cells.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var on_axis := 0
	var off_axis := 0
	var n := 50
	for q in n:
		var c := cells[rng.randi_range(0, cells.size() - 1)]
		var x := float(info.origin_x_m) + (c % w) * float(info.spacing_m)
		var z := float(info.origin_z_m) + (c / w) * float(info.spacing_m)
		on_axis += int(t.surface_at(x, z) == SurfaceLayer.WATER)
		off_axis += int(t.surface_at(x + 300.0, z) != SurfaceLayer.WATER)
	check(on_axis >= 0.9 * n, "surface_at = вода на оси реки: %d/%d" % [on_axis, n])
	check(off_axis >= 0.7 * n, "в 300 м от оси — не вода: %d/%d" % [off_axis, n])
	print("         ось реки: вода %d/%d, в 300 м не вода %d/%d" % [on_axis, n, off_axis, n])


## Чётность пересечений луча (ray casting): точка внутри многоугольника (x, z), p — [x0,z0,x1,z1…].
func _point_in_polygon(p: Array, x: float, z: float) -> bool:
	var count := p.size() / 2
	var inside := false
	var j := count - 1
	for i in count:
		var xi: float = p[i * 2]
		var zi: float = p[i * 2 + 1]
		var xj: float = p[j * 2]
		var zj: float = p[j * 2 + 1]
		if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi:
			inside = not inside
		j = i
	return inside


func test_lake_iou_aushkul() -> void:
	# T03/VR-9 (U1): контур озера Аушкуль в маске 10 м (канал G) — IoU с полигоном OSM ≥ 0,85.
	var t := _aush()
	var sl := _mask_layer(t)
	check(sl != null, "у Аушкуля есть маска 10 м")
	if sl == null:
		return
	var osm_str := FileAccess.get_file_as_string(Locations.osm_path("aushkul"))
	var osm: Dictionary = JSON.parse_string(osm_str)
	var poly: Array = []
	for lake in osm.water.lakes:
		if lake.n == "Аушкуль":
			poly = lake.p
			break
	check(poly.size() >= 6, "полигон озера Аушкуль найден")
	if poly.size() < 6:
		return
	var x0 := INF
	var x1 := -INF
	var z0 := INF
	var z1 := -INF
	for i in range(0, poly.size(), 2):
		x0 = minf(x0, poly[i])
		x1 = maxf(x1, poly[i])
		z0 = minf(z0, poly[i + 1])
		z1 = maxf(z1, poly[i + 1])
	var step := 10.0
	var inter := 0
	var uni := 0
	var z := z0
	while z <= z1:
		var x := x0
		while x <= x1:
			var a := _point_in_polygon(poly, x, z)
			var b := sl.mask_g(x, z) >= 0.5
			if a or b:
				uni += 1
			if a and b:
				inter += 1
			x += step
		z += step
	var iou := float(inter) / maxf(float(uni), 1.0)
	check(iou >= 0.85, "IoU озера Аушкуль (OSM vs маска 10 м): %.3f" % iou)
	print("         IoU озера Аушкуль (OSM vs маска 10 м): %.3f" % iou)


func test_height_includes_crowns() -> void:
	# VR-21: height_at над лесом — DSM с кронами (посадка в лес = удар о кроны). На чистых кромках
	# прямые по высотам снаружи и внутри (50–150 м) расходятся на ступеньку крон.
	var t := _ong()
	var ds := PackedFloat32Array([50.0, 75.0, 100.0, 125.0, 150.0])
	var clean := ds.duplicate()
	clean.append(20.0)
	var edges := _forest_edges(t, 40, clean, 5)
	check(edges.size() >= 30, "чистых кромок: %d" % edges.size())
	var sum := 0.0
	for e: Array in edges:
		var p: Vector2 = e[0]
		var g: Vector2 = e[1]
		var h_in := PackedFloat32Array()
		var h_out := PackedFloat32Array()
		for d in ds:
			h_in.append(t.height_at(p.x + g.x * d, p.y + g.y * d))
			h_out.append(t.height_at(p.x - g.x * d, p.y - g.y * d))
		sum += _intercept(ds, h_in) - _intercept(ds, h_out)
	var step := sum / maxf(edges.size(), 1)
	check(step > 5.0, "ступенька крон в height_at на опушке %.1f м (> 5 м)" % step)
	print("         ступенька крон DSM на опушке: %.1f м (%d кромок)" % [step, edges.size()])


## Значение в 0 прямой МНК по точкам (d, h).
func _intercept(ds: PackedFloat32Array, hs: PackedFloat32Array) -> float:
	var n := ds.size()
	var sd := 0.0
	var sh := 0.0
	var sdd := 0.0
	var sdh := 0.0
	for k in n:
		sd += ds[k]
		sh += hs[k]
		sdd += ds[k] * ds[k]
		sdh += ds[k] * hs[k]
	var b := (n * sdh - sd * sh) / (n * sdd - sd * sd)
	return (sh - b * sd) / n


func test_zz_cleanup() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
	if _ongudai != null:
		_ongudai.free()
		_ongudai = null
	if _aushkul != null:
		_aushkul.free()
		_aushkul = null
