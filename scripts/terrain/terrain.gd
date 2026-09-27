class_name Terrain
extends Node3D
## Рельеф локации (контракт — docs/ARCHITECTURE.md, группа "terrain").
##   height_at(x, z)       — высота земли над уровнем моря, м (билинейно по сетке DEM)
##   normal_at(x, z)       — нормаль к поверхности
##   get_start_sites()     — стартовые площадки {id, name, position, heading_deg, lat, lon}
##   sun_exposure_at(x, z) — освещённость склона солнцем 0..1
##   surface_at(x, z)      — класс поверхности (SurfaceLayer.FOREST, GRASS, CROP…), VR-4
##   thermal_source_strength_at(x, z) — сила источника термиков 0..1 (класс × освещённость),
##                           годится как sun_fn для Atmosphere.set_ground
## Цвет земли, деревья и источники термиков берутся из одной карты поверхности (VR-0, VR-4).
## Ветер на земле (VR-17): set_wind_sources(atmo.mean_wind_at, atmo.thermals_near), set_pilot(node).
## Дополнительно: load_location(id), load_location_latlon(lat, lon, size_km) (рантайм, FR-17),
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

var _sites: Array[Dictionary] = []
var _landings: Array[Dictionary] = []
## [Image, origin, cell_m] — просеки (set_clearings), переживают перезагрузку деревьев.
var _clearings: Array = []
var _sun_dir: Vector3 = Vector3.UP
## terrain_look после переопределений локации (палитра — get_grass_palette).
var _look: Dictionary = {}
var _loader: TerrariumLoader
var _wc_loader: WorldCoverLoader
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


func _init() -> void:
	add_to_group("terrain")


func _ready() -> void:
	if location_id != "" and layers.is_empty():
		load_location(location_id)


## Загрузить встроенную локацию (данные в data/terrain/<id>/,
## подготовленные tools/terrain/fetch_dem.py).
func load_location(id: String) -> bool:
	var t0 := Time.get_ticks_usec()
	var cfg: Dictionary = Config.get_config("locations/" + id)
	if cfg.is_empty():
		load_failed.emit("нет конфига локации " + id)
		return false
	var dir := String(cfg.get("data_dir", "res://data/terrain/" + id))
	var meta_text := FileAccess.get_file_as_string(dir.path_join("meta.json"))
	var meta: Variant = JSON.parse_string(meta_text)
	if not meta is Dictionary:
		push_error("Terrain: нет %s/meta.json — запусти tools/terrain/fetch_dem.py %s" % [dir, id])
		load_failed.emit("нет данных рельефа " + id)
		return false
	var new_layers: Array[HeightLayer] = []
	for info in meta.layers:
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		if l == null:
			load_failed.emit("ошибка чтения слоя " + String(info.id))
			return false
		if info.has("water_file"):
			l.water_texture = TerrainRenderer.load_texture(dir.path_join(String(info.water_file)))
		new_layers.append(l)
	location_id = id
	var new_surfaces := _load_surfaces(dir, new_layers)
	setup(cfg, new_layers, float(meta.center_lat), float(meta.center_lon), new_surfaces)
	last_load_time_s = (Time.get_ticks_usec() - t0) / 1e6
	print(
		(
			"Terrain: локация '%s' загружена за %.2f с, чанков %d"
			% [id, last_load_time_s, renderer.chunk_count()]
		)
	)
	loaded.emit()
	return true


## Рантайм-загрузка рельефа вокруг точки (FR-17): тайлы Terrarium с кешем в user://terrain_cache.
## Асинхронно: по готовности — сигнал loaded (или load_failed).
## Параметры — configs/world.json → runtime_terrain.
func load_location_latlon(lat: float, lon: float, size_km: float = -1.0) -> void:
	if _loader == null:
		_loader = TerrariumLoader.new()
		_loader.name = "TerrariumLoader"
		add_child(_loader)
	var t0 := Time.get_ticks_usec()
	var result: Dictionary = await _loader.build_location(lat, lon, size_km)
	if result.has("error"):
		push_error("Terrain: " + String(result.error))
		load_failed.emit(String(result.error))
		return
	# Карта поверхности: WorldCover по сети (кеш), иначе — процедурная (в setup).
	if _wc_loader == null:
		_wc_loader = WorldCoverLoader.new()
		_wc_loader.name = "WorldCoverLoader"
		add_child(_wc_loader)
	var new_surfaces: Array[SurfaceLayer] = []
	for l: HeightLayer in result.layers:
		var s: SurfaceLayer = await _wc_loader.build_surface(l, lat, lon)
		if s == null:
			push_warning("Terrain: нет карты WorldCover для слоя %s — процедурная" % l.id)
		new_surfaces.append(s)
	location_id = ""
	setup(result.config, result.layers, lat, lon, new_surfaces)
	last_load_time_s = (Time.get_ticks_usec() - t0) / 1e6
	print("Terrain: рельеф вокруг %.4f, %.4f загружен за %.2f с" % [lat, lon, last_load_time_s])
	loaded.emit()


## Собрать рельеф из готовых слоёв. cfg — словарь в формате configs/locations/<id>.json.
## new_surfaces — карта поверхности каждого слоя (null или нет элемента — процедурная).
func setup(
	cfg: Dictionary,
	new_layers: Array[HeightLayer],
	lat0: float,
	lon0: float,
	new_surfaces: Array[SurfaceLayer] = []
) -> void:
	location = cfg
	layers = new_layers
	_clearings = []  # просеки — от прежней локации; интегратор задаст новые
	center_lat = lat0
	center_lon = lon0
	var world: Dictionary = Config.get_config("world")
	refresh_sun()
	var look: Dictionary = Config._deep_merge(
		world.get("terrain_look", {}), cfg.get("terrain_look", {})
	)
	_build_sites()
	_look = look
	set_surfaces(new_surfaces, world.get("surface", {}), look)
	if renderer == null:
		renderer = TerrainRenderer.new()
		renderer.name = "Mesh"
		add_child(renderer)
	look["sun_dir"] = _sun_dir
	renderer.build(layers, surfaces, cfg.get("render", {}), look, world.get("rendering", {}))
	renderer.apply_textures(world.get("terrain_textures", {}))
	var trees_cfg: Dictionary = Config._deep_merge(world.get("trees", {}), cfg.get("trees", {}))
	if trees != null:
		trees.queue_free()
		trees = null
	if bool(trees_cfg.get("enabled", false)) and not renderer.height_textures.is_empty():
		trees = _make_trees(trees_cfg, look)
	_make_grass(Config.get_config("vegetation").get("grass", {}), look)
	_setup_wind(world.get("wind_visual", {}))


## Источники ветра для визуала (VR-17): mean_wind_fn(pos) -> Vector3 (Atmosphere.mean_wind_at),
## thermals_fn(pos, radius) -> Array[Dictionary] (Atmosphere.thermals_near). Пустые — штиль.
func set_wind_sources(mean_wind_fn: Callable, thermals_fn: Callable) -> void:
	if wind == null:
		_setup_wind(Config.get_config("world").get("wind_visual", {}))
	wind.mean_wind_fn = mean_wind_fn
	wind.thermals_fn = thermals_fn


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
	if not bool(cfg.get("enabled", false)) or renderer.height_textures.is_empty():
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
		wind.add_materials([grass.material])


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


## Сила источника термиков 0..1 (VR-4, FR-11): класс поверхности × освещённость склона солнцем
## × усиление у границ классов (поле–лес, луг–лес, пашня–луг — триггеры отрыва):
## clamp(class_strength[класс] · exposure_gain · sun_exposure^exposure_power
##       · (1 + edge_boost · edge_proximity), 0, 1)   (configs/world.json → surface.thermal).
## Сигнатура как у sun_fn в Atmosphere.set_ground.
func thermal_source_strength_at(x: float, z: float) -> float:
	var n := normal_at(x, z)
	var c := _surface_class(x, z, n)
	var e := clampf(n.dot(_sun_dir), 0.0, 1.0)
	var k := _thermal_k[c] if c < _thermal_k.size() else 1.0
	var edge := 1.0 + _edge_boost * _edge_proximity(x, z)
	return clampf(k * _thermal_gain * pow(e, _thermal_power) * edge, 0.0, 1.0)


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


## Карты поверхности из <data_dir>/surface.json (tools/terrain/fetch_landcover.py); по id слоя.
func _load_surfaces(dir: String, new_layers: Array[HeightLayer]) -> Array[SurfaceLayer]:
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
	# Старты — открытые склоны: лес и кустарник вокруг площадки → луг (и в цвете, и в термиках).
	var clear_r := float(location.get("start_clearing_radius_m", 0.0))
	if clear_r > 0.0:
		for site in _sites:
			var p: Vector3 = site.position
			for s in surfaces:
				s.replace_in_circle(p.x, p.z, clear_r, SurfaceLayer.FOREST, SurfaceLayer.GRASS)
				s.replace_in_circle(p.x, p.z, clear_r, SurfaceLayer.SHRUB, SurfaceLayer.GRASS)
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
