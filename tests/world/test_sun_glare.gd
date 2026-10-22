extends TestCase
## Солнце и ослепление: луч к солнцу через рельеф и облака (SunGlare.trace_sun), кольцо лучей
## по диску, вечером диск и ослепление слабее (пропускание атмосферы, HH-11), небо — свой шейдер с диском.


func test_trace_sun_clear_terrain_and_cloud() -> void:
	var cfg := {"ray_steps": 16, "ray_distance_m": 10000.0, "cloud_opacity_per_m": 0.004}
	var up := Vector3(0.0, 0.5, -1.0).normalized()
	var flat := func(_x: float, _z: float) -> float: return 0.0
	check(SunGlare.trace_sun(Vector3(0, 100, 0), up, flat, Callable(), cfg) == Vector2.ONE, "ясно")
	# хребет выше луча в 2 км по пути к солнцу
	var ridge := func(_x: float, z: float) -> float: return 3000.0 if z < -2000.0 else 0.0
	approx(SunGlare.trace_sun(Vector3(0, 100, 0), up, ridge, Callable(), cfg).x, 0.0, 1e-6, "рельеф")
	# облако плотности 0,5 на ~800 м пути (высоты 350..700 м по лучу)
	var cloud := func(q: Vector3) -> float: return 0.5 if q.y > 350.0 and q.y < 700.0 else 0.0
	var t := SunGlare.trace_sun(Vector3(0, 100, 0), up, flat, cloud, cfg).y
	check(t > 0.0 and t < 1.0, "облако ослабляет, но не до нуля: %.3f" % t)
	var thick := func(q: Vector3) -> float: return 1.0 if q.y > 400.0 and q.y < 1400.0 else 0.0
	check(SunGlare.trace_sun(Vector3(0, 100, 0), up, flat, thick, cfg).y < 0.01, "толстое облако")


func test_ray_ring_directions() -> void:
	var s := Vector3(0.3, 0.8, -0.5).normalized()
	var dirs := SunGlare.ray_directions(s, 8, 1.0)
	check(dirs.size() == 9, "центр + 8 лучей")
	approx(rad_to_deg(dirs[0].angle_to(s)), 0.0, 1e-4, "центр — на солнце")
	for i in range(1, dirs.size()):
		approx(rad_to_deg(dirs[i].angle_to(s)), 1.0, 0.01, "кольцо на 1°")
		approx(dirs[i].length(), 1.0, 1e-5, "единичный")


## Яркость солнца — пропускание атмосферы (HH-11): днём 1, к горизонту падает, ниже горизонта 0.
func test_sun_luminance_from_transmission() -> void:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()
	approx(sky.sun_luminance_ratio(60.0, 600.0), 1.0, 1e-6, "выше 35° — дневная")
	var l5 := sky.sun_luminance_ratio(5.0, 600.0)
	var l2 := sky.sun_luminance_ratio(2.0, 600.0)
	var l07 := sky.sun_luminance_ratio(0.7, 600.0)
	check(l5 < 0.4 and l5 > 0.1, "на 5°: %.3f (≈0,2–0,3 дневной)" % l5)
	check(l2 < l5 * 0.4 and l07 < l2 * 0.3, "ниже — быстро слабее: 2° %.3f, 0,7° %.4f" % [l2, l07])
	check(l07 > 0.0, "на 0,7° солнце ещё светит")
	approx(sky.sun_luminance_ratio(-30.0, 600.0), 0.0, 1e-9, "под горизонтом точки — 0")
	# густая дымка — солнце у горизонта слабее
	sky.set_haze_density(3.0)
	check(sky.sun_luminance_ratio(5.0, 600.0) < l5, "гуще дымка — слабее солнце")
	sky.free()


func test_disk_dimmer_in_evening() -> void:
	# яркость диска, как её видно после квада дымки (он гасит диск; в небе она с компенсацией)
	var sky := SkyEnvironment.new()
	sky.apply_config()
	sky.clock.start_flight(51.0, 85.0, 10, 15, 12.0)
	var y := 600.0
	var noon := float(sky.sky_material().get_shader_parameter("disk_energy"))
	noon *= sky.haze_sky_transmission(sky.clock.angles().y, y)
	var h := 12.0
	while h < 20.0 and sky.clock.angles().y > 4.0:
		h += 0.05
		sky.clock.set_hour(h)
	var dusk := float(sky.sky_material().get_shader_parameter("disk_energy"))
	dusk *= sky.haze_sky_transmission(sky.clock.angles().y, y)
	check(dusk < noon * 0.7 and dusk > 0.0, "диск вечером тусклее: %.1f против %.1f" % [dusk, noon])
	check(noon > 6.0, "днём диск ярче белого тонмаппинга: %.1f" % noon)
	sky.free()


## Квад дымки гасит диск тем сильнее, чем ниже солнце; без дымки — не гасит.
func test_haze_sky_transmission_falls_toward_horizon() -> void:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()
	var t60 := sky.haze_sky_transmission(60.0, 600.0)
	var t5 := sky.haze_sky_transmission(5.0, 600.0)
	var t1 := sky.haze_sky_transmission(1.0, 600.0)
	check(t60 > t5 and t5 > t1 and t1 >= 0.03 - 1e-6, "T дымки: 60° %.3f, 5° %.3f, 1° %.3f" % [t60, t5, t1])
	approx(sky.haze_sky_transmission(-1.0, 600.0), 1.0, 1e-9, "под горизонтом диска нет — 1")
	sky.free()


func test_sky_shader_and_glare_created() -> void:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()  # без дерева: _ready не вызывается
	check(sky.sky_material() != null, "небо — ShaderMaterial")
	check(sky.sky_material().shader.resource_path.ends_with("sky.gdshader"), "свой шейдер неба")
	var day := float(sky.sky_material().get_shader_parameter("disk_energy"))
	check(day > 6.0, "диск солнца ярче белого тонмаппинга: %.1f" % day)
	check(sky.glare != null, "SunGlare создан")
	check(sky.haze_material() != null, "дымка на месте")
	sky.free()


## Диск, ореол и засвет — по истинной высоте солнца, свет рельефа зажат min_light_elevation_deg (HH-11).
func test_disk_at_true_elevation_light_clamped() -> void:
	var sky := SkyEnvironment.new()
	sky.apply_config()
	sky.clock.start_flight(51.0, 85.0, 10, 15, 12.0)
	var h := 12.0
	while h < 20.0 and sky.clock.angles().y > 1.0:
		h += 0.05
		sky.clock.set_hour(h)
	var el := sky.clock.angles().y
	check(el < 1.05 and el > 0.0, "высота солнца ≈ 1°: %.2f" % el)
	var disk: Vector3 = sky.sky_material().get_shader_parameter("sun_dir")
	approx(rad_to_deg(asin(disk.y)), el, 0.06, "диск — на настоящей высоте")
	var light := -sky.sun.transform.basis.z
	var min_el := float(Config.value("world", "time.min_light_elevation_deg", 2.0))
	approx(rad_to_deg(asin(-light.y)), min_el, 0.06, "свет — зажат")
	var m := sky.haze_material()
	if m != null:
		var hd: Vector3 = m.get_shader_parameter("sun_dir")
		approx(hd.dot(disk), 1.0, 1e-4, "дымка — к диску")
	sky.free()


## Диск у горизонта ещё различим, но тусклее дневного; засвет шире у более яркого солнца.
func test_glare_scales_with_sun_brightness() -> void:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()
	var info := sky.glare._mat.shader.get_shader_uniform_list()
	for n in ["veil_core", "veil_core_deg", "veil_wide", "veil_wide_deg", "disk_deg"]:
		check(info.any(func(u): return u.name == n), "параметр засвета %s" % n)
	sky.free()


## Цветность при солнце под горизонтом точки (в том числе при старте с ним): не белая, а на ближайшей высоте с T > 0.
func test_first_tint_below_horizon_not_white() -> void:
	var sky := SkyEnvironment.new()
	sky.apply_config()
	var c: Color = sky._tint(-3.0, 600.0, 1)
	check(c.r >= 0.0 and c.g < 0.5 and c.b < 0.2, "красная цветность, а не белая: %s" % c)
	sky.free()


func test_sky_disk_radius_not_enlarged() -> void:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()
	approx(
		rad_to_deg(float(sky.sky_material().get_shader_parameter("disk_radius"))), 0.3, 1e-4,
		"диск настоящего размера"
	)
	sky.free()
