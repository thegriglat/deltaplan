extends TestCase
## Брелок-чайка (К16): физический маятник на нерастяжимой нити от ускорения точки подвеса.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_bar_charm

const DT := 1.0 / 60.0


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.bar_charm


func _make() -> EggBarCharm:
	var e := EggBarCharm.new()
	e.begin(EggContext.new(), _cfg(), RandomNumberGenerator.new(), 0.0)
	return e


## Точка подвеса в покое/с постоянным ускорением a (мир) в течение secs, потом возвращает отклонение.
func _run(e: EggBarCharm, a: Vector3, secs: float, p := Vector3(0, 1000, 0), v := Vector3.ZERO):
	for i in int(secs / DT):
		v += a * DT
		p += v * DT
		e.advance(p, Vector3.FORWARD, DT)
	return [p, v]


func test_hangs_down_at_rest() -> void:
	var e := _make()
	_run(e, Vector3.ZERO, 3.0)
	check(e.dir.angle_to(Vector3.DOWN) < deg_to_rad(0.5), "в покое висит вниз")
	e.free()


func test_forward_accel_swings_back_sideways_opposite() -> void:
	var e := _make()
	# вперёд = −Z крыла; чайка отклоняется назад (+Z)
	var st = _run(e, Vector3(0, 0, -4), 0.15)
	check(e.dir.z > 0.05, "ускорение вперёд: отклонение назад (z=%.3f)" % e.dir.z)
	e.free()
	e = _make()
	st = _run(e, Vector3(3, 0, 0), 0.15)
	check(e.dir.x < -0.05, "ускорение вправо: отклонение влево (x=%.3f)" % e.dir.x)
	e.free()


func test_constant_load_hangs_along_g_minus_a() -> void:
	var e := _make()
	var a := Vector3(2.0, 6.0, -3.0)  # перегрузка ~1,6 g, плюс разгон вперёд и вбок
	_run(e, a, 4.0)
	var want := (Vector3(0, -9.81, 0) - a).normalized()
	var err := rad_to_deg(e.dir.angle_to(want))
	check(err < 2.0, "висит вдоль g − a, ошибка %.2f°" % err)
	e.free()


func test_jerk_decays_and_cord_constant() -> void:
	var e := _make()
	var st = _run(e, Vector3.ZERO, 1.0, Vector3(0, 1000, 0), Vector3(0, 0, -12))
	var p: Vector3 = st[0]
	var v: Vector3 = st[1]
	st = _run(e, Vector3(5, 0, -10), 0.2, p, v)  # рывок
	p = st[0]
	v = st[1]
	var env: Array = []
	var len_err := 0.0
	for w in 6:  # окна по 0,5 с: максимальное отклонение от вертикали
		var m := 0.0
		for i in int(0.5 / DT):
			p += v * DT
			e.advance(p, Vector3.FORWARD, DT)
			m = maxf(m, e.dir.angle_to(Vector3.DOWN))
			len_err = maxf(len_err, absf(e._charm.position.distance_to(p) - e.length_m))
		env.append(m)
	check(env[0] > deg_to_rad(10.0), "рывок раскачал: %.1f°" % rad_to_deg(env[0]))
	for k in range(1, 6):
		check(env[k] < env[k - 1], "огибающая убывает, окно %d" % k)
	check(env[5] < env[0] * 0.2, "к концу почти затухло")
	check(len_err < 1e-4, "длина нити постоянна, ошибка %.3f мкм" % (len_err * 1e6))
	e.free()


func test_big_dt_stable() -> void:
	var e := _make()
	var p := Vector3(0, 1000, 0)
	for i in 20:
		p += Vector3(0.3, 0, -0.5)
		e.advance(p, Vector3.FORWARD, 0.25)
		check(is_finite(e.dir.x) and absf(e.dir.length() - 1.0) < 1e-4, "dt 0,25: конечно")
	e.free()


func test_cpu_ms_bar_charm() -> void:
	var e := _make()
	var p := Vector3(0, 1000, 0)
	var n := 20000
	var t0 := Time.get_ticks_usec()
	for i in n:
		p += Vector3(0.2, sin(i * 0.05) * 0.1, -0.5)
		e.advance(p, Vector3.FORWARD, DT)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / n
	print("cpu_ms_bar_charm=%.4f" % ms)
	check(ms <= 0.02, "cpu_ms_bar_charm %.4f > 0,02" % ms)
	e.free()
