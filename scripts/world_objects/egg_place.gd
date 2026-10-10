class_name EggPlace
extends RefCounted
## Место для пасхалок (docs/contracts/easter-eggs.md → К8 v4): дешёвые проверки «логично ли здесь»
## по рельефу, карте поверхности (WorldCover), пятнам застройки и лагерю. ТОЛЬКО ЧТЕНИЕ: рельеф,
## покров и WorldObjects не меняются. Нет данных → «нет»: {} / [] / INF / NONE.
## Строит планировщик один раз на полёт (EasterEggs), пороги — configs/easter_eggs.json → place.

var build_ms := 0.0  ## сколько строилось, мс (для тестов)
var _terrain: Terrain
var _camp: Array[Dictionary] = []
var _cfg: Dictionary = {}
var _valley := 0.0
var _places: Array[Dictionary] = []
var _places_ready := false
var _place_xz := PackedVector2Array()  ## центры places() для быстрого поиска ближайшего


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


## «Посёлки» места (копия): пятна застройки WorldCover (BuiltPatches) {x, z, radius_m, src: "built"};
## нет пятен — опорные точки по рельефу {x, z, radius_m, src: "relief"}. Считается один раз.
func places() -> Array[Dictionary]:
	_ensure_places()
	return _places.duplicate()


## Ближайший из places() + dist_m; {} — places() пуст.
func nearest_place(x: float, z: float) -> Dictionary:
	_ensure_places()
	var best := -1
	var best_d := INF
	var q := Vector2(x, z)
	for i in _place_xz.size():
		var d := q.distance_squared_to(_place_xz[i])
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return {}
	var out: Dictionary = _places[best].duplicate()
	out["dist_m"] = sqrt(best_d)
	return out


func _ensure_places() -> void:
	if _places_ready:
		return
	_places_ready = true
	if _terrain == null:
		return
	for p in BuiltPatches.for_terrain(_terrain).patches():
		_places.append(
			{"x": float(p.x), "z": float(p.z), "radius_m": sqrt(float(p.area_m2) / PI), "src": "built"}
		)
	if _places.is_empty():
		_places = _relief_places()
	for p in _places:
		_place_xz.append(Vector2(p.x, p.z))


## Опорные точки по рельефу, когда пятен застройки нет: низко над дном долины, ровно, открытый
## грунт, ближе к воде. Сетка шагом relief_step_m в круге valley_radius_m; лучшие по оценке,
## не ближе relief_gap_m друг к другу. Порядок детерминирован.
func _relief_places() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rad := float(_cfg.get("valley_radius_m", 10000.0))
	var step := float(_cfg.get("relief_step_m", 500.0))
	var low := float(_cfg.get("relief_above_valley_m", 200.0))
	var slope_max := float(_cfg.get("relief_slope_deg", 5.0))
	var water_m := float(_cfg.get("relief_water_m", 1500.0))
	var cand: Array = []
	var n := int(rad / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var x := i * step
			var z := j * step
			if x * x + z * z > rad * rad:
				continue
			if above_valley_m(x, z) > low or slope_deg_at(x, z) > slope_max:
				continue
			var sf := surface_at(x, z)
			if not (sf == SurfaceLayer.GRASS or sf == SurfaceLayer.CROP or sf == SurfaceLayer.SHRUB or sf == SurfaceLayer.NONE):
				continue
			cand.append({"x": x, "z": z, "score": above_valley_m(x, z)})
	cand.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
	# воду (дорогая) считаем только для лучших по высоте над дном
	cand = cand.slice(0, int(_cfg.get("relief_water_candidates", 40)))
	for c in cand:
		var w := near_water_m(float(c.x), float(c.z), water_m)
		c.score = float(c.score) + (w if not is_inf(w) else water_m * 2.0) * 0.1
	cand.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
	var gap := float(_cfg.get("relief_gap_m", 2000.0))
	var max_n := int(_cfg.get("relief_places_max", 6))
	var min_n := int(_cfg.get("relief_places_min", 3))
	while true:
		out.clear()
		for c in cand:
			if out.size() >= max_n:
				break
			var ok := true
			for o in out:
				if Vector2(c.x - o.x, c.z - o.z).length() < gap:
					ok = false
					break
			if ok:
				(
					out
					. append(
						{
							"x": c.x,
							"z": c.z,
							"radius_m": float(_cfg.get("relief_radius_m", 150.0)),
							"src": "relief"
						}
					)
				)
		if out.size() >= min_n or gap < 250.0:
			break
		gap *= 0.5  # точек мало — разрешить ближе друг к другу
	return out


## До воды, м: класс WATER покрова (в нём маска воды 10 м и реки по рельефу); поиск кольцами
## шагом max(25, max_m/20) м до max_m (по умолчанию place.water_search_m); дальше — INF. Не для каждого кадра.
func near_water_m(x: float, z: float, max_m := -1.0) -> float:
	if _terrain == null:
		return INF
	var lim := max_m if max_m > 0.0 else float(_cfg.get("water_search_m", 1500.0))
	var step := maxf(25.0, lim / 20.0)
	if _is_water(x, z):
		return 0.0
	var r := step
	while r <= lim:
		var n := maxi(8, int(TAU * r / step))
		for k in n:
			var a := TAU * float(k) / float(n)
			if _is_water(x + cos(a) * r, z + sin(a) * r):
				return r
		r += step
	return INF


## Вода в точке: как первая ветка Terrain.surface_at (маска воды 10 м, в ней реки по рельефу; иначе
## класс карты поверхности), но без нормали — на порядок дешевле.
func _is_water(x: float, z: float) -> bool:
	var sl: SurfaceLayer = null
	for l in _terrain.surfaces:
		if l != null and l.contains(x, z):
			sl = l
			break
	if sl == null:
		return false
	if sl.mask_contains(x, z):
		return sl.mask_g(x, z) >= 0.5
	return sl.class_at(x, z) == SurfaceLayer.WATER


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
