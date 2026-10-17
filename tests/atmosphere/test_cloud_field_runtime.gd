extends TestCase
## Поле облачности в симуляции (CLF-3): CloudPhysics держит CloudField и шагает его в рабочем потоке;
## на главном потоке refresh дёшев (печатает cloud_refresh_main_ms), результат потока совпадает с
## синхронным, облачность поля видна физике (плотность, подсос, число облаков), боты видят облака.


func _atmo(async_field: bool, deterministic: bool) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": 0.0}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(
		func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0
	)
	a.cloud_phys.async_field = async_field
	a.cloud_phys.deterministic = deterministic
	a.add_static_thermal(0.0, 0.0, 4.0, 130.0)
	a.add_static_thermal(1500.0, 800.0, 3.5, 120.0)
	return a


func test_refresh_main_ms() -> void:
	# Не блокирует: рабочий поток шагает поле (включая разгон при первом refresh), главный — снимок
	# входов и подмена. Максимум за 30 вызовов refresh с шагом времени 1 с.
	var a := _atmo(true, false)
	var worst := 0.0
	for k in 30:
		a.time_s = float(k)
		var t0 := Time.get_ticks_usec()
		a.cloud_phys.refresh(a.field.thermals, a.time_s, Vector3.ZERO, 6000.0)
		worst = maxf(worst, float(Time.get_ticks_usec() - t0) / 1000.0)
		OS.delay_msec(5)
	a.cloud_phys.wait_field()
	print("cloud_refresh_main_ms=%.2f" % worst)
	check(worst <= 2.0, "refresh на главном потоке ≤ 2 мс (макс %.2f)" % worst)
	a.free()


func test_thread_matches_sync() -> void:
	var a := _atmo(true, true)
	var b := _atmo(false, true)
	for k in 5:
		var t := 100.0 * (k + 1)
		a.time_s = t
		b.time_s = t
		a.cloud_phys.refresh(a.field.thermals, t, Vector3.ZERO, 6000.0)
		b.cloud_phys.refresh(b.field.thermals, t, Vector3.ZERO, 6000.0)
	a.cloud_phys.wait_field()
	b.cloud_phys.wait_field()
	var fa := a.cloud_phys.field
	var fb := b.cloud_phys.field
	check(fa.nx > 0 and fa.signature() == fb.signature(), "сетка поля есть и совпадает")
	check(fa.cover == fb.cover and fa.depth == fb.depth, "поток и синхронный шаг — побитно те же массивы")
	check(fa.time == fb.time, "время поля то же")
	a.free()
	b.free()


func test_field_cloud_seen_by_physics() -> void:
	var a := _atmo(false, true)
	a.time_s = 3000.0
	a.refresh_now()
	a.time_s = 3001.0
	a.refresh_now()
	var f := a.cloud_phys.field
	var cb := a.get_cloudbase_msl()
	var s := f.sample(Vector3(0, cb + 100.0, 0))
	check(s.x > 0.05, "над статичным термиком облако поля: покрытие %.2f" % s.x)
	check(a.cloud_phys.cloud_count() > 0, "cloud_count > 0 при облачности у фокуса")
	check(a.cloud_density_at(Vector3(0, cb + 150.0, 0)) > 0.1, "плотность в облаке из поля")
	approx(a.cloud_density_at(Vector3(0, cb - 100.0, 0)), 0.0, 1e-6, "под основанием ясно")
	approx(a.cloud_density_at(Vector3(15000, cb + 150.0, 0)), 0.0, 0.05, "вдали ясно")
	var th: AtmoThermal = a.field.thermals.values()[0]
	check(a.cloud_phys.suck(th, a.time_s).x >= th.suck, "подсос не меньше собственного")
	a.free()


func test_bots_see_field_clouds() -> void:
	var a := _atmo(false, true)
	a.time_s = 3000.0
	a.refresh_now()
	a.time_s = 3001.0
	a.refresh_now()
	var clouds: Array = BotPilots._visible_clouds(a)
	check(not clouds.is_empty(), "боты видят облака поля")
	for c: Dictionary in clouds:
		check(float(c.radius) > 0.0 and c.center is Vector2, "облако: центр и радиус")
	a.free()


func test_shade_at_uses_field() -> void:
	# Тень поля над точкой земли: покрытие × непрозрачность, смещена от облака против солнца.
	var a := _atmo(false, true)
	a.time_s = 3000.0
	a.refresh_now()
	a.time_s = 3001.0
	a.refresh_now()
	var f := a.cloud_phys.field
	var sun := Vector3(0.0, 1.0, 0.0)
	check(f.shade_at(Vector2(0, 0), sun) > 0.1, "под облаком поля тень")
	approx(f.shade_at(Vector2(15000, 0), sun), 0.0, 0.05, "вдали тени нет")
	a.free()


func test_refresh_main_ms_many_thermals() -> void:
	# Аналитика с сотнями термиков (радиус игры 20 км): снимок входов для потока — на главном потоке,
	# каждый вызов refresh с шагом времени шага поля (самый тяжёлый случай).
	var cfg := Config.get_config("atmosphere").duplicate(true)
	var a := AtmoFingerprint.make_world(AtmoFingerprint.DEFAULT_KEY, cfg)
	a.cloud_phys.deterministic = false
	AtmoFingerprint.run_to(a, 600.0, 1.0)
	var step := float(Config.get_config("atmosphere").cloud_field.step_s)
	var worst := 0.0
	for k in 12:
		a.time_s = 600.0 + k * step
		var t0 := Time.get_ticks_usec()
		a.cloud_phys.refresh(a.field.thermals, a.time_s, AtmoFingerprint.CENTER, 6000.0)
		worst = maxf(worst, float(Time.get_ticks_usec() - t0) / 1000.0)
		a.cloud_phys.wait_field()
	print("cloud_refresh_many_ms=%.2f (термиков %d)" % [worst, a.field.thermals.size()])
	check(worst <= 3.0, "refresh при %d термиках ≤ 3 мс (макс %.2f)" % [a.field.thermals.size(), worst])
	a.free()
