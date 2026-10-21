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
