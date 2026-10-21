class_name SunTransmission
extends RefCounted
## Пропускание атмосферы для света солнца на облаках (контракт HH4, docs/contracts/haze-humidity.md).
##
## Таблица T(высота солнца, высота точки) → RGB: оптическая толща вдоль луча от точки к солнцу в
## сферической атмосфере: Рэлей (β ∝ λ⁻⁴, плотность exp(−h/H)) + мутный слой (extinction дымки ×
## extinction_rgb, постоянное от моря до верха дымки, выше — 0). T = exp(−τ); луч, задевающий сферу
## уровня моря, — T = 0 (рельеф не учитывается). Озон и многократное рассеяние не учитываются.
##
## Толща считается по каналам из двух интегралов вдоль луча, общих для всех длин волн:
## τ_c = β_R(λ_c)·I_R + ext·rgb_c·I_H; I_H — длина хорды в сфере верха дымки (аналитически),
## I_R = ∫ exp(−высота/H) ds — численно (Симпсон, шаг растёт от «опорной» точки отрезка квадратично:
## под горизонтом отрезков два — к перигею и от него).
## Параметры — configs/atmosphere.json → clouds.sun_transmission (params()).

## Параметры из конфига (с запасными значениями — те же, что в конфиге).
static func params(cfg: Dictionary = {}) -> Dictionary:
	var c: Dictionary = cfg
	if c.is_empty():
		c = Config.get_config("atmosphere").get("clouds", {}).get("sun_transmission", {})
	var wl: Array = c.get("wavelengths_nm", [680.0, 550.0, 440.0])
	return {
		"n_el": int(c.get("n_el", 64)),
		"n_h": int(c.get("n_h", 64)),
		"el_min_deg": float(c.get("el_min_deg", -8.0)),
		"el_max_deg": float(c.get("el_max_deg", 30.0)),
		"h_max_m": float(c.get("h_max_m", 16000.0)),
		"ref_el_deg": float(c.get("ref_el_deg", 35.0)),
		"beta_r_550": float(c.get("beta_r_550", 1.16e-5)),
		"scale_height_m": float(c.get("scale_height_m", 8000.0)),
		"wavelengths_nm": Vector3(float(wl[0]), float(wl[1]), float(wl[2])),
		"earth_radius_m": float(c.get("earth_radius_m", 6371000.0)),
		"top_m": float(c.get("top_m", 100000.0)),
		"steps": int(c.get("steps", 32)),
	}


## Таблица: Image.FORMAT_RGBF, ширина n_el (высота солнца от el_min до el_max), высота n_h
## (высота точки от 0 до h_max). extinction_550 — м⁻¹ на 550 нм (уже × haze_k), extinction_rgb —
## спектр слоя, haze_top_msl — верх дымки над морем, м. p — params().
static func build(
	extinction_550: float, extinction_rgb: Vector3, haze_top_msl: float, p: Dictionary = {}
) -> Image:
	var q: Dictionary = p if not p.is_empty() else params()
	var n_el: int = q.n_el
	var n_h: int = q.n_h
	var data := PackedFloat32Array()
	data.resize(n_el * n_h * 3)
	var k := 0
	for j in n_h:
		var h: float = float(j) / float(n_h - 1) * q.h_max_m
		for i in n_el:
			var el: float = lerpf(q.el_min_deg, q.el_max_deg, float(i) / float(n_el - 1))
			var t := transmission(el, h, extinction_550, extinction_rgb, haze_top_msl, q)
			data[k] = t.x
			data[k + 1] = t.y
			data[k + 2] = t.z
			k += 3
	return Image.create_from_data(n_el, n_h, false, Image.FORMAT_RGBF, data.to_byte_array())


## Пропускание T(R, G, B) вдоль луча от точки на высоте h_m (над морем) к солнцу на высоте el_deg
## над математическим горизонтом точки. 0 — луч задевает сферу уровня моря.
static func transmission(
	el_deg: float, h_m: float, extinction_550: float, extinction_rgb: Vector3,
	haze_top_msl: float, p: Dictionary
) -> Vector3:
	var tau := optical_depth(el_deg, h_m, extinction_550, extinction_rgb, haze_top_msl, p)
	if tau.x < 0.0:
		return Vector3.ZERO
	return Vector3(exp(-tau.x), exp(-tau.y), exp(-tau.z))


## Поправка за краем таблицы: солнце выше el_max_deg (таблица зажата краем), но не выше ref_el_deg
## (выше — свет не растёт, как в time.light): T(el, долина) / T(el_max, долина) по каналам; 1 — иначе.
## Умножается на sun_toa. У основания облака на высоте долины днём (солнце ≥ ref_el_deg) свет ровно
## T_ref / T_ref = прежний.
static func sun_factor(
	el_deg: float, extinction_550: float, extinction_rgb: Vector3, haze_top_msl: float,
	valley_m: float, p: Dictionary
) -> Vector3:
	var el_eff := minf(el_deg, float(p.ref_el_deg))
	if el_eff <= float(p.el_max_deg):
		return Vector3.ONE
	var hi := transmission(el_eff, valley_m, extinction_550, extinction_rgb, haze_top_msl, p)
	var lo := transmission(
		float(p.el_max_deg), valley_m, extinction_550, extinction_rgb, haze_top_msl, p
	)
	return Vector3(
		hi.x / maxf(lo.x, 1.0e-6), hi.y / maxf(lo.y, 1.0e-6), hi.z / maxf(lo.z, 1.0e-6)
	)


## Оптическая толща по каналам (R, G, B); (−1, −1, −1) — луч упирается в сферу уровня моря.
static func optical_depth(
	el_deg: float, h_m: float, extinction_550: float, extinction_rgb: Vector3,
	haze_top_msl: float, p: Dictionary
) -> Vector3:
	var big_r: float = p.earth_radius_m
	var r0 := big_r + h_m
	var el := deg_to_rad(el_deg)
	var sin_e := sin(el)
	var cos_e := cos(el)
	# Ближайшая к центру точка луча (перигей) — на расстоянии r0·cos(el) при el < 0.
	var b := r0 * cos_e
	if sin_e < 0.0 and b < big_r:
		return Vector3(-1, -1, -1)
	var r_top := big_r + float(p.top_m)
	var d_top := r_top * r_top - b * b
	var s_exit := -r0 * sin_e + sqrt(maxf(d_top, 0.0))
	var s_peri := -r0 * sin_e if sin_e < 0.0 else 0.0
	var inv_h: float = 1.0 / float(p.scale_height_m)
	var steps: int = int(p.steps)
	var ir := 0.0
	if s_peri > 0.0:
		ir += _seg(r0, sin_e, big_r, inv_h, s_peri, 0.0, steps)
		ir += _seg(r0, sin_e, big_r, inv_h, s_peri, s_exit, steps)
	else:
		ir += _seg(r0, sin_e, big_r, inv_h, 0.0, s_exit, steps)
	# Мутный слой: длина части луча внутри сферы верха дымки.
	var ih := 0.0
	var top_m := maxf(haze_top_msl, 0.0)
	if extinction_550 > 0.0 and top_m > 0.0:
		var rt := big_r + top_m
		var dd := rt * rt - b * b
		if dd > 0.0:
			var sq := sqrt(dd)
			var s_in := maxf(-r0 * sin_e - sq, 0.0)
			var s_out := -r0 * sin_e + sq
			if s_out > s_in:
				ih = s_out - s_in
	var w: Vector3 = p.wavelengths_nm
	var br: float = p.beta_r_550
	var lam_g := w.y
	return Vector3(
		br * pow(lam_g / w.x, 4.0) * ir + extinction_550 * extinction_rgb.x * ih,
		br * ir + extinction_550 * extinction_rgb.y * ih,
		br * pow(lam_g / w.z, 4.0) * ir + extinction_550 * extinction_rgb.z * ih
	)


## ∫ exp(−(r(s) − R)/H) ds по отрезку между s_from (опорная точка: шаг у неё мелкий) и s_to,
## Симпсон по u ∈ [0, 1], s = s_from + (s_to − s_from)·u².
static func _seg(
	r0: float, sin_e: float, big_r: float, inv_h: float, s_from: float, s_to: float, n: int
) -> float:
	var len_s := s_to - s_from
	if absf(len_s) < 1.0e-3:
		return 0.0
	var n2 := n + (n & 1)
	var du := 1.0 / float(n2)
	var sum := 0.0
	var r0_2 := 2.0 * r0 * sin_e
	var r0_sq := r0 * r0
	for i in n2 + 1:
		var u := float(i) * du
		var s := s_from + len_s * u * u
		var r := sqrt(r0_sq + r0_2 * s + s * s)
		var f := exp(-(r - big_r) * inv_h) * 2.0 * u
		var wgt := 1.0 if (i == 0 or i == n2) else (4.0 if (i & 1) == 1 else 2.0)
		sum += wgt * f
	return absf(len_s) * sum * du / 3.0
