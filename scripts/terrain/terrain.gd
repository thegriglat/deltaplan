class_name Terrain
extends Node3D
## Рельеф локации (контракт — docs/ARCHITECTURE.md, группа "terrain").
##   height_at(x, z)       — высота земли над уровнем моря, м (билинейно по сетке DEM)
##   normal_at(x, z)       — нормаль к поверхности
##   get_start_sites()     — стартовые площадки {id, name, position, heading_deg, lat, lon}
##   sun_exposure_at(x, z) — освещённость склона солнцем 0..1
## Дополнительно: load_location(id), load_location_latlon(lat, lon, size_km) (рантайм, FR-17),
## latlon_to_local / local_to_latlon, сигнал loaded.
## Координаты: X — восток, −Z — север, Y — высота над уровнем моря; начало X/Z — центр локации.

signal loaded
signal load_failed(message: String)

## Сколько полян у стартов передаётся в шейдер (размер массива в terrain_common.gdshaderinc).
const MAX_CLEARINGS := 8

## Локация из configs/locations/<id>.json, загружается в _ready (пусто — не грузить).
@export var location_id: String = "altai"

var location: Dictionary = {}
var center_lat: float = 0.0
var center_lon: float = 0.0
## Слои высот от детального к грубому.
var layers: Array[HeightLayer] = []
## Время последней загрузки, с (NFR-2).
var last_load_time_s: float = 0.0
var renderer: TerrainRenderer
var trees: TerrainTrees

var _sites: Array[Dictionary] = []
var _sun_dir: Vector3 = Vector3.UP
var _loader: TerrariumLoader


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
	setup(cfg, new_layers, float(meta.center_lat), float(meta.center_lon))
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
	location_id = ""
	setup(result.config, result.layers, lat, lon)
	last_load_time_s = (Time.get_ticks_usec() - t0) / 1e6
	print("Terrain: рельеф вокруг %.4f, %.4f загружен за %.2f с" % [lat, lon, last_load_time_s])
	loaded.emit()


## Собрать рельеф из готовых слоёв. cfg — словарь в формате configs/locations/<id>.json.
func setup(cfg: Dictionary, new_layers: Array[HeightLayer], lat0: float, lon0: float) -> void:
	location = cfg
	layers = new_layers
	center_lat = lat0
	center_lon = lon0
	var world: Dictionary = Config.get_config("world")
	refresh_sun()
	var look: Dictionary = Config._deep_merge(
		world.get("terrain_look", {}), cfg.get("terrain_look", {})
	)
	_build_sites()
	look = look.duplicate()
	var clear_r := float(cfg.get("start_clearing_radius_m", 0.0))
	var clearings: Array[Vector4] = []
	for site in _sites:
		if clearings.size() < MAX_CLEARINGS and clear_r > 0.0:
			var p: Vector3 = site.position
			clearings.append(Vector4(p.x, p.z, clear_r, 0.0))
	look["clearings"] = clearings
	look["clearing_count"] = clearings.size()
	if renderer == null:
		renderer = TerrainRenderer.new()
		renderer.name = "Mesh"
		add_child(renderer)
	renderer.build(layers, cfg.get("render", {}), look, world.get("rendering", {}))
	renderer.apply_textures(world.get("terrain_textures", {}))
	var trees_cfg: Dictionary = world.get("trees", {})
	if trees != null:
		trees.queue_free()
		trees = null
	if bool(trees_cfg.get("enabled", false)) and not renderer.height_textures.is_empty():
		trees = TerrainTrees.new()
		trees.name = "Trees"
		add_child(trees)
		trees.setup(layers[0], renderer.height_textures[0], look, trees_cfg)


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


## Освещённость склона солнцем 0..1: косинус угла между нормалью и направлением на солнце
## (направление — configs/world.json → sun). Ровная площадка при солнце на 52° → ~0.79.
func sun_exposure_at(x: float, z: float) -> float:
	return clampf(normal_at(x, z).dot(_sun_dir), 0.0, 1.0)


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


func _spacing_at(x: float, z: float) -> float:
	for l in layers:
		if l.contains(x, z):
			return l.spacing
	return layers[layers.size() - 1].spacing if not layers.is_empty() else 1.0


func _build_sites() -> void:
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
