extends TestCase
## Запечённое поле на GPU (TI-4, TI-К3): поле Онгудая (старт kayancha_south, область 400 м + окна 100 и 50 м)
## считается AirRuntime → запекается в файлы → новый AirRuntime берёт его из файла: поле совпадает
## (≤ 0,01 м/с), поле старта сразу не пересчитывается, источники термиков построены, затем идёт обычный
## фоновый пересчёт (окна у пилота, тёплый старт) с плавной подменой.
## tools/gpu_tests.sh --filter=baked. Замеры (размер файла, время загрузки против расчёта) — в вывод.

const AR := preload("res://tests/atmosphere/test_air_runtime_gpu.gd")
const ROOT := "user://ti4_baked_gpu"
const SITE := "kayancha_south"
const START_LATLON := Vector2(50.78708, 86.23278)
const TOL_MS := 0.01

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


static func weather() -> Dictionary:
	return {
		"wind_from_deg": 150, "wind_speed_ms": 3.0, "start_hour": 12.0, "month": 7, "day": 15,
		"sky": "clear", "temperature_c": 25.0,
	}


func _place() -> Dictionary:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	loc.month = int(weather().month)
	loc.day = int(weather().day)
	var p := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	var pos := Vector3(p.x, (lw[0] as HeightLayer).sample(p.x, p.y), p.y)
	return {
		detail = lw[0], water = lw[1], loc = loc,
		start_sites = [{id = SITE, position = pos, weather = weather()}],
	}


func _runtime(place: Dictionary) -> Array:
	var atmo := AR._atmo(place.detail)
	atmo.field.air_async = false
	var rt := AirRuntime.new()
	rt.cache_enabled = false  # расчёт, не кеш поля (FL-К1)
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, place, _cond)
	var pos: Vector3 = place.start_sites[0].position
	rt.set_focus(null, pos)
	return [rt, atmo]


func _err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for q in a.size():
		e = maxf(e, absf(a[q] - b[q]))
	return e


func test_baked_roundtrip_ongudai() -> void:
	await Engine.get_main_loop().process_frame
	AirBakedField.baked_root = ROOT
	_c = AirBakedField.conditions_of(weather())
	var place := _place()
	# ---- расчёт (как при загрузке без файла) и запекание
	var r1 := _runtime(place)
	var rt1: AirRuntime = r1[0]
	var atmo1: Atmosphere = r1[1]
	rt1.baked_enabled = false
	check(rt1.unavailable_reason() == "", "расчёт доступен: %s" % rt1.unavailable_reason())
	var t0 := Time.get_ticks_usec()
	var ok: bool = await rt1.load_field()
	var calc_s := (Time.get_ticks_usec() - t0) / 1e6
	check(ok, "поле посчитано: %s" % rt1.last_error)
	if not ok:
		return
	var levels1: Array[WindField] = atmo1.air_field.levels
	check(levels1.size() == 3, "три уровня (область и два окна): %d" % levels1.size())
	var loc: Dictionary = place.loc
	var key := AirBakedField.make_key(
		"ongudai", float(loc.center_lat), float(loc.center_lon), SITE, weather(),
		place.start_sites[0].position, AirBakedField.place_hash(Locations.data_dir("ongudai")),
		Config.get_config("atmosphere").air_model.window_levels_m
	)
	var path := AirBakedField.path_of("ongudai", SITE, ROOT)
	var t1 := Time.get_ticks_usec()
	var h := {"location": "ongudai", "site": SITE, "key": key, "model_hash": AirBakedField.model_hash()}
	check(AirBakedField.save(atmo1.air_field, h, path), "запись")
	var save_s := (Time.get_ticks_usec() - t1) / 1e6
	var mb := FileAccess.get_file_as_bytes(path.trim_suffix(".json") + ".bin").size() / 1.0e6
	# ---- загрузка из файла новым AirRuntime
	var r2 := _runtime(place)
	var rt2: AirRuntime = r2[0]
	var atmo2: Atmosphere = r2[1]
	check(rt2.baked_ready(), "baked_ready")
	var t2 := Time.get_ticks_usec()
	var ok2: bool = await rt2.load_field()
	var load_s := (Time.get_ticks_usec() - t2) / 1e6
	check(ok2 and rt2.last_info.get("baked", false) == true, "поле из файла: %s" % rt2.last_error)
	print(
		"  файл на старт %.2f МБ (float16 + zstd), запись %.2f с; загрузка из файла %.2f с против расчёта %.2f с"
		% [mb, save_s, load_s, calc_s]
	)
	if not ok2:
		return
	var levels2: Array[WindField] = atmo2.air_field.levels
	check(levels2.size() == levels1.size(), "число уровней то же")
	var worst := 0.0
	for q in mini(levels1.size(), levels2.size()):
		var a: WindField = levels1[q]
		var b: WindField = levels2[q]
		var e := maxf(_err(a._vel, b._vel), maxf(_err(a._wconv, b._wconv), _err(a._theta, b._theta)))
		worst = maxf(worst, e)
		check(e <= TOL_MS, "уровень %d: ошибка %.5f ≤ %.2f м/с" % [q, e, TOL_MS])
		check(a._hc == b._hc and a.heat_flux() == b.heat_flux(), "рельеф и поток тепла побитно (уровень %d)" % q)
	print("  наибольшая ошибка float16: %.5f м/с" % worst)
	# выборка у старта
	var sp: Vector3 = place.start_sites[0].position
	var s1 := atmo1.air_field.sample(sp + Vector3(0, 30, 0), sp.y)
	var s2 := atmo2.air_field.sample(sp + Vector3(0, 30, 0), sp.y)
	check(absf(s1.x - s2.x) <= 2.0 * TOL_MS and absf(s1.z - s2.z) <= 2.0 * TOL_MS, "выборка у старта совпала")
	# ---- состояние: поле старта сразу не пересчитывается
	check(not rt2.busy(), "после загрузки расчёт не идёт")
	check(AirRuntime.needs_recompute(rt2.current_conditions(), _c, 15.0) == "", "needs_recompute пуст")
	check(rt2.inflow_k > 0.0 and is_equal_approx(rt2.inflow_k, rt1.inflow_k), "k притока как у расчёта")
	# ---- источники термиков из поля
	atmo2.field._update_air()
	atmo2.field.air_wait()
	check(atmo2.field.air_src != null and atmo2.field.air_src.count() > 0, "источники термиков построены")
	# ---- recompute_enabled: при тех же условиях и пилоте у старта пересчёта нет
	var baked_levels: Array[WindField] = atmo2.air_field.levels.duplicate()
	rt2.recompute_enabled = true
	var n0 := rt2.applied_count
	for _i in 120:
		await Engine.get_main_loop().process_frame
	check(rt2.applied_count == n0 and not rt2.busy(), "тот же час и условия, пилот у старта — пересчёта нет")
	# ---- замер: холодный пересчёт при тех же условиях против запечённого поля (окно 50 м у старта)
	rt2._baked_pending = false
	rt2._begin(rt2.conditions_fn.call(), "замер", false)
	var t3 := Time.get_ticks_msec()
	while rt2.applied_count == n0 and rt2.failed_count == 0 and (Time.get_ticks_msec() - t3) < 90000:
		await Engine.get_main_loop().process_frame
	check(rt2.applied_count == n0 + 1, "холодный пересчёт подан (ошибка: %s)" % rt2.last_error)
	if rt2.applied_count == n0 + 1:
		var fa := AirFieldSet.new()
		fa.set_field(baked_levels, 0.0)
		var fb := AirFieldSet.new()
		fb.set_field(atmo2.air_field.levels, 0.0)
		var du := 0.0
		var dw := 0.0
		for ix in range(-2, 3):
			for iz in range(-2, 3):
				for agl in [10.0, 30.0, 60.0, 100.0, 150.0, 200.0, 300.0]:
					var q := Vector3(sp.x + ix * 12.5, 0.0, sp.z + iz * 12.5)
					q.y = (place.detail as HeightLayer).sample(q.x, q.z) + agl
					var va := fa.sample(q, sp.y)
					var vb := fb.sample(q, sp.y)
					du = maxf(du, Vector2(va.x - vb.x, va.z - vb.z).length())
					dw = maxf(dw, absf(va.y - vb.y))
		print(
			"  запечённое против холодного пересчёта, окно 50 м у старта, 0–300 м: max|Δu| %.3f, max|Δw| %.3f м/с (%s)"
			% [du, dw, rt2.last_info.get("reason")]
		)
	rt1.queue_free()
	rt2.queue_free()
	atmo1.free()
	atmo2.free()
	AirBakedField.baked_root = "res://data/locations"
	var d := ROOT.path_join("ongudai").path_join("air")
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))
