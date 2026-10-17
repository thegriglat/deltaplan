extends TestCase
## Облака с первого кадра полёта (CLF-12): после старта в t = 13 ч (Atmosphere.start_at, как
## Game.set_world_time) поле облачности разогнано и подхвачено за ≤ 2 с реального времени —
## разгон идёт в рабочем потоке сразу, готовый результат принимается покадровым poll(), как в
## CloudLayer, а не ждёт следующего refresh. Печатает cloud_ready_after_s.

const T_START := 13.0 * 3600.0


func _atmo() -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": 0.0}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(
		func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0
	)
	a.cloud_phys.async_field = true
	a.cloud_phys.deterministic = false  # как в игре с экраном
	a.add_static_thermal(0.0, 0.0, 4.0, 130.0)
	a.add_static_thermal(1500.0, 800.0, 3.5, 120.0)
	return a


func test_cloud_ready_after_start() -> void:
	var a := _atmo()
	var step_s := float(Config.get_config("atmosphere").cloud_field.step_s)
	var cp := a.cloud_phys
	var t0 := Time.get_ticks_usec()
	a.start_at(T_START)
	var ready := -1.0
	var v0 := cp.field_version
	# кадры по 16 мс: физика атмосферы (refresh раз в интервал) + покадровый poll слоя
	for k in 1500:
		a.step(0.016)
		cp.poll()
		if cp.field.nx > 0 and cp.field.time >= T_START - step_s:
			ready = float(Time.get_ticks_usec() - t0) / 1.0e6
			break
		OS.delay_msec(16)
	cp.wait_field()
	print("cloud_ready_after_s=%.2f" % ready)
	check(ready >= 0.0 and ready <= 2.0, "поле готово ≤ 2 с после старта (%.2f)" % ready)
	check(cp.field_version > v0, "версия данных поля выросла")
	a.free()


func test_field_version_on_swap() -> void:
	var a := _atmo()
	a.start_at(T_START)
	var cp := a.cloud_phys
	cp.wait_field()
	var v := cp.field_version
	cp.mark_field_changed()
	check(cp.field_version == v + 1, "mark_field_changed растит версию")
	a.free()
