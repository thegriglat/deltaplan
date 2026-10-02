class_name GustSpectrum
extends RefCounted
## Порывы со спектром фон Кармана (масштаб 3 с полем, AM-08; docs/guide/air-model.md → «Масштаб 3:
## возмущения из поля»). Сумма октав «замороженного» шума (симплекс без фрактала, переносится
## ветром — гипотеза Тейлора, как WindModel.gust_unit); вес октавы — дисперсия спектра фон Кармана
## с интегральным масштабом L в полосе этой октавы (MIL-HDBK-1797, п. 4.9.1/B.4.9: продольная форма
## для u, v, поперечная — для w). Масштабы L — функция места (высота, устойчивость) и меняются
## плавно: координаты шума не зависят от L, от L зависят только веса октав — поле непрерывно.
##
## Одна октава симплекс-шума с «масштабом» s — полосовой сигнал: пик k·S(k) на длине волны
## ≈ 1,75 s, короче s — спад круче k⁻⁹, длиннее — ровный хвост (замер
## tools/research/air_turb/noise_line.gd). Октавы s = S0·2^i — смежные полосы шириной в октаву
## вокруг 1,75 s. Масштабы длиннее верхней полосы (λ > √2·1,75·S0·2^(N−1) ≈ 2,5 км) октав нет —
## их доля дисперсии отдаётся октавам пропорционально (СКО шума = 1 при любом L): σ из физики
## пограничного слоя пилот получает целиком, спектр в инерционном интервале не меняется.

## Наименьший масштаб октавы, м, и число октав: полосы 14 м … 2,5 км.
const S0 := 8.0
const OCTAVES := 8
## Пик k·S одной октавы — на длине волны PEAK·s.
const PEAK := 1.75
## Таблица весов по L: от L_MIN до L_MAX, логарифмически.
const L_MIN := 2.0
const L_MAX := 4000.0
const L_STEPS := 64
## Коэффициент формы фон Кармана (MIL-HDBK-1797: 1,339).
const VK_A := 1.339

## Таблицы не зависят от сида — общие для всех (строятся один раз).
static var _wu := PackedFloat32Array()
static var _ww := PackedFloat32Array()
static var _inv_dl: float = 1.0

var _noise: FastNoiseLite
var _norm: float = 1.0
var _evolve: float = 0.0
## Смещения координат: октава × компонента (u, w, v).
var _off := PackedVector3Array()


func setup(seed_value: int, evolve_ms: float) -> void:
	_evolve = evolve_ms
	_noise = FastNoiseLite.new()
	_noise.seed = seed_value + 7919
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	_noise.frequency = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7919
	_off.resize(OCTAVES * 3)
	for i in OCTAVES * 3:
		_off[i] = Vector3(
			rng.randf_range(-5000, 5000), rng.randf_range(-5000, 5000), rng.randf_range(-5000, 5000)
		)
	var sum := 0.0
	for i in 4096:
		var v := _noise.get_noise_3d(
			rng.randf_range(-800, 800), rng.randf_range(-800, 800), rng.randf_range(-800, 800)
		)
		sum += v * v
	_norm = 1.0 / maxf(sqrt(sum / 4096.0), 1.0e-4)
	if _wu.is_empty():
		_build_tables()


## Доля дисперсии (из 1) каждой октавы для спектров фон Кармана с масштабом L: интеграл по
## полосе [k_p/√2, k_p·√2] (k_p = 2π/(PEAK·s)); мельче нижней и крупнее верхней полосы — не несём
## (шум нормируется на СКО 1 в sample).
static func _build_tables() -> void:
	_wu.resize(L_STEPS * OCTAVES)
	_ww.resize(L_STEPS * OCTAVES)
	_inv_dl = (L_STEPS - 1) / log(L_MAX / L_MIN)
	for li in L_STEPS:
		var el := L_MIN * exp(li / _inv_dl)
		for o in OCTAVES:
			var kp := TAU / (PEAK * S0 * pow(2.0, o))
			var k_hi := kp * sqrt(2.0)
			var k_lo := kp / sqrt(2.0)
			_wu[li * OCTAVES + o] = _band(el, k_lo, k_hi, false)
			_ww[li * OCTAVES + o] = _band(el, k_lo, k_hi, true)


## ∫ E(k) dk по [k_lo, k_hi] для нормированного (∫₀^∞ E = 1) спектра фон Кармана, k — рад/м:
## продольный E = (2L/π)/(1 + (aLk)²)^(5/6),
## поперечный E = (L/π)(1 + 8/3(aLk)²)/(1 + (aLk)²)^(11/6).
static func _band(el: float, k_lo: float, k_hi: float, transverse: bool) -> float:
	var n := 24
	var s := 0.0
	var r := log(k_hi / k_lo)
	for q in n:
		var k := k_lo * exp((q + 0.5) / n * r)
		var x := VK_A * el * k
		var x2 := x * x
		var e: float
		if transverse:
			e = el / PI * (1.0 + 8.0 / 3.0 * x2) / pow(1.0 + x2, 11.0 / 6.0)
		else:
			e = 2.0 * el / PI / pow(1.0 + x2, 5.0 / 6.0)
		s += e * k
	return s * r / n


## Пульсации в точке pos в момент t, СКО каждой компоненты 1: Vector3(a, w, c) — a, c — две
## независимые горизонтальные компоненты (потребитель кладёт их вдоль и поперёк ветра), w —
## вертикаль. Горизонталь — спектр фон Кармана с масштабом l_u; доля дисперсии f_a (у a) и f_c
## (у c) — со вторым масштабом l_2 (конвективные вихри ~z_i, AS-2): веса октав — смесь
## (1 − f)·W(l_u) + f·W(l_2), каждая нормирована на 1. Вертикаль — поперечный спектр с l_w.
## advect — скорость переноса поля (м/с) вдоль dir. Умножать на σ.
func sample(
	pos: Vector3, t: float, advect: float, dir: Vector3, l_u: float, l_w: float,
	l_2: float = 0.0, f_a: float = 0.0, f_c: float = 0.0
) -> Vector3:
	var p := Vector3(pos.x - dir.x * advect * t, pos.y + _evolve * t, pos.z - dir.z * advect * t)
	var wu := _weights(_wu, l_u)
	var ww := _weights(_ww, l_w)
	var w2 := wu
	if l_2 > 0.0 and (f_a > 0.0 or f_c > 0.0):
		w2 = _weights(_wu, l_2)
	var out := Vector3.ZERO
	var s := S0
	for o in OCTAVES:
		var aa := sqrt(lerpf(wu[o], w2[o], f_a))
		var ac := sqrt(lerpf(wu[o], w2[o], f_c))
		var aw := sqrt(ww[o])
		var q := p / s
		var j := o * 3
		if aa > 1.0e-3:
			var a := q + _off[j]
			out.x += aa * _noise.get_noise_3d(a.x, a.y, a.z)
		if ac > 1.0e-3:
			var c := q + _off[j + 2]
			out.z += ac * _noise.get_noise_3d(c.x, c.y, c.z)
		if aw > 1.0e-3:
			var b := q + _off[j + 1]
			out.y += aw * _noise.get_noise_3d(b.x, b.y, b.z)
		s *= 2.0
	return out * _norm


## Доли дисперсии октав для масштаба el (таблица tab — _wu или _ww), нормированные на сумму 1.
func _weights(tab: PackedFloat32Array, el: float) -> PackedFloat32Array:
	var b := _row(el)
	var f := b - floorf(b)
	var i := int(b) * OCTAVES
	var out := PackedFloat32Array()
	out.resize(OCTAVES)
	var sum := 0.0
	for o in OCTAVES:
		out[o] = lerpf(tab[i + o], tab[i + OCTAVES + o], f)
		sum += out[o]
	var k := 1.0 / maxf(sum, 1.0e-6)
	for o in OCTAVES:
		out[o] *= k
	return out


## Дробный номер строки таблицы для L (зажат в таблицу; последняя строка — только как пара).
func _row(el: float) -> float:
	var r := log(clampf(el, L_MIN, L_MAX) / L_MIN) * _inv_dl
	return minf(r, L_STEPS - 1.0001)


## Доля дисперсии (из 1), которую несут октавы при масштабе L: горизонталь, вертикаль.
func carried(el_u: float, el_w: float) -> Vector2:
	var bu := _row(el_u)
	var bw := _row(el_w)
	var su := 0.0
	var sw := 0.0
	for o in OCTAVES:
		su += lerpf(_wu[int(bu) * OCTAVES + o], _wu[int(bu) * OCTAVES + OCTAVES + o], bu - int(bu))
		sw += lerpf(_ww[int(bw) * OCTAVES + o], _ww[int(bw) * OCTAVES + OCTAVES + o], bw - int(bw))
	return Vector2(su, sw)
