class_name PlaceData
extends RefCounted
## Общие данные места на одну загрузку (контракт FL-К2, docs/contracts/fast-load.md): высоты (слои рельефа),
## OSM, пятна застройки и план домов посёлков (с домами OSM) — читаются и считаются один раз и делятся между
## маской просек (WorldClearings) и объектами мира (WorldObjects).
## После сборки — только чтение; height_at безопасна для рабочих потоков.
##   var pd := PlaceData.for_terrain(terrain)   # живой рельеф: те же слои, кеш в мета Terrain "place_data"
##   var pd := PlaceData.from_files("ongudai")  # без Terrain: каждый файл читается один раз

const META_KEY := "place_data"

## Сборок за процесс (проверка «один раз за загрузку» в тестах).
static var builds: int = 0

var location_id: String = ""
## Папка данных места (Locations.data_dir).
var dir: String = ""
var center_lat: float = 0.0
var center_lon: float = 0.0
## Слои рельефа: у живого рельефа — те же объекты, что Terrain.layers.
var layers: Array[HeightLayer] = []
var patches: BuiltPatches
## Данные OSM места; пустой OsmData — нет тайлов или OSM выключен.
var osm: OsmData
## План домов посёлков (VillagePlacer.plan с osm_houses = osm.buildings); пусто — дома выключены или нет рельефа.
var house_plan: Array = []
## Время сборки, с (OSM, план домов).
var build_time_s: float = 0.0
var osm_time_s: float = 0.0
var plan_time_s: float = 0.0


## Данные загруженного рельефа (кеш в мета Terrain; новый рельеф или место — новая сборка).
static func for_terrain(t: Terrain) -> PlaceData:
	if t == null:
		return null
	if t.has_meta(META_KEY):
		var cached: PlaceData = t.get_meta(META_KEY)
		if cached != null and cached._matches(t):
			return cached
	var pd := build(t.location_id, t.layers, BuiltPatches.for_terrain(t))
	t.set_meta(META_KEY, pd)
	return pd


## Данные места из файлов (без живого рельефа: превью, инструменты, маска по id). Пустое место — null.
static func from_files(id: String) -> PlaceData:
	if Locations.config(id).is_empty():
		return null
	var d := Locations.data_dir(id)
	var ls: Array[HeightLayer] = []
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(d.path_join("meta.json")))
	if meta is Dictionary and (meta as Dictionary).has("layers"):
		for l: Variant in HeightLayer.load_files(d, meta.layers):
			if l != null:
				ls.append(l)
	return build(id, ls, BuiltPatches.for_dir(d))


## Сборка: OSM (OsmData.load_for) и план домов. layers — готовые слои (не читаются).
static func build(id: String, ls: Array[HeightLayer], bp: BuiltPatches) -> PlaceData:
	var t0 := Time.get_ticks_usec()
	builds += 1
	var pd := PlaceData.new()
	pd.location_id = id
	pd.dir = Locations.data_dir(id) if id != "" else ""
	pd.layers = ls
	pd.patches = bp if bp != null else BuiltPatches.new()
	pd.patches.ensure_loaded()  # растр долей — до рабочих потоков
	var loc: Dictionary = Locations.config(id)
	pd.center_lat = float(loc.get("center_lat", 0.0))
	pd.center_lon = float(loc.get("center_lon", 0.0))
	pd.osm = OsmData.new()
	var ocfg: Dictionary = Config.get_config("osm_tiles")
	if not loc.is_empty() and bool(ocfg.get("enabled", true)):
		pd.osm = OsmData.load_for(pd.dir, pd.center_lat, pd.center_lon, float(ocfg.get("half_m", 20000.0)))
	var t1 := Time.get_ticks_usec()
	pd.osm_time_s = (t1 - t0) / 1.0e6
	var cfg := WorldObjects.load_config()
	if not ls.is_empty() and bool(cfg.buildings.get("enabled", true)):
		pd.house_plan = VillagePlacer.plan(pd.patches, id, cfg.villages, pd.height_at, pd.osm.buildings)
	var t2 := Time.get_ticks_usec()
	pd.plan_time_s = (t2 - t1) / 1.0e6
	pd.build_time_s = (t2 - t0) / 1.0e6
	print(
		"PlaceData: '%s' за %.2f с — OSM %.2f с (домов OSM %d), план домов %.2f с (%d)"
		% [id, pd.build_time_s, pd.osm_time_s, pd.osm.buildings.size(), pd.plan_time_s, pd.house_plan.size()]
	)
	return pd


## Высота рельефа по слоям, как Terrain.height_at (без узлов сцены).
func height_at(x: float, z: float) -> float:
	for l in layers:
		if l.contains(x, z):
			return l.sample(x, z)
	if layers.is_empty():
		return 0.0
	return layers[layers.size() - 1].sample(x, z)


func _matches(t: Terrain) -> bool:
	if location_id != t.location_id or dir != Locations.data_dir(t.location_id):
		return false
	if layers.size() != t.layers.size() or patches != BuiltPatches.for_terrain(t):
		return false
	for i in layers.size():
		if layers[i] != t.layers[i]:
			return false
	return true
