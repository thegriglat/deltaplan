class_name VillagePlacer
extends RefCounted
## Дома посёлков (NO-2, контракт N3, docs/contracts/no-osm.md): процедурно внутри пятен застройки WorldCover
## (BuiltPatches). Без нод и без глобального RNG: одинаково у всех при одном месте.
## plan() → Array записей дома [x, z, w, l, угол_град, высота_стен_м, крыша] (формат BuildingPlacer).
## Параметры — configs/world_objects.json → villages.

const TYPE_HOUSE := 0
const TYPE_SHED := 1
const TYPE_BANYA := 2

## Кеш на (ключ места, путь данных): план считается и для расстановки, и для маски просек.
static var _cache: Dictionary = {}


## Пятна места по каталогу данных (без живой ноды Terrain) — для маски просек и build() без Terrain.
static func patches_for_dir(dir: String) -> BuiltPatches:
	return BuiltPatches.for_dir(dir)


## Дома места. loc_key — ключ места (идёт в rng), height_fn(x, z) -> высота, м.
## Результат кешируется по loc_key (место не меняется в процессе).
static func plan(
	patches: BuiltPatches, loc_key: String, vcfg: Dictionary, height_fn: Callable
) -> Array:
	if patches == null or patches.source == "none" or not bool(vcfg.get("enabled", true)):
		return []
	var ck := loc_key + "|" + str(patches.get_instance_id())
	if _cache.has(ck):
		return _cache[ck]
	var out := _plan_uncached(patches, loc_key, vcfg, height_fn)
	if _cache.size() > 4:
		_cache.clear()
	_cache[ck] = out
	return out


static func _plan_uncached(
	patches: BuiltPatches, loc_key: String, vcfg: Dictionary, height_fn: Callable
) -> Array:
	var out: Array = []
	var yard := float(vcfg.yard_m2)
	var step := sqrt(yard)
	var min_share := float(vcfg.min_share)
	var max_slope := tan(deg_to_rad(float(vcfg.max_slope_deg)))
	var align_slope := tan(deg_to_rad(float(vcfg.slope_align_deg)))
	var types: Dictionary = vcfg.types
	var taken := {}  # клетки сетки дворов, уже обработанные более ранним пятном
	var key_hash := hash(loc_key)
	var list := patches.patches()
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.id) < int(b.id))
	for p in list:
		var bb: Rect2 = p.bbox
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([key_hash, int(p.id)])
		var base_ang := rng.randf() * 180.0
		var i0 := floori(bb.position.x / step)
		var i1 := floori(bb.end.x / step)
		var j0 := floori(bb.position.y / step)
		var j1 := floori(bb.end.y / step)
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				# три случайных числа на двор всегда, чтобы порядок rng не зависел от отбора
				var r_a := rng.randf()
				var r_b := rng.randf()
				var r_c := rng.randf()
				var r_d := rng.randf()
				var r_e := rng.randf()
				var r_f := rng.randf()
				var r_g := rng.randf()
				var gk := Vector2i(i, j)
				if taken.has(gk):
					continue
				var x := (i + 0.15 + 0.7 * r_a) * step
				var z := (j + 0.15 + 0.7 * r_b) * step
				var sh := patches.share_at(x, z)
				if sh < min_share:
					continue
				taken[gk] = true
				if r_c > sh * float(vcfg.fill):  # плотность по доле застройки
					continue
				# рельеф: уклон и направление горизонтали
				var gx := (float(height_fn.call(x + 5.0, z)) - float(height_fn.call(x - 5.0, z))) / 10.0
				var gz := (float(height_fn.call(x, z + 5.0)) - float(height_fn.call(x, z - 5.0))) / 10.0
				var slope := Vector2(gx, gz).length()
				if slope > max_slope:
					continue
				# разворот: вдоль горизонтали на склоне; параллельно краю пятна у края; иначе — общий по пятну
				var ang: float
				if slope > align_slope:
					ang = rad_to_deg(atan2(gx, -gz)) + 90.0  # горизонталь ⟂ градиенту
				else:
					var ex := patches.share_at(x + 10.0, z) - patches.share_at(x - 10.0, z)
					var ez := patches.share_at(x, z + 10.0) - patches.share_at(x, z - 10.0)
					if Vector2(ex, ez).length() > float(vcfg.edge_grad_min):
						ang = rad_to_deg(atan2(ex, -ez)) + 90.0
					else:
						ang = base_ang
				ang = fposmod(ang + (r_d - 0.5) * float(vcfg.angle_jitter_deg), 180.0)
				var h := _make(types.house, r_e, r_f, ang, x, z, 0)
				out.append(h)
				var rot := deg_to_rad(ang)
				var ax := Vector2(cos(rot), sin(rot))  # локальная x-ось дома в мире (x, z)
				if r_g < float(vcfg.shed_prob):
					_outbuilding(out, h, ax, types.shed, rng, patches, 1.0, height_fn, max_slope)
				if rng.randf() < float(vcfg.banya_prob):
					_outbuilding(out, h, ax, types.banya, rng, patches, -1.0, height_fn, max_slope)
	return out


## Запись дома выбранного типа: размеры в диапазонах конфига (u, v ∈ 0..1), высота стен, крыша.
static func _make(ty: Dictionary, u: float, v: float, ang: float, x: float, z: float, kind: int) -> Array:
	var w: Array = ty.width_m
	var l: Array = ty.length_m
	var hh: Array = ty.wall_height_m
	return [
		x,
		z,
		lerpf(float(w[0]), float(w[1]), u),
		lerpf(float(l[0]), float(l[1]), v),
		ang,
		lerpf(float(hh[0]), float(hh[1]), (u + v) * 0.5),
		int(ty.roof),
	]


## Хозпостройка рядом с домом: сбоку (side = ±1) вдоль его оси, без наложения; остаётся внутри пятна.
static func _outbuilding(
	out: Array, house: Array, ax: Vector2, ty: Dictionary, rng: RandomNumberGenerator,
	patches: BuiltPatches, side: float, height_fn: Callable, max_slope: float
) -> void:
	var ang := float(house[4])
	var b := _make(ty, rng.randf(), rng.randf(), ang, 0.0, 0.0, 0)
	var gap := 1.5 + rng.randf() * 3.0
	var along := (float(house[2]) + float(b[2])) * 0.5 + gap
	var off := Vector2(float(house[0]), float(house[1])) + ax * along * side
	if patches.share_at(off.x, off.y) <= 0.0:
		return
	var gx := (float(height_fn.call(off.x + 5.0, off.y)) - float(height_fn.call(off.x - 5.0, off.y))) / 10.0
	var gz := (float(height_fn.call(off.x, off.y + 5.0)) - float(height_fn.call(off.x, off.y - 5.0))) / 10.0
	if Vector2(gx, gz).length() > max_slope:
		return
	b[0] = off.x
	b[1] = off.y
	out.append(b)
