extends TestCase
## Контракт HH4 (docs/contracts/haze-humidity.md): таблица пропускания атмосферы для света облаков.
## Проверяет SunTransmission.build — формат, диапазон, монотонность, Чепмен у горизонта, зенит,
## точка выше горизонта земли при солнце под горизонтом.

const EXT := 3.912 / 60000.0 * 1.5
const RGB := Vector3(0.85, 1.0, 1.2)
const TOP := 2200.0


func _table(ext: float) -> Image:
	return SunTransmission.build(ext, RGB, TOP)


func _px(img: Image, p: Dictionary, el: float, h: float) -> Color:
	var u: float = (el - p.el_min_deg) / (p.el_max_deg - p.el_min_deg) * (p.n_el - 1)
	var v: float = h / p.h_max_m * (p.n_h - 1)
	return img.get_pixel(int(round(u)), int(round(v)))


func test_table_format() -> void:
	var p := SunTransmission.params()
	var img := _table(EXT)
	check(img.get_format() == Image.FORMAT_RGBF, "формат RGBF: %d" % img.get_format())
	check(img.get_width() == p.n_el and img.get_height() == p.n_h, "размер n_el × n_h")
	check(p.n_el == 64 and p.n_h == 64, "по умолчанию 64 × 64")
	check(p.el_min_deg == -8.0 and p.el_max_deg == 30.0 and p.h_max_m == 16000.0, "оси по контракту")


func test_range_and_spectrum() -> void:
	for ext in [0.0, EXT]:
		var img := _table(ext)
		var bad := 0
		var bad_order := 0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.r < 0.0 or c.g < 0.0 or c.b < 0.0 or c.r > 1.0 or c.g > 1.0 or c.b > 1.0:
					bad += 1
				if c.b > c.g + 1.0e-6 or c.g > c.r + 1.0e-6:
					bad_order += 1
		check(bad == 0, "T ∈ [0, 1] (ext %s): %d ячеек вне" % [ext, bad])
		check(bad_order == 0, "T(B) ≤ T(G) ≤ T(R) (ext %s): %d ячеек нарушают" % [ext, bad_order])


func test_monotonic() -> void:
	for ext in [0.0, EXT]:
		var img := _table(ext)
		var w := img.get_width()
		var h := img.get_height()
		var bad_el := 0
		var bad_h := 0
		for y in h:
			for x in w:
				var c := img.get_pixel(x, y)
				if x + 1 < w and img.get_pixel(x + 1, y).g < c.g - 1.0e-6:
					bad_el += 1
				if y + 1 < h and img.get_pixel(x, y + 1).g < c.g - 1.0e-6:
					bad_h += 1
		check(bad_el == 0, "T растёт с высотой солнца (ext %s): %d нарушений" % [ext, bad_el])
		check(bad_h == 0, "T растёт с высотой точки (ext %s): %d нарушений" % [ext, bad_h])


func test_chapman_horizon_and_zenith() -> void:
	var p := SunTransmission.params()
	var tau_h := SunTransmission.optical_depth(0.0, 0.0, 0.0, RGB, TOP, p)
	var h_scale: float = p.scale_height_m
	var chapman: float = p.beta_r_550 * h_scale * sqrt(PI * p.earth_radius_m / (2.0 * h_scale))
	approx(tau_h.y, chapman, chapman * 0.05, "−ln T(G) у моря на горизонте (Чепмен 90°)")
	var tau_z := SunTransmission.optical_depth(90.0, 0.0, 0.0, RGB, TOP, p)
	var zen: float = p.beta_r_550 * h_scale
	approx(tau_z.y, zen, zen * 0.02, "−ln T(G) у моря в зените")
	# То же — по готовой таблице: первая ячейка выше математического горизонта (el > 0).
	var img := _table(0.0)
	var i0 := int(ceil((0.0 - p.el_min_deg) / (p.el_max_deg - p.el_min_deg) * (p.n_el - 1)))
	var c := img.get_pixel(i0, 0)
	check(c.g > 0.0 and c.g < 0.1, "у горизонта у моря T(G) = %.4f мал, но не нуль" % c.g)


func test_point_above_earth_shadow() -> void:
	var p := SunTransmission.params()
	# Контракт HH4 называет el = −2° для 3 км, но провал горизонта на 3 км — 1,76°: при −2° луч
	# уходит под сферу уровня моря (T = 0 по тому же контракту), поэтому проверяется −1° (карточка HH-7).
	var t3 := SunTransmission.transmission(-1.0, 3000.0, EXT, RGB, TOP, p)
	check(t3.y > 0.0 and t3.x > t3.z, "3 км при el = −1°: T = %s > 0, красный сильнее синего" % t3)
	var t0 := SunTransmission.transmission(-1.0, 0.0, EXT, RGB, TOP, p)
	check(t0 == Vector3.ZERO, "у моря при el = −1°: T = 0, получено %s" % t0)
	var t2 := SunTransmission.transmission(-2.0, 3000.0, EXT, RGB, TOP, p)
	check(t2 == Vector3.ZERO, "3 км при el = −2° (глубже провала горизонта 1,76°): T = 0, получено %s" % t2)


# --- v2: цвет солнца SunTransmission.sun_tint (контрольные числа главной 2026-10-22) ---

## Аэрозоль τ550 = 0,1, Ангстрем 1,3: слой до 1850 м, extinction = τ / верх.
const TINT_TOP := 1850.0
const TINT_EXT := 0.1 / TINT_TOP
const TINT_RGB := Vector3(0.7603, 1.0, 1.3366)  # (550/λ)^1,3 для 680 / 550 / 440 нм


func _tint(el: float, y: float = 0.0) -> Color:
	return SunTransmission.sun_tint(el, y, TINT_EXT, TINT_RGB, TINT_TOP)


func test_tint_day_white() -> void:
	for el in [35.0, 50.0, 80.0]:
		var c := _tint(el)
		approx(c.g, 1.0, 0.02, "G/R днём (el %s)" % el)
		approx(c.b, 1.0, 0.02, "B/R днём (el %s)" % el)
	approx(_tint(35.0, 1500.0).b, 1.0, 0.02, "белый и на высоте")


func test_tint_reference_numbers() -> void:
	# контракт HH4 v2 (уточнение 2026-10-22): 18° — (1; 0,89; 0,70) ± 0,08
	var ref := {2.0: [0.24, 0.02], 5.0: [0.47, 0.13], 8.0: [0.60, 0.25], 18.0: [0.89, 0.70]}
	for el in ref:
		var c := _tint(el)
		print("sun_tint el=%s g_r=%.3f b_r=%.3f" % [el, c.g, c.b])
		approx(c.g, ref[el][0], 0.08, "G/R при %s°" % el)
		approx(c.b, ref[el][1], 0.08, "B/R при %s°" % el)


func test_tint_monotonic_redder_lower() -> void:
	var prev := _tint(0.0)
	for el in [1.0, 2.0, 4.0, 8.0, 14.0, 20.0, 30.0]:
		var c := _tint(el)
		check(c.g >= prev.g - 1.0e-6 and c.b >= prev.b - 1.0e-6, "ниже солнце — краснее (%s°)" % el)
		prev = c
	check(_tint(0.0).g < 0.2 and _tint(0.0).b < 0.03, "у горизонта почти тёмно-красное: %s" % _tint(0.0))


func test_tint_below_sea_sphere() -> void:
	check(SunTransmission.sun_tint(-5.0, 0.0, TINT_EXT, TINT_RGB, TINT_TOP).r < 0.0, "T = 0 — признак")


# --- v3: яркость сцены по высоте солнца и экспозиция заката ---


func _sky_at(el_hour: float) -> SkyEnvironment:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()
	sky.clock.start_flight(53.26, 58.54, 7, 15, el_hour, 5.0)
	sky.snap_exposure()
	return sky


func test_v3_no_manual_tables() -> void:
	var l: Dictionary = Config.get_config("world").time.light
	check(not l.has("sun_energy") and not l.has("sky_energy"), "ручных таблиц sun_energy/sky_energy нет")
	check(not Config.get_config("atmosphere").clouds.has("sky_light"), "clouds.sky_light удалена")


func test_v3_sky_k_table() -> void:
	check(absf(SunTransmission.sky_k(35.0) - 1.0) < 1e-6 and absf(SunTransmission.sky_k(60.0) - 1.0) < 1e-6, "sky_k(≥35°) = 1")
	var prev := 0.0
	for el in [0.0, 1.0, 2.0, 4.0, 8.0, 12.0, 18.0, 26.0, 35.0]:
		var k := SunTransmission.sky_k(el)
		check(k > prev, "sky_k растёт с высотой: %.1f° → %.3f" % [el, k])
		prev = k
	check(SunTransmission.sky_k(-2.0) == SunTransmission.sky_k(0.0), "ниже 0° — значение при 0° (сумерки не моделируются)")
	# сверка с ESRA (Rigollier 2000, TL = 3, tools/research/haze_humidity/sky_light): ±5 % при 6–35°
	var esra := {6.0: 0.343, 8.0: 0.410, 12.0: 0.535, 18.0: 0.697, 26.0: 0.867}
	for el in esra:
		check(absf(SunTransmission.sky_k(el) / float(esra[el]) - 1.0) < 0.05, "sky_k(%.0f°) = %.3f против ESRA %.3f" % [el, SunTransmission.sky_k(el), esra[el]])


func test_v3_light_energy_from_transmission() -> void:
	var sky := _sky_at(19.6)  # солнце ≈ 8°
	var el: float = sky.clock.angles().y
	var hz := sky._haze_extinction()
	var valley := _y_of_light(sky)
	var k := SunTransmission.light_ratio(el, valley, hz[0], hz[1], sky.get_haze_top_msl())
	approx(sky.sun.light_energy, float(Config.get_config("world").sun.energy) * k, 1e-4, "light_energy = sun.energy · T_G/T_G(35°)")
	check(k > 0.0 and k < 1.0, "на 8° слабее дневного: %.3f" % k)
	sky.free()
	var day := _sky_at(13.5)
	approx(day.sun.light_energy, float(Config.get_config("world").sun.energy), 1e-3, "днём — sun.energy")
	day.free()
	check(SunTransmission.light_ratio(-3.0, 0.0, EXT, RGB, TOP) == 0.0, "T = 0 (луч в Землю) — свет рельефа 0")
	check(SunTransmission.light_ratio(60.0, 0.0, EXT, RGB, TOP) == 1.0, "выше 35° — 1")


func _y_of_light(sky: SkyEnvironment) -> float:
	return sky.valley_msl_m if not is_nan(sky.valley_msl_m) else sky._tint_cam_y


func test_v3_exposure() -> void:
	var day := _sky_at(13.5)
	approx(day.exposure_target, 1.0, 0.02, "днём E = 1 ± 2 %")
	approx(day._env.tonemap_exposure, float(Config.get_config("world").rendering.tonemap_exposure), 0.03, "днём tonemap_exposure прежняя")
	day.free()
	var prev := 1.0
	var emax := float(Config.get_config("world").rendering.sunset_exposure.e_max)
	for hour in [17.0, 18.5, 19.6, 20.5, 21.0]:
		var s := _sky_at(hour)
		check(s.exposure_target >= prev - 1e-6 and s.exposure_target <= emax + 1e-6, "E растёт к закату: %.2f ч → %.2f (el %.1f°)" % [hour, s.exposure_target, s.clock.angles().y])
		prev = s.exposure_target
		var sk := SunTransmission.sky_k(s.clock.angles().y)
		approx(float(s.sky_material().get_shader_parameter("exposure")), sk, 1e-5, "энергия неба = sky_k")
		approx(s._env.ambient_light_energy, float(Config.get_config("world").sky.ambient_light_energy) * sk, 1e-5, "окружение = sky_k")
		s.free()
	check(prev > 2.5, "на закате (2°) E > 2,5: %.2f" % prev)
	# смена E плавная: после скачка времени current ≠ target, через время — сходится
	var s2 := _sky_at(13.5)
	s2.clock.start_flight(53.26, 58.54, 7, 15, 20.9, 5.0)
	check(s2.exposure_target > 2.0, "цель после перемотки")
	s2.snap_exposure()
	approx(s2.exposure_current, s2.exposure_target, 1e-6, "snap_exposure")
	s2.free()


func test_v3_glare_and_disk_independent_of_exposure() -> void:
	var s := _sky_at(20.5)
	var el: float = s.clock.angles().y
	var lum := s.sun_luminance_ratio(el, s._tint_cam_y)
	approx(s.glare._time_k, lum, 1e-4, "засвет глаза = яркость солнца к дневной (не зависит от E)")
	check(s.exposure_current > 2.0, "E на закате > 2")
	var p := float(Config.get_config("world").sky.sun_disk.energy_exponent)
	var dk := pow(lum, p) / s.haze_sky_transmission(el, s._tint_cam_y)
	approx(float(s.sky_material().get_shader_parameter("disk_energy")) * s.exposure_current, float(Config.get_config("world").sky.sun_disk.energy) * dk, 1e-3, "диск на кадре = energy × lum^p (E его не раздувает)")
	s.free()
