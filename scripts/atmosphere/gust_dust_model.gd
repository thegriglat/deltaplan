class_name GustDustModel
extends RefCounted
## Клубы пыли от порывов у земли — модель (без отрисовки). Порыв на 10 м выше порога сдувания
## над сухой открытой поверхностью (пашня, голая земля) поднимает клуб. Событие — функция
## (клетка мира, слот времени): детерминировано, не зависит от камеры и одинаково у всех в сети
## (порыв — WindModel.gust_unit, шум мира, бегущий с ветром). Камера лишь выбирает, какие клетки
## смотреть. Сила растёт с превышением порога. Сырая погода и неподходящая поверхность — пыли нет.

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
var force_wind: float = 0.0

var _wind: WindModel
var _dusty: Array = []
var _sigma_frac: float = 0.25
var _conv_k: float = 0.5
var _conv: float = 0.0
var _large_k: float = 0.6
var _wet: bool = false
var _offsets: Array[Vector2i] = []


func setup(cfg: Dictionary, weather: Dictionary, wind: WindModel) -> void:
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
	force_wind = float(cfg.force_wind_ms)
	_sigma_frac = float(cfg.gust_sigma_frac)
	_conv_k = float(cfg.conv_sigma_k)
	_large_k = float(cfg.gust_large_k)
	_dusty.clear()
	for c in cfg.dusty_surface_classes:
		_dusty.append(int(c))
	_wind = wind
	update_weather(cfg, weather)
	_build_offsets()


func update_weather(cfg: Dictionary, weather: Dictionary) -> void:
	_conv = float(weather.get("convective_turbulence_ms", 0.0))
	_wet = bool(weather.get("wet", false)) or (cfg.wet_skies as Array).has(
		String(weather.get("sky", "clear"))
	)


func is_wet() -> bool:
	return _wet


## Сухая пылящая поверхность?
func is_dusty_class(c: int) -> bool:
	return _dusty.has(c)


func mean_wind10() -> float:
	return force_wind if force_wind > 0.0 else _wind.speed_at(10.0)


## Порыв (скорость ветра вдоль среднего, м/с) на 10 м в точке мира в момент t.
func gust_ms(x: float, z: float, t: float) -> float:
	var u := mean_wind10()
	var sigma := sqrt(pow(_sigma_frac * u, 2.0) + pow(_conv_k * _conv, 2.0))
	var g := _wind.gust_unit(Vector3(x, 10.0, z), t, u, _large_k)
	return maxf(u + sigma * (g.x * _wind.dir.x + g.z * _wind.dir.z), 0.0)


## Сила 0..1 по порыву: 0 — не выше порога.
func strength(gust: float) -> float:
	return clampf((gust - threshold) / span, 0.0, 1.0)


## Событие клетки (cx, cz) в слоте: {} или {t0, life, pos (x, z — y ставит вызывающий), k, h, n,
## cls, key}. surface_fn(x, z) -> класс поверхности (пустой — считать пашней).
func event(cx: int, cz: int, slot: int, surface_fn: Callable) -> Dictionary:
	if not enabled or _wet:
		return {}
	var x := (float(cx) + 0.1 + 0.8 * _hash(cx, cz, slot, 1)) * cell_m
	var z := (float(cz) + 0.1 + 0.8 * _hash(cx, cz, slot, 2)) * cell_m
	var t0 := (float(slot) + _hash(cx, cz, slot, 3)) * slot_s
	var k := strength(gust_ms(x, z, t0))
	if k <= 0.0:
		return {}
	if _hash(cx, cz, slot, 4) >= lerpf(float(chance[0]), float(chance[1]), k):
		return {}
	var cls := 3
	if surface_fn.is_valid():
		cls = int(surface_fn.call(x, z))
	if not _dusty.has(cls):
		return {}
	return {
		"t0": t0,
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
	_offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.length_squared() < b.length_squared())


static func _hash(a: int, b: int, c: int, salt: int) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791) ^ (salt * 2654435761)
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0
