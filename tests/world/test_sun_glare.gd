extends TestCase
## Солнце и ослепление: луч к солнцу через рельеф и облака (SunGlare.trace_sun), кольцо лучей
## по диску, вечером диск и ослепление слабее (time.light), небо — свой шейдер с диском.


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


func test_evening_sun_weaker() -> void:
	var noon := SunClock.light_at(50.0)
	var dusk := SunClock.light_at(4.0)
	check(float(dusk.disk_energy) < float(noon.disk_energy) * 0.5, "диск вечером тусклее")
	check(float(dusk.glare) < float(noon.glare) * 0.5, "вечером слепит слабее")


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
