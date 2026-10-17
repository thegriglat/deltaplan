class_name PlaceData
extends RefCounted
## Общие данные места на одну загрузку (контракт FL-К2, docs/contracts/fast-load.md): высоты (слои рельефа),
## OSM, пятна застройки и план домов посёлков (с домами OSM) — читаются и считаются один раз и делятся между
## маской просек (WorldClearings) и объектами мира (WorldObjects).
## После сборки — только чтение; height_at безопасна для рабочих потоков.
##   var pd := PlaceData.for_terrain(terrain)   # живой рельеф: те же слои, кеш в мета Terrain "place_data"
##   var pd := PlaceData.from_files("ongudai")  # без Terrain: каждый файл читается один раз
##   var job := PlaceData.start_for_terrain(terrain)   # то же в рабочем потоке: job.done(), job.finish()

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
	return _assemble(_inputs(id), ls, bp)


## Сборка в рабочем потоке (FL-10): входы из кешей автозагрузок (Config, Locations) — здесь, на главном потоке;
## расчёт (OSM, план домов) — задачей WorkerThreadPool; готово — job.done(), результат — job.finish() на главном
## потоке (кладёт в мета Terrain). Данные этого места уже есть — job сразу готов.
static func start_for_terrain(t: Terrain) -> Job:
	var job := Job.new()
	job.terrain = t
	if t == null:
		return job
	if t.has_meta(META_KEY):
		var cached: PlaceData = t.get_meta(META_KEY)
		if cached != null and cached._matches(t):
			job.result = cached
			return job
	var inp := _inputs(t.location_id)
	var ls: Array[HeightLayer] = t.layers.duplicate()
	var bp := BuiltPatches.for_terrain(t)
	bp.ensure_loaded()  # растр долей — здесь: экземпляр общий (мета Terrain), в потоке только читается
	# низкий приоритет: OsmData.load_for внутри ждёт свои группы пула (высокого приоритета) — им остаются потоки
	job.task = WorkerThreadPool.add_task(
		func() -> void: job.result = _assemble(inp, ls, bp), false, "PlaceData"
	)
	return job


## Сборка общих данных места в рабочем потоке (start_for_terrain).
class Job:
	extends RefCounted
	var terrain: Terrain
	var task := -1
	var result: PlaceData

	## Расчёт закончен (не ждёт).
	func done() -> bool:
		return task < 0 or WorkerThreadPool.is_task_completed(task)

	## Главный поток: дождаться и отдать данные (в мета Terrain, если рельеф тот же; сменился — null).
	func finish() -> PlaceData:
		if task >= 0:
			WorkerThreadPool.wait_for_task_completion(task)
			task = -1
		if result == null or not is_instance_valid(terrain) or not result._matches(terrain):
			return null
		terrain.set_meta(META_KEY, result)
		return result


## Входы сборки из конфигов (главный поток: кеши Config и Locations пишутся при первом чтении).
static func _inputs(id: String) -> Dictionary:
	var ocfg: Dictionary = Config.get_config("osm_tiles")
	OsmTilesStage.cache_root()
	return {
		"id": id,
		"dir": Locations.data_dir(id) if id != "" else "",
		# корень тайлов OSM (VI-К1): bundled — папка места osm/, иначе кеш тайлов
		"osm_root": Locations.osm_root(id) if id != "" else OsmTilesStage.cache_root(),
		"loc": Locations.config(id),
		"ocfg": ocfg,
		"wcfg": WorldObjects.load_config(),
	}


## Расчёт по входам _inputs — потокобезопасен (файлы, слои и пятна только читаются).
static func _assemble(inp: Dictionary, ls: Array[HeightLayer], bp: BuiltPatches) -> PlaceData:
	var t0 := Time.get_ticks_usec()
	builds += 1
	var id := String(inp.id)
	var pd := PlaceData.new()
	pd.location_id = id
	pd.dir = String(inp.dir)
	pd.layers = ls
	pd.patches = bp if bp != null else BuiltPatches.new()
	pd.patches.ensure_loaded()  # растр долей — до потоков плана домов
	var loc: Dictionary = inp.loc
	pd.center_lat = float(loc.get("center_lat", 0.0))
	pd.center_lon = float(loc.get("center_lon", 0.0))
	pd.osm = OsmData.new()
	var ocfg: Dictionary = inp.ocfg
	if not loc.is_empty() and bool(ocfg.get("enabled", true)):
		pd.osm = OsmData.load_for(
			pd.dir, pd.center_lat, pd.center_lon, float(ocfg.get("half_m", 20000.0)), String(inp.osm_root)
		)
	var t1 := Time.get_ticks_usec()
	pd.osm_time_s = (t1 - t0) / 1.0e6
	var cfg: Dictionary = inp.wcfg
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
