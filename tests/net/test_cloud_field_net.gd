extends TestCase
## Поле облачности по сети (CLF-К4, CLF-4): снимок ведущего делает поля клиентов одинаковыми
## (побитно в RGBA8 К2 при blend 1), подтяжка с blend < 1 сходится за net_blend_s шагами NetFlight,
## чужая сетка или версия — снимок не применяется.


func _atmo(wind_kmh: float) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": wind_kmh}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(
		func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0
	)
	a.cloud_phys.async_field = false
	a.cloud_phys.deterministic = true
	a.add_static_thermal(0.0, 0.0, 4.0, 130.0)
	a.add_static_thermal(1500.0, 800.0, 3.5, 120.0)
	return a


## Поле к моменту t_end (разные клиенты — разное время и ветер, как разный Φ).
func _run(a: Atmosphere, t_end: float, dt: float) -> void:
	var t := dt
	while t <= t_end:
		a.time_s = t
		a.cloud_phys.refresh(a.field.thermals, t, Vector3.ZERO, 6000.0)
		t += dt
	a.cloud_phys.wait_field()


func _diff(a: CloudField, b: CloudField) -> int:
	var ia := a.to_image().get_data()
	var ib := b.to_image().get_data()
	var m := 0
	for i in ia.size():
		m = maxi(m, absi(int(ia[i]) - int(ib[i])))
	return m


func test_snapshot_makes_fields_equal() -> void:
	var lead := _atmo(0.0)
	var cli := _atmo(12.0)
	_run(lead, 1400.0, 100.0)
	_run(cli, 900.0, 60.0)
	var fl := lead.cloud_phys.field
	var fc := cli.cloud_phys.field
	check(fl.nx > 0 and fl.nx == fc.nx, "сетки одинаковы")
	var before := _diff(fl, fc)
	check(before > 0, "до снимка поля разные (разница %d)" % before)
	var snap := fl.snapshot()
	check(snap.size() < 10000, "снимок %d байт — единицы КБ" % snap.size())
	var r := cli.cloud_phys.apply_net_snapshot(snap, 1.0)
	check(r == CloudPhysics.Net.APPLIED, "применён")
	check(fc.to_image().get_data() == fl.to_image().get_data(), "после blend 1 побитно равны RGBA8")
	# рабочая копия тоже подтянута: следующий шаг считается от снимка, а не от старого состояния
	cli.cloud_phys.wait_field()
	check(cli.cloud_phys._work.to_image().get_data() == fl.to_image().get_data(), "рабочая копия равна снимку")
	lead.free()
	cli.free()


func test_blend_converges() -> void:
	var lead := _atmo(0.0)
	var cli := _atmo(12.0)
	_run(lead, 1400.0, 100.0)
	_run(cli, 900.0, 60.0)
	var fl := lead.cloud_phys.field
	var fc := cli.cloud_phys.field
	var snap := fl.snapshot()
	var d0 := _diff(fl, fc)
	# как NetFlight.sync_cloud_field: net_blend_s = 10 с, шаг 1 с, доля = шаг / оставшееся
	var left := 10.0
	var mid := -1
	while left > 0.0:
		var k := 1.0 if left <= 1.0 else 1.0 / left
		check(cli.cloud_phys.apply_net_snapshot(snap, k) == CloudPhysics.Net.APPLIED, "шаг подтяжки")
		left -= 1.0
		if is_equal_approx(left, 5.0):
			mid = _diff(fl, fc)
	check(mid >= 0 and mid < d0, "на полпути ближе (%d < %d)" % [mid, d0])
	check(_diff(fl, fc) <= 1, "за net_blend_s сошлись в пределах квантования (%d)" % _diff(fl, fc))
	lead.free()
	cli.free()


func test_alien_snapshot_rejected() -> void:
	var cli := _atmo(5.0)
	_run(cli, 600.0, 60.0)
	var fc := cli.cloud_phys.field
	var img := fc.to_image().get_data()
	var alien := CloudField.new({})
	alien.setup_grid(fc.nx + 1, fc.ny, fc.dx, fc.x0, fc.y0)
	alien.cover[3] = 0.9
	check(cli.cloud_phys.apply_net_snapshot(alien.snapshot(), 1.0) == CloudPhysics.Net.REJECTED, "чужая сетка")
	check(fc.to_image().get_data() == img, "поле не тронуто")
	# другая версия формата: первый байт заголовка
	var own := CloudField.new(fc.cfg)
	own.setup_grid(fc.nx, fc.ny, fc.dx, fc.x0, fc.y0)
	own.cover[3] = 0.9
	var raw := own.snapshot().decompress(CloudFieldCodec.expected_size(own), FileAccess.COMPRESSION_ZSTD)
	raw[0] = CloudField.FORMAT_VERSION + 1
	var bad := raw.compress(FileAccess.COMPRESSION_ZSTD)
	check(cli.cloud_phys.apply_net_snapshot(bad, 1.0) == CloudPhysics.Net.REJECTED, "чужая версия")
	check(fc.to_image().get_data() == img, "поле не тронуто версией")
	check(cli.cloud_phys.apply_net_snapshot(PackedByteArray([1, 2, 3]), 1.0) == CloudPhysics.Net.REJECTED, "мусор")
	cli.free()
