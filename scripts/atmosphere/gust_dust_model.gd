class_name GustDustModel
extends RefCounted
## Клубы пыли от порывов у земли — модель (без отрисовки). Порыв на 10 м выше порога сдувания
## над сухой открытой поверхностью (пашня, голая земля) поднимает клуб. Событие — функция
## (клетка мира, слот времени): детерминировано, не зависит от камеры и одинаково у всех в сети
## (порыв — W2 surface_gust_many: шум мира, бегущий с ветром, считает крейт). Камера лишь выбирает,
## какие клетки смотреть. Сила растёт с превышением порога. Сырая погода и неподходящая
## поверхность — пыли нет. Событие делится на три шага: кандидаты клеток (точка и момент из хеша)
## -> пачка порывов одним вызовом -> событие по порыву (порог, шанс, поверхность).

var enabled: bool = true
var threshold: float = 7.5
var span: float = 6.0
var cell_m: float = 200.0
var slot_s: float = 4.0
var radius_m: float = 4000.0
var chance: Array = [0.12, 0.7]
var life: Array = [5.0, 15.0]
var height: Array = [3.0, 30.0]
var puffs_max: int = 6

var _dusty: Array = []
var _wet: bool = false
var _offsets: Array[Vector2i] = []


func setup(cfg: Dictionary, weather: Dictionary) -> void:
	enabled = bool(cfg.enabled)
	threshold = float(cfg.threshold_ms)
	span = maxf(float(cfg.span_ms), 0.1)
	cell_m = float(cfg.cell_m)
	slot_s = float(cfg.slot_s)
	radius_m = float(cfg.radius_m)
	chance = cfg.chance
	life = cfg.life_s
	height = cfg.height_m
	puffs_max = int(cfg.puffs_max)
	_dusty.clear()
	for c in cfg.dusty_surface_classes:
		_dusty.append(int(c))
	update_weather(cfg, weather)
	_build_offsets()


func update_weather(cfg: Dictionary, weather: Dictionary) -> void:
	_wet = bool(weather.get("wet", false)) or (cfg.wet_skies as Array).has(
		String(weather.get("sky", "clear"))
	)


func is_wet() -> bool:
	return _wet


## Сухая пылящая поверхность?
func is_dusty_class(c: int) -> bool:
	return _dusty.has(c)


## Сила 0..1 по порыву: 0 — не выше порога.
func strength(gust: float) -> float:
	return clampf((gust - threshold) / span, 0.0, 1.0)


## Кандидат клетки (cx, cz) в слоте: точка порыва и момент старта из хеша (не зависят от ветра).
## {x, z, t0} — порыв в нём считается пачкой (surface_gust_many) вне модели.
func candidate(cx: int, cz: int, slot: int) -> Dictionary:
	return {
		"x": (float(cx) + 0.1 + 0.8 * _hash(cx, cz, slot, 1)) * cell_m,
		"z": (float(cz) + 0.1 + 0.8 * _hash(cx, cz, slot, 2)) * cell_m,
		"t0": (float(slot) + _hash(cx, cz, slot, 3)) * slot_s,
	}


## События клеток слота пачкой: cells — Array[Vector2i]; gust_fn(xz: PackedVector2Array,
## t: PackedFloat64Array) -> PackedFloat32Array (порыв на 10 м, м/с; обычно
## Atmosphere.surface_gust_many),
## вызывается один раз на пачку. Результат — события (для клеток без события — {}) по порядку cells.
## surface_fn(x, z) -> класс поверхности (пустой — считать пашней).
func events(
	cells: Array[Vector2i], slot: int, surface_fn: Callable, gust_fn: Callable
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.resize(cells.size())
	for i in out.size():
		out[i] = {}
	if not enabled or _wet or cells.is_empty():
		return out
	var xz := PackedVector2Array()
	var ts := PackedFloat64Array()
	var cand: Array[Dictionary] = []
	for c in cells:
		var cd := candidate(c.x, c.y, slot)
		cand.append(cd)
		xz.append(Vector2(float(cd.x), float(cd.z)))
		ts.append(float(cd.t0))
	var gusts: PackedFloat32Array = gust_fn.call(xz, ts)
	for i in cells.size():
		if i < gusts.size():
			out[i] = _event(cells[i].x, cells[i].y, slot, cand[i], float(gusts[i]), surface_fn)
	return out


## Событие одной клетки (пачка из одного): {} или {t0, life, x, z, k, h, n, cls, seed}.
func event(cx: int, cz: int, slot: int, surface_fn: Callable, gust_fn: Callable) -> Dictionary:
	var cells: Array[Vector2i] = [Vector2i(cx, cz)]
	return events(cells, slot, surface_fn, gust_fn)[0]


## Событие по порыву в точке кандидата: {} или {t0, life, x, z, k, h, n, cls, seed}.
func _event(
	cx: int, cz: int, slot: int, cd: Dictionary, gust: float, surface_fn: Callable
) -> Dictionary:
	var k := strength(gust)
	if k <= 0.0:
		return {}
	if _hash(cx, cz, slot, 4) >= lerpf(float(chance[0]), float(chance[1]), k):
		return {}
	var x: float = cd.x
	var z: float = cd.z
	var cls := 3
	if surface_fn.is_valid():
		cls = int(surface_fn.call(x, z))
	if not _dusty.has(cls):
		return {}
	return {
		"t0": cd.t0,
		"life": lerpf(float(life[0]), float(life[1]), k) * (0.8 + 0.4 * _hash(cx, cz, slot, 5)),
		"x": x,
		"z": z,
		"k": k,
		"h": lerpf(float(height[0]), float(height[1]), k) * (0.8 + 0.4 * _hash(cx, cz, slot, 6)),
		"n": 3 + int(round(k * float(puffs_max - 3))),
		"cls": cls,
		"seed": _hash(cx, cz, slot, 7),
	}


func slot_of(t: float) -> int:
	return int(floor(t / slot_s))


## Сколько слотов назад ещё может жить клуб.
func lookback_slots() -> int:
	return int(ceil(float(life[1]) * 1.2 / slot_s)) + 1


## Смещения клеток в радиусе, ближние первыми.
func offsets() -> Array[Vector2i]:
	return _offsets


func _build_offsets() -> void:
	_offsets.clear()
	var r := int(ceil(radius_m / cell_m))
	for i in range(-r, r + 1):
		for j in range(-r, r + 1):
			if Vector2(i, j).length() * cell_m <= radius_m:
				_offsets.append(Vector2i(i, j))
	_offsets.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool: return a.length_squared() < b.length_squared()
	)


static func _hash(a: int, b: int, c: int, salt: int) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791) ^ (salt * 2654435761)
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0
