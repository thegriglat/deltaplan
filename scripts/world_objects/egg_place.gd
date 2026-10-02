class_name EggPlace
extends RefCounted
## Место для пасхалок (docs/contracts/easter-eggs.md → К8): дешёвые проверки «логично ли здесь»
## по рельефу, карте поверхности, OSM локации и лагерю. ТОЛЬКО ЧТЕНИЕ: рельеф, OSM и
## WorldObjects не меняются. Нет данных (OSM, WorldCover) → «нет»: {} / [] / INF / NONE.
## Строит планировщик один раз на полёт (EasterEggs), пороги — configs/easter_eggs.json → place.

var build_ms := 0.0  ## сколько строилось, мс (для тестов)
var _terrain: Terrain
var _osm: OsmData
var _camp: Array[Dictionary] = []
var _cfg: Dictionary = {}
var _valley := 0.0
var _road_cache := {}  ## ключ классов → Array[PackedVector2Array]
var _water_lines: Array = []  ## PackedVector2Array: реки и контуры озёр
var _water_ready := false


## terrain — рельеф (null → пустое место: высота 0, всё «нет»); objects — WorldObjects или null;
## place_cfg — блок place из configs/easter_eggs.json (пусто — читается из конфига).
static func build(terrain: Terrain, objects: Node = null, place_cfg: Dictionary = {}) -> EggPlace:
	var t0 := Time.get_ticks_usec()
	var p := EggPlace.new()
	p._terrain = terrain
	p._cfg = place_cfg
	if p._cfg.is_empty():
		p._cfg = Config.get_config("easter_eggs").get("place", {})
	if objects != null:
		var o: Variant = objects.get("osm")
		p._osm = o as OsmData
		var c: Variant = objects.get("camp")
		if c is Array:
			for d in c:
				p._camp.append(d)
	if terrain != null:
		p._valley = float(
			WeatherModel.ground_context(
				terrain.height_at,
				float(p._cfg.get("valley_radius_m", 10000.0)),
				int(p._cfg.get("valley_samples", 15)),
				float(p._cfg.get("valley_percentile", 0.1))
			).valley_msl_m
		)
	p.build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return p


func height_at(x: float, z: float) -> float:
	return _terrain.height_at(x, z) if _terrain != null else 0.0


## Крутизна склона, градусы.
func slope_deg_at(x: float, z: float) -> float:
	if _terrain == null:
		return 0.0
	return rad_to_deg(acos(clampf(_terrain.normal_at(x, z).y, -1.0, 1.0)))


## Класс SurfaceLayer (NONE — нет данных).
func surface_at(x: float, z: float) -> int:
	return _terrain.surface_at(x, z) if _terrain != null else SurfaceLayer.NONE


## «Дно» локации, м н.у.м.
func valley_msl() -> float:
	return _valley


func above_valley_m(x: float, z: float) -> float:
	return height_at(x, z) - _valley


func is_mountain(x: float, z: float) -> bool:
	if _terrain == null:
		return false
	return (
		above_valley_m(x, z) > float(_cfg.get("mountain_above_valley_m", 600.0))
		or slope_deg_at(x, z) > float(_cfg.get("mountain_slope_deg", 25.0))
	)


## Ближайший посёлок OSM {n, t, x, z, pop, dist_m}; {} — нет данных.
func nearest_place(x: float, z: float) -> Dictionary:
	if _osm == null:
		return {}
	var best := {}
	var best_d := INF
	for pl in _osm.places:
		var d := Vector2(float(pl.x) - x, float(pl.z) - z).length()
		if d < best_d:
			best_d = d
			best = pl
	if best.is_empty():
		return {}
	var out: Dictionary = best.duplicate()
	out["dist_m"] = best_d
	return out


## Дороги OSM этих классов (highway): Array[PackedVector2Array]; [] — нет.
func roads(classes: PackedStringArray) -> Array:
	if _osm == null:
		return []
	var key := ",".join(classes)
	if not _road_cache.has(key):
		var out: Array = []
		for r in _osm.roads:
			if classes.has(String(r.get("t", ""))):
				out.append(OsmData.points(r.p))
		_road_cache[key] = out
	return _road_cache[key]


func nearest_road_m(x: float, z: float, classes: PackedStringArray) -> float:
	return _dist_to_lines(Vector2(x, z), roads(classes))


## До реки или озера OSM, м (для озера — до контура); INF — нет данных.
func near_water_m(x: float, z: float) -> float:
	if _osm == null:
		return INF
	if not _water_ready:
		_water_ready = true
		for r in _osm.rivers:
			_water_lines.append(OsmData.points(r.p))
		for l in _osm.lakes:
			_water_lines.append(OsmData.points(l.p))
	return _dist_to_lines(Vector2(x, z), _water_lines)


## Старты локации (копия).
func start_sites() -> Array[Dictionary]:
	return _terrain.get_start_sites() if _terrain != null else ([] as Array[Dictionary])


## Лагерь у старта; [] — нет.
func camp() -> Array[Dictionary]:
	return _camp.duplicate()


## Случайная точка в круге (from rng), где accept.call(x, z) истинно: Vector3 на рельефе или null.
## Число бросков rng не зависит от accept (по 2 на попытку) — одинаково у всех при одном сиде.
func find_point(
	rng: RandomNumberGenerator, around: Vector2, radius_m: float, accept: Callable, tries := 48
) -> Variant:
	for i in tries:
		var a := rng.randf() * TAU
		var r := radius_m * sqrt(rng.randf())
		var x := around.x + cos(a) * r
		var z := around.y + sin(a) * r
		if accept.is_null() or bool(accept.call(x, z)):
			return Vector3(x, height_at(x, z), z)
	return null


static func _dist_to_lines(p: Vector2, lines: Array) -> float:
	var best := INF
	for line in lines:
		var pts: PackedVector2Array = line
		if pts.size() == 1:
			best = minf(best, p.distance_squared_to(pts[0]))
		for i in range(pts.size() - 1):
			var a := pts[i]
			var ab := pts[i + 1] - a
			var l2 := ab.length_squared()
			var t := 0.0 if l2 < 1.0e-9 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			best = minf(best, p.distance_squared_to(a + ab * t))
	return sqrt(best) if not is_inf(best) else INF
