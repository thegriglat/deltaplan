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
## Обратный поток в пузыре отрыва, доли U_out (lee.field_reverse_per_wind).
var reverse: float = 0.25
## Масштаб вихрей зоны отрыва, доли превышения гребня (lee.field_eddy_scale_per_relief).
var sep_scale: float = 0.5

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
## Среднее g рывка по распределению шума рывков (NAN — ещё не считали).
var _burst_mean: float = NAN


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
	reverse = float(lee_cfg.field_reverse_per_wind)
	sep_scale = float(lee_cfg.field_eddy_scale_per_relief)
	_burst_mean = NAN


## Болтанка слоя смешения за гребнем (σ_u, σ_w) по скачку скорости ΔU (уже × признак отрыва):
## u′/ΔU ≈ 0,18, v′/ΔU ≈ 0,14 (Bell & Mehta 1990; Pope 2000, §5.4).
func sep_sigma(du: float) -> Vector2:
	return Vector2(_sep_su * du, _sep_sw * du)


## Среднее g = clamp((n − порог)/ширина) рывка по распределению его шума — у поля рывки идут с
## нулевым средним (опускание в среднем — только из поля). Считается один раз.
func burst_mean(wind: WindModel, k: float, thr: float, width: float) -> float:
	if is_nan(_burst_mean):
		_burst_mean = _measure_burst_mean(wind, k, thr, width)
	return _burst_mean


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


## σ болтанки поля: Vector4(σ_u, σ_w, L_u, L_w) — СКО горизонтали и вертикали (м/с) и интегральные
## масштабы (м) для спектра. Законы и источники — docs/air_model.md → «Масштаб 3: возмущения».
## conv_analytic — (σ_u, σ_w) конвективной болтанки аналитики: берётся, если в поле нет данных о
## нагреве (T_HMIX = 0).
func sigma(agl: float, tb: PackedFloat32Array, conv_analytic: Vector2) -> Vector4:
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
	var u_m := maxf(ustar * decay, l_mix * shear)
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
	var su_m := sw_m * aniso
	# конвекция: Lenschow et al. (1980) по w* поля (H ≤ 0 — нет); нет данных о нагреве — аналитика
	var su_c := 0.0
	var sw_c := 0.0
	var wstar := tb[WindField.T_WSTAR]
	var l_w := mil_lw(z)
	var l_u := mil_lu(z)
	if h_mix > 0.0:
		var xi := z / h_mix
		if xi < 1.0:
			su_c = _conv_su * wstar
			# шум несёт только вертикаль мельче масштаба конвективных вихрей (крупнее — термики):
			# доля по Колмогорову (L_w / L_cbl)^(1/3), L_cbl = 0,22 z_i (пик спектра 1,5 z_i)
			var l_cbl := _cbl_frac * h_mix
			sw_c = wstar * sqrt(1.8) * pow(xi, 1.0 / 3.0) * (1.0 - 0.8 * xi)
			sw_c *= pow(minf(l_w / l_cbl, 1.0), 1.0 / 3.0)
	else:
		su_c = conv_analytic.x
		sw_c = conv_analytic.y
	var s_u := sqrt(su_m * su_m + su_c * su_c)
	var s_w := sqrt(sw_m * sw_m + sw_c * sw_c)
	# масштабы: в устойчивом воздухе вихри не крупнее σ_w/N (Hunt, Kaimal & Gaynor 1985)
	if n_bv > 0.0 and s_w > 1.0e-3:
		var lb := s_w / n_bv
		l_u = 1.0 / (1.0 / l_u + 1.0 / lb)
		l_w = 1.0 / (1.0 / l_w + 1.0 / lb)
	return Vector4(s_u, s_w, l_u, l_w)


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


## Среднее g рывка по распределению шума рывков (4096 точек; шум нормирован на СКО 1).
func _measure_burst_mean(wind: WindModel, k: float, thr: float, width: float) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var s := 0.0
	for i in 2048:
		var p := Vector3(
			rng.randf_range(-3000, 3000), rng.randf_range(0, 3000), rng.randf_range(-3000, 3000)
		)
		var nb := wind.gust_unit(p * k, 0.0, 0.0, 0.0).x
		s += clampf((nb - thr) / width, 0.0, 1.0)
	return s / 2048.0
