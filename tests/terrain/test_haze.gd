extends TestCase
## Дымка слоя перемешивания (VR-3, FR-20): аналитическая оптическая толщина вдоль луча
## (SkyEnvironment.haze_path_m — та же формула, что в haze.gdshader) против численного интеграла,
## пропускание на 20 км, верх слоя по инверсии.

const TOP := 1900.0
const W := 60.0


func _profile(y: float) -> float:
	return clampf((TOP + 0.5 * W - y) / W, 0.0, 1.0)


## Численный интеграл плотности по лучу (средние точки).
func _numeric_path(y0: float, dir_y: float, length_m: float, n: int = 50000) -> float:
	var ds := length_m / n
	var s := 0.0
	for i in n:
		s += _profile(y0 + dir_y * (i + 0.5) * ds)
	return s * ds


func test_optical_depth_analytic_vs_numeric() -> void:
	# [высота камеры, угол луча к горизонту°, длина, м]: сверху вниз, снизу вверх, внутри перехода,
	# горизонтально под слоем, пологий луч сквозь верх слоя
	var rays := [
		[3870.0, -8.0, 30000.0],
		[3870.0, -1.5, 80000.0],
		[1200.0, 2.0, 60000.0],
		[1905.0, 0.0, 20000.0],
		[1905.0, -0.3, 40000.0],
		[1500.0, 0.0, 20000.0],
		[2500.0, -0.4, 150000.0],
		[1000.0, 30.0, 5000.0],
	]
	for r: Array in rays:
		var dir_y := sin(deg_to_rad(float(r[1])))
		var len_m := float(r[2]) / cos(deg_to_rad(float(r[1])))
		var a := SkyEnvironment.haze_path_m(float(r[0]), dir_y, len_m, TOP, W)
		var n := _numeric_path(float(r[0]), dir_y, len_m)
		check(
			absf(a - n) <= 0.01 * maxf(n, 1.0),
			"луч %s: аналитика %.1f м, интеграл %.1f м" % [str(r), a, n]
		)


func test_transmission_20km() -> void:
	# Отзыв пилота: дальние хребты были видны слишком чётко — дымку сгустили (T04.1), суммарная
	# видимость 58 → 35 км (visibility_km 100 → 60, clear_visibility_km 140 → 84), пропускание на
	# 20 км упало пропорционально (26 % → ~11 %). FR-20 (видимость ≥ 20 км) по-прежнему выполняется.
	var t := SkyEnvironment.transmission_in_layer(20000.0)
	check(t >= 0.08, "пропускание на 20 км внутри слоя %.3f (≥ 0,08)" % t)


func test_top_follows_inversion() -> void:
	var sky := SkyEnvironment.new()
	sky.apply_config()
	var hz: Dictionary = Config.get_config("world").get("haze", {})
	sky.set_inversion_height_msl(1900.0)
	var top := 1900.0 + float(hz.get("top_margin_m", 0.0))
	approx(sky.get_haze_top_msl(), top, 0.01, "верх дымки = инверсия + запас")
	var mat := sky.haze_material()
	check(mat != null, "дымка включена")
	if mat != null:
		approx(float(mat.get_shader_parameter("top_msl")), top, 0.01, "top_msl в шейдере")
		check(float(mat.get_shader_parameter("top_transition_m")) <= 100.0, "верх слоя резкий")
	sky.free()
