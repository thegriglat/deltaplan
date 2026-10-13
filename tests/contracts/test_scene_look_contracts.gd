extends TestCase
## Контрактные тесты scene-look (docs/contracts/scene-look.md). SL-К1 — свой include, своя секция
## конфига, стык с mountain-look; SL-К2 (проводка, SL-2) — uniform-ы sl_lat_deg, sl_doy от даты
## полёта. Сезон (test_k2_season_*) — SL-6.

const DOC := "res://docs/contracts/scene-look.md"
const VERSIONS := {"SL-К1": 3, "SL-К2": 2}
const INC := "res://scripts/terrain/scene_look.gdshaderinc"
const TERRAIN := "res://scripts/terrain/terrain.gdshader"
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
	var t := _read(TERRAIN)
	var common := t.find('#include "res://scripts/terrain/terrain_common.gdshaderinc"')
	var sl := t.find('#include "%s"' % INC)
	check(sl >= 0, "К1: include подключён в terrain.gdshader")
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
	check(re.search(_read(TERRAIN)) == null, "К1: в terrain.gdshader нет uniform-ов sl_* вне include")
	# строки рельефа, вызывающие код scene-look, помечены // SL
	for line in _read(TERRAIN).split("\n"):
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
