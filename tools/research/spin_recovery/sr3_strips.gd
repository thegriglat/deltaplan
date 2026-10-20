class_name SR3Strips
extends PendulumWingStrips
## SR-3: наследник PendulumWingStrips — упоры концов (гипотеза 2) и C_L max концевых полос (гипотеза 4).
## Все правки выключены по умолчанию (n_tip = 0 или параметр отрицательный/1,0) — тогда расчёт идентичен игре (вариант strips_id).
## Полосы каждой консоли идут от корня (j = 0) к концу (j = n/2 − 1); крайние — j ≥ n/2 − n_tip.

var n_tip: int = 0  ## число крайних полос с каждой стороны, к которым применяются правки
var sprog_min_washout_deg: float = -1.0  ## упор: геометрический угол полосы ≤ угла корня консоли − это значение; < 0 — выкл.
var clmax_tip_k: float = 1.0  ## множитель C_L max крайних полос (потолок c_l), 1 — выкл.

var _twist_eff := PackedFloat64Array()
var sprog_active_max_deg: float = 0.0  ## макс. «срезанный» упором угол за прогон, ° (диагностика)


func _is_tip(j: int) -> bool:
	return n_tip > 0 and (j % (n / 2)) >= n / 2 - n_tip


## Упор: α_геом полосы = twist + (−side·billow_shift·λ·|y|) — тот же, что в aero базового класса. Если он выше предела
## (угол корня консоли − sprog_min_washout), лишнее срезается (модель нагруженного упора). Реализация — подмена twist
## на время вызова базового aero: twist в aero входит только в α полосы (setup уже отработал).
func aero(
	vel: Vector3, R: Basis, w: Vector3, air: PackedVector3Array, air_c: Vector3,
	billow_lam: float, rho: float, ge := PackedFloat64Array()
) -> void:
	if n_tip <= 0 or sprog_min_washout_deg < 0.0:
		super.aero(vel, R, w, air, air_c, billow_lam, rho, ge)
		return
	var wmin := deg_to_rad(sprog_min_washout_deg)
	var h := n / 2
	if _twist_eff.size() != n:
		_twist_eff.resize(n)
	var saved := twist
	_twist_eff = twist.duplicate()
	var shift := billow_shift * billow_lam
	var cut_max := 0.0
	for s in 2:
		var j0 := s * h
		var g_root := twist[j0] - side[j0] * shift * yabs[j0]
		var lim := g_root - wmin
		for j in range(h - n_tip, h):
			var i := j0 + j
			var g := twist[i] - side[i] * shift * yabs[i]
			if g > lim:
				_twist_eff[i] = twist[i] - (g - lim)
				cut_max = maxf(cut_max, g - lim)
	sprog_active_max_deg = maxf(sprog_active_max_deg, rad_to_deg(cut_max))
	twist = _twist_eff
	super.aero(vel, R, w, air, air_c, billow_lam, rho, ge)
	twist = saved


## Потолок c_l крайних полос × clmax_tip_k (cap — cl_max или критического сечения; срыв, Viterna и динамика — от него).
func _strip_cl(j: int, r: float, sl: float, cap: float, un := 0.0) -> Vector4:
	if clmax_tip_k != 1.0 and _is_tip(j):
		cap *= clmax_tip_k
	return super._strip_cl(j, r, sl, cap, un)
