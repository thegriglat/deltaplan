extends TestCase
## Свет солнца на облаках через пропускание атмосферы (HH-7): нормировка днём, облака выше горизонта
## земли при зашедшем солнце, низ краснее верха на закате, граница T = 0, стоимость сборки.

const EXT := 3.912 / 60000.0 * 1.5
const RGB := Vector3(0.85, 1.0, 1.2)
const TOP := 2200.0
const VALLEY := 600.0


func _t(el: float, h: float, ext: float = EXT) -> Vector3:
	return SunTransmission.transmission(el, h, ext, RGB, TOP, SunTransmission.params())


func test_day_normalization() -> void:
	# Днём (солнце ≥ 35°) у основания облака на высоте долины свет совпадает с прежним ±5 %:
	# таблица зажата краем 30°, недостающее даёт sun_factor (как в CloudLayer).
	var p := SunTransmission.params()
	var tr := _t(p.ref_el_deg, VALLEY)
	for ext in [0.0, EXT]:
		for el in [35.0, 50.0, 80.0]:
			var f := SunTransmission.sun_factor(el, ext, RGB, TOP, VALLEY, p)
			var t := _t(minf(el, p.el_max_deg), VALLEY, ext)
			var tr_e := _t(p.ref_el_deg, VALLEY, ext)
			for c in 3:
				var r: float = t[c] * f[c] / tr_e[c]
				check(absf(r - 1.0) <= 0.05, "ext %s, el %s°, канал %d: отношение к прежнему %.3f" % [ext, el, c, r])
	# Опорный случай — ровно 1, ниже el_max поправки нет.
	check(SunTransmission.sun_factor(20.0, EXT, RGB, TOP, VALLEY, p) == Vector3.ONE, "ниже el_max поправка 1")
	check(tr.y > 0.0, "T_ref > 0")


func test_cloud_lit_after_ground_sunset() -> void:
	var t3 := _t(-1.0, 3000.0)
	check(t3.y > 0.0, "el = −1°, облако на 3 км освещено: T(G) = %.4f" % t3.y)
	var t0 := _t(-1.0, 0.0)
	check(t0 == Vector3.ZERO, "el = −1°, у моря темно: T = %s" % t0)


func test_low_base_redder() -> void:
	var lo := _t(3.0, 1000.0)
	var hi := _t(3.0, 5000.0)
	check(lo.x / lo.z > hi.x / hi.z, "el = 3°: R/B на 1 км (%.2f) больше, чем на 5 км (%.2f)" % [lo.x / lo.z, hi.x / hi.z])


func test_build_cost() -> void:
	var t0 := Time.get_ticks_usec()
	var img := SunTransmission.build(EXT, RGB, TOP)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("sun_transmission: build 64×64 = %.1f мс" % ms)
	check(img.get_width() == 64, "собрана")
	check(ms < 3000.0, "сборка таблицы %.0f мс — слишком долго" % ms)


func test_steps_converged() -> void:
	# 32 шага на отрезок — против 512 (сходимость интегрирования) по всей таблице, G-канал.
	var p := SunTransmission.params()
	var fine := p.duplicate()
	fine.steps = 512
	var worst := 0.0
	for el in [-3.0, 0.0, 1.0, 5.0, 15.0, 30.0]:
		for h in [0.0, 500.0, 3000.0, 12000.0]:
			var a := SunTransmission.optical_depth(el, h, EXT, RGB, TOP, p)
			var b := SunTransmission.optical_depth(el, h, EXT, RGB, TOP, fine)
			if b.y < 0.0:
				continue
			worst = maxf(worst, absf(a.y - b.y) / maxf(b.y, 1e-3))
	check(worst < 0.01, "расхождение 32 и 512 шагов %.4f" % worst)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sunf(_x: float, _z: float) -> float:
	return 1.0


## Слой облаков с небом (дымка и часы) — без дерева сцены: узел неба подставляется напрямую.
func _layer() -> Array:
	var cfg := Config.get_config("atmosphere").duplicate(true)
	cfg.clouds.renderer = "boxes"
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = 7
	a.configure(cfg, Config.get_config("weather/medium"))
	a.turbulence_enabled = false
	a.set_ground(_flat, _sunf)
	a.set_focus(Vector3.ZERO)
	var sky := SkyEnvironment.new()
	sky.apply_config()
	var layer := CloudLayer.new()
	layer.history_free = true
	layer.setup(a)
	layer._sky = sky
	return [layer, sky, a]


func _free(arr: Array) -> void:
	(arr[0] as CloudLayer).free()
	(arr[1] as SkyEnvironment).free()


func test_layer_day_and_below_horizon() -> void:
	var arr := _layer()
	var layer: CloudLayer = arr[0]
	var sky: SkyEnvironment = arr[1]
	var m := layer._material
	# День: таблица включена, солнце высоко — край таблицы по высоте солнца, свет — опорный (35°).
	sky.clock.start_flight(51.0, 85.0, 7, 15, 13.0)
	layer._update_light()
	check(float(m.get_shader_parameter("sun_tab_on")) > 0.5, "таблица включена")
	check(layer.sun_tab_builds == 1, "таблица собрана при старте: %d" % layer.sun_tab_builds)
	var p := SunTransmission.params()
	var lt := SunClock.light_at(p.ref_el_deg)
	var e: float = float(m.get_shader_parameter("sun_energy"))
	check(absf(e - 1.2 * float(lt.sun_energy) * layer.atmo.get_insolation()) < 1e-3, "яркость — свет на 35°: %.3f" % e)
	var tref: Vector3 = m.get_shader_parameter("sun_tref")
	check(tref.y > 0.0 and tref.x >= tref.y and tref.y >= tref.z, "T_ref = %s" % tref)
	# Зима, вечер: солнце под горизонтом — направление для облаков настоящее, для света рельефа зажато.
	sky.clock.start_flight(51.0, 85.0, 12, 21, 19.0)
	layer._update_light()
	var d_true: Vector3 = m.get_shader_parameter("sun_dir_t")
	var d_clamped: Vector3 = m.get_shader_parameter("sun_dir")
	check(d_true.y < -0.1, "солнце ниже горизонта у облаков: y = %.3f" % d_true.y)
	check(d_clamped.y >= -1.0e-6, "sun_dir (тени, рельеф) не ниже горизонта: y = %.3f" % d_clamped.y)
	check(absf(d_true.length() - 1.0) < 1e-4, "направление единичное")
	_free(arr)


func test_layer_rebuild_threshold() -> void:
	var arr := _layer()
	var layer: CloudLayer = arr[0]
	var sky: SkyEnvironment = arr[1]
	sky.clock.start_flight(51.0, 85.0, 7, 15, 13.0)
	sky.set_haze_density(1.0)
	layer._update_light()
	check(layer.sun_tab_builds == 1, "первая сборка")
	sky.set_haze_density(1.03)
	layer._update_light()
	check(layer._tab_task < 0 and layer.sun_tab_builds == 1, "дымка +3 % — без пересборки")
	sky.set_haze_density(1.5)
	layer._update_light()
	check(layer._tab_task >= 0, "дымка +50 % — пересборка в фоне")
	while not WorkerThreadPool.is_task_completed(layer._tab_task):
		OS.delay_msec(5)
	layer._update_light()
	check(layer.sun_tab_builds == 2, "таблица обновлена: %d" % layer.sun_tab_builds)
	_free(arr)
