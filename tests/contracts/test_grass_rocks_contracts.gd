extends TestCase
## Контрактные тесты модуля grass-rocks (docs/contracts/grass-rocks.md): test_g1_ — модели камней rocks.glb,
## test_g2_ — открытый интерфейс GrassField и пресеты густоты, test_g3_ — версии в документе.

const DOC := "res://docs/contracts/grass-rocks.md"
const VERSIONS := {"G1": 1, "G2": 1, "G3": 1}


func test_g3_versions_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	for id in VERSIONS:
		var at := text.find("## %s." % id)
		var line := text.substr(at, text.find("\n", at) - at) if at >= 0 else ""
		check(line.contains("версия %d" % VERSIONS[id]), "%s v%d в документе" % [id, VERSIONS[id]])


func test_g1_rock_models() -> void:
	var cfg: Dictionary = Config.get_config("world").rocks
	check(
		cfg.boulders == ["boulder0", "chunk0", "chunk1", "slab0", "slab1", "wedge0", "tooth0", "comb0", "comb1"],
		"крупные варианты: %s" % [cfg.boulders]
	)
	check(cfg.stones == ["pebble0", "chip0", "flake0", "wedge1"], "мелкие варианты: %s" % [cfg.stones])
	var names: Array = cfg.boulders + cfg.stones
	var m := RockScatter.load_meshes(String(cfg.model_path), names)
	check(m.size() == names.size() * RockScatter.LODS, "ноды <вариант>_LOD0/1/2 у всех: %d" % m.size())
	if m.size() != names.size() * RockScatter.LODS:
		return
	for v in names.size():
		var n := String(names[v])
		var tris: Array[int] = []
		for lod in RockScatter.LODS:
			var mesh := m[v * RockScatter.LODS + lod]
			check(mesh.get_surface_count() == 1, "%s_LOD%d: одна поверхность" % [n, lod])
			var arr := mesh.surface_get_arrays(0)
			check(arr[Mesh.ARRAY_NORMAL] != null, "%s_LOD%d: есть нормали" % [n, lod])
			tris.append(mesh.get_faces().size() / 3)
			if lod > 0:
				continue
			var a := mesh.get_aabb()
			var horiz := maxf(a.size.x, a.size.z)
			check(absf(horiz - 1.0) <= 0.02, "%s_LOD%d: наибольший горизонтальный %.3f = 1 ± 2 %%" % [n, lod, horiz])
			if n.begins_with("comb"):
				check(a.size.x >= a.size.z, "%s_LOD%d: гребешок вдоль X" % [n, lod])
			check(
				absf(a.position.y + 0.15 * a.size.y) <= 0.02,
				"%s_LOD%d: низ %.3f = −0,15·высоты (%.3f)" % [n, lod, a.position.y, -0.15 * a.size.y]
			)
			var c := a.get_center()
			check(absf(c.x) <= 0.1 and absf(c.z) <= 0.1, "%s_LOD%d: центр X/Z у начала (%.3f, %.3f)" % [n, lod, c.x, c.z])
		check(tris[2] <= tris[1] and tris[1] <= tris[0], "%s: LOD2 ≤ LOD1 ≤ LOD0: %s" % [n, tris])


func test_g2_grass_api() -> void:
	var want := {
		"setup": 7, "set_relief": 1, "set_landing_sites": 1, "set_trample_mask": 3, "height_at": 2,
		"materials": 0, "apply_scene_look": 1, "is_enabled": 1, "density_k": 1, "ring_offsets": 3,
	}
	var have := {}
	for md in (GrassField as Script).get_script_method_list():
		have[String(md.name)] = (md.args as Array).size()
	for name in want:
		check(have.has(name), "GrassField.%s есть" % name)
		if have.has(name):
			check(have[name] == want[name], "GrassField.%s: аргументов %d, ждём %d" % [name, have[name], want[name]])
	check(not GrassField.is_enabled({"enabled": true, "density_pct": 0}), "density_pct 0 — травы нет")
	check(GrassField.is_enabled({"enabled": true, "density_pct": 100}), "density_pct 100 — трава есть")
	check(is_equal_approx(GrassField.density_k({"density_pct": 150}), 1.5), "density_k = density_pct / 100")
	check(GrassField.ring_offsets(1.0, -1.0, 5.0).size() > 0, "ring_offsets даёт точки")
	var g := GrassField.new()
	check(g is Node3D, "GrassField — Node3D")
	g.free()


func test_g2_grass_config_and_presets() -> void:
	var grass: Dictionary = Config.get_config("vegetation").grass
	for k in ["enabled", "density_pct", "density_range_pct", "density_step_pct"]:
		check(grass.has(k), "vegetation.grass.%s есть" % k)
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/game.json"))
	var want := {"low": 0.0, "medium": 100.0, "high": 150.0}
	var found := {}
	_find_presets(j, want, found)
	for p in want:
		check(found.has(p), "пресет %s задаёт grass.density_pct" % p)
		if found.has(p):
			check(is_equal_approx(found[p], want[p]), "пресет %s: density_pct %s, ждём %s" % [p, found[p], want[p]])


## Пресеты графики в game.json: словарь с ключом-именем пресета, внутри configs.vegetation.grass.density_pct.
func _find_presets(v: Variant, want: Dictionary, found: Dictionary) -> void:
	if v is Dictionary:
		for k in v:
			var x: Variant = v[k]
			if want.has(k) and x is Dictionary:
				var d: Variant = x.get("configs", {}).get("vegetation", {}).get("grass", {}).get("density_pct")
				if d != null:
					found[k] = float(d)
			_find_presets(x, want, found)
	elif v is Array:
		for x in v:
			_find_presets(x, want, found)
