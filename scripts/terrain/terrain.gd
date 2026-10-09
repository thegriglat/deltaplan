# gdlint: disable=max-public-methods, max-file-lines
class_name Terrain
extends Node3D
## Рельеф локации (контракт — docs/guide/architecture.md, группа "terrain").
##   height_at(x, z)       — высота земли над уровнем моря, м (билинейно по сетке DEM)
##   normal_at(x, z)       — нормаль к поверхности
##   get_start_sites()     — стартовые площадки {id, name, position, heading_deg, lat, lon}
##   sun_exposure_at(x, z) — освещённость склона солнцем 0..1
##   surface_at(x, z)      — класс поверхности (SurfaceLayer.FOREST, GRASS, CROP…), VR-4;
##                           вода и лес — по маске «деталь 10 м», где она есть (как в шейдере;
##                           вода — реки/ручьи/озёра OSM, T03, VR-9)
##   forest_at(x, z)       — доля леса 0..1 (маска 10 м), get_forest_mask() — сама маска
##   add_start_clearing(x, z, r), get_start_clearings() — пустыри у стартов (К1 v2, SF-1)
##   thermal_source_strength_at(x, z) — сила источника термиков 0..1 (класс × освещённость
##                           × сухость), годится как sun_fn для Atmosphere.set_ground
##   moisture_at / relief_ao_at / relief_horizon_at — поля рельефа (TerrainRelief): влажность
##                           ложбин, AO, горизонт к солнцу; set_sun(to_sun) — смена солнца
##                           (SunClock.sun_changed), тень склонов пересчитывается в фоне
## Цвет земли, деревья и источники термиков берутся из одной карты поверхности (VR-0, VR-4).
## Ветер на земле (VR-17): set_wind_sources(atmo.mean_wind_at, atmo.thermals_near,
## atmo.air_velocity_at), set_pilot(node).
## Дополнительно: load_location(id), load_point(lat, lon) (сборка/кеш места точки, OA-К4),
## latlon_to_local / local_to_latlon, сигнал loaded.
## Координаты: X — восток, −Z — север, Y — высота над уровнем моря; начало X/Z — центр локации.

signal loaded
signal load_failed(message: String)

## Локация из configs/locations/<id>.json, загружается в _ready (пусто — не грузить).
@export var location_id: String = "altai"

var location: Dictionary = {}
var center_lat: float = 0.0
var center_lon: float = 0.0
## Слои высот от детального к грубому.
var layers: Array[HeightLayer] = []
## Карта поверхности каждого слоя (тот же порядок, что layers).
var surfaces: Array[SurfaceLayer] = []
## Время последней загрузки, с (NFR-2).
var last_load_time_s: float = 0.0
var renderer: TerrainRenderer
var trees: Node3D
var grass: GrassField
## Средний план леса (билборды), null — нет атласа.
var impostors: ForestImpostors
## Передаёт ветер и термики атмосферы шейдерам земли, травы и деревьев.
var wind: TerrainWind
## Поля рельефа каждого слоя (влажность, AO, горизонт к солнцу) — тот же порядок, что layers.
var reliefs: Array[TerrainRelief] = []
## Ход рантайм-загрузки (load_point): этап и доля — для экрана загрузки.
var progress := LoadProgress.new()
## Растёт при правке карты поверхности после сборки (add_start_clearing): сброс кеша кустов/камней.
var surface_revision: int = 0

var _sites: Array[Dictionary] = []
var _landings: Array[Dictionary] = []
## [Image, origin, cell_m] — просеки (set_clearings), переживают перезагрузку деревьев.
var _clearings: Array = []
## Пустыри у стартов: Vector3(x, z, радиус), м — встроенные (set_surfaces) и add_start_clearing.
var _start_clearings: Array[Vector3] = []
var _sun_dir: Vector3 = Vector3.UP
## Солнце по классам поверхности с запаздыванием прогрева (SurfaceHeating); пусто — _sun_dir.
var _class_sun := PackedVector3Array()
## terrain_look после переопределений локации (палитра — get_grass_palette).
var _look: Dictionary = {}
var _builder: LocationBuilder
## Коэффициенты источников термиков по классам (configs/world.json → surface.thermal).
var _thermal_k := PackedFloat32Array()
var _thermal_gain: float = 1.0
var _thermal_power: float = 1.0
var _edge_boost: float = 0.0
var _edge_full: float = 50.0
var _edge_max: float = 150.0
## Пары классов-триггеров: _edge_pair[a * CLASS_COUNT + b] = true.
var _edge_pair := PackedByteArray()
## С этого уклона луг/поле/кустарник считаются скалами (как в шейдере), радианы → cos.
var _rock_cos: float = -1.0
## Сырые ложбины — слабее источник термиков (surface.thermal.wet_k / wet_from).
var _wet_k: float = 0.0
var _wet_from: float = 0.7
## world.json → surface.relief
var _relief_cfg: Dictionary = {}
## Фоновый пересчёт горизонта к солнцу при смене азимута.
var _relief_thread: Thread
var _relief_pending_az: float = NAN
var _relief_full := false
var _relief_t0 := 0
## Номер текущей рантайм-загрузки: сменился — загрузка отменена (cancel_load) или закончена.
var _load_gen := 0


func _init() -> void:
	add_to_group("terrain")


func _ready() -> void:
	if location_id != "" and layers.is_empty():
		load_location(location_id)


## Загрузить место: встроенное (configs/locations/<id>.json, data/terrain/<id>/) или собранную
## точку (user://locations/<ключ>/) — файлы и путь одни (Locations, OA-К4).
func load_location(id: String) -> bool:
	var t0 := Time.get_ticks_usec()
	var r := _read_location(id)
	if r.is_empty():
		return false
	location_id = id
	for task_id: int in r.masks.get("tasks", []):
		WorkerThreadPool.wait_for_task_completion(task_id)
	var new_surfaces := _load_surfaces(r.dir, r.layers, r.masks.get("images", {}))
	setup(r.cfg, r.layers, float(r.meta.center_lat), float(r.meta.center_lon), new_surfaces)
	last_load_time_s = (Time.get_ticks_usec() - t0) / 1e6
	print(
		(
			"Terrain: локация '%s' загружена за %.2f с, чанков %d"
			% [id, last_load_time_s, renderer.chunk_count()]
		)
	)
	loaded.emit()
	return true


## Читает файлы места: {cfg, dir, meta, layers, masks}; пустой словарь — ошибка (load_failed послан).
func _read_location(id: String) -> Dictionary:
	var cfg: Dictionary = Locations.config(id)
	if cfg.is_empty():
		load_failed.emit(tr("err_no_location_config") % id)
		return {}
	var dir := String(cfg.get("data_dir", "res://data/terrain/" + id))
	var meta_text := FileAccess.get_file_as_string(dir.path_join("meta.json"))
	var meta: Variant = JSON.parse_string(meta_text)
	if not meta is Dictionary:
		push_error("Terrain: нет %s/meta.json — запусти tools/terrain/fetch_dem.py %s" % [dir, id])
		load_failed.emit(tr("err_no_location_data") % id)
		return {}
	# маски 10 м (PNG ≈ 60 мс) читаются в рабочем потоке, пока распаковываются высоты
	var masks := _start_mask_decode(dir)
	var new_layers: Array[HeightLayer] = []
	for info in meta.layers:
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		if l == null:
			load_failed.emit(tr("err_layer_read") % String(info.id))
			return {}
		if info.has("water_file"):
			l.water_texture = TerrainRenderer.load_texture(dir.path_join(String(info.water_file)))
		new_layers.append(l)
	return {"cfg": cfg, "dir": dir, "meta": meta, "layers": new_layers, "masks": masks}


## Загрузка места для точки с карты (FR-17, OA-К4): сборщик берёт место из кеша
## user://locations/<ключ> или собирает стадиями (рельеф, реки, покров, OSM), затем обычный путь
## load_location. Асинхронно: по готовности — loaded (или load_failed с текстом для пилота).
## Ход — progress (этапы и доля для экрана загрузки); сеть молчит stall_timeout_s — отмена.
func load_point(lat: float, lon: float) -> void:
	cancel_load()
	_load_gen += 1
	var gen := _load_gen
	var rt: Dictionary = Config.get_config("world").get("runtime_terrain", {})
	var t0 := Time.get_ticks_usec()
	progress.begin()
	_watch_stall(gen, float(rt.get("stall_timeout_s", 90.0)))
	progress.stage("dem", tr("loading_dem"))
	var builder := LocationBuilder.new()
	_builder = builder
	var shown := {"stage": ""}
	builder.progress.connect(
		func(stage: String, f: float) -> void:
			if gen != _load_gen:
				return
			if shown.stage != stage:
				shown.stage = stage
				match stage:
					"surface":
						progress.stage("landcover", tr("loading_landcover"))
					"osm":
						progress.stage("osm", tr("loading_osm"))
			progress.sub(f, 1.0)
	)
	var res: Dictionary = await builder.build(self, lat, lon)
	if _builder == builder:
		_builder = null
	if gen != _load_gen:
		return  # отменено (cancel_load) — load_failed уже отправлен
	if not bool(res.ok):
		push_error("Terrain: место %s не собрано: %s" % [res.key, res.error])
		_fail(gen, _error_text(String(res.error)))
		return
	progress.stage("mesh", tr("loading_mesh"))
	var r := _read_location(String(res.key))
	if r.is_empty():
		_fail(gen, tr("err_terrain_failed"))
		return
	var new_surfaces := _load_surfaces(r.dir, r.layers, r.masks.get("images", {}))
	for task_id: int in r.masks.get("tasks", []):
		WorkerThreadPool.wait_for_task_completion(task_id)
	var surf0: SurfaceLayer = new_surfaces[0] if not new_surfaces.is_empty() else null
	if is_sea(r.layers[0], surf0, float(rt.get("sea_depth_m", -450.0))):
		_fail(gen, tr("err_sea"))
		return
	location_id = String(res.key)
	await setup_async(r.cfg, r.layers, float(r.meta.center_lat), float(r.meta.center_lon), new_surfaces)
	if gen != _load_gen:
		return
	_load_gen += 1  # загрузка закончена — сторож молчит (progress.finish — у вызывающего: дальше
	# ещё этапы игры — погода, объекты)
	last_load_time_s = (Time.get_ticks_usec() - t0) / 1e6
	print("Terrain: место %s загружено за %.2f с" % [res.key, last_load_time_s])
	loaded.emit()


## Прервать рантайм-загрузку (если идёт): сеть закрывается, сигналов не будет.
func cancel_load() -> void:
	_load_gen += 1
	if _builder != null:
		_builder.cancel()


## Точка — море: ниже sea_depth_m — всегда; не выше нуля (тайлы Terrarium крупного уровня дают
## над океаном ровно 0) — если карта покрова говорит «вода» или её нет (у океана нет файлов
## WorldCover). Выше нуля — суша.
static func is_sea(detail: HeightLayer, surf: SurfaceLayer, sea_depth_m: float) -> bool:
	var h := detail.sample(0.0, 0.0)
	if h > 0.5:
		return false
	if h < sea_depth_m:
		return true
	return surf == null or surf.class_at(0.0, 0.0) == SurfaceLayer.WATER


func _fail(gen: int, message: String) -> void:
	if gen != _load_gen:
		return
	cancel_load()
	progress.finish()
	load_failed.emit(message)


## Текст ошибки загрузки для пилота по виду ошибки загрузчика.
func _error_text(kind: String) -> String:
	match kind:
		"nodata":
			return tr("err_no_terrain_data")
		"network":
			return tr("err_network")
	return tr("err_terrain_failed")


## Сторож: пока идёт загрузка gen, ход не менялся дольше timeout_s — отмена и сообщение.
func _watch_stall(gen: int, timeout_s: float) -> void:
	var last := progress.fraction
	var since := Time.get_ticks_msec()
	while gen == _load_gen and is_inside_tree():
		await get_tree().create_timer(1.0, true, false, true).timeout
		if progress.fraction != last:
			last = progress.fraction
			since = Time.get_ticks_msec()
		elif (Time.get_ticks_msec() - since) / 1000.0 > timeout_s:
			push_warning("Terrain: загрузка стоит %.0f с — отмена" % timeout_s)
			_fail(gen, tr("err_server_timeout"))
			return


## Собрать рельеф из готовых слоёв. cfg — словарь в формате configs/locations/<id>.json.
## new_surfaces — карта поверхности каждого слоя (null или нет элемента — процедурная).
func setup(
	cfg: Dictionary,
	new_layers: Array[HeightLayer],
	lat0: float,
	lon0: float,
	new_surfaces: Array[SurfaceLayer] = []
) -> void:
	_setup_steps(cfg, new_layers, lat0, lon0, new_surfaces, false)


## То же, но без долгих остановок главного потока: процедурная карта поверхности — в рабочем
## потоке, меш, деревья и трава — в разных кадрах (окно отвечает, экран загрузки живой).
## Пока идёт — рельеф и его дети не обрабатываются (_process), чтобы не видеть полусборку.
func setup_async(
	cfg: Dictionary,
	new_layers: Array[HeightLayer],
	lat0: float,
	lon0: float,
	new_surfaces: Array[SurfaceLayer] = []
) -> void:
	var mode := process_mode
	process_mode = Node.PROCESS_MODE_DISABLED
	await _setup_steps(cfg, new_layers, lat0, lon0, new_surfaces, true)
	process_mode = mode


func _setup_steps(
	cfg: Dictionary,
	new_layers: Array[HeightLayer],
	lat0: float,
	lon0: float,
	new_surfaces: Array[SurfaceLayer],
	async: bool
) -> void:
	var world: Dictionary = Config.get_config("world")
	progress.stage("classify", tr("loading_classify"))
	if async:
		new_surfaces = await _classify_missing(new_layers, new_surfaces, world.get("surface", {}))
	location = cfg
	layers = new_layers
	_clearings = []  # просеки — от прежней локации; интегратор задаст новые
	center_lat = lat0
	center_lon = lon0
	refresh_sun()
	var look: Dictionary = Config._deep_merge(
		world.get("terrain_look", {}), cfg.get("terrain_look", {})
	)
	_build_sites()
	_look = look
	set_surfaces(new_surfaces, world.get("surface", {}), look)
	_compute_reliefs(world.get("surface", {}).get("relief", {}))
	progress.stage("mesh", tr("loading_mesh"))
	if async:
		await get_tree().process_frame
	if renderer == null:
		renderer = TerrainRenderer.new()
		renderer.name = "Mesh"
		add_child(renderer)
	look["sun_dir"] = _sun_dir
	renderer.build(
		layers, surfaces, cfg.get("render", {}), look, world.get("rendering", {}), reliefs
	)
	renderer.apply_textures(world.get("terrain_textures", {}))
	var trees_cfg: Dictionary = Config._deep_merge(world.get("trees", {}), cfg.get("trees", {}))
	progress.stage("trees", tr("loading_trees"))
	if async:
		await get_tree().process_frame
	if trees != null:
		trees.queue_free()
		trees = null
	if bool(trees_cfg.get("enabled", false)) and not renderer.height_textures.is_empty():
		trees = _make_trees(trees_cfg, look)
	progress.stage("grass", tr("loading_grass"))
	if async:
		await get_tree().process_frame
	_make_grass(Config.get_config("vegetation").get("grass", {}), look)
	_setup_wind(world.get("wind_visual", {}))


## Процедурные карты поверхности для слоёв без готовой (SurfaceClassifier) — в рабочем потоке.
func _classify_missing(
	new_layers: Array[HeightLayer], new_surfaces: Array[SurfaceLayer], scfg: Dictionary
) -> Array[SurfaceLayer]:
	var out: Array[SurfaceLayer] = []
	out.resize(new_layers.size())
	var fb: Dictionary = scfg.get("fallback", {})
	var slots: Array = []
	var tasks: Array[int] = []
	for k in new_layers.size():
		var s: SurfaceLayer = new_surfaces[k] if k < new_surfaces.size() else null
		out[k] = s
		if s != null:
			continue
		var slot := [null]
		slots.append([k, slot])
		var l := new_layers[k]
		tasks.append(
			WorkerThreadPool.add_task(func() -> void: slot[0] = SurfaceClassifier.classify(l, fb))
		)
	for t in tasks:
		while not WorkerThreadPool.is_task_completed(t):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(t)
	for ks: Array in slots:
		out[int(ks[0])] = ks[1][0]
	return out


## Источники ветра для визуала (VR-17): mean_wind_fn(pos) -> Vector3 (Atmosphere.mean_wind_at),
## thermals_fn(pos, radius) -> Array[Dictionary] (Atmosphere.thermals_near).
## air_fn(pos) -> Vector3 (Atmosphere.air_velocity_at) — необязательный (T05): порывистость
## |air − mean_wind| у земли усиливает амплитуду пятен на траве. Без него — как раньше (штиль
## порывов).
## field_src — необязательный (AM-10, WF-10): сам Atmosphere (is_air_field_on(), air_field) — для
## текстуры ветра поля травы на бровке/в долине. Без него (или без поля) — как раньше.
func set_wind_sources(
	mean_wind_fn: Callable,
	thermals_fn: Callable,
	air_fn: Callable = Callable(),
	field_src: Object = null
) -> void:
	if wind == null:
		_setup_wind(Config.get_config("world").get("wind_visual", {}))
	wind.mean_wind_fn = mean_wind_fn
	wind.thermals_fn = thermals_fn
	wind.air_fn = air_fn
	wind.field_src = field_src


## Просеки для деревьев (дороги, коридоры ЛЭП, здания, посадки) — маска WorldClearings:
## Image L8 (255 — расчищено), origin — мир (x, z) угла пикселя (0, 0), cell_m — размер пикселя.
## Интегратор: var c := WorldClearings.build_for(id)
## terrain.set_clearings(c.image, c.origin, c.cell_m)
func set_clearings(mask: Image, origin: Vector2, cell_m: float) -> void:
	_clearings = [mask, origin, cell_m]
	if trees is TerrainTreeModels:
		(trees as TerrainTreeModels).set_clearings(mask, origin, cell_m)
	if impostors != null:
		impostors.set_clearings(mask, origin, cell_m)


## Палитра травы локации (та же, что у рельефа, meadow_color в terrain_common.gdshaderinc):
## {grass_color, dry_grass_color, straw_color, field_color: Color (линейные), dryness, dry_noise,
##  dry_south_k, grass_saturation, patch_scale_m: float}. Для травинок (агент vegetation).
func get_grass_palette() -> Dictionary:
	var out := {}
	for k in ["grass_color", "dry_grass_color", "straw_color", "field_color"]:
		var a: Array = _look.get(k, [0.3, 0.4, 0.15])
		out[k] = Color(float(a[0]), float(a[1]), float(a[2]))
	for k in ["dryness", "dry_noise", "dry_south_k", "grass_saturation", "patch_scale_m"]:
		out[k] = float(_look.get(k, 0.0))
	return out


## Нода пилота: трава приминается у его ног.
func set_pilot(node: Node3D) -> void:
	if grass != null:
		grass.pilot = node


func _make_grass(cfg: Dictionary, look: Dictionary) -> void:
	if grass != null:
		grass.queue_free()
		grass = null
	if not GrassField.is_enabled(cfg) or renderer.height_textures.is_empty():
		return
	var spots: Array[Vector4] = []
	var r := float(cfg.get("landing_mow_radius_m", 0.0))
	for l in _landings:
		var p: Vector3 = l.position
		spots.append(Vector4(p.x, p.z, r, float(cfg.get("mowed_height_k", 0.3))))
	# Сухость травинок сверх палитры локации (configs/vegetation.json →
	# grass.dryness_add_by_location) — только для травы, не для рельефа/леса.
	var dryness_add := float(cfg.get("dryness_add_by_location", {}).get(location_id, 0.0))
	var grass_look := look
	if dryness_add != 0.0:
		grass_look = look.duplicate(true)
		grass_look["dryness"] = float(look.get("dryness", 0.3)) + dryness_add
	grass = GrassField.new()
	grass.name = "Grass"
	add_child(grass)
	grass.setup(
		layers[0],
		renderer.height_textures[0],
		surfaces[0],
		renderer.surface_textures[0],
		grass_look,
		cfg,
		spots
	)
	if not reliefs.is_empty():
		grass.set_relief(reliefs[0])


func _setup_wind(cfg: Dictionary) -> void:
	if wind == null:
		wind = TerrainWind.new()
		wind.name = "Wind"
		add_child(wind)
	wind.setup(cfg)
	wind.ground_fn = height_at
	wind.clear_materials()
	if renderer != null:
		wind.add_materials(renderer.materials())
	if trees is TerrainTreeModels:
		wind.add_materials((trees as TerrainTreeModels).materials)
	if grass != null:
		wind.add_materials(grass.materials())


## Деревья: модели пород, если есть файлы, иначе процедурные кроны.
func _make_trees(trees_cfg: Dictionary, look: Dictionary) -> Node3D:
	var models := TerrainTreeModels.new()
	models.name = "Trees"
	if impostors != null:
		impostors.queue_free()
		impostors = null
	if models.setup(layers[0], surfaces[0], trees_cfg):
		add_child(models)
		impostors = ForestImpostors.new()
		impostors.name = "ForestImpostors"
		if impostors.setup(
			layers[0],
			renderer.height_textures[0],
			surfaces[0],
			renderer.surface_textures[0],
			trees_cfg
		):
			add_child(impostors)
		else:
			impostors.free()
			impostors = null
		if _clearings.size() == 3:
			set_clearings(_clearings[0], _clearings[1], _clearings[2])
		_pass_forest_mask(models)
		return models
	models.free()
	var cones := TerrainTrees.new()
	cones.name = "Trees"
	add_child(cones)
	cones.setup(
		layers[0],
		renderer.height_textures[0],
		surfaces[0],
		renderer.surface_textures[0],
		look,
		trees_cfg
	)
	return cones


## Маска леса 10 м — деревьям и импостерам, если они её принимают (метод делает V02).
func _pass_forest_mask(models: Node) -> void:
	var fm := get_forest_mask()
	if fm.is_empty():
		return
	for n: Object in [models, impostors]:
		if n != null and n.has_method("set_forest_mask"):
			n.call("set_forest_mask", fm[0], fm[1], fm[2])


# ---------------- контракт ----------------


## Высота земли над уровнем моря, м. Берётся самый детальный слой, покрывающий точку.
func height_at(x: float, z: float) -> float:
	for l in layers:
		if l.contains(x, z):
			return l.sample(x, z)
	if layers.is_empty():
		return 0.0
	return layers[layers.size() - 1].sample(x, z)


## Единичная нормаль к поверхности (центральные разности с шагом сетки).
func normal_at(x: float, z: float) -> Vector3:
	var e := _spacing_at(x, z)
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## Стартовые площадки: {id, name, position: Vector3, heading_deg, lat, lon}.
func get_start_sites() -> Array[Dictionary]:
	return _sites.duplicate(true)


## Посадочные площадки локации: {id, name, position: Vector3 (на земле), lat, lon}.
func get_landing_sites() -> Array[Dictionary]:
	return _landings.duplicate(true)


## Освещённость склона солнцем 0..1: косинус угла между нормалью и направлением на солнце
## (направление — configs/world.json → sun). Ровная площадка при солнце на 52° → ~0.79.
func sun_exposure_at(x: float, z: float) -> float:
	return clampf(normal_at(x, z).dot(_sun_dir), 0.0, 1.0)


## Класс поверхности в точке (SurfaceLayer.FOREST, GRASS, CROP, SHRUB, BARE, WATER, BUILT, SNOW;
## NONE — нет данных). Берётся самая детальная карта, покрывающая точку. Как и в шейдере,
## луг/поле/кустарник на склоне круче terrain_look.rock_slope_deg — это скалы (BARE).
func surface_at(x: float, z: float) -> int:
	return _surface_class(x, z, normal_at(x, z))


## Доля леса в точке 0..1 (VR-4, VR-21, для деревьев и травы) — как кромка в шейдере (без шума):
## маска «деталь 10 м» билинейно + порог 0,5 (terrain_look.forest_edge_soft), переход 0,1→0,9
## в пределах ~10 м; где маски нет — по классу карты поверхности (0 или 1).
func forest_at(x: float, z: float) -> float:
	var sl := _surface_layer_at(x, z)
	if sl == null:
		return 0.0
	return sl.forest_at(x, z)


## Маска леса 10 м детального слоя: [Image RG8 (R — доля леса 0..255, G — доля воды, T03),
## origin: Vector2 — мир (x, z) угла пикселя (0, 0), cell_m] — как у set_clearings:
## центр пикселя (i, j) = origin + (i + 0,5, j + 0,5)·cell_m. Пусто — маски нет (рантайм-локация).
## Поляны у стартов в маске уже вырезаны.
func get_forest_mask() -> Array:
	for sl in surfaces:
		if sl != null and sl.has_forest_mask():
			var h := sl.mask_spacing * 0.5
			return [
				sl.forest_mask_image(),
				Vector2(sl.mask_origin_x - h, sl.mask_origin_z - h),
				sl.mask_spacing
			]
	return []


## Сила источника термиков 0..1 (VR-4, FR-11): класс поверхности × освещённость склона солнцем
## × усиление у границ классов (поле–лес, луг–лес, пашня–луг — триггеры отрыва):
## clamp(class_strength[класс] · exposure_gain · sun_exposure^exposure_power
##       · (1 + edge_boost · edge_proximity), 0, 1)   (configs/world.json → surface.thermal).
## Сигнатура как у sun_fn в Atmosphere.set_ground.
func thermal_source_strength_at(x: float, z: float) -> float:
	return thermal_source_strength_for(x, z, _class_sun, _sun_dir)


## То же при заданном солнце: class_sun — направления по классам (SurfaceHeating.directions),
## to_sun — для классов без своего. Чистая функция (для атмосферы по времени, AtmoDay).
func thermal_source_strength_for(
	x: float, z: float, class_sun: PackedVector3Array, to_sun: Vector3
) -> float:
	var n := normal_at(x, z)
	var c := _surface_class(x, z, n)
	var sd := class_sun[c] if c < class_sun.size() else to_sun
	var e := clampf(n.dot(sd), 0.0, 1.0)
	var k := _thermal_k[c] if c < _thermal_k.size() else 1.0
	var edge := 1.0 + _edge_boost * _edge_proximity(x, z)
	var wet := 1.0
	if _wet_k > 0.0:
		wet -= _wet_k * smoothstep(_wet_from, 1.0, moisture_at(x, z))
	return clampf(k * _thermal_gain * pow(e, _thermal_power) * edge * wet, 0.0, 1.0)


## Близость к границе классов-триггеров 0..1: 1 ближе edge_full_m, 0 дальше edge_max_m.
## Ищется по 8 направлениям на нескольких расстояниях (класс — без учёта уклона).
func _edge_proximity(x: float, z: float) -> float:
	if _edge_boost <= 0.0 or _edge_pair.is_empty():
		return 0.0
	var sl := _surface_layer_at(x, z)
	if sl == null:
		return 0.0
	var c0 := sl.class_at(x, z)
	var n := SurfaceLayer.CLASS_COUNT
	var steps := 4
	for s in steps:
		var d := _edge_full * 0.5 + (_edge_max - _edge_full * 0.5) * s / float(steps - 1)
		for k in 8:
			var a := TAU * k / 8.0
			var c1 := sl.class_at(x + cos(a) * d, z + sin(a) * d)
			if c1 != c0 and _edge_pair[c0 * n + c1] != 0:
				return clampf((_edge_max - d) / maxf(_edge_max - _edge_full, 1.0), 0.0, 1.0)
	return 0.0


# ---------------- дополнительно ----------------


## Влажность рельефа 0..1 (ложбины, днища долин — выше; гребни — ниже), TerrainRelief.
## Нет полей — 0,5.
func moisture_at(x: float, z: float) -> float:
	var r := _relief_at(x, z)
	return r.moisture_at(x, z) if r != null else 0.5


## Видимость неба (AO рельефа) 0..1: ложбины темнее; нет полей — 1.
func relief_ao_at(x: float, z: float) -> float:
	var r := _relief_at(x, z)
	return r.ao_at(x, z) if r != null else 1.0


## Угол горизонта рельефа в сторону солнца, градусы (солнце ниже — склон в тени рельефа).
func relief_horizon_at(x: float, z: float) -> float:
	var r := _relief_at(x, z)
	return r.horizon_at(x, z) if r != null else 0.0


## Новое направление НА солнце (единичный вектор) — от SunClock.sun_changed:
##   sky.clock.sun_changed.connect(terrain.set_sun)
## Обновляет освещение полога/камней в шейдере и источники термиков; горизонт к солнцу (тень
## рельефа) пересчитывается в фоне, когда азимут ушёл дальше surface.relief.shadow_recompute_deg.
## Солнце для источников термиков по классам (инерция прогрева: камни и деревни греют и вечером,
## SurfaceHeating.directions). Пустой массив — всем классам текущее солнце.
func set_class_sun(dirs: PackedVector3Array) -> void:
	_class_sun = dirs


func set_sun(to_sun: Vector3) -> void:
	if to_sun.length_squared() < 1e-8:
		return
	_sun_dir = to_sun.normalized()
	if renderer != null:
		renderer.apply_look({"sun_dir": _sun_dir})
	if reliefs.is_empty():
		return
	var az := _sun_azimuth_deg()
	var old := reliefs[0].horizon_azimuth_deg
	var step := float(_relief_cfg.get("shadow_recompute_deg", 2.0))
	if is_nan(old) or absf(angle_difference(deg_to_rad(az), deg_to_rad(old))) >= deg_to_rad(step):
		_start_horizon(az)


## Идёт ли фоновый расчёт полей рельефа (влажность ложбин — в силе источников термиков).
func relief_busy() -> bool:
	return _relief_thread != null


## Дождаться фонового расчёта полей рельефа и тени (тесты, кадры превью).
func wait_relief() -> void:
	while _relief_thread != null:
		_finish_relief(true)


func _process(_delta: float) -> void:
	if _relief_thread != null:
		_finish_relief(false)


func _exit_tree() -> void:
	_join_relief()


## Terrain, освобождённый вне дерева (тесты: Terrain.new() … free()), _exit_tree не получает:
## без ожидания Thread отцепляется, и расчёт полей дорабатывает в выгружаемом движке
## (SCRIPT ERROR в terrain_relief.gd, падение 134/139 при выходе).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_join_relief()


func _join_relief() -> void:
	if _relief_thread != null:
		_relief_thread.wait_to_finish()
		_relief_thread = null


## Поля рельефа всех слоёв — в фоне (поток + WorkerThreadPool, ≈ 1,5–2 с на локацию 40 км + фон):
## загрузка не ждёт, шейдер получает поля по готовности (до того — нейтрально).
func _compute_reliefs(cfg: Dictionary) -> void:
	if _relief_thread != null:
		_relief_thread.wait_to_finish()  # расчёт для прежних слоёв — не нужен
		_relief_thread = null
	_relief_pending_az = NAN
	_relief_cfg = cfg
	reliefs.clear()
	if not bool(cfg.get("enabled", true)) or layers.is_empty():
		return
	var az := _sun_azimuth_deg()
	var ls := layers.duplicate()
	_relief_full = true
	_relief_t0 = Time.get_ticks_usec()
	_relief_thread = Thread.new()
	_relief_thread.start(
		func() -> Array:
			var out: Array[TerrainRelief] = []
			for k in ls.size():
				out.append(TerrainRelief.compute(ls[k], cfg, az, k, false))
			return out
	)


func _start_horizon(az: float) -> void:
	if _relief_thread != null:
		_relief_pending_az = az
		return
	var rs := reliefs.duplicate()
	_relief_full = false
	_relief_thread = Thread.new()
	_relief_thread.start(
		func() -> Array:
			for r: TerrainRelief in rs:
				r.recompute_horizon(az)
			return rs
	)


func _finish_relief(block: bool) -> void:
	if not block and _relief_thread.is_alive():
		return
	var res: Array = _relief_thread.wait_to_finish()
	_relief_thread = null
	if _relief_full:
		reliefs.assign(res)
		for r in reliefs:
			r.make_textures()
		if renderer != null:
			renderer.set_reliefs(reliefs)
		if grass != null and not reliefs.is_empty():
			grass.set_relief(reliefs[0])
		print("Terrain: поля рельефа за %.2f с" % ((Time.get_ticks_usec() - _relief_t0) / 1e6))
	else:
		for r in reliefs:
			r.update_shadow_texture()
	var az := _relief_pending_az
	_relief_pending_az = NAN
	if is_nan(az) and not reliefs.is_empty():
		# солнце сдвинулось, пока считались поля
		var cur := _sun_azimuth_deg()
		var step := deg_to_rad(float(_relief_cfg.get("shadow_recompute_deg", 2.0)))
		var old := deg_to_rad(reliefs[0].horizon_azimuth_deg)
		if absf(angle_difference(deg_to_rad(cur), old)) >= step:
			az = cur
	if not is_nan(az):
		_start_horizon(az)


## Азимут солнца (0 — север, по часовой), градусы.
func _sun_azimuth_deg() -> float:
	return fposmod(rad_to_deg(atan2(_sun_dir.x, -_sun_dir.z)), 360.0)


func _relief_at(x: float, z: float) -> TerrainRelief:
	for r in reliefs:
		if r.contains(x, z):
			return r
	return reliefs[reliefs.size() - 1] if not reliefs.is_empty() else null


## Перечитать направление солнца из configs/world.json → sun.
func refresh_sun() -> void:
	var sun: Dictionary = Config.get_config("world").get("sun", {})
	_sun_dir = TerrainGeo.sun_direction(
		float(sun.get("azimuth_deg", 180.0)), float(sun.get("elevation_deg", 45.0))
	)


## Направление НА солнце (единичный вектор).
func sun_direction() -> Vector3:
	return _sun_dir


func latlon_to_local(lat: float, lon: float) -> Vector2:
	return TerrainGeo.latlon_to_local(lat, lon, center_lat, center_lon)


func local_to_latlon(x: float, z: float) -> Vector2:
	return TerrainGeo.local_to_latlon(x, z, center_lat, center_lon)


## Границы детального слоя (зона полётов) в мире: Rect2(x, z, размер).
func detail_bounds() -> Rect2:
	if layers.is_empty():
		return Rect2()
	var l := layers[0]
	return Rect2(l.origin_x, l.origin_z, l.size_x(), l.size_z())


## Карта поверхности, покрывающая точку (самая детальная), или null.
func _surface_layer_at(x: float, z: float) -> SurfaceLayer:
	for sl in surfaces:
		if sl != null and sl.contains(x, z):
			return sl
	return surfaces[surfaces.size() - 1] if not surfaces.is_empty() else null


func _surface_class(x: float, z: float, n: Vector3) -> int:
	var sl := _surface_layer_at(x, z)
	var c := sl.class_at(x, z) if sl != null else SurfaceLayer.NONE
	if sl != null and sl.mask_contains(x, z):
		# вода — по каналу G маски 10 м (T03: реки/ручьи/озёра OSM, точнее карты классов 25 м)
		if sl.mask_g(x, z) >= 0.5:
			return SurfaceLayer.WATER
		# лес — по маске 10 м (порог 0,5, как кромка в шейдере)
		if sl.mask_r(x, z) >= 0.5:
			return SurfaceLayer.FOREST
		if c == SurfaceLayer.FOREST:
			c = sl.open_class_near(x, z)
	if (
		n.y < _rock_cos
		and (
			c == SurfaceLayer.GRASS
			or c == SurfaceLayer.CROP
			or c == SurfaceLayer.SHRUB
			or c == SurfaceLayer.NONE
		)
	):
		return SurfaceLayer.BARE
	return c


## Начать чтение масок 10 м (surface.json → layers[].detail10) в рабочих потоках:
## {tasks: [id], images: {id слоя: [Image]}} — Image появляется по завершении задачи.
func _start_mask_decode(dir: String) -> Dictionary:
	var out := {"tasks": [], "images": {}}
	var meta: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("surface.json"))
	)
	if not meta is Dictionary:
		return out
	var images: Dictionary = out.images
	for info: Dictionary in meta.get("layers", []):
		if not info.has("detail10"):
			continue
		var path := dir.path_join(String(info.detail10.file))
		var lid := String(info.id)
		var slot := [null]  # у каждой задачи своя ячейка (без общей записи в словарь)
		images[lid] = slot
		var job := func() -> void: slot[0] = SurfaceLayer.decode_detail10(path)
		(out.tasks as Array).append(WorkerThreadPool.add_task(job))
	return out


## Карты поверхности из <data_dir>/surface.json (tools/terrain/fetch_landcover.py); по id слоя.
## mask_images — уже прочитанные маски 10 м: {id слоя: [Image]} (нет — читаются здесь).
func _load_surfaces(
	dir: String, new_layers: Array[HeightLayer], mask_images: Dictionary = {}
) -> Array[SurfaceLayer]:
	var out: Array[SurfaceLayer] = []
	out.resize(new_layers.size())
	var path := dir.path_join("surface.json")
	if not FileAccess.file_exists(path):
		return out
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not meta is Dictionary:
		return out
	for info: Dictionary in meta.get("layers", []):
		for k in new_layers.size():
			if new_layers[k].id == String(info.id):
				out[k] = SurfaceLayer.load_png(dir.path_join(String(info.file)), info)
				if out[k] != null and info.has("detail10"):
					var d10: Dictionary = info.detail10
					var slot: Array = mask_images.get(info.id, [null])
					out[k].load_detail10(dir.path_join(String(d10.file)), d10, slot[0])
	return out


## Карты поверхности всех слоёв (без перестройки меша; зовётся из setup, нужна и тестам):
## готовые, иначе процедурные; поляны у стартов; коэффициенты источников термиков.
## scfg — configs/world.json → surface, look — terrain_look.
func set_surfaces(new_surfaces: Array[SurfaceLayer], scfg: Dictionary, look: Dictionary) -> void:
	surfaces.clear()
	for k in layers.size():
		var s: SurfaceLayer = new_surfaces[k] if k < new_surfaces.size() else null
		if s == null:
			s = SurfaceClassifier.classify(layers[k], scfg.get("fallback", {}))
		surfaces.append(s)
	# Старты — открытые склоны: лес и кустарник вокруг площадки → луг (и в цвете, и в термиках);
	# дальше, до пустыря старта с карты (≥ 2 длины разбега, game.json → start_search), — только лес.
	_start_clearings.clear()
	var site_r := float(location.get("start_clearing_radius_m", 0.0))
	var clear_r := maxf(site_r, start_clearing_radius_m())
	for site in _sites:
		var p: Vector3 = site.position
		for s in surfaces:
			s.replace_in_circle(p.x, p.z, site_r, SurfaceLayer.SHRUB, SurfaceLayer.GRASS)
		_clear_forest(p.x, p.z, clear_r)
	var th: Dictionary = scfg.get("thermal", {})
	var ks: Dictionary = th.get("class_strength", {})
	_thermal_k.resize(SurfaceLayer.CLASS_COUNT)
	for c in SurfaceLayer.CLASS_COUNT:
		_thermal_k[c] = float(ks.get(SurfaceLayer.CLASS_NAMES[c], 1.0))
	_thermal_gain = float(th.get("exposure_gain", 1.0))
	_thermal_power = float(th.get("exposure_power", 1.0))
	_edge_boost = float(th.get("edge_boost", 0.0))
	_edge_full = float(th.get("edge_full_m", 50.0))
	_edge_max = float(th.get("edge_max_m", 150.0))
	_wet_k = float(th.get("wet_k", 0.0))
	_wet_from = float(th.get("wet_from", 0.7))
	var n := SurfaceLayer.CLASS_COUNT
	_edge_pair = PackedByteArray()
	_edge_pair.resize(n * n)
	for pair: Array in th.get("edge_pairs", []):
		var a := SurfaceLayer.CLASS_NAMES.find(String(pair[0]))
		var b := SurfaceLayer.CLASS_NAMES.find(String(pair[1]))
		if a >= 0 and b >= 0:
			_edge_pair[a * n + b] = 1
			_edge_pair[b * n + a] = 1
	_rock_cos = cos(deg_to_rad(float(look.get("rock_slope_deg", 90.0))))
	for s in surfaces:
		s.mask_edge_soft = float(look.get("forest_edge_soft", 0.12))


## Лес в круге → луг во всех картах поверхности (и маска леса 10 м); кустарник остаётся.
func _clear_forest(x: float, z: float, r: float) -> void:
	if r <= 0.0:
		return
	for s in surfaces:
		s.replace_in_circle(x, z, r, SurfaceLayer.FOREST, SurfaceLayer.GRASS)
	_start_clearings.append(Vector3(x, z, r))


## Радиус пустыря вокруг старта, м: configs/game.json → start_search.clearing_radius_m
## (≥ 2 длины разбега, решение пользователя; обоснование — там же в _doc).
static func start_clearing_radius_m() -> float:
	return float(Config.value("game", "start_search.clearing_radius_m", 0.0))


## Пустырь вокруг произвольного старта после загрузки (К1 v2): лес в круге → луг (кустарник,
## трава, камни — как были), маска леса — ноль; синхронно — карта, текстуры рельефа (их же читают
## трава, импостеры), маска деревьев; деревья и кусты — со следующего кадра (docs/guide/terrain.md).
func add_start_clearing(x: float, z: float, radius_m: float) -> void:
	if radius_m <= 0.0 or surfaces.is_empty():
		return
	_clear_forest(x, z, radius_m)
	surface_revision += 1
	if renderer != null:
		for k in surfaces.size():
			renderer.refresh_surface(k, surfaces[k])
	if trees is TerrainTreeModels:
		_pass_forest_mask(trees)
		(trees as TerrainTreeModels).invalidate()


## Пустыри у стартов: Vector3(x, z, радиус), м — встроенные площадки и add_start_clearing.
func get_start_clearings() -> Array[Vector3]:
	return _start_clearings.duplicate()


func _spacing_at(x: float, z: float) -> float:
	for l in layers:
		if l.contains(x, z):
			return l.spacing
	return layers[layers.size() - 1].spacing if not layers.is_empty() else 1.0


func _build_sites() -> void:
	_landings.clear()
	for s in location.get("landing_sites", []):
		var q := latlon_to_local(float(s.lat), float(s.lon))
		(
			_landings
			. append(
				{
					"id": String(s.id),
					"name": String(s.name),
					"position": Vector3(q.x, height_at(q.x, q.y), q.y),
					"lat": float(s.lat),
					"lon": float(s.lon),
				}
			)
		)
	_sites.clear()
	var agl := float(location.get("start_position_agl_m", 0.0))
	for s in location.get("start_sites", []):
		var p := latlon_to_local(float(s.lat), float(s.lon))
		(
			_sites
			. append(
				{
					"id": String(s.id),
					"name": String(s.name),
					"position": Vector3(p.x, height_at(p.x, p.y) + agl, p.y),
					"heading_deg": float(s.heading_deg),
					"lat": float(s.lat),
					"lon": float(s.lon),
				}
			)
		)
