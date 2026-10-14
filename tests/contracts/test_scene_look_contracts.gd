extends TestCase
## Контрактные тесты scene-look (docs/contracts/scene-look.md). SL-К1 — свой include, своя секция
## конфига, стык с mountain-look; SL-К2 (проводка, SL-2) — uniform-ы sl_lat_deg, sl_doy от даты
## полёта. Сезон (test_k2_season_*) — SL-6. SL-К6 — варианты шейдера рельефа (тело terrain_main, #ifndef T_*_OFF).

const DOC := "res://docs/contracts/scene-look.md"
const VERSIONS := {"SL-К1": 4, "SL-К2": 2, "SL-К4": 2, "SL-К6": 2, "SL-К7": 1}
const INC := "res://scripts/terrain/scene_look.gdshaderinc"
const TERRAIN := "res://scripts/terrain/terrain.gdshader"
## тело шейдера рельефа (SL-К6): include-ы и строки // SL — здесь; TERRAIN — вариант «full»
const TERRAIN_MAIN := "res://scripts/terrain/terrain_main.gdshaderinc"
const VARIANTS_DIR := "res://scripts/terrain/variants"
const IMPOSTORS := "res://scripts/terrain/forest_impostors.gdshader"


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


static func _uniforms(path: String) -> Dictionary:
	var out := {}
	var sh := load(path) as Shader
	if sh == null:
		return out
	for u in sh.get_shader_uniform_list():
		out[String(u.name)] = int(u.type)
	return out


func _section() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


func _keys() -> Array[String]:
	var out: Array[String] = []
	for k: String in _section():
		if not k.begins_with("_") and not k.ends_with("_doc"):
			out.append(k)
	return out


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]), "%s v%d" % [id, VERSIONS[id]])
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


func test_k1_include_exists_and_included() -> void:
	check(FileAccess.file_exists(INC), "К1: есть %s" % INC)
	var t := _read(TERRAIN_MAIN)
	var common := t.find('#include "res://scripts/terrain/terrain_common.gdshaderinc"')
	var sl := t.find('#include "%s"' % INC)
	check(sl >= 0, "К1: include подключён в terrain_main.gdshaderinc")
	check(common >= 0 and sl > common, "К1: include — после terrain_common")
	check(_read(IMPOSTORS).contains('#include "%s"' % INC), "К1: include в forest_impostors.gdshader")


func test_k1_shaders_compile_with_include() -> void:
	# список uniform-ов строит компилятор шейдерного языка: ошибка разбора — пустой список
	for path in [TERRAIN, IMPOSTORS]:
		var u := _uniforms(path)
		check(u.has("sl_light_enabled") and u.has("sl_lat_deg"), "К1: %s разбирается, uniform-ы sl_* есть" % path)


func test_k1_section_flat_and_switches() -> void:
	var sec := _section()
	check(not sec.is_empty(), "К1: configs/world.json → scene_look")
	var world_keys: Array = Config.get_config("world").keys()
	check(world_keys.find("scene_look") == world_keys.size() - 1, "К1: секция scene_look — в конце файла")
	check(not Config.get_config("world").get("terrain_look", {}).has("scene_look"), "К1: не внутри terrain_look")
	for k in _keys():
		var v: Variant = sec[k]
		check(not (v is Dictionary), "К1: %s — без вложенных объектов" % k)
		if v is Array:
			check((v as Array).size() >= 2 and (v as Array).size() <= 4, "К1: %s — массив 2…4 чисел" % k)
			for x: Variant in v:
				check(x is float or x is int, "К1: %s — числа" % k)
		if k.ends_with("_enabled"):
			check(v is bool, "К1: выключатель %s — bool" % k)
		check(sec.has(k + "_doc"), "К1: %s_doc" % k)
	check(sec.has("light_enabled"), "К1: выключатель SL-2 light_enabled")


func test_k1_every_key_is_uniform() -> void:
	var u := _uniforms(TERRAIN)
	for k in _keys():
		check(u.has("sl_" + k), "К1: ключ scene_look.%s → uniform sl_%s в шейдере рельефа" % [k, k])


func test_k1_no_sl_uniforms_outside_include() -> void:
	var re := RegEx.create_from_string("(?m)^\\s*uniform\\s+[^;]*\\bsl_\\w+")
	for path in [TERRAIN, TERRAIN_MAIN]:
		check(re.search(_read(path)) == null, "К1: в %s нет uniform-ов sl_* вне include" % path.get_file())
	# строки рельефа, вызывающие код scene-look, помечены // SL
	for line in _read(TERRAIN_MAIN).split("\n"):
		if line.contains("sl_") and not line.strip_edges().begins_with("//"):
			check(line.ends_with("// SL"), "К1: строка с sl_* помечена // SL: %s" % line.strip_edges())


func test_k1_defaults_off_in_shader() -> void:
	# материал без конфига (значения по умолчанию в include) — модуль выключен: картинка как до модуля
	var t := _read(INC)
	var re := RegEx.create_from_string("uniform\\s+bool\\s+(sl_\\w+_enabled)\\s*=\\s*(\\w+)")
	var n := 0
	for m in re.search_all(t):
		n += 1
		check(m.get_string(2) == "false", "К1: %s по умолчанию false" % m.get_string(1))
	check(n >= 1, "К1: выключатели в include")


func test_k1_v2_runtime_uniforms() -> void:
	# v2: рантайм-uniform-ы ставит Terrain (не ключи конфига)
	for path in [TERRAIN, IMPOSTORS]:
		var u := _uniforms(path)
		for n in ["sl_lat_deg", "sl_doy", "sl_sun_dir", "sl_sky_up", "sl_ground_low"]:
			check(u.has(n), "К1 v2: %s в %s" % [n, path])
	var sky := TerrainRenderer.scene_look_sky(Vector3(0.0, 0.8, -0.6))
	for n in ["sun_dir", "sky_up", "ground_low"]:
		check(sky.get(n) is Vector3, "К1 v2: scene_look_sky → %s (Vector3)" % n)


func test_k1_params_to_material() -> void:
	var m := ShaderMaterial.new()
	m.shader = load(TERRAIN)
	TerrainRenderer.apply_scene_look_params(
		m, {"light_enabled": true, "canopy_albedo": [0.05, 0.08], "ground_albedo": [0.1, 0.2, 0.3],
			"x4": [1, 2, 3, 4], "_doc": "x", "light_enabled_doc": "y", "canopy_floor": 1}
	)
	check(m.get_shader_parameter("sl_light_enabled") == true, "К1: bool")
	check(m.get_shader_parameter("sl_canopy_albedo") is Vector2, "К1: [a, b] → vec2")
	check(m.get_shader_parameter("sl_ground_albedo") is Vector3, "К1: [r, g, b] → vec3 (без sRGB)")
	approx((m.get_shader_parameter("sl_ground_albedo") as Vector3).y, 0.2, 1e-6, "К1: цвет линейный")
	check(m.get_shader_parameter("sl_x4") is Vector4, "К1: 4 числа → vec4")
	check(m.get_shader_parameter("sl_canopy_floor") is float, "К1: int → float")
	check(m.get_shader_parameter("sl__doc") == null, "К1: _doc не передаётся")


func test_k2_wiring_uniforms() -> void:
	for path in [TERRAIN, IMPOSTORS]:
		var u := _uniforms(path)
		check(u.has("sl_lat_deg"), "К2: sl_lat_deg в %s" % path)
		check(u.has("sl_doy"), "К2: sl_doy в %s" % path)
	var re := RegEx.create_from_string("uniform\\s+float\\s+sl_doy\\s*=\\s*196\\.0")
	check(re.search(_read(INC)) != null, "К2: sl_doy по умолчанию 196 (15 июля)")


func test_k2_wiring_day_of_year() -> void:
	approx(Terrain.day_of_year(7, 15), 196.0, 1e-6, "К2: 15 июля → 196")
	approx(Terrain.day_of_year(1, 1), 1.0, 1e-6, "К2: 1 января → 1")
	approx(Terrain.day_of_year(10, 1), 274.0, 1e-6, "К2: 1 октября → 274")
	approx(Terrain.day_of_year(12, 31), 365.0, 1e-6, "К2: 31 декабря → 365")


func test_k2_wiring_set_flight_date() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.has_method("set_flight_date"), "К2: Terrain.set_flight_date(month, day)")
	t.center_lat = 51.5
	var p := t.scene_look_params()
	approx(float(p.lat_deg), 51.5, 1e-6, "К2: lat_deg — широта центра места")
	approx(float(p.doy), 196.0, 1e-6, "К2: doy по умолчанию 196")
	t.set_flight_date(10, 1)
	approx(t.flight_doy, 274.0, 1e-6, "К2: set_flight_date → день года")
	approx(float(t.scene_look_params().doy), 274.0, 1e-6, "К2: doy в параметрах материалов")
	# материалы: рельеф (renderer) и импостеры — тем же путём
	var r := TerrainRenderer.new()
	var m := ShaderMaterial.new()
	m.shader = load(TERRAIN)
	r._materials.append(m)
	t.renderer = r
	var im := ForestImpostors.new()
	im.material = ShaderMaterial.new()
	im.material.shader = load(IMPOSTORS)
	t.impostors = im
	t.set_flight_date(3, 1)
	approx(float(m.get_shader_parameter("sl_doy")), 60.0, 1e-6, "К2: sl_doy в материале рельефа")
	approx(float(im.material.get_shader_parameter("sl_doy")), 60.0, 1e-6, "К2: sl_doy у импостеров")
	t._apply_scene_look(t.scene_look_params())
	approx(float(m.get_shader_parameter("sl_lat_deg")), 51.5, 1e-6, "К2: sl_lat_deg в материале рельефа")
	approx(float(im.material.get_shader_parameter("sl_lat_deg")), 51.5, 1e-6, "К2: sl_lat_deg у импостеров")
	t.set_sun(Vector3(0.3, 0.5, -0.8).normalized())
	var sd: Variant = m.get_shader_parameter("sl_sun_dir")
	check(sd is Vector3 and (sd as Vector3).is_equal_approx(Vector3(0.3, 0.5, -0.8).normalized()), "солнце → sl_sun_dir")
	im.free()
	r.free()
	t.free()


func test_k2_wiring_game_calls_set_flight_date() -> void:
	var g := _read("res://scripts/game/game.gd")
	var at_sun := g.find("terrain.set_sun(sky.clock.to_sun())")
	var at_date := g.find("terrain.set_flight_date(settings.month, settings.day)")
	check(at_date > 0, "К2: game.gd вызывает Terrain.set_flight_date(month, day)")
	check(at_sun > 0 and absi(at_date - at_sun) < 400, "К2: там же, где солнце (старт полёта)")


# --- SL-К2: сезон (SL-6) ---

func _season(doy: float, lat: float, alt: float) -> Dictionary:
	return SeasonLook.state(doy, lat, alt, _section())


func test_k2_season_range() -> void:
	for lat in [-52.0, -30.0, -5.0, 0.0, 5.0, 24.0, 40.0, 51.0, 64.0]:
		for alt in [0.0, 500.0, 1500.0, 3500.0]:
			for doy in range(1, 366, 7):
				var s := _season(float(doy), lat, alt)
				for k in ["green", "dry", "autumn", "bare"]:
					var v := float(s[k])
					check(v >= 0.0 and v <= 1.0, "К2: %s в [0, 1] (doy %d, φ %.0f, h %.0f: %f)" % [k, doy, lat, alt, v])


func test_k2_season_southern_half_year() -> void:
	for lat in [35.0, 51.0, 60.0]:
		for alt in [0.0, 1200.0]:
			for doy in [30.0, 100.0, 150.0, 196.0, 250.0, 290.0, 330.0]:
				var a := _season(doy, lat, alt)
				var b := _season(doy + 182.5, -lat, alt)
				for k in ["green", "dry", "autumn", "bare"]:
					approx(float(a[k]), float(b[k]), 0.02, "К2: юг = север + полгода (%s, φ %.0f, doy %.0f)" % [k, lat, doy])


func test_k2_season_autumn_rises_with_altitude() -> void:
	for doy in [240.0, 255.0, 270.0, 285.0]:
		var prev := -1.0
		for alt in [0.0, 300.0, 600.0, 1000.0, 1500.0, 2200.0, 3000.0]:
			var a := float(_season(doy, 51.0, alt).autumn)
			check(a >= prev - 1e-6, "К2: autumn не убывает с высотой (doy %.0f, h %.0f)" % [doy, alt])
			prev = a


func test_k2_season_dates() -> void:
	var summer := _season(196.0, 51.0, 1000.0)
	approx(float(summer.autumn), 0.0, 1e-6, "К2: 15 июля, 51°, 1000 м — autumn 0")
	approx(float(summer.bare), 0.0, 1e-6, "К2: 15 июля, 51°, 1000 м — bare 0")
	var oct := _season(274.0, 51.0, 1000.0)
	check(float(oct.autumn) >= 0.5, "К2: 1 октября, 51°, 1000 м — autumn ≥ 0,5 (%f)" % float(oct.autumn))
	for doy in range(1, 366, 5):
		for lat in [5.0, -5.0, 0.0, 12.0]:
			var s := _season(float(doy), lat, 1500.0)
			approx(float(s.autumn), 0.0, 1e-6, "К2: тропики без осени (φ %.0f, doy %d)" % [lat, doy])
			approx(float(s.bare), 0.0, 1e-6, "К2: тропики без листопада (φ %.0f, doy %d)" % [lat, doy])
	# середина зимы в средних широтах: листва опала, мёртвая трава
	var winter := _season(15.0, 51.0, 300.0)
	check(float(winter.bare) > 0.99 and float(winter.dry) > 0.3, "К2: январь — голый лес, сухая трава")
	# выключено — нули
	var off := SeasonLook.state(274.0, 51.0, 1000.0, {"season_enabled": false})
	check(float(off.autumn) == 0.0 and float(off.dry) == 0.0 and float(off.green) == 0.0, "К2: season_enabled=false — нули")


func test_k2_season_hopkins() -> void:
	# 4 дня на 1° широты и на 122 м: у весны (rel — дней от начала вегетации) на дату doy
	var base := float(_season(150.0, 50.0, 0.0).rel)
	approx(float(_season(150.0, 51.0, 0.0).rel), base - 4.0, 1e-4, "Хопкинс: +1° — весна на 4 дня позже")
	approx(float(_season(150.0, 50.0, 122.0).rel), base - 4.0, 1e-4, "Хопкинс: +122 м — весна на 4 дня позже")
	approx(float(_season(150.0, 52.0, 244.0).rel), base - 16.0, 1e-4, "Хопкинс: +2° и +244 м — на 16 дней")
	# весна позже и севернее: свежая трава на ту же дату — раньше на юге
	check(float(_season(115.0, 45.0, 0.0).green) > float(_season(115.0, 58.0, 0.0).green), "весна позже к северу")
	# осень раньше севернее и выше: окраска на ту же дату
	check(float(_season(255.0, 58.0, 0.0).autumn) > float(_season(255.0, 45.0, 0.0).autumn), "осень раньше к северу")
	check(float(_season(255.0, 51.0, 1800.0).autumn) > float(_season(255.0, 51.0, 0.0).autumn), "осень раньше выше")
	# лиственница позже берёзы
	var b := float(SeasonLook.state_species(1, 262.0, 51.0, 800.0, _section()).autumn)
	var l := float(SeasonLook.state_species(2, 262.0, 51.0, 800.0, _section()).autumn)
	check(b > l, "лиственница желтеет позже берёзы (%f > %f)" % [b, l])


# --- SL-К2 v2: свежий снег и снеговая линия (SL-10) ---

func test_k2_snow_range_monotonic_symmetric() -> void:
	for lat in [-60.0, -46.0, -5.0, 0.0, 5.0, 30.0, 46.0, 51.0, 64.0, 75.0]:
		for doy in range(1, 366, 9):
			var prev := 0.0
			for alt in range(0, 6001, 250):
				var s := _season(float(doy), lat, float(alt))
				var v := float(s.snow_fresh)
				check(v >= 0.0 and v <= 1.0, "К2 v2: snow_fresh в [0, 1] (%d, %.0f, %d: %f)" % [doy, lat, alt, v])
				check(v >= prev - 1e-6, "К2 v2: snow_fresh не убывает с высотой (%d, %.0f, %d)" % [doy, lat, alt])
				prev = v
				var m := _season(doy + 182.5, -lat, float(alt))
				approx(float(m.snow_fresh), v, 0.02, "К2 v2: симметрия полушарий (%d, %.0f, %d)" % [doy, lat, alt])


func test_k2_snow_numbers() -> void:
	check(float(_season(196.0, 51.0, 1000.0).snow_fresh) == 0.0, "К2 v2: 15 июля, 51°, 1000 м — снега нет")
	check(float(_season(15.0, 51.0, 2500.0).snow_fresh) >= 0.9, "К2 v2: 15 января, 51°, 2500 м ≥ 0,9")
	check(float(_season(15.0, 51.0, 1200.0).snow_fresh) > 0.0, "К2 v2: 15 января, 51°, 1200 м — снег есть")
	for doy in range(1, 366, 7):
		check(float(_season(float(doy), 5.0, 3000.0).snow_fresh) == 0.0, "К2 v2: 5°, 3000 м — 0 круглый год (%d)" % doy)
	var line := float(_season(196.0, 46.0, 0.0).snow_line_m)
	check(line >= 2600.0 and line <= 3400.0, "К2 v2: линия 15 июля на 46° — 2600…3400 м (%f)" % line)
	check(float(_season(15.0, 51.0, 0.0).snow_line_m) < float(_season(250.0, 51.0, 0.0).snow_line_m), "К2 v2: зимой линия ниже")
	var off := SeasonLook.state(15.0, 51.0, 3000.0, {"snow_enabled": false})
	check(float(off.snow_fresh) == 0.0, "К2 v2: snow_enabled=false — snow_fresh 0")


func test_k2_snow_shader_mirror() -> void:
	var inc := _read(INC)
	check(inc.contains("float sl_snow_fresh(float doy, float lat, float alt)"), "К2 v2: float sl_snow_fresh(doy, lat, alt)")
	check(inc.contains("uniform vec4 sl_snow_pre"), "К2 v2: sl_snow_pre (линия считается на CPU)")
	check(inc.contains("vec4 sl_season(float doy, float lat, float alt)"), "К2 v2: sl_season не меняется")
	var tg := _read(TERRAIN_MAIN)
	check(tg.contains("sl_fresh_snow(") and tg.contains("// SL"), "К2 v2: вызов свежего снега в рельефе — строкой // SL")


func test_k2_season_dryness_adds() -> void:
	# сухость сезона прибавляется к местной: к концу лета больше, чем весной; чем суше место, тем соломеннее
	var spring := float(_season(150.0, 51.0, 300.0).dry)
	var late := float(_season(235.0, 51.0, 300.0).dry)
	check(late > spring + 0.2, "К2: сухость растёт к концу лета (%f → %f)" % [spring, late])
	check(late <= float(_section().get("season_dry_amount", 0.35)) + 1e-6, "К2: прибавка не больше season_dry_amount")


func test_k2_season_shader_mirror() -> void:
	# CPU-зеркало = шейдер: значения по умолчанию include и config/SeasonLook.DEFAULTS совпадают,
	# контрактная функция есть
	var inc := _read(INC)
	check(inc.contains("vec4 sl_season(float doy, float lat, float alt)"), "К2: vec4 sl_season(doy, lat, alt)")
	var sec := _section()
	for key: String in SeasonLook.DEFAULTS:
		check(sec.has(key), "К2: ключ %s есть в scene_look" % key)
		check(str(sec.get(key)) == str(SeasonLook.DEFAULTS[key]), "К2: %s: config = SeasonLook.DEFAULTS" % key)
		if inc.contains("uniform") and not key.ends_with("_enabled"):
			var re := RegEx.create_from_string("uniform\\s+\\w+\\s+sl_%s\\s*=\\s*([^;]+);" % key)
			var m := re.search(inc)
			check(m != null, "К2: sl_%s с умолчанием в include" % key)
			if m != null:
				var txt := m.get_string(1).replace("vec2", "").replace("vec3", "").replace("vec4", "")
				txt = txt.replace("(", "").replace(")", "")
				var parts := txt.split(",")
				var want: Array = SeasonLook.DEFAULTS[key] if SeasonLook.DEFAULTS[key] is Array else [SeasonLook.DEFAULTS[key]]
				check(parts.size() == want.size(), "К2: sl_%s: размер" % key)
				for i in mini(parts.size(), want.size()):
					approx(float(parts[i]), float(want[i]), 1e-6, "К2: sl_%s[%d] в include = DEFAULTS" % [key, i])


func test_k4_function_in_include_and_config() -> void:
	# К4: одна функция множителя на дерево в include, диапазон — trees.lod_k_min/max, ширина дизеринга
	var inc := _read(INC)
	for f in ["float sl_lod_k(vec2 xz)", "float sl_lod_hash(vec2 xz, uint salt)", "float sl_lod_swap_t(float d, float db, float dither)"]:
		check(inc.contains(f), "К4: %s в include" % f)
	var trees: Dictionary = Config.get_config("world").get("trees", {})
	check(trees.has("lod_k_min") and trees.has("lod_k_max") and trees.has("lod_dither_m"), "К4: ключи trees.lod_*")
	check(float(trees.lod_k_min) > 0.0 and float(trees.lod_k_min) <= float(trees.lod_k_max), "К4: 0 < lod_k_min ≤ lod_k_max")
	check(float(trees.lod_dither_m) > float(trees.get("lod_fade_m", 10.0)), "К4: дизеринг шире lod_fade_m")
	var re := RegEx.create_from_string("uniform\\s+vec2\\s+sl_lod_k_range\\s*=\\s*vec2\\(([^,]+),([^)]+)\\)")
	var m := re.search(inc)
	check(m != null, "К4: sl_lod_k_range с умолчанием")
	if m != null:
		approx(float(m.get_string(1)), float(trees.lod_k_min), 1e-6, "К4: умолчание include = lod_k_min")
		approx(float(m.get_string(2)), float(trees.lod_k_max), 1e-6, "К4: умолчание include = lod_k_max")
	# потребители подключают одну функцию, у моделей и импостеров одна и та же граница
	check(_read("res://scripts/terrain/tree_model.gdshader").contains("sl_lod_k(base.xz)"), "К4: модели зовут sl_lod_k")
	# К4 v2 (SL-18): дальняя граница модели — стык с LOD2-крестом в шейдере (band-импостеры сняты)
	check(_read("res://scripts/terrain/tree_cross.gdshader").contains("sl_lod_k(p)"), "К4 v2: кресты зовут sl_lod_k")


func test_k4_cpu_mirror_range() -> void:
	var kmin := float(Config.get_config("world").trees.lod_k_min)
	var kmax := float(Config.get_config("world").trees.lod_k_max)
	for i in 400:
		var x := fposmod(i * 37.31, 3000.0) - 1500.0
		var z := fposmod(i * 91.77, 3000.0) - 1500.0
		var k := TreePlacer.lod_k_at(x, z, kmin, kmax)
		check(k >= kmin and k <= kmax, "К4: k в диапазоне")


# --- SL-К6: варианты шейдера рельефа ---


func test_k6_full_is_header_and_include() -> void:
	# «full» — только shader_type/render_mode и include тела (без #define): тот же код, что до распила
	var t := _code(_read(TERRAIN))
	check(not t.contains("#define"), "К6: в terrain.gdshader нет #define")
	check(t.contains('#include "%s"' % TERRAIN_MAIN), "К6: terrain.gdshader подключает terrain_main")
	check(not _code(_read(TERRAIN_MAIN)).contains("shader_type"), "К6: shader_type — в файле варианта, не в теле")


## Текст шейдера без строк-комментариев.
static func _code(t: String) -> String:
	var out: PackedStringArray = []
	for ln in t.split("\n"):
		if not ln.strip_edges().begins_with("//"):
			out.append(ln)
	return "\n".join(out)


func test_k6_variant_files_format() -> void:
	# v2: файл варианта — shader_type, render_mode (как у full), строки #define T_*_OFF, include тела
	var head := ""
	for ln in _read(TERRAIN).split("\n"):
		if ln.begins_with("render_mode"):
			head = ln
	var n := 0
	for f in DirAccess.get_files_at(VARIANTS_DIR):
		if not f.ends_with(".gdshader"):
			continue
		n += 1
		check(f.begins_with("terrain_"), "К6: имя варианта terrain_<имя>: %s" % f)
		var body := 0
		for ln: String in _read(VARIANTS_DIR + "/" + f).split("\n"):
			var l := ln.strip_edges()
			if l == "" or l.begins_with("//"):
				continue
			var ok := l == "shader_type spatial;" or l == head or l == '#include "%s"' % TERRAIN_MAIN
			if l.begins_with("#define T_") and l.ends_with("_OFF"):
				ok = true
			check(ok, "К6: %s — лишняя строка: %s" % [f, l])
			if not ok:
				body += 1
		check(_uniforms(VARIANTS_DIR + "/" + f).has("layer_spacing"), "К6: %s разбирается" % f)
	check(n >= 1, "К6: есть закоммиченные варианты")


func test_k6_variant_selection() -> void:
	check(TerrainRenderer.variant_path("full") == TERRAIN, "К6: full → terrain.gdshader")
	check(TerrainRenderer.variant_path("") == TERRAIN, "К6: пусто → full")
	check(TerrainRenderer.variant_path("min") == VARIANTS_DIR + "/terrain_min.gdshader", "К6: min → variants/terrain_min")
	check(
		TerrainRenderer.variant_path("_bench/no_sl_light") == VARIANTS_DIR + "/_bench/terrain_no_sl_light.gdshader",
		"К6: временный вариант замера — variants/_bench/"
	)
	check(TerrainRenderer.variant_shader("нет_такого") == TerrainRenderer.SHADER, "К6: нет файла → full")
	var cfg := {"variant": "min", "variant_far": "", "variant_far_lod": 2}
	check(TerrainRenderer.pick_variant(cfg, 0, 0) == "min", "К6: ближний LOD — variant")
	check(TerrainRenderer.pick_variant(cfg, 1, 3) == "min", "К6: variant_far пуст — везде variant")
	cfg["variant_far"] = "far"
	check(TerrainRenderer.pick_variant(cfg, 0, 1) == "min", "К6: LOD 1 < variant_far_lod — variant")
	check(TerrainRenderer.pick_variant(cfg, 0, 2) == "far", "К6: LOD ≥ variant_far_lod — variant_far")
	check(TerrainRenderer.pick_variant(cfg, 1, 0) == "far", "К6: фоновый слой — variant_far")
	check(TerrainRenderer.pick_variant({}, 0, 0) == "full", "К6: нет ключей — full")
	# конфиг: ключи есть; пресеты задают свой вариант и дальний (SL-23: low/low_far, far)
	var t: Dictionary = Config.get_config("world").get("terrain", {})
	check(t.has("variant") and t.has("variant_far") and t.has("variant_far_lod"), "К6: world.json → terrain.variant*")
	var presets: Dictionary = Config.get_config("game").get("graphics_presets", {})
	for p: String in presets:
		if p.begins_with("_"):
			continue
		var pt: Dictionary = presets[p].get("configs", {}).get("world", {}).get("terrain", {})
		check(pt.has("variant"), "К6: пресет %s задаёт terrain.variant" % p)
		if pt.has("variant"):
			check(ResourceLoader.exists(TerrainRenderer.variant_path(String(pt.variant))), "К6: вариант пресета %s есть" % p)
		if String(pt.get("variant_far", "")) != "":
			check(
				ResourceLoader.exists(TerrainRenderer.variant_path(String(pt.variant_far))),
				"К6: дальний вариант пресета %s есть" % p
			)


# ---------------------------------------------------------------- SL-К7 (упаковка карт рельефа)
func test_k7_relief_shadow_in_alpha() -> void:
	var main := _read(TERRAIN_MAIN)
	check(not main.contains("relief_shadow_tex"), "К7: relief_shadow_tex удалён из рельефа")
	check(main.contains("hz_deg = rel.a * 60.0"), "К7: горизонт — канал A relief_tex")
	check(not _read("res://scripts/terrain/terrain_renderer.gd").contains("relief_shadow_tex"), "К7: renderer не ставит relief_shadow_tex")
	var r := TerrainRelief.new()
	check(not ("shadow_texture" in r), "К7: у TerrainRelief нет отдельной shadow_texture")
	check(TerrainRelief.HORIZON_MAX_DEG == 60.0, "К7: A = горизонт / 60°")
