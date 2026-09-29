class_name AirFieldSet
extends RefCounted
## Набор уровней среднего поля (масштаб 1) для выборки на CPU и плавная подмена поля
## (docs/air_model.md → «Поле на CPU»). Уровни — от мелкого к грубому (клипмапы AM-04: окна
## 50/100 м, область 400 м); сейчас обычно один. Выборка: мелкий уровень с весом края w₁, остаток
## (1 − w₁) — следующему, …; что не покрыто ни одним уровнем — аналитике (вес поля < 1).
## Подмена (set_field): новое поле за blend_s секунд времени атмосферы смешивается со старым
## (доля нового — smoothstep по времени, монотонно); старое — набор уровней или «нет поля»
## (аналитика), так же плавно и выключение (set_field([], blend_s)).

var levels: Array[WindField] = []
## Ограничители, применяются к каждому новому полю (air_model.max_speed_ms, max_w_ms).
var max_speed: float = 40.0
var max_w: float = 10.0
## Ширина полосы края, клеток (air_model.edge_blend_cells) — ставится каждому уровню.
var edge_cells: float = 5.0

var _prev: Array[WindField] = []
var _blend_total: float = 0.0
var _blend_t: float = 0.0


## Задать поле (WindField или Array[WindField] от мелкого к грубому; null / [] — без поля) и
## смешивать со старым blend_s секунд (≤ 0 — сразу).
func set_field(new_field: Variant, blend_s: float = 0.0) -> void:
	var lv: Array[WindField] = []
	if new_field is WindField:
		lv.append(new_field)
	elif new_field is Array:
		for f: Variant in new_field:
			if f is WindField:
				lv.append(f)
	for f in lv:
		f.clamp_values(max_speed, max_w)
		f.edge_cells = edge_cells
	if blend_s > 0.0 and (not levels.is_empty() or not lv.is_empty()):
		# подмена во время подмены: «старым» становится текущее смешение — берём то, что ближе
		_prev = levels if blend_fraction() >= 0.5 or _blend_total <= 0.0 else _prev
		_blend_total = blend_s
		_blend_t = 0.0
	else:
		_prev = []
		_blend_total = 0.0
	levels = lv


## Продвинуть подмену на dt секунд.
func advance(dt: float) -> void:
	if _blend_total <= 0.0:
		return
	_blend_t += dt
	if _blend_t >= _blend_total:
		_blend_total = 0.0
		_prev = []


## Доля нового поля в подмене 0..1 (1 — подмены нет).
func blend_fraction() -> float:
	if _blend_total <= 0.0:
		return 1.0
	return smoothstep(0.0, 1.0, _blend_t / _blend_total)


## Есть ли что выбирать (поле или идёт подмена).
func is_active() -> bool:
	return not levels.is_empty() or _blend_total > 0.0


## Точка покрыта хотя бы одним уровнем.
func contains(pos: Vector3) -> bool:
	for f in levels:
		if f.contains(pos):
			return true
	return false


## Скорость поля, взвешенная долей поля: (x, y, z) = Σ вклад уровней (мир, м/с; y — w_mech),
## w = доля поля 0..1. Итог для пилота: xyz + (1 − w)·аналитика.
func sample(pos: Vector3, ground_h: float) -> Vector4:
	var cur := _sample_levels(levels, pos, ground_h)
	if _blend_total <= 0.0:
		return cur
	var s := blend_fraction()
	return _sample_levels(_prev, pos, ground_h).lerp(cur, s)


## θ′ (К), взвешенная долей поля: Vector2(Σ вклад, доля).
func sample_theta(pos: Vector3, ground_h: float) -> Vector2:
	return _scalar(pos, ground_h, false)


## w_conv (м/с), взвешенная долей поля: Vector2(Σ вклад, доля). Пилоту напрямую не отдаётся.
func sample_w_conv(pos: Vector3, ground_h: float) -> Vector2:
	return _scalar(pos, ground_h, true)


static func _sample_levels(lv: Array[WindField], pos: Vector3, ground_h: float) -> Vector4:
	var acc := Vector3.ZERO
	var rem := 1.0
	for f in lv:
		var wgt := f.edge_weight(pos)
		if wgt <= 0.0:
			continue
		acc += f.sample(pos, ground_h) * (rem * wgt)
		rem *= 1.0 - wgt
		if rem <= 0.0:
			break
	return Vector4(acc.x, acc.y, acc.z, 1.0 - rem)


func _scalar(pos: Vector3, ground_h: float, conv: bool) -> Vector2:
	var cur := _scalar_levels(levels, pos, ground_h, conv)
	if _blend_total <= 0.0:
		return cur
	return _scalar_levels(_prev, pos, ground_h, conv).lerp(cur, blend_fraction())


static func _scalar_levels(
	lv: Array[WindField], pos: Vector3, ground_h: float, conv: bool
) -> Vector2:
	var acc := 0.0
	var rem := 1.0
	for f in lv:
		var wgt := f.edge_weight(pos)
		if wgt <= 0.0:
			continue
		var v := f.sample_w_conv(pos, ground_h) if conv else f.sample_theta(pos, ground_h)
		acc += v * rem * wgt
		rem *= 1.0 - wgt
		if rem <= 0.0:
			break
	return Vector2(acc, 1.0 - rem)
