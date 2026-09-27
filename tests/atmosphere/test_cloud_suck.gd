extends TestCase
## Облачный подсос (FR-14b): под крупным живым облаком подъём у основания сильнее и продолжается
## в облако; под молодым и распадающимся — слабеет у кромки; cloud_density_at; болтанка в облаке.


func _atmo_with_cloud(stage: Vector3 = Vector3(-1, 0, 0)) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": 0.0}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0,
		func(_x: float, _z: float) -> float: return 1.0)
	var id := a.add_static_thermal(0.0, 0.0, 4.0, 130.0)
	if stage.x >= 0.0:
		a.cloud_phys.model.stage_override[id] = stage
	a.step(1.0)
	return a


func test_suck_under_mature_cloud() -> void:
	var a := _atmo_with_cloud()
	var cb := a.get_cloudbase_msl()
	var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
	var base := a.air_velocity_at(Vector3(0, cb - 40.0, 0)).y
	check(base > mid * 1.2, "у основания крупного облака подъём сильнее: %.2f > %.2f" % [base, mid])
	a.free()


func test_in_cloud_chaos_and_eject() -> void:
	# В облаке — не поток, а бурление: средний подъём слабый, пульсации большие, «выкидывает» к краю.
	var a := _atmo_with_cloud()
	a.turbulence_enabled = true
	var cb := a.get_cloudbase_msl()
	var base := a.air_velocity_at(Vector3(0, cb - 40.0, 0)).y
	var sum := Vector3.ZERO
	var sum2 := 0.0
	var n := 400
	for i in n:
		var p := Vector3(150.0 + (i % 20) * 1.5, cb + 200.0 + (i / 20) * 1.5, 30.0)
		var v := a.air_velocity_at(p)
		sum += v
		sum2 += v.y * v.y
	var mean := sum / n
	var sigma := sqrt(sum2 / n - mean.y * mean.y)
	check(mean.y < base * 0.6, "в облаке средний подъём слабее, чем у основания: %.2f" % mean.y)
	check(sigma > 1.5, "в облаке бурление: σ = %.2f м/с" % sigma)
	check(mean.x > 0.5, "выкидывает к краю (точки восточнее центра): %.2f" % mean.x)
	check(a.turbulence_intensity_at(Vector3(150, cb + 200, 30)) > 2.0, "метрика болтанки в облаке")
	check(
		a.turbulence_intensity_at(Vector3(3000, cb - 500, 0)) < 1.5, "метрика болтанки вне облака"
	)
	a.free()


func test_no_suck_under_young_or_decaying() -> void:
	for st in [Vector3(0.3, 0.0, 1.0), Vector3(1.0, 0.7, 0.2)]:
		var a := _atmo_with_cloud(st)
		var cb := a.get_cloudbase_msl()
		var mid := a.air_velocity_at(Vector3(0, cb * 0.5, 0)).y
		var base := a.air_velocity_at(Vector3(0, cb - 20.0, 0)).y
		check(base < mid * 0.6, "стадия %s: у кромки слабеет %.2f < %.2f" % [st, base, mid])
		a.free()


func test_cloud_density_at() -> void:
	var a := _atmo_with_cloud()
	var cb := a.get_cloudbase_msl()
	check(a.cloud_density_at(Vector3(0, cb + 150.0, 0)) > 0.3, "в облаке плотность > 0")
	approx(a.cloud_density_at(Vector3(0, cb - 100.0, 0)), 0.0, 1e-6, "под облаком ясно")
	approx(a.cloud_density_at(Vector3(5000, cb + 150.0, 0)), 0.0, 1e-6, "в стороне ясно")
	# Дёшево: 10 000 вызовов.
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		a.cloud_density_at(Vector3(i * 0.3, cb + 150.0, 0))
	var us := float(Time.get_ticks_usec() - t0) / 10000.0
	check(us < 20.0, "cloud_density_at дёшево: %.2f мкс" % us)
	a.free()


func test_turbulence_stronger_in_cloud() -> void:
	var a := _atmo_with_cloud()
	a.turbulence_enabled = true
	var cb := a.get_cloudbase_msl()
	var s_in := 0.0
	var s_out := 0.0
	for i in 300:
		var p := Vector3(-300.0 + i * 2.0, cb + 150.0, 40.0)
		var q := Vector3(-300.0 + i * 2.0, cb - 350.0, 40.0)
		s_in += (a.air_velocity_at(p) - a.mean_wind_at(p)).length_squared()
		s_out += (a.air_velocity_at(q) - a.mean_wind_at(q)).length_squared()
	check(s_in > s_out * 1.2, "в облаке болтает сильнее: %.1f > %.1f" % [s_in / 300, s_out / 300])
	a.free()
