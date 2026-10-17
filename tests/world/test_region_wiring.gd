extends TestCase
## Профиль региона места в конфигах (RV-9, RV-К1 «Слияние»): набор пород и профиль для 5 мест, Онгудай не меняется,
## реестр моделей домов, потолок этажей на Рапа-Нуи, атлас импостеров (ячейки 5–7 не пустые, 0–4 прежние).

const PLACES := [
	["Флорианополис", -27.72, -48.78, "subtropical", ["tropical", "palm", "oak", "pine", "cedar", "spruce"]],
	["Альпы", 47.05, 11.0, "temperate", ["spruce", "larch", "cedar", "pine", "oak", "birch"]],
	["Онгудай", 50.79, 86.13, "boreal", ["pine", "cedar", "larch", "birch", "spruce"]],
	["Ницца", 43.70, 7.26, "mediterranean", ["pine", "oak", "palm", "cedar", "spruce"]],
	["Рапа-Нуи", -27.12, -109.35, "island", ["palm", "tropical"]],
]
## hash() данных ячеек 0–4 атласа до RV-9 (pine, cedar, larch, birch, spruce).
const OLD_CELL_HASH := [463111545, 620354492, 2570485689, 1515168097, 2744863529]


func _real() -> void:
	Biome.path = "res://configs/biomes.json"
	Biome.reset()


func test_profile_and_set_for_places() -> void:
	_real()
	var world: Dictionary = Config.get_config("world")
	for p: Array in PLACES:
		var id := Biome.at(float(p[1]), float(p[2]))
		check(id == String(p[3]), "%s: профиль %s, ожидался %s" % [p[0], id, p[3]])
		var t := Terrain.region_section(world, "trees", {}, float(p[1]), float(p[2]))
		var set := TreePlacer.species_set(t)
		check(Array(set) == p[4], "%s: trees.set %s, ожидался %s" % [p[0], set, p[4]])
		for sp in set:
			check(t.models.has(sp) and ResourceLoader.exists(String(t.models[sp])), "%s: нет модели породы %s" % [p[0], sp])
			check(t.species.has(sp) or sp == "", "%s: нет пояса породы %s" % [p[0], sp])


func test_species_belts() -> void:
	_real()
	var sp: Dictionary = Config.get_config("world").trees.species
	check(float(sp.palm.max_m) <= 500.0, "palm до ≈ 450 м")
	check(float(sp.tropical.max_m) >= 1500.0 and float(sp.tropical.max_m) <= 1800.0, "tropical до ≈ 1700 м")
	check(float(sp.oak.min_m) == 0.0 and float(sp.oak.max_m) <= 1200.0, "oak 0–1200 м")


## Онгудай (boreal): слитые деревья, полог, сцена и дома равны прежним (world ← location).
func test_ongudai_unchanged() -> void:
	_real()
	var world: Dictionary = Config.get_config("world")
	var loc: Dictionary = Locations.config("ongudai")
	var lat := float(loc.center_lat)
	var lon := float(loc.center_lon)
	for key in ["trees", "terrain_look", "scene_look"]:
		var got := Terrain.region_section(world, key, loc, lat, lon)
		got.erase("set")  # boreal: set = старые пять (проверка ниже), других ключей нет
		var old := Config._deep_merge(world.get(key, {}), loc.get(key, {}))
		check(got == old, "Онгудай: %s изменился профилем" % key)
	var wo := WorldObjects.load_config(lat, lon)
	var wo0 := WorldObjects.load_config()
	check(wo.buildings == wo0.buildings, "Онгудай: дома изменились профилем")
	check(Array(TreePlacer.species_set(Terrain.region_section(world, "trees", loc, lat, lon))) == Array(TreePlacer.DEFAULT_SET), "Онгудай: набор старых пород")


func test_profile_keys() -> void:
	_real()
	var world: Dictionary = Config.get_config("world")
	var sl_nice := Terrain.region_section(world, "scene_look", {}, 43.70, 7.26)
	check(float(sl_nice.evergreen) == 0.5, "Ницца: evergreen 0,5")
	var sl_rn := Terrain.region_section(world, "scene_look", {}, -27.12, -109.35)
	check(float(sl_rn.evergreen) == 1.0, "Рапа-Нуи: evergreen 1")
	var sl_alps := Terrain.region_section(world, "scene_look", {}, 47.05, 11.0)
	check(float(sl_alps.evergreen) == 0.0, "Альпы: evergreen 0")
	# тон полога тропиков темнее хвойного по умолчанию
	var tl: Dictionary = Terrain.region_section(world, "terrain_look", {}, -27.72, -48.78)
	check(float(tl.forest_color[1]) < float(world.terrain_look.forest_color[1]), "субтропики: полог темнее")
	# локация переопределяет профиль
	var over := Terrain.region_section(world, "scene_look", {"scene_look": {"evergreen": 0.25}}, -27.12, -109.35)
	check(float(over.evergreen) == 0.25, "место побеждает профиль")


func test_buildings_profiles() -> void:
	_real()
	var reg: Dictionary = WorldObjects.load_config().buildings.models
	for m in ["rondavel", "tin_house", "stilt_house"]:
		check(reg.has(m) and ResourceLoader.exists(String(reg[m].path)), "модель домов %s в реестре" % m)
	for p: Array in PLACES:
		var bc: Dictionary = WorldObjects.load_config(float(p[1]), float(p[2])).buildings
		var share := float(bc.get("village_model_share", 0.0))
		for e: Dictionary in bc.get("village_models", []):
			check(reg.has(String(e.name)), "%s: модель %s не в реестре" % [p[0], e.name])
		if share > 0.0:
			check(share >= 0.3 and share <= 0.7, "%s: доля моделей 0,3…0,7 (%s)" % [p[0], share])
	var rn: Dictionary = WorldObjects.load_config(-27.12, -109.35).buildings
	check(int(rn.max_levels) == 1, "Рапа-Нуи: один этаж")
	check(String(rn.village_models[0].name) == "tin_house", "Рапа-Нуи: дома из профлиста")
	var nice: Dictionary = WorldObjects.load_config(43.70, 7.26).buildings
	check(String(nice.village_roof) == "hip" and int(nice.max_levels) == 4, "Ницца: вальма, до 4 этажей")
	var alps: Dictionary = WorldObjects.load_config(47.05, 11.0).buildings
	check(String(alps.village_roof) == "gable" and int(alps.max_levels) == 0, "Альпы: как сейчас")


static func _flat(_x: float, _z: float) -> float:
	return 0.0


## Рапа-Нуи: потолок этажей на всех домах: 7 полей (посёлок), OSM по правилу и по тегам (max_levels_osm).
func test_rapa_nui_one_floor() -> void:
	_real()
	var bc: Dictionary = WorldObjects.load_config(-27.12, -109.35).buildings.duplicate(true)
	bc["village_model_share"] = 0.0
	var houses := []
	for i in 10:
		houses.append([100.0 + 30.0 * i, 0.0, 7.0, 9.0, 0.0, 3.2 + 0.1 * i, 0])  # посёлок, 7 полей
	for i in 10:
		houses.append([100.0 + 30.0 * i, 200.0, 8.0, 10.0, 0.0, 12.0, 0, 1, 1])  # OSM по правилу, 4 этажа
	houses.append([900.0, 400.0, 8.0, 10.0, 0.0, 12.0, 0, 1, 0])  # OSM, высота из тегов — режется (max_levels_osm)
	check(bool(bc.get("max_levels_osm", false)), "Рапа-Нуи: max_levels_osm")
	var tiles := BuildingPlacer.place(houses, bc, _flat)
	var level := float(bc.get("level_m", 3.0))
	var max_wall := 0.0
	var tall := 0
	for k in tiles:
		var t: Dictionary = tiles[k]
		for xf: Transform3D in t.walls:
			var h := xf.basis.get_scale().y - float(bc.sink_m)
			if h > level + 0.01:
				tall += 1
			max_wall = maxf(max_wall, h)
	check(tall == 0, "Рапа-Нуи: все дома не выше этажа (%d выше)" % tall)
	check(max_wall <= level + 0.01, "максимум стены %.2f" % max_wall)
	# вне острова (Ницца) высота из тегов не режется
	var nb: Dictionary = WorldObjects.load_config(43.70, 7.26).buildings.duplicate(true)
	check(not bool(nb.get("max_levels_osm", false)), "Ницца: max_levels_osm выключен")


func _cell_hash(im: Image, c: int) -> int:
	return hash(im.get_region(Rect2i((c % 4) * 256, (c / 4) * 512, 256, 512)).get_data())


## Атлас: ячейки 0–4 те же, что до RV-9; 5–7 (oak, palm, tropical) — не пустые (альфа > 0 в центре ячейки).
func test_atlas_cells() -> void:
	var im := Image.load_from_file(ProjectSettings.globalize_path("res://assets/models/trees/trees_impostor_atlas.png"))
	check(im != null and im.get_size() == Vector2i(1024, 1024), "атлас 1024×1024")
	if im == null:
		return
	for c in 5:
		check(_cell_hash(im, c) == OLD_CELL_HASH[c], "ячейка %d атласа изменилась" % c)
	for c in range(5, 8):
		var n := 0
		var ox := (c % 4) * 256
		var oy := (c / 4) * 512
		for y in range(oy + 192, oy + 320, 2):
			for x in range(ox + 96, ox + 160, 2):
				if im.get_pixel(x, y).a > 0.05:
					n += 1
		check(n > 40, "ячейка %d атласа пуста в центре (непрозрачных точек %d)" % [c, n])
