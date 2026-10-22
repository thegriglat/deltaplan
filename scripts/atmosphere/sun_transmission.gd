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
		"sky_el": (c.get("sky_k", {}) as Dictionary).get("elevation_deg", [0.0, 35.0]),
		"sky_k": (c.get("sky_k", {}) as Dictionary).get("k", [1.0, 1.0]),
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


## Цветность прямого солнца в точке (контракт HH4 v2): c = T(el, y) / T(ref_el, y) по каналам,
## делённое на R — (1, G/R, B/R); днём (el ≥ ref_el) — белый. Аэрозоль — как в таблице (дымка места).
## Color(−1, −1, −1) — луч упирается в сферу уровня моря (T = 0): вызывающий берёт прошлую цветность.
static func sun_tint(
	el_deg: float, y_msl: float, extinction_550: float, extinction_rgb: Vector3,
	haze_top_msl: float, p: Dictionary = {}
) -> Color:
	var q: Dictionary = p if not p.is_empty() else params()
	var el := minf(el_deg, float(q.ref_el_deg))
	var t := transmission(el, y_msl, extinction_550, extinction_rgb, haze_top_msl, q)
	if t.x <= 0.0:
		return Color(-1.0, -1.0, -1.0)
	var r := transmission(
		float(q.ref_el_deg), y_msl, extinction_550, extinction_rgb, haze_top_msl, q
	)
	var c := Vector3(t.x / maxf(r.x, 1.0e-9), t.y / maxf(r.y, 1.0e-9), t.z / maxf(r.z, 1.0e-9))
	return Color(1.0, c.y / c.x, c.z / c.x)


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


## Яркость рассеянного света безоблачного неба относительно 35° (контракт HH4 v3): линейно по таблице
## clouds.sun_transmission.sky_k (рассеянная освещённость DHI, tools/research/haze_humidity/sky_light/).
## Ниже первого узла (0°) — его значение (сумерки не моделируются), выше последнего (35°) — 1.
static func sky_k(el_deg: float, p: Dictionary = {}) -> float:
	var q: Dictionary = p if not p.is_empty() else params()
	var xs: Array = q.sky_el
	var ys: Array = q.sky_k
	if el_deg <= float(xs[0]):
		return float(ys[0])
	for i in range(1, xs.size()):
		if el_deg <= float(xs[i]):
			var f := (el_deg - float(xs[i - 1])) / maxf(float(xs[i]) - float(xs[i - 1]), 1.0e-6)
			return lerpf(float(ys[i - 1]), float(ys[i]), f)
	return float(ys[ys.size() - 1])


## Свет прямого солнца в точке относительно дневного (контракт HH4 v3): T_G(el, y) / T_G(ref_el, y), зелёный
## канал (550 нм); 0 — луч упирается в сферу уровня моря; выше ref_el_deg — 1. Множитель к sun.energy.
static func light_ratio(
	el_deg: float, y_msl: float, extinction_550: float, extinction_rgb: Vector3,
	haze_top_msl: float, p: Dictionary = {}
) -> float:
	var q: Dictionary = p if not p.is_empty() else params()
	var t := transmission(
		minf(el_deg, float(q.ref_el_deg)), y_msl, extinction_550, extinction_rgb, haze_top_msl, q
	)
	if t.y <= 0.0:
		return 0.0
	var r := transmission(
		float(q.ref_el_deg), y_msl, extinction_550, extinction_rgb, haze_top_msl, q
	)
	return clampf(t.y / maxf(r.y, 1.0e-9), 0.0, 1.0)


## Яркость сцены относительно дня (контракт HH4 v3): L(el) = light_energy·max(sin el, 0)·ρ + sky_k, отнесённая к
## тому же при ref_el_deg: light_energy = sun_energy·light (light — light_ratio, sun_energy — world.json → sun.energy),
## sky_k — SunTransmission.sky_k, ρ — средняя отражательная способность рельефа (параметр
## rendering.sunset_exposure.albedo). Выше ref_el_deg — 1.
static func scene_luminance(
	el_deg: float, light: float, sky: float, albedo: float, sun_energy: float, ref_el_deg: float = 35.0
) -> float:
	var s_ref := sin(deg_to_rad(ref_el_deg))
	var s := sin(deg_to_rad(clampf(el_deg, 0.0, ref_el_deg)))
	return (sun_energy * light * s * albedo + sky) / (sun_energy * s_ref * albedo + 1.0)


## Множитель экспозиции заката E = clamp((1/L)^a, 1, E_max) (контракт HH4 v3), установившееся значение.
static func exposure_factor(scene_l: float, a: float, e_max: float) -> float:
	return clampf(pow(1.0 / maxf(scene_l, 1.0e-6), a), 1.0, e_max)
