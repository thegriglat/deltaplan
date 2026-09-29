class_name AirFieldSet
extends RefCounted
## Набор уровней среднего поля (масштаб 1) для выборки на CPU и плавная подмена поля
## (docs/air_model.md → «Поле на CPU»). Уровни — от мелкого к грубому (клипмапы AM-04: окна
## 50/100 м, область 400 м); сейчас обычно один. Выборка: мелкий уровень с весом края w₁, остаток
## (1 − w₁) — следующему, …; что не покрыто ни одним уровнем — аналитике (вес поля < 1).
## Подмена (set_field): новое поле за blend_s секунд времени атмосферы смешивается со старым
## (доля нового — smoothstep по времени, монотонно); старое — набор уровней или «нет поля»
## (аналитика), так же плавно и выключение (set_field([], blend_s)). Подмена во время подмены:
## «старым» становится снимок текущей смеси (C8 v2) — выборка не скачет.

const MAX_OLD := 3
const OLD_MIN_W := 1.0e-3

var levels: Array[WindField] = []
## Ограничители, применяются к каждому новому полю (air_model.max_speed_ms, max_w_ms).
var max_speed: float = 40.0
var max_w: float = 10.0
## Ширина полосы края, клеток (air_model.edge_blend_cells) — ставится каждому уровню.
var edge_cells: float = 5.0

## «Старое» поле подмены — смесь наборов уровней: [[уровни, вес], …], Σ весов = 1 (снимок смеси
## на момент set_field; наборов не больше MAX_OLD, доли < OLD_MIN_W отбрасываются).
var _old: Array = []
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
	if blend_s > 0.0 and (not levels.is_empty() or not lv.is_empty() or _blend_total > 0.0):
		_old = _snapshot()
		_blend_total = blend_s
		_blend_t = 0.0
	else:
		_old = []
		_blend_total = 0.0
	levels = lv


## Снимок текущей смеси (старое × (1 − s) + текущие уровни × s) — «старое» новой подмены.
func _snapshot() -> Array:
	var s := blend_fraction()
	var out: Array = []
	if _blend_total > 0.0:
		for part: Array in _old:
			out.append([part[0], float(part[1]) * (1.0 - s)])
		out.append([levels, s])
	else:
		out.append([levels, 1.0])
	out = out.filter(_heavy)
	# не больше MAX_OLD наборов: самые лёгкие отбросить (остаток ≤ их доли)
	out.sort_custom(_heavier)
	out.resize(mini(out.size(), MAX_OLD))
	var total := 0.0
	for part: Array in out:
		total += float(part[1])
	for part: Array in out:
		part[1] = float(part[1]) / maxf(total, 1.0e-9)
	return out


static func _heavy(part: Array) -> bool:
	return float(part[1]) >= OLD_MIN_W


static func _heavier(a: Array, b: Array) -> bool:
	return float(a[1]) > float(b[1])


## Продвинуть подмену на dt секунд.
func advance(dt: float) -> void:
	if _blend_total <= 0.0:
		return
	_blend_t += dt
	if _blend_t >= _blend_total:
		_blend_total = 0.0
		_old = []


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
	var old := Vector4.ZERO
	for part: Array in _old:
		old += _sample_levels(part[0], pos, ground_h) * float(part[1])
	return old.lerp(cur, blend_fraction())


## θ′ (К), взвешенная долей поля: Vector2(Σ вклад, доля).
func sample_theta(pos: Vector3, ground_h: float) -> Vector2:
	return _scalar(pos, ground_h, false)


## w_conv (м/с), взвешенная долей поля: Vector2(Σ вклад, доля). Пилоту напрямую не отдаётся.
func sample_w_conv(pos: Vector3, ground_h: float) -> Vector2:
	return _scalar(pos, ground_h, true)


## Величины пограничного слоя для масштаба 3 (WindField.turb_at, AM-08), среднее по уровням с их
## весами (не умножено на долю): массив WindField.T_SIZE + 1, последнее — доля поля 0..1.
## N² = NAN, если хоть у одного участвующего уровня нет meta.gam. Нет поля — все нули.
func sample_turb(pos: Vector3, ground_h: float) -> PackedFloat32Array:
	var cur := _turb_levels(levels, pos, ground_h)
	if _blend_total <= 0.0:
		return cur
	# среднее по наборам снимка «старого» и новому с весами (вес набора × его доля поля)
	var s := blend_fraction()
	var wn := cur[WindField.T_SIZE] * s
	var tot := wn
	for q in WindField.T_SIZE:
		cur[q] *= wn
	for part: Array in _old:
		var old := _turb_levels(part[0], pos, ground_h)
		var wo := old[WindField.T_SIZE] * float(part[1]) * (1.0 - s)
		tot += wo
		for q in WindField.T_SIZE:
			cur[q] += old[q] * wo
	if tot <= 0.0:
		return _turb_levels(levels, pos, ground_h)
	for q in WindField.T_SIZE:
		cur[q] /= tot
	cur[WindField.T_SIZE] = tot
	return cur


static func _turb_levels(lv: Array[WindField], pos: Vector3, ground_h: float) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(WindField.T_SIZE + 1)
	var rem := 1.0
	for f in lv:
		var wgt := f.edge_weight(pos)
		if wgt <= 0.0:
			continue
		var t := f.turb_at(pos, ground_h)
		var k := rem * wgt
		for q in WindField.T_SIZE:
			acc[q] += t[q] * k
		rem *= 1.0 - wgt
		if rem <= 0.0:
			break
	var share := 1.0 - rem
	if share > 0.0:
		for q in WindField.T_SIZE:
			acc[q] /= share
	acc[WindField.T_SIZE] = share
	return acc


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
	var old := Vector2.ZERO
	for part: Array in _old:
		old += _scalar_levels(part[0], pos, ground_h, conv) * float(part[1])
	return old.lerp(cur, blend_fraction())


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
