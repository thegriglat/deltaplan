class_name WingPolar
extends RefCounted
## Поляра крыла в безразмерном виде: таблица CL→CD.
##
## Строится из точек (воздушная скорость, снижение) при эталонной массе и плотности:
## CL = 2·M·g·cosγ / (ρ·S·V²), CD = CL·tgγ, sinγ = снижение / V. В безразмерном виде
## поляра не зависит от массы и высоты — они входят через ρ и M при расчёте скоростей.

## Коэффициент подъёмной силы на скорости сваливания (первая точка поляры).
var cl_max: float = 0.0

var _cl: PackedFloat64Array = []
var _cd: PackedFloat64Array = []
var _cd0: float = 0.0
var _k: float = 0.0


## points — пары [км/ч, м/с], mass_ref — полная эталонная масса, кг.
func _init(points: Array, mass_ref: float, rho_ref: float, area: float) -> void:
	var pairs: Array = []
	for p: Array in points:
		var v := Units.kmh(float(p[0]))
		var sin_g := float(p[1]) / v
		var cos_g := sqrt(1.0 - sin_g * sin_g)
		var cl := 2.0 * mass_ref * Units.G * cos_g / (rho_ref * area * v * v)
		pairs.append([cl, cl * sin_g / cos_g])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for p: Array in pairs:
		_cl.append(p[0])
		_cd.append(p[1])
	cl_max = _cl[_cl.size() - 1]
	# быстрее самой быстрой точки — парабола CD = CD0 + k·CL² по двум крайним точкам
	var c1 := _cl[0]
	var c2 := _cl[1]
	_k = maxf((_cd[1] - _cd[0]) / (c2 * c2 - c1 * c1), 0.0)
	_cd0 = _cd[0] - _k * c1 * c1


## Коэффициент сопротивления при данном CL (присоединённый поток).
func cd_at(cl: float) -> float:
	var n := _cl.size()
	if cl <= _cl[0]:
		return _cd0 + _k * cl * cl
	if cl >= _cl[n - 1]:
		var slope := (_cd[n - 1] - _cd[n - 2]) / (_cl[n - 1] - _cl[n - 2])
		return _cd[n - 1] + slope * (cl - _cl[n - 1])
	var i := _cl.bsearch(cl)
	var t := (cl - _cl[i - 1]) / (_cl[i] - _cl[i - 1])
	return lerpf(_cd[i - 1], _cd[i], t)
