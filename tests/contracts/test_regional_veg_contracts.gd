extends TestCase
## Контракты regional-veg (docs/contracts/regional-veg.md, RV-К1…К5).
## Пока артефакта нет (файл, ключ, класс) — проверка пропускается (печать «skip»); есть, а формат другой — падает.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=regional_veg_contracts

const CLASSES := ["arid", "tropical_wet", "savanna", "mediterranean", "subtropical", "temperate", "boreal", "alpine_ice"]
const OLD_SET := ["pine", "cedar", "larch", "birch", "spruce"]
const NEW := ["oak", "palm", "tropical"]
const REF := [
	["Анси", 45.90, 6.15, "temperate"],
	["Казбеги", 42.66, 44.64, "temperate"],
	["Онгудай", 50.79, 86.13, "boreal"],
	["Аушкуль", 54.72, 59.69, "boreal"],
	["Флорианополис", -27.72, -48.78, "subtropical"],
	["Манаус", -3.10, -60.00, "tropical_wet"],
	["Рапа-Нуи", -27.12, -109.35, "island"],
	["Ницца", 43.70, 7.26, "mediterranean"],
	["Кейптаун", -33.95, 18.42, "mediterranean"],
	["Покхара", 28.21, 83.99, "subtropical"],
	["Кернс", -16.92, 145.77, "tropical_wet"],
	["Тегеран", 35.70, 51.40, "arid"],
]


func _skip(what: String) -> void:
	print("  skip regional_veg_contracts: %s — артефакта ещё нет" % what)


func _global_class_path(cls: String) -> String:
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if String(c["class"]) == cls:
			return String(c["path"])
	return ""


func _biomes() -> Dictionary:
	var path := "res://configs/biomes.json"
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(d is Dictionary, "biomes.json — JSON-объект")
	return d if d is Dictionary else {}


## Глубина узла n (корень — 1); -1 — ссылка вне массива или цикл.
func _depth(tree: Array, n: int, seen: int) -> int:
	if n < 0 or n >= tree.size() or seen > tree.size():
		return -1
	var node: Array = tree[n]
	if int(node[0]) == -1:
		return 1
	var a := _depth(tree, int(node[2]), seen + 1)
	var b := _depth(tree, int(node[3]), seen + 1)
	if a < 0 or b < 0:
		return -1
	return 1 + maxi(a, b)


func test_k1_biomes_format() -> void:
	var b := _biomes()
	if b.is_empty():
		_skip("configs/biomes.json")
		return
	check(FileAccess.get_file_as_bytes("res://configs/biomes.json").size() <= 16384, "biomes.json ≤ 16 КБ (RV-К1 v2)")
	check(JSON.stringify(b.get("tree", [])).length() <= 8192, "дерево ≤ 8 КБ")
	check(int(b.get("version", 0)) == 1, "version 1")
	check(String(b.get("source", "")).contains("Beck"), "source — Beck 2018")
	check(Array(b.get("classes", [])) == CLASSES, "classes — 8 наборов в порядке контракта")
	var tree: Array = b.get("tree", [])
	var leaves := 0
	for node: Variant in tree:
		check(node is Array, "узел — массив")
		var a: Array = node
		if int(a[0]) == -1:
			leaves += 1
			check(a.size() == 2 and int(a[1]) >= 0 and int(a[1]) < CLASSES.size(), "лист [-1, класс]")
		else:
			check(a.size() == 4 and (int(a[0]) == 0 or int(a[0]) == 1), "узел [feat 0|1, thr, left, right]")
	check(leaves >= 128 and leaves <= 256, "листьев 128…256: %d" % leaves)
	var depth := _depth(tree, 0, 0)
	check(depth > 0 and depth <= 17, "глубина ≤ 16 (+лист), ссылки внутри массива: %d" % depth)
	var profiles: Dictionary = b.get("profiles", {})
	for c: String in CLASSES:
		check(profiles.has(c), "профиль " + c)
	for e: Variant in b.get("exceptions", []):
		var ex: Dictionary = e
		check(ex.has("name") and Array(ex.get("lat", [])).size() == 2 and Array(ex.get("lon", [])).size() == 2, "исключение: name, lat[2], lon[2]")
		check(profiles.has(String(ex.get("profile", ""))), "профиль исключения существует: " + String(ex.get("name", "")))
	check(profiles.has("island"), "доп. профиль island")
	var boreal: Dictionary = profiles.get("boreal", {})
	check(Array(boreal.get("trees", {}).get("set", [])) == OLD_SET, "boreal: trees.set — старые 5")
	check(boreal.get("trees", {}).size() == 1, "boreal: в trees только set")
	for sec in ["terrain_look", "scene_look", "buildings"]:
		check(Dictionary(boreal.get(sec, {})).is_empty(), "boreal: %s пусто" % sec)
	for id: String in profiles:
		var p: Dictionary = profiles[id]
		for sec: String in p:
			check(sec in ["trees", "terrain_look", "scene_look", "buildings"], "%s: секция %s из списка" % [id, sec])
		var s: Array = p.get("trees", {}).get("set", OLD_SET)
		check(s.size() >= 1 and s.size() <= 6, "%s: в наборе 1…6 пород" % id)


func test_k1_reference_points() -> void:
	var path := _global_class_path("Biome")
	if path == "":
		_skip("class Biome")
		return
	var biome: Script = load(path)
	for r: Array in REF:
		var got := String(biome.call("at", float(r[1]), float(r[2])))
		check(got == String(r[3]), "%s: ожидался %s, получен %s" % [r[0], r[3], got])
	var cls := String(biome.call("classify_tree", 45.90, 6.15))
	check(cls in CLASSES, "classify_tree — класс из списка")
	check(Dictionary(biome.call("profile", "нет-такого")).is_empty(), "неизвестный профиль — {}")
	check(Array(Dictionary(biome.call("profile", "boreal")).get("trees", {}).get("set", [])) == OLD_SET, "profile(boreal)")


func test_k2_registry() -> void:
	var trees: Dictionary = Config.get_config("world").get("trees", {})
	if not trees.has("atlas_cell"):
		_skip("trees.atlas_cell")
		return
	var cell := {"pine": 0, "cedar": 1, "larch": 2, "birch": 3, "spruce": 4, "oak": 5, "palm": 6, "tropical": 7}
	var kind := {"pine": 0, "cedar": 0, "larch": 2, "birch": 1, "spruce": 0, "oak": 1, "palm": 0, "tropical": 0}
	var con := {"pine": true, "cedar": true, "larch": false, "birch": false, "spruce": true, "oak": false, "palm": false, "tropical": false}
	for sp: String in cell:
		check(int(trees.get("atlas_cell", {}).get(sp, -1)) == cell[sp], "atlas_cell." + sp)
		check(int(trees.get("season_kind", {}).get(sp, -1)) == kind[sp], "season_kind." + sp)
		check(bool(trees.get("conifer", {}).get(sp, null)) == con[sp], "conifer." + sp)
		check(trees.get("models", {}).has(sp), "models." + sp)
	if trees.has("set"):
		check(Array(trees["set"]) == OLD_SET, "world.json: набор по умолчанию — старые 5")
	var consts: Dictionary = (load("res://scripts/terrain/tree_placer.gd") as Script).get_script_constant_map()
	check(not consts.has("SPECIES"), "TreePlacer.SPECIES — не константа")
	check(Array(consts.get("DEFAULT_SET", [])) == OLD_SET, "TreePlacer.DEFAULT_SET — старые 5")
	check("species" in TreePlacer.new(), "TreePlacer.species — поле экземпляра")
	for f in ["res://scripts/terrain/tree_cross.gdshader", "res://scripts/terrain/forest_impostors.gdshader"]:
		var src := FileAccess.get_file_as_string(f)
		check(src.contains("MAX_SP = 6") and src.contains("uniform int sp_count"), f + ": MAX_SP = 6, sp_count")
		check(src.contains("sp_kind["), f + ": sp_kind")
		check(not src.contains("[5]"), f + ": массивов на 5 нет")
	var imp := FileAccess.get_file_as_string("res://scripts/terrain/forest_impostors.gdshader")
	check(imp.contains("sp_cell[") and imp.contains("sp_conifer["), "импостеры: sp_cell, sp_conifer")


func test_k3_models() -> void:
	var models: Dictionary = Config.get_config("world").get("trees", {}).get("models", {})
	var hrange := {"oak": Vector2(15, 30), "palm": Vector2(8, 25), "tropical": Vector2(20, 40)}
	var any := false
	for sp: String in NEW:
		var path := String(models.get(sp, "res://assets/models/trees/tree_%s.glb" % sp))
		if not ResourceLoader.exists(path):
			continue
		any = true
		check(FileAccess.get_file_as_bytes(path).size() <= 1_500_000, sp + ": glb ≤ 1,5 МБ")
		var root := (load(path) as PackedScene).instantiate()
		for v in 4:
			for lod in 3:
				var mi := root.find_child("V%d_LOD%d" % [v, lod], true, false) as MeshInstance3D
				check(mi != null and mi.mesh != null, "%s: V%d_LOD%d" % [sp, v, lod])
				if mi == null or mi.mesh == null:
					continue
				if lod == 0:
					var h := mi.mesh.get_aabb().size.y
					check(h >= hrange[sp].x and h <= hrange[sp].y, "%s V%d: высота %.1f м в диапазоне" % [sp, v, h])
				for s in mi.mesh.get_surface_count():
					var m := mi.mesh.surface_get_material(s)
					var n := m.resource_name if m != null else ""
					var ok := n == "Bark_" + sp or n == "Leaf_" + sp or n == "Impostor_%s_v%d" % [sp, v]
					check(ok, "%s V%d_LOD%d: имя материала «%s»" % [sp, v, lod, n])
		check(root.find_child("V4_LOD0", true, false) == null, sp + ": ровно 4 варианта")
		root.free()
	if not any:
		_skip("tree_{oak,palm,tropical}.glb")


func test_k4_buildings_keys() -> void:
	var b: Dictionary = Config.get_config("world_objects").get("buildings", {})
	if not b.has("village_roof"):
		_skip("buildings.village_roof")
		return
	check(String(b.get("village_roof")) == "gable", "village_roof по умолчанию gable")
	check(String(b.get("city_roof", "")) == "flat", "city_roof по умолчанию flat")
	check(int(b.get("max_levels", -1)) == 0, "max_levels по умолчанию 0")
	var hp := float(b.get("hip_pitch_deg", 0))
	check(hp >= 15.0 and hp <= 25.0, "hip_pitch_deg 15…25")
	check(float(b.get("parapet_h_m", 0)) > 0.0 and float(b.get("parapet_t_m", 0)) > 0.0, "парапет: высота и толщина")


func test_k5_evergreen() -> void:
	var look: Dictionary = Config.get_config("world").get("scene_look", {}).duplicate(true)
	if not look.has("evergreen"):
		_skip("scene_look.evergreen")
		return
	check(float(look["evergreen"]) == 0.0, "evergreen по умолчанию 0")
	var base := SeasonLook.state(274.0, 51.0, 1000.0, look)
	check(base.has("canopy_autumn") and base.has("canopy_bare"), "state: canopy_autumn, canopy_bare")
	approx(float(base.get("canopy_autumn", -1)), float(base["autumn"]), 1e-6, "evergreen 0: canopy_autumn = autumn")
	look["evergreen"] = 1.0
	var ev := SeasonLook.state(274.0, 51.0, 1000.0, look)
	approx(float(ev.get("canopy_autumn", -1)), 0.0, 1e-6, "evergreen 1: canopy_autumn 0")
	approx(float(ev.get("canopy_bare", -1)), 0.0, 1e-6, "evergreen 1: canopy_bare 0")
	for k in ["green", "dry", "autumn", "bare", "snow_fresh", "snow_line_m"]:
		approx(float(ev[k]), float(base[k]), 1e-6, "evergreen не меняет " + k)


func test_k6_house_models() -> void:
	var tri := [800, 200, 40]
	var any := false
	for name in ["rondavel", "tin_house", "stilt_house"]:
		var path := "res://assets/models/houses/house_%s.glb" % name
		if not ResourceLoader.exists(path):
			continue
		any = true
		check(FileAccess.get_file_as_bytes(path).size() <= 300_000, name + ": glb ≤ 300 КБ")
		var root := (load(path) as PackedScene).instantiate()
		for lod in 3:
			var mi := root.find_child("LOD%d" % lod, true, false) as MeshInstance3D
			check(mi != null and mi.mesh != null, "%s: LOD%d" % [name, lod])
			if mi == null or mi.mesh == null:
				continue
			var n := 0
			for s in mi.mesh.get_surface_count():
				var a := mi.mesh.surface_get_arrays(s)
				var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				n += idx.size() / 3 if idx.size() > 0 else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
				var m := mi.mesh.surface_get_material(s)
				var mn := m.resource_name if m != null else ""
				check(mn in ["Wall_" + name, "Roof_" + name, "Wood_" + name], "%s LOD%d: материал «%s»" % [name, lod, mn])
			check(n <= tri[lod], "%s LOD%d: треугольников %d ≤ %d" % [name, lod, n, tri[lod]])
			if lod == 0:
				var bb := mi.mesh.get_aabb()
				check(absf(bb.position.y) < 0.05, name + ": низ на y = 0")
				check(bb.size.x >= bb.size.z - 0.01, name + ": длинная сторона вдоль X")
		root.free()
	if not any:
		_skip("house_{rondavel,tin_house,stilt_house}.glb")
