class_name DustModel
extends RefCounted
## Пылевые вихри (VR-18) — строго из модели термика (VR-0): у основания МОЛОДОГО термика
## (стадия роста) над сухой поверхностью (пашня, голая земля — surface_fn) в солнечный день.
## Живут 10–60 с, дрейфуют со слабым приземным ветром, высота 20–200 м от силы термика.
## Детерминированно от id термика: один и тот же день — те же вихри.

var _chance: float = 0.0
var _min_strength: float = 2.0
var _life: Array = [10.0, 60.0]
var _height: Array = [20.0, 200.0]
var _dusty: Array = []
var _start_frac: float = 0.6
var _top_radius_frac: float = 0.15


func setup(dust_cfg: Dictionary, weather: Dictionary) -> void:
	_chance = float(weather.get("dust_devil_chance", 0.0))
	_min_strength = float(dust_cfg.min_strength_ms)
	_life = dust_cfg.life_s
	_height = dust_cfg.height_m
	# JSON-числа — float; классы поверхности — int.
	_dusty.clear()
	for c in dust_cfg.dusty_surface_classes:
		_dusty.append(int(c))
	_start_frac = float(dust_cfg.start_grow_frac)
	_top_radius_frac = float(dust_cfg.top_radius_frac)


## Вихрь у термика в момент t: {pos: Vector3 (на земле), height, radius, age 0..1, spin} или {}.
## surface_fn(x, z) -> класс поверхности (или пустой Callable — считать сухой везде).
func devil(th: AtmoThermal, t: float, surface_fn: Callable, wind: Vector2) -> Dictionary:
	if _chance <= 0.0 or th.is_static or th.strength < _min_strength:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = th.id * 7919 + 13
	if rng.randf() >= _chance:
		return {}
	var life := rng.randf_range(float(_life[0]), float(_life[1]))
	var start := th.t_birth + rng.randf() * th.t_grow * _start_frac
	var age := (t - start) / life
	if age < 0.0 or age > 1.0:
		return {}
	if surface_fn.is_valid() and not _dusty.has(int(surface_fn.call(th.src.x, th.src.z))):
		return {}
	var smax := 5.0
	var k := clampf((th.strength - _min_strength) / maxf(smax - _min_strength, 0.1), 0.0, 1.0)
	var h := lerpf(float(_height[0]), float(_height[1]), k) * rng.randf_range(0.7, 1.0)
	var drift := wind * (t - start)
	return {
		"pos": Vector3(th.src.x + drift.x, th.src.y, th.src.z + drift.y),
		"height": h,
		"radius": h * _top_radius_frac + 4.0,
		"age": age,
		"spin": 1.0 if rng.randf() < 0.5 else -1.0,
		"seed": float(th.id % 997),
	}
