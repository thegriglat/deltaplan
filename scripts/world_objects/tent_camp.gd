class_name TentCamp
extends RefCounted
## Лагерь пилотов у старта (docs/world_objects.md → «Палатки у старта»): туристические палатки
## (купольная 2-местная, туннельная 3-местная, тент-навес; assets/models/world/tents.glb —
## tools/blender/build_tents.py, 2 LOD) кучкой на ровном месте в нескольких десятках метров от
## старта. Палаток = 1 (игрок) + боты («Другие пилоты в небе», configs/bots.json → count).
## Не ставятся: в коридоре разбега и на местах ожидания ботов (прямоугольник позади старта из
## bots.json → launch), впереди линии старта, на тропе к старту, дорогах и реках (OSM), в лесу,
## воде, застройке, на склоне круче max_slope_deg и у обрыва, на камнях и кустах.
## Детерминированно от места старта: тот же старт — тот же лагерь.
## Параметры — configs/world_objects.json → tents. Без нод: plan() — чистая функция (тесты),
## build_node() — визуал, WorldObjects.place_camp() — всё вместе + препятствия «tent».
##   var tents := TentCamp.plan(start, heading_deg, TentCamp.tent_count(), cfg.tents, env)

const MODEL_PATH := "res://assets/models/world/tents.glb"
const TINTED := ["Fabric", "Door"]

## Меши из GLB: "<тип>_LOD<n>" → Mesh (загружаются один раз).
static var _meshes: Dictionary = {}
## Материалы по (имя материала, цвет): "Fabric|3" → StandardMaterial3D.
static var _materials: Dictionary = {}


## Сколько палаток: игрок + боты. bots < 0 — из настроек (bots.json → count, до 4 по умолчанию).
static func tent_count(bots: int = -1) -> int:
	if bots < 0:
		bots = bot_count_setting()
	return 1 + maxi(bots, 0)


## Настройка «Другие пилоты в небе» (configs/bots.json + user-конфиг); нет конфига — 4.
static func bot_count_setting() -> int:
	var c: Dictionary = Config.get_config("bots") if _has_bots_config() else {}
	return clampi(int(c.get("count", 4)), 0, int(c.get("count_max", 20)))


static func _has_bots_config() -> bool:
	return FileAccess.file_exists("res://configs/bots.json")


## Зона старта, где стоят и бегут игрок и боты (в осях старта: along — вперёд по курсу,
## lat — вправо): {behind_m, lateral_m} — из bots.json → launch (+ cfg.launch_zone_margin_m).
static func launch_zone(cfg: Dictionary) -> Dictionary:
	var lc: Dictionary = {}
	if _has_bots_config():
		lc = Config.get_config("bots").get("launch", {})
	var margin := float(cfg.get("launch_zone_margin_m", 8.0))
	return {
		"behind_m": float(lc.get("behind_max_m", 70.0)) + margin,
		"lateral_m":
		(
			maxf(float(lc.get("lateral_max_m", 40.0)), float(lc.get("corridor_half_width_m", 9.0)))
			+ margin
		),
	}


## План лагеря: [{type, position: Vector3, basis: Basis, yaw, color: int, radius}].
## start — точка старта на земле, heading_deg — курс разбега (ветер — в лицо, из этого курса).
## env: height_fn(x, z) (обязательно); blocked_fn(x, z) -> bool — лес, вода, застройка;
## lines — [[PackedVector2Array ломаная, полуширина м]] — тропы, дороги, реки;
## points — [Vector3(x, z, радиус)] — камни, кусты, здания; points_fn(c: Vector2, r) -> такие же
## точки в круге (дорогой запрос — зовётся только у пробуемых центров лагеря); zone — как
## launch_zone().
## Ровного места нет — палаток меньше или ни одной.
static func plan(
	start: Vector3, heading_deg: float, count: int, cfg: Dictionary, env: Dictionary
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if count <= 0:
		return out
	var ctx := _Ctx.new(start, heading_deg, cfg, env)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(
		[int(cfg.get("seed", 1)), roundi(start.x * 2.0), roundi(start.z * 2.0), roundi(heading_deg)]
	)
	# центры-кандидаты: сетка в кольце distance_m, ровно и свободно в радиусе camp_flat_m
	var d_lo := float(cfg.distance_m[0])
	var d_hi := float(cfg.distance_m[1])
	var step := float(cfg.get("grid_m", 6.0))
	var prefer := float(cfg.get("prefer_distance_m", 60.0))
	var cands: Array = []
	var n := ceili(d_hi / step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var p := Vector2(start.x + ix * step, start.z + iz * step)
			var d := p.distance_to(ctx.s)
			if d < d_lo or d > d_hi:
				continue
			var r := float(cfg.get("camp_flat_m", 5.0))
			if not ctx.is_free(p, r) or ctx.slope_deg(p, r) > ctx.max_slope:
				continue
			var score := absf(d - prefer) / 50.0 + ctx.slope_deg(p, r) / ctx.max_slope
			if not ctx.seen_from_start(p):
				score += float(cfg.get("hidden_penalty", 1.5))
			cands.append([score + rng.randf() * 0.5, p])
	if cands.is_empty():
		return out
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	# лучшие несколько центров — пробуем лагерь целиком, берём тот, где встало больше палаток
	# из них — где встало больше палаток, при равенстве — меньше камней и кустов вокруг (лагерь на
	# чистой поляне, а не среди глыб) и лучше оценка центра
	var best: Array[Dictionary] = []
	var best_score := INF
	var points_fn: Callable = env.get("points_fn", Callable())
	var base_points: Array = ctx.points
	var tried: Array[Vector2] = []
	var spread := float(cfg.get("camp_try_spread_m", 15.0))
	var per_point := float(cfg.get("scatter_penalty", 0.03))
	for cand: Array in cands:
		if tried.size() >= int(cfg.get("camp_tries", 10)):
			break
		var c: Vector2 = cand[1]
		if tried.any(func(q: Vector2) -> bool: return q.distance_to(c) < spread):
			continue
		tried.append(c)
		var sub := RandomNumberGenerator.new()
		sub.seed = rng.randi()
		var near: Array = []
		if points_fn.is_valid():
			near = points_fn.call(c, camp_radius(cfg, count) + 3.0)
			ctx.points = base_points + near
		var camp := _grow(ctx, c, count, sub)
		var score := float(count - camp.size()) * 100.0 + float(cand[0]) + near.size() * per_point
		if camp.size() > 0 and score < best_score:
			best = camp
			best_score = score
	for t in best:
		out.append(ctx.finish(t))
	return out


## Радиус кучки из count палаток от её центра, м.
static func camp_radius(cfg: Dictionary, count: int) -> float:
	return float(cfg.get("camp_radius_m", 12.0)) * sqrt(maxf(count, 1.0) / 4.0) + 6.0


## Кучка палаток от центра c: следующая — рядом со случайной уже стоящей, зазор gap_m.
static func _grow(
	ctx: _Ctx, c: Vector2, count: int, rng: RandomNumberGenerator
) -> Array[Dictionary]:
	var cfg := ctx.cfg
	var gap: Array = cfg.gap_m
	var camp_r := camp_radius(cfg, count)
	var placed: Array[Dictionary] = []
	# цвета — перемешанная палитра по кругу: все разные, пока не кончатся
	var palette: Array = range((cfg.colors as Array).size())
	for i in range(palette.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: int = palette[i]
		palette[i] = palette[j]
		palette[j] = tmp
	for i in count:
		var type := _pick_type(cfg, rng, placed)
		var r := float(cfg.types[type].radius_m)
		var ok := false
		for attempt in int(cfg.get("attempts", 40)):
			var p := c
			if not placed.is_empty():
				var a: Dictionary = placed[rng.randi_range(0, placed.size() - 1)]
				var g := lerpf(float(gap[0]), float(gap[1]), pow(rng.randf(), 1.6))
				var ang := rng.randf() * TAU
				p = a.xz + Vector2(cos(ang), sin(ang)) * (float(a.radius) + r + g)
			elif attempt > 0:
				p = c + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 4.0
			if p.distance_to(c) > camp_r:
				continue
			if not _clear_of(placed, p, r, float(gap[0])):
				continue
			if not ctx.is_free(p, r) or ctx.slope_deg(p, r) > ctx.max_slope:
				continue
			if ctx.slope_deg(p, r + float(cfg.get("cliff_probe_m", 4.0))) > ctx.cliff_slope:
				continue
			(
				placed
				. append(
					{
						"type": type,
						"xz": p,
						"radius": r,
						"yaw": _pick_yaw(ctx, rng),
						"color": palette[placed.size() % palette.size()],
					}
				)
			)
			ok = true
			break
		if not ok and placed.is_empty():
			return placed
	return placed


static func _clear_of(placed: Array[Dictionary], p: Vector2, r: float, gap: float) -> bool:
	for t in placed:
		if p.distance_to(t.xz) < float(t.radius) + r + gap:
			return false
	return true


## Тип по весам; тентов-навесов не больше доли max_share (по одному на ~4 палатки).
static func _pick_type(cfg: Dictionary, rng: RandomNumberGenerator, placed: Array) -> String:
	var types: Dictionary = cfg.types
	var total := 0.0
	var allowed: Array[String] = []
	for k: String in types:
		if k.begins_with("_"):
			continue
		var cap := float(types[k].get("max_share", 1.0))
		var have := placed.filter(func(t: Dictionary) -> bool: return t.type == k).size()
		if have + 1 > maxf(1.0, ceilf(cap * (placed.size() + 1))):
			continue
		allowed.append(k)
		total += float(types[k].weight)
	var x := rng.randf() * total
	for k in allowed:
		x -= float(types[k].weight)
		if x <= 0.0:
			return k
	return allowed[-1] if not allowed.is_empty() else "dome2"


## Поворот входа: чаще спиной к ветру (вход по ветру, с разбросом), иногда боком или как попало.
static func _pick_yaw(ctx: _Ctx, rng: RandomNumberGenerator) -> float:
	var cfg := ctx.cfg
	# ветер дует в склон — из курса старта, т. е. в сторону −fwd: подветренная сторона — −fwd
	var down := -ctx.fwd
	var base := atan2(-down.x, -down.y)  # вход модели — −Z; yaw так, чтобы −Z смотрел в down
	var x := rng.randf()
	var spread := deg_to_rad(float(cfg.get("yaw_spread_deg", 45.0)))
	if x < float(cfg.get("downwind_share", 0.6)):
		return base + rng.randf_range(-spread, spread)
	if x < float(cfg.get("downwind_share", 0.6)) + float(cfg.get("side_share", 0.25)):
		return base + (PI / 2 if rng.randf() < 0.5 else -PI / 2) + rng.randf_range(-0.4, 0.4)
	return rng.randf() * TAU


## Узел лагеря: Node3D с палатками (LOD0/LOD1 — visibility range, цвет — материалы).
static func build_node(tents: Array, cfg: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Camp"
	var lod_m := float(cfg.get("lod_m", 70.0))
	var vis_m := float(cfg.get("visibility_m", 900.0))
	var shadows := bool(cfg.get("cast_shadows", true))
	var colors: Array = cfg.colors
	for i in tents.size():
		var t: Dictionary = tents[i]
		var node := Node3D.new()
		node.name = "Tent_%d_%s" % [i, t.type]
		node.transform = Transform3D(t.basis, t.position)
		root.add_child(node)
		for lod in 2:
			var mesh := mesh_for(String(t.type), lod)
			if mesh == null:
				continue
			var mi := MeshInstance3D.new()
			mi.name = "LOD%d" % lod
			mi.mesh = mesh
			mi.visibility_range_begin = 0.0 if lod == 0 else lod_m
			mi.visibility_range_end = lod_m if lod == 0 else vis_m
			mi.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if shadows
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			var ci := int(t.color) % colors.size()
			for s in mesh.get_surface_count():
				var m := mesh.surface_get_material(s)
				if m != null and String(m.resource_name) in TINTED:
					mi.set_surface_override_material(s, _tinted(m, ci, colors[ci], cfg))
			node.add_child(mi)
	return root


## Меш типа палатки и LOD из tents.glb (null — нет модели).
static func mesh_for(type: String, lod: int) -> Mesh:
	if _meshes.is_empty():
		if not ResourceLoader.exists(MODEL_PATH):
			push_warning("TentCamp: нет модели %s" % MODEL_PATH)
			return null
		var inst := (load(MODEL_PATH) as PackedScene).instantiate()
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			_meshes[String(mi.name)] = (mi as MeshInstance3D).mesh
		inst.free()
	return _meshes.get("%s_LOD%d" % [type, lod])


static func _tinted(base: Material, ci: int, rgb: Array, cfg: Dictionary) -> Material:
	var key := "%s|%d" % [base.resource_name, ci]
	if _materials.has(key):
		return _materials[key]
	var m := base.duplicate() as BaseMaterial3D
	if m == null:
		return base
	var c := Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
	if String(base.resource_name) == "Door":
		c = c.darkened(float(cfg.get("door_darken", 0.35)))
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[key] = m
	return m


## Контекст проверок места (оси старта, рельеф, запреты).
class _Ctx:
	var s: Vector2
	var fwd: Vector2
	var right: Vector2
	var cfg: Dictionary
	var height_fn: Callable
	var blocked_fn: Callable
	var lines: Array
	var points: Array
	var zone: Dictionary
	var max_slope: float
	var cliff_slope: float
	var ahead_m: float
	var point_margin: float

	func _init(start: Vector3, heading_deg: float, c: Dictionary, env: Dictionary) -> void:
		s = Vector2(start.x, start.z)
		var h := TerrainGeo.heading_vector(heading_deg)
		fwd = Vector2(h.x, h.z).normalized()
		right = Vector2(-fwd.y, fwd.x)
		cfg = c
		height_fn = env.height_fn
		blocked_fn = env.get("blocked_fn", Callable())
		lines = env.get("lines", [])
		points = env.get("points", [])
		zone = env.get("zone", TentCamp.launch_zone(c))
		max_slope = float(c.get("max_slope_deg", 8.0))
		cliff_slope = float(c.get("cliff_slope_deg", 14.0))
		ahead_m = float(c.get("ahead_m", -5.0))
		point_margin = float(c.get("scatter_margin_m", 0.3))

	## Место свободно для круга радиуса r (вне зоны старта, троп, дорог, воды, леса, камней).
	func is_free(p: Vector2, r: float) -> bool:
		var v := p - s
		var along := v.dot(fwd)
		var lat := v.dot(right)
		if along > ahead_m - r:
			return false  # впереди линии старта — склон, коридор разбега
		if along > -float(zone.behind_m) - r and absf(lat) < float(zone.lateral_m) + r:
			return false  # места ожидания и подход ботов, разбег игрока
		for l: Array in lines:
			var pts: PackedVector2Array = l[0]
			if TentCamp.dist_to_polyline(p, pts) < float(l[1]) + r:
				return false
		for o: Vector3 in points:
			if p.distance_to(Vector2(o.x, o.y)) < o.z + r + point_margin:
				return false
		if blocked_fn.is_valid():
			for k in 5:
				var q := p if k == 0 else p + Vector2.from_angle(k * TAU / 4.0) * r
				if blocked_fn.call(q.x, q.y):
					return false
		return true

	## Лагерь виден с глаз пилота на старте (рельеф не заслоняет верх палаток).
	func seen_from_start(p: Vector2) -> bool:
		var a := Vector3(s.x, float(height_fn.call(s.x, s.y)) + 1.7, s.y)
		var b := Vector3(p.x, float(height_fn.call(p.x, p.y)) + 1.0, p.y)
		for k in range(1, 12):
			var q := a.lerp(b, k / 12.0)
			if float(height_fn.call(q.x, q.z)) > q.y:
				return false
		return true

	## Наибольший уклон от центра к 8 точкам на окружности радиуса r, град.
	func slope_deg(p: Vector2, r: float) -> float:
		var h0 := float(height_fn.call(p.x, p.y))
		var worst := 0.0
		for k in 8:
			var q := p + Vector2.from_angle(k * TAU / 8.0) * r
			worst = maxf(worst, absf(float(height_fn.call(q.x, q.y)) - h0))
		return rad_to_deg(atan2(worst, r))

	## Поставить палатку на землю: высота, наклон по рельефу, поворот.
	func finish(t: Dictionary) -> Dictionary:
		var p: Vector2 = t.xz
		var r := maxf(float(t.radius), 1.0)
		var hx1 := float(height_fn.call(p.x + r, p.y))
		var hx0 := float(height_fn.call(p.x - r, p.y))
		var hz1 := float(height_fn.call(p.x, p.y + r))
		var hz0 := float(height_fn.call(p.x, p.y - r))
		var n := Vector3(hx0 - hx1, 2.0 * r, hz0 - hz1).normalized()
		var yaw := float(t.yaw)
		var tilt := Basis(Quaternion(Vector3.UP, n))
		var y := float(height_fn.call(p.x, p.y)) - float(cfg.get("sink_m", 0.02))
		return {
			"type": t.type,
			"position": Vector3(p.x, y, p.y),
			"basis": tilt * Basis(Vector3.UP, yaw),
			"yaw": yaw,
			"color": t.color,
			"radius": t.radius,
		}


## Нельзя ставить палатку: лес (и кромка), вода, застройка, скалы, снег (Terrain.surface_at).
static func blocked_by_surface(x: float, z: float, terrain: Node) -> bool:
	var c := int(terrain.call(&"surface_at", x, z))
	if (
		c
		in [
			SurfaceLayer.FOREST,
			SurfaceLayer.WATER,
			SurfaceLayer.BUILT,
			SurfaceLayer.BARE,
			SurfaceLayer.SNOW
		]
	):
		return true
	return float(terrain.call(&"forest_at", x, z)) > 0.15


## Камни, кусты и отдельные деревья (RockScatter, ShrubScatter — дети Terrain) в радиусе r от c:
## [Vector3(x, z, радиус)] — палатка не на камне и не в кусте. Мельче min_size (камешки в траве) —
## не мешают: внутри палатки их не видно.
## cache — словарь тайлов между вызовами (соседние центры лагеря делят тайлы).
static func scatter_near(
	terrain: Node, c: Vector2, r: float, min_size: float = 0.6, cache: Dictionary = {}
) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for spec: Array in [
		["Rocks", "build_tile", ""],
		["Shrubs", "build_tile", ""],
		["Shrubs", "build_tree_tile", "trees"]
	]:
		var n := terrain.get_node_or_null(String(spec[0]))
		if n == null or not n.has_method(String(spec[1])):
			continue
		var ncfg: Variant = n.get("_cfg")
		if not ncfg is Dictionary:
			continue
		if String(spec[2]) != "":
			ncfg = (ncfg as Dictionary).get(spec[2], {})
		var tile := float((ncfg as Dictionary).get("tile_m", 96.0))
		for tz in range(floori((c.y - r) / tile), floori((c.y + r) / tile) + 1):
			for tx in range(floori((c.x - r) / tile), floori((c.x + r) / tile) + 1):
				var key := "%s|%s|%d|%d" % [spec[0], spec[1], tx, tz]
				if not cache.has(key):
					cache[key] = n.call(String(spec[1]), tx, tz)
				var d: Dictionary = cache[key]
				var xf: PackedFloat32Array = d.get("xf", PackedFloat32Array())
				var sz: PackedFloat32Array = d.get("size", PackedFloat32Array())
				for i in sz.size():
					var p := Vector2(xf[i * 12 + 3], xf[i * 12 + 11])
					if sz[i] >= min_size and p.distance_to(c) <= r:
						out.append(Vector3(p.x, p.y, sz[i] * 0.5))
	return out


## Расстояние от точки до ломаной, м.
static func dist_to_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	var best := INF
	for i in pts.size() - 1:
		best = minf(
			best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1]))
		)
	if pts.size() == 1:
		best = p.distance_to(pts[0])
	return best
