class_name FieldTurbulence
extends RefCounted
## Масштаб 3 с полем воздуха (AM-08, docs/air_model.md → «Масштаб 3: возмущения из поля»):
## признак отрыва за гребнем, σ болтанки по u*, сдвигу, устойчивости и w* поля, болтанка слоя
## смешения, спектр порывов (GustSpectrum). Использует Atmosphere._air_velocity_field; величины
## поля — AirFieldSet.sample_turb (WindField.turb_at, контракт C4 v3).
## Коэффициенты — configs/atmosphere.json → turbulence.field_*, lee.field_* (источники в _doc);
## λ/h и толщина нейтрального слоя — AirCase.LAM_FRAC, NEUTRAL_BL_K (одни с решателем, AM-09б).

## Порывы со спектром фон Кармана.
var gusts: GustSpectrum
## Шероховатость поля (z0 уровня), м.
var z0: float = 0.1
## Обратный поток в пузыре отрыва, доли U_H — ветра на уровне гребня (lee.field_reverse_per_uh).
var reverse: float = 0.22
## Рывки вниз в зоне отрыва, доли ΔU (lee.field_burst_per_du).
var burst_per_du: float = 0.42
## Длина пузыря отрыва, доли превышения гребня (lee.field_bubble_length_per_relief).
var bubble_len: float = 2.8
## Разрешённость пузыря решателем: smoothstep(n0, n1, L/dx) (lee.field_resolved_cells).
var resolved_n0: float = 4.0
var resolved_n1: float = 8.0
## Масштаб вихрей зоны отрыва, доли превышения гребня (lee.field_eddy_scale_per_relief).
var sep_scale: float = 0.5

## Последний вызов sigma: σ поперёк ветра (м/с), доли конвективной дисперсии горизонтали вдоль и
## поперёк ветра (0..1) и их интегральный масштаб (м; 0 — нет).
var last_sv: float = 0.0
var last_fu_c: float = 0.0
var last_fv_c: float = 0.0
var last_l_c: float = 0.0

## Приземный слой — нижняя доля пограничного слоя (≈ 0,1 h, Stull 1988, §1.5): ниже u* болтанки
## согласован со средним ветром в точке.
const SURFACE_FRAC := 0.1
## σ_v/σ_w = 1 + V_ANISO·(σ_u/σ_w − 1): у земли 1,9/1,25 при σ_u/σ_w = 2,4/1,25 (Panofsky & Dutton
## 1984), выше — к изотропии вместе с σ_u.
const V_ANISO := (1.9 / 1.25 - 1.0) / (2.4 / 1.25 - 1.0)
## Растяжение масштабов у земли (taylor_stretch): высота спада, м (≈ размах крыла: ниже пилот на
## земле, на разбеге или выравнивании), и наибольший множитель.
const TAYLOR_H := 10.0
const TAYLOR_MAX := 8.0

var _sw_per_ustar: float = 1.25
var _mix_len: float = 40.0
var _neutral_h_k: float = AirCase.NEUTRAL_BL_K / AirCase.F_COR
var _conv_su: float = 0.6
var _cbl_frac: float = 0.22
var _ex0: float = 0.3
var _ex1: float = 0.7
var _desc: float = 0.05
var _sep_su: float = 0.18
var _sep_sw: float = 0.14
## Среднее и СКО g рывка по распределению шума рывков (NAN — ещё не считали).
var _burst_mean: float = NAN
var _burst_std: float = NAN


func setup(turb_cfg: Dictionary, lee_cfg: Dictionary, seed_value: int) -> void:
	gusts = GustSpectrum.new()
	gusts.setup(seed_value, float(turb_cfg.evolve_ms))
	_sw_per_ustar = float(turb_cfg.field_sigma_w_per_ustar)
	_mix_len = float(turb_cfg.field_mixing_length_m)
	_conv_su = float(turb_cfg.field_conv_sigma_u_per_wstar)
	_cbl_frac = float(turb_cfg.field_cbl_scale_per_zi)
	_ex0 = float(lee_cfg.field_deficit_attached)
	_ex1 = float(lee_cfg.field_deficit_separated)
	_desc = float(lee_cfg.field_descent_slope)
	_sep_su = float(lee_cfg.field_sigma_u_per_du)
	_sep_sw = float(lee_cfg.field_sigma_w_per_du)
	reverse = float(lee_cfg.field_reverse_per_uh)
	burst_per_du = float(lee_cfg.field_burst_per_du)
	bubble_len = float(lee_cfg.field_bubble_length_per_relief)
	var rc: Array = lee_cfg.field_resolved_cells
	resolved_n0 = float(rc[0])
	resolved_n1 = float(rc[1])
	sep_scale = float(lee_cfg.field_eddy_scale_per_relief)
	_burst_mean = NAN
	_burst_std = NAN


## Болтанка слоя смешения за гребнем (σ_u, σ_w) по скачку скорости ΔU (уже × признак отрыва):
## u′/ΔU ≈ 0,18, v′/ΔU ≈ 0,14 (Bell & Mehta 1990; Pope 2000, §5.4). ΔU = max(U_H − |U|, 0)·lee,
## U_H — ветер поля на уровне гребня (C4 v4).
func sep_sigma(du: float) -> Vector2:
	return Vector2(_sep_su * du, _sep_sw * du)


## Среднее g = clamp((n − порог)/ширина) рывка по распределению его шума — у поля рывки идут с
## нулевым средним (опускание в среднем — только из поля). Считается один раз.
func burst_mean(wind: WindModel, k: float, thr: float, width: float) -> float:
	if is_nan(_burst_mean):
		_measure_burst(wind, k, thr, width)
	return _burst_mean


## СКО g рывка по тому же распределению (для доли рывков в σ_w слоя смешения).
func burst_std(wind: WindModel, k: float, thr: float, width: float) -> float:
	if is_nan(_burst_std):
		_measure_burst(wind, k, thr, width)
	return _burst_std


## Доля эвристики обратного потока 0..1 (C4 v4): 1 − smoothstep(n0, n1, L/dx), L = bubble_len·r —
## длина пузыря отрыва (Menke 2019: L/H ≈ 2,8), dx — клетка поля в точке (AirFieldSet.sample_dx).
## Пузырь, разрешённый решателем (≥ n1 клеток), эвристика не повторяет.
func reverse_unresolved(relief: float, dx: float) -> float:
	if dx <= 0.0:
		return 1.0
	return 1.0 - smoothstep(resolved_n0, resolved_n1, bubble_len * maxf(relief, 0.0) / dx)


## Признак отрыва из поля 0..1: дефицит скорости в точке против лог-профиля под «внешним» ветром
## столба, ex = 1 − (|U|/U_out)/(ln(z/z0)/ln(a_out/z0)) — у прилегающего потока ex ≲ 0,3 (на
## подветренном склоне Askervein ΔS ≈ −0,3…−0,4), в следе и пузыре отрыва ex → 1; × опускание
## столба (наклон s_d = −min w/U_out: за гребнем, не у наветренного подножия, где поток тоже
## тормозится). Выше a_out (верх следа) — 0.
func lee(uf: float, agl: float, tb: PackedFloat32Array) -> float:
	var u_out := tb[WindField.T_UOUT]
	var a_out := tb[WindField.T_AOUT]
	if u_out < 0.5 or agl >= a_out:
		return 0.0
	var r := log(maxf(agl, 2.0 * z0) / z0) / log(maxf(a_out, 2.0 * z0) / z0)
	var ex := 1.0 - uf / u_out / maxf(r, 1.0e-3)
	var sep := smoothstep(_ex0, _ex1, ex)
	if sep <= 0.0:
		return 0.0
	return sep * smoothstep(0.0, _desc, tb[WindField.T_DESC])


## σ болтанки поля: Vector4(σ_u, σ_w, L_u, L_w) — СКО горизонтали вдоль ветра и вертикали (м/с) и
## интегральные масштабы механических вихрей (м) для спектра; заодно last_sv (σ поперёк ветра) и
## доли конвективной дисперсии горизонтали last_fu_c, last_fv_c с их масштабом last_l_c.
## Законы и источники — docs/air_model.md → «Масштаб 3: возмущения».
## conv_analytic — (σ_u, σ_w) конвективной болтанки аналитики: берётся, если в поле нет данных о
## нагреве (T_HMIX = 0). u_pt — модуль среднего ветра поля в точке (≥ 0): у земли (ниже
## SURFACE_FRAC·h) u* берётся согласованным с ним — κ·U/ln(z/z0) (AS-2); < 0 — не учитывать.
func sigma(agl: float, tb: PackedFloat32Array, conv_analytic: Vector2, u_pt: float = -1.0) -> Vector4:
	var z := maxf(agl, 1.0)
	var h_mix := tb[WindField.T_HMIX]
	var ustar := tb[WindField.T_USTAR]
	# механика: u* стенки (лог-закон поля) гаснет к верху слоя (1 − z/h)^(3/4) (Nieuwstadt 1984);
	# местный сдвиг — длина перемешивания Прандтля–Блэкадара, как замыкание решателя:
	# λ = max(λ₀, λ/h·h) (AirCase.LAM_FRAC — одно значение с решателем, AM-09б); h без данных о
	# нагреве — нейтральный слой NEUTRAL_BL_K·u*/f, как у решателя
	var h_bl := h_mix if h_mix > 0.0 else _neutral_h_k * ustar
	var lam := maxf(_mix_len, AirCase.LAM_FRAC * h_bl)
	var decay := pow(maxf(1.0 - z / maxf(h_bl, 1.0), 0.0), 0.75)
	var shear := tb[WindField.T_SHEAR]
	var l_mix := 1.0 / (1.0 / (WindField.KAPPA * z) + 1.0 / lam)
	var u_wall := ustar * decay
	if u_pt >= 0.0:
		# приземный слой: турбулентность в равновесии со средним профилем в точке — u* из того
		# же лог-закона, что даёт пилоту средний ветер (u* столбца берётся по клетке выше и на
		# склонах с разгоном расходится с ветром в точке до 10–40 %); выше — u* стенки
		var u_loc := WindField.KAPPA * u_pt / log(maxf(z, 2.0 * z0) / z0)
		var sl := smoothstep(0.5, 1.0, z / maxf(SURFACE_FRAC * h_bl, 1.0))
		u_wall = lerpf(u_loc, u_wall, sl)
	var u_m := maxf(u_wall, l_mix * shear)
	# устойчивость: градиентное число Ричардсона, u*_loc ∝ √F(Ri), F = 1/(1 + 5Ri)² — как решатель
	var n2 := tb[WindField.T_N2]
	var n_bv := 0.0
	if is_finite(n2) and n2 > 0.0:
		var ri := n2 / maxf(shear * shear, 1.0e-6)
		u_m /= 1.0 + 5.0 * ri
		n_bv = sqrt(n2)
	var sw_m := _sw_per_ustar * u_m
	var h_ft := z / 0.3048
	var aniso := 1.0
	if h_ft < 1000.0:
		aniso = 1.0 / pow(0.177 + 0.000823 * h_ft, 0.4)
	# анизотропия: σ_u/σ_w по MIL-HDBK-1797 (≈ 2 у земли → 1 к 300 м); поперёк ветра — та же доля
	# пути к изотропии, у земли σ_v/σ_w = 1,9/1,25 (σ_u : σ_v : σ_w = 2,4 : 1,9 : 1,25 u* —
	# Panofsky & Dutton 1984; Kaimal & Finnigan 1994, §1.6)
	var su_m := sw_m * aniso
	var sv_m := sw_m * (1.0 + V_ANISO * (aniso - 1.0))
	# конвекция: Lenschow et al. (1980) по w* поля (H ≤ 0 — нет); нет данных о нагреве — аналитика
	var su_c := 0.0
	var sw_c := 0.0
	var wstar := tb[WindField.T_WSTAR]
	var l_w := mil_lw(z)
	var l_u := mil_lu(z)
	var l_c := 0.0
	if h_mix > 0.0:
		var xi := z / h_mix
		if xi < 1.0:
			su_c = _conv_su * wstar
			# шум несёт только вертикаль мельче масштаба конвективных вихрей (крупнее — термики):
			# доля по Колмогорову (L_w / L_cbl)^(1/3), L_cbl = 0,22 z_i (пик спектра 1,5 z_i)
			var l_cbl := _cbl_frac * h_mix
			sw_c = wstar * sqrt(1.8) * pow(xi, 1.0 / 3.0) * (1.0 - 0.8 * xi)
			sw_c *= pow(minf(l_w / l_cbl, 1.0), 1.0 / 3.0)
			# горизонталь конвективных вихрей — масштаба слоя (пик спектров u, v на ~1,5 z_i,
			# Kaimal et al. 1976), не высоты над землёй
			l_c = l_cbl
	else:
		su_c = conv_analytic.x
		sw_c = conv_analytic.y
	# сложение механики и конвекции — как в подобии приземного слоя: σ³ = σ_m³ + σ_c³
	# (σ_u/u* = (12 + 0,5 z_i/|L|)^(1/3), σ_w/u* = 1,25(1 + 3|z/L|)^(1/3) — Panofsky et al. 1977;
	# конвективный член 0,5 z_i/|L| = 0,5κ (w*/u*)³ → σ_u,c ≈ 0,59 w*)
	var s_u := _cube_sum(su_m, su_c)
	var s_v := _cube_sum(sv_m, su_c)
	var s_w := _cube_sum(sw_m, sw_c)
	# доля дисперсии сверх механической — конвективные вихрей масштаба l_c (с данными о нагреве)
	last_l_c = l_c
	last_fu_c = 0.0
	last_fv_c = 0.0
	if l_c > 0.0:
		last_fu_c = 1.0 - su_m * su_m / maxf(s_u * s_u, 1.0e-9) if s_u > 1.0e-4 else 0.0
		last_fv_c = 1.0 - sv_m * sv_m / maxf(s_v * s_v, 1.0e-9) if s_v > 1.0e-4 else 0.0
	last_sv = s_v
	# масштабы: в устойчивом воздухе вихри не крупнее σ_w/N (Hunt, Kaimal & Gaynor 1985)
	if n_bv > 0.0 and s_w > 1.0e-3:
		var lb := s_w / n_bv
		l_u = 1.0 / (1.0 / l_u + 1.0 / lb)
		l_w = 1.0 / (1.0 / l_w + 1.0 / lb)
		if last_l_c > 0.0:
			last_l_c = 1.0 / (1.0 / last_l_c + 1.0 / lb)
	return Vector4(s_u, s_w, l_u, l_w)


## Растяжение масштабов механических вихрей у земли (AS-2): шум переносится одной скоростью
## advect (ветер на turbulence.advection_height_m, 300 м), а вихри приземного слоя — местным ветром
## U (гипотеза Тейлора с местной скоростью переноса — Willis & Deardorff 1976; Kaimal & Finnigan
## 1994, §2.5). У стоящего или бегущего пилота время вихря — L/U, а не L/advect (у земли при
## 6 м/с advect/U ≈ 3–4: порывы в 3–4 раза чаще и резче, чем в воздухе). Множитель масштаба —
## advect/U (не больше TAYLOR_MAX) с весом e^(−agl/TAYLOR_H): выше пилот летит ~10 м/с
## относительно воздуха, и встречу с вихрями задаёт его полёт. Перенос поля по высоте один —
## иначе шум со временем рвётся сдвигом.
static func taylor_stretch(advect: float, u_loc: float, agl: float) -> float:
	var r := clampf(advect / maxf(u_loc, 0.5), 1.0, TAYLOR_MAX)
	return 1.0 + (r - 1.0) * exp(-maxf(agl, 0.0) / TAYLOR_H)


static func _cube_sum(a: float, b: float) -> float:
	return pow(a * a * a + b * b * b, 1.0 / 3.0)


## Масштабы MIL-HDBK-1797 (фон Карман), м: ниже 1000 футов L_w = h, L_u = h/(0,177 + 0,000823h)^1,2
## (h в футах); от 2000 футов — 2500 футов; между — линейно.
static func mil_lw(z: float) -> float:
	var h := maxf(z / 0.3048, 10.0)
	if h <= 1000.0:
		return h * 0.3048
	return lerpf(1000.0, 2500.0, minf((h - 1000.0) / 1000.0, 1.0)) * 0.3048


static func mil_lu(z: float) -> float:
	var h := maxf(z / 0.3048, 10.0)
	if h <= 1000.0:
		return h / pow(0.177 + 0.000823 * h, 1.2) * 0.3048
	return lerpf(1000.0, 2500.0, minf((h - 1000.0) / 1000.0, 1.0)) * 0.3048


## Среднее и СКО g рывка по распределению шума рывков (2048 точек; шум нормирован на СКО 1).
func _measure_burst(wind: WindModel, k: float, thr: float, width: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var s := 0.0
	var s2 := 0.0
	for i in 2048:
		var p := Vector3(
			rng.randf_range(-3000, 3000), rng.randf_range(0, 3000), rng.randf_range(-3000, 3000)
		)
		var nb := wind.gust_unit(p * k, 0.0, 0.0, 0.0).x
		var g := clampf((nb - thr) / width, 0.0, 1.0)
		s += g
		s2 += g * g
	_burst_mean = s / 2048.0
	_burst_std = sqrt(maxf(s2 / 2048.0 - _burst_mean * _burst_mean, 0.0))
