extends TestCase
## Кеш поля на GPU (FL-2, FL-К1): поле Онгудая (старт у Каянчи, область 400 м + окна 100 и 50 м)
## считается AirRuntime при загрузке и фоном пишется в кеш; новый AirRuntime берёт его из кеша без
## расчёта: поле совпадает (|Δu, v, w| ≤ 0,01 м/с), чтение и подача ≤ 1 с, наибольший кадр главного
## потока при записи и при чтении ≤ 100 мс. tools/gpu_tests.sh --filter=air_cache. Замеры — в вывод.

const AR := preload("res://tests/atmosphere/test_air_runtime_gpu.gd")
const DIR := "user://air_cache_gpu_test"
const START_LATLON := Vector2(50.78708, 86.23278)
const TOL_MS := 0.01
const HIT_MAX_S := 1.0
const FRAME_MAX_MS := 100.0

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


func _place() -> Dictionary:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	loc.month = 7
	loc.day = 15
	var p := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	var pos := Vector3(p.x, (lw[0] as HeightLayer).sample(p.x, p.y), p.y)
	return {detail = lw[0], water = lw[1], loc = loc, start = pos}


func _cache() -> AirFieldCache:
	var c := AirFieldCache.new()
	c.dir = DIR
	return c


func _runtime(place: Dictionary) -> Array:
	var atmo := AR._atmo(place.detail)
	atmo.field.air_async = false
	var rt := AirRuntime.new()
	rt.baked_enabled = false
	rt.cache_enabled = true
	rt.cache_override = _cache()
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, {detail = place.detail, water = place.water, loc = place.loc}, _cond)
	rt.set_focus(null, place.start)
	return [rt, atmo]


func _err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for q in a.size():
		e = maxf(e, absf(a[q] - b[q]))
	return e


## Наибольший интервал кадров, мс, пока cond() истинно (не дольше limit_s).
func _max_frame_while(cond: Callable, limit_s: float) -> Array:
	var tree := Engine.get_main_loop() as SceneTree
	var t_end := Time.get_ticks_usec() + int(limit_s * 1e6)
	var prev := Time.get_ticks_usec()
	var worst := 0.0
	var n := 0
	while cond.call() and Time.get_ticks_usec() < t_end:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - prev) / 1000.0)
		prev = now
		n += 1
	return [worst, n]


func test_air_cache_gpu_roundtrip_ongudai() -> void:
	await Engine.get_main_loop().process_frame
	var cache := _cache()
	for f in DirAccess.get_files_at(DIR) if DirAccess.dir_exists_absolute(DIR) else PackedStringArray():
		DirAccess.remove_absolute(DIR.path_join(f))
	_c = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = 25.0, sky = "clear", wind_ref = "start"}
	var place := _place()
	# ---- расчёт при загрузке → запись фоном
	var r1 := _runtime(place)
	var rt1: AirRuntime = r1[0]
	var atmo1: Atmosphere = r1[1]
	check(rt1.unavailable_reason() == "", "расчёт доступен: %s" % rt1.unavailable_reason())
	check(not rt1.cache_ready(), "кеш пуст")
	var t0 := Time.get_ticks_usec()
	var ok: bool = await rt1.load_field()
	var calc_s := (Time.get_ticks_usec() - t0) / 1e6
	check(ok and rt1.last_info.get("cache", false) != true, "поле посчитано: %s" % rt1.last_error)
	if not ok:
		return
	var levels1: Array[WindField] = atmo1.air_field.levels
	check(levels1.size() == 3, "три уровня: %d" % levels1.size())
	var tw := Time.get_ticks_usec()
	var wr: Array = await _max_frame_while(rt1.cache_writing, 60.0)
	var write_s := (Time.get_ticks_usec() - tw) / 1e6
	check(not rt1.cache_writing(), "запись закончилась за %.2f с" % write_s)
	check(float(wr[0]) <= FRAME_MAX_MS, "кадр при записи %.1f мс ≤ %.0f (%d кадров)" % [wr[0], FRAME_MAX_MS, wr[1]])
	var key := rt1.cache_key(_c)
	var nm := AirFieldCache.name_of(key)
	var mb := cache.total_bytes() / 1.0e6
	check(cache.entries().has(nm), "запись в index.json")
	var h := AirBakedField.read_header(DIR.path_join(nm))
	check(h.get("status") in ["ok", "not_converged", "previous_pass"], "status: %s" % h.get("status"))
	# ---- новый AirRuntime: из кеша
	var r2 := _runtime(place)
	var rt2: AirRuntime = r2[0]
	var atmo2: Atmosphere = r2[1]
	check(rt2.cache_ready(), "cache_ready")
	var state := {done = false}
	var frames: Array = []
	var watch := func() -> void: frames.append(await _max_frame_while(func() -> bool: return not state.done, 10.0))
	watch.call()
	var t2 := Time.get_ticks_usec()
	var ok2: bool = await rt2.load_field()
	var hit_s := (Time.get_ticks_usec() - t2) / 1e6
	state.done = true
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	check(ok2 and rt2.last_info.get("cache", false) == true, "поле из кеша: %s" % rt2.last_error)
	check(rt2.applied_count == 1 and not rt2.busy(), "расчёта не было")
	check(hit_s <= HIT_MAX_S, "чтение и подача %.2f с ≤ %.1f" % [hit_s, HIT_MAX_S])
	var read_frame := float(frames[0][0]) if not frames.is_empty() else NAN
	check(read_frame <= FRAME_MAX_MS, "кадр при чтении %.1f мс ≤ %.0f" % [read_frame, FRAME_MAX_MS])
	if not ok2:
		return
	var levels2: Array[WindField] = atmo2.air_field.levels
	check(levels2.size() == levels1.size(), "число уровней то же")
	var worst := 0.0
	for q in mini(levels1.size(), levels2.size()):
		var a: WindField = levels1[q]
		var b: WindField = levels2[q]
		var e := maxf(_err(a._vel, b._vel), _err(a._wconv, b._wconv))
		worst = maxf(worst, e)
		check(e <= TOL_MS, "уровень %d: |Δu,v,w| %.5f ≤ %.2f м/с" % [q, e, TOL_MS])
		check(a._hc == b._hc, "рельеф побитно (уровень %d)" % q)
	check(is_equal_approx(rt2.inflow_k, rt1.inflow_k), "k притока как у расчёта: %.3f / %.3f" % [rt2.inflow_k, rt1.inflow_k])
	check(AirRuntime.needs_recompute(rt2.current_conditions(), _c, 15.0) == "", "поле сразу не пересчитывается")
	print(
		(
			"  FL-2: расчёт %.2f с; запись %.2f с, %.2f МБ, кадр при записи %.1f мс; из кеша %.2f с, кадр %.1f мс; "
			+ "|Δu,v,w| %.5f м/с; status %s"
		)
		% [calc_s, write_s, mb, wr[0], hit_s, read_frame, worst, h.get("status")]
	)
	rt1.queue_free()
	rt2.queue_free()
