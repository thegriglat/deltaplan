class_name XcCircleFit
extends RefCounted
## Центровка термика по первой гармонике (карточка 07, как ThermalAssistant): за последний полный
## круг подъём ≈ n̄ + g·(p − C), МНК даёт градиент g; перепад по кругу a = |g|·r. Для профиля
## ядра (1 − x²)·e^(−x²) при смещении d от оси перепад ∝ d, поэтому центр круга сдвигаем к
## сильной стороне на shift_per_ms·a·r (не больше shift_max_r·r за раз). Весь круг — фильтр
## болтанки; позиции — с запаздыванием отклика вариометра. Пересчёт раз в полкруга.

## Сдвиг центра круга, радиусов круга на 1 м/с перепада подъёма по кругу; предел за раз, радиусов.
var shift_per_ms: float = 2.0
var shift_max_r: float = 2.0

## Есть оценка; куда сдвигать центр круга (x, z); нетто сильной стороны (n̄ + a) и перепад a, м/с.
var ok: bool = false
var target: Vector2 = Vector2.ZERO
var peak: float = -INF
var amp: float = 0.0

var _pos: PackedVector2Array = PackedVector2Array()
var _n: PackedFloat32Array = PackedFloat32Array()
var _turn: PackedFloat32Array = PackedFloat32Array()
var _total: float = 0.0
var _half: float = 0.0


## Новый термик: начальная цель (место сильного подъёма), ok — считать ли её оценкой.
func reset(start_target: Vector2, start_ok: bool) -> void:
	_pos.clear()
	_n.clear()
	_turn.clear()
	_total = 0.0
	_half = 0.0
	target = start_target
	ok = start_ok
	peak = -INF
	amp = 0.0


## Отсчёт: позиция (с запаздыванием), нетто, м/с; dh — на сколько повернули с прошлого, °.
func add(pos: Vector2, netto: float, dh: float) -> void:
	_total += dh
	_half += dh
	_pos.append(pos)
	_n.append(netto)
	_turn.append(_total)
	if _total >= 360.0 and _half >= 180.0:
		_half = 0.0
		_update()


func _update() -> void:
	var n := _turn.size()
	var i0 := _turn.bsearch(_total - 360.0)
	var m := n - i0
	if m < 8:
		return
	var c := Vector2.ZERO
	var nb := 0.0
	for i in range(i0, n):
		c += _pos[i]
		nb += _n[i]
	c /= m
	nb /= m
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var b := Vector2.ZERO
	var r := 0.0
	for i in range(i0, n):
		var d := _pos[i] - c
		sxx += d.x * d.x
		sxy += d.x * d.y
		syy += d.y * d.y
		b += d * (_n[i] - nb)
		r += d.length()
	r /= m
	var det := sxx * syy - sxy * sxy
	if det < 1.0e-6 or r < 3.0:
		return
	var g := Vector2(syy * b.x - sxy * b.y, sxx * b.y - sxy * b.x) / det
	var a := g.length() * r
	var shift := minf(shift_per_ms * a * r, shift_max_r * r)
	target = c + g.normalized() * shift
	peak = nb + a
	amp = a
	ok = true
	# Держим только последний круг.
	_pos = _pos.slice(i0)
	_n = _n.slice(i0)
	_turn = _turn.slice(i0)
