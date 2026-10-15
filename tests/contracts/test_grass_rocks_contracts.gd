extends TestCase
## Контрактные тесты модуля grass-rocks (docs/contracts/grass-rocks.md): test_g1_ — модели камней rocks.glb,
## test_g2_ — открытый интерфейс GrassField и пресеты густоты, test_g3_ — версии в документе,
## test_g4_ — режим средней дистанции травы.

const DOC := "res://docs/contracts/grass-rocks.md"
const VERSIONS := {"G1": 1, "G2": 1, "G3": 2, "G4": 1}


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


## G4: режим из конфига, переменная окружения DP_GRASS_MID сильнее, неизвестное — как конфиг.
func test_g4_mid_mode_env_and_config() -> void:
	var old := OS.get_environment("DP_GRASS_MID")
	OS.unset_environment("DP_GRASS_MID")
	var grass: Dictionary = Config.get_config("vegetation").grass
	check(grass.has("mid") and grass.mid.has("mode"), "vegetation.grass.mid.mode есть")
	check(GrassField.mid_mode(grass) == "blades", "по умолчанию до шлюза 2 — blades: %s" % GrassField.mid_mode(grass))
	for m in ["blades", "shell", "cards"]:
		check(GrassField.mid_mode({"mid": {"mode": m}}) == m, "конфиг %s" % m)
	check(GrassField.mid_mode({}) == "blades", "нет mid — blades")
	check(GrassField.mid_mode({"mid": {"mode": "fur"}}) == "blades", "неизвестный конфиг — blades")
	OS.set_environment("DP_GRASS_MID", "cards")
	check(GrassField.mid_mode({"mid": {"mode": "shell"}}) == "cards", "переменная сильнее конфига")
	OS.set_environment("DP_GRASS_MID", "shell")
	check(GrassField.mid_mode({"mid": {"mode": "blades"}}) == "shell", "переменная shell")
	OS.set_environment("DP_GRASS_MID", "velvet")
	check(GrassField.mid_mode({"mid": {"mode": "cards"}}) == "cards", "неизвестная переменная — как конфиг")
	if old.is_empty():
		OS.unset_environment("DP_GRASS_MID")
	else:
		OS.set_environment("DP_GRASS_MID", old)


## G4: в shell/cards — узел средней травы потомок GrassField, дальних колец травинок нет;
## в blades — кольца травинок как были, узла средней травы нет. Headless, без рендера.
func test_g4_mid_nodes_and_no_far_ring() -> void:
	var old := OS.get_environment("DP_GRASS_MID")
	OS.unset_environment("DP_GRASS_MID")
	var n := 40
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	hs.fill(100.0)
	var layer := HeightLayer.from_heights("t", n, n, 4.0, -80.0, -80.0, hs)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	img.fill(Color(100.0, 0, 0))
	var htex := ImageTexture.create_from_image(img)
	var cls := PackedByteArray()
	cls.resize(n * n)
	cls.fill(SurfaceLayer.GRASS)
	var surf := SurfaceLayer.from_classes("s", n, n, 4.0, -80.0, -80.0, cls)
	var simg := Image.create(n, n, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	var stex := ImageTexture.create_from_image(simg)
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	var spots: Array[Vector4] = []
	for mode in ["blades", "shell", "cards"]:
		var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
		cfg.mid.mode = mode
		var g := GrassField.new()
		g.setup(layer, htex, surf, stex, look, cfg, spots)
		var mids := 0
		var blade_rings := 0
		for c in g.get_children():
			if c is GrassMidShell or c is GrassMidCards:
				mids += 1
			if c is GrassField:
				blade_rings += 1
		if mode == "blades":
			check(mids == 0 and g.mid_layer == null, "blades: узла средней травы нет")
			check(g.far_layer != null and blade_rings == 1, "blades: кольцо травинок за ближним есть")
		else:
			check(g.far_layer == null and blade_rings == 0, "%s: колец травинок дальше ближнего нет" % mode)
			check(mids == 1 and g.mid_layer != null, "%s: узел средней травы — потомок GrassField" % mode)
			var typed := g.mid_layer is GrassMidShell if mode == "shell" else g.mid_layer is GrassMidCards
			check(typed, "%s: тип узла" % mode)
			check(g.materials().size() == 2, "%s: материалы — ближний и средний" % mode)
			var mm: ShaderMaterial = g.mid_material()
			check(mm != null and mm.get_shader_parameter("height_tex") == htex, "%s: общие uniform'ы скопированы" % mode)
		if mode != "blades":
			# приминание у пилота доходит и до средней травы (вид сзади в ~12 м — пилот в её кольце)
			var root := Node3D.new()
			var cam := Camera3D.new()
			var pilot := Node3D.new()
			root.add_child(cam)
			root.add_child(pilot)
			root.add_child(g)
			# в дерево — под узел раннера (окно root занято, пока раннер в _ready)
			var tree_root := (Engine.get_main_loop() as SceneTree).root
			tree_root.get_child(tree_root.get_child_count() - 1).add_child(root)
			cam.global_position = Vector3(0.0, 101.5, 0.0)
			pilot.global_position = Vector3(3.0, 100.2, -12.0)
			g.camera = cam
			g.pilot = pilot
			g._process(0.016)
			var mp: Variant = g.mid_material().get_shader_parameter("press_pos")
			check(mp is Vector3 and (mp as Vector3).is_equal_approx(pilot.global_position),
					"%s: press_pos средней травы = положение пилота: %s" % [mode, mp])
			root.remove_child(g)
			root.get_parent().remove_child(root)
			root.free()
		g.free()
	if not old.is_empty():
		OS.set_environment("DP_GRASS_MID", old)
