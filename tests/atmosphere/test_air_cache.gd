extends TestCase
## AirRuntime и кеш поля на диске (FL-2, FL-К1) без GPU: запись есть — load_field берёт поле из кеша
## (этапа расчёта нет, состояние как у запечённого: поле старта сразу не пересчитывается); другие условия /
## cache_enabled = false / max_mb = 0 — обычный путь (headless: аналитика). Запись поля загрузки — фоном,
## главный поток в _apply не ждёт упаковки; пересчёты в полёте и аналитика не пишутся.
## Поле — синтетическое (tests/contracts/test_training_island_k3.gd), место — Онгудай из фикстур.

const K3 := preload("res://tests/contracts/test_training_island_k3.gd")
const DIR := "user://air_cache_rt_test"
const START_LATLON := Vector2(50.78708, 86.23278)
## Главный поток при записи поля загрузки (FL-К1), мс.
const MAIN_MAX_MS := 100.0


class StubAtmo:
	extends RefCounted
	var field: Variant = null
	var air_field: AirFieldSet = AirFieldSet.new()
	var calls := 0
	var blend := -1.0

	func set_air_field(f: Variant, b: float) -> void:
		field = f
		if f != null:
			air_field.set_field(f, 0.0)
		blend = b
		calls += 1


var _c := {}


func _cond() -> Dictionary:
	return _c


func _cache(max_mb: float = 200.0) -> AirFieldCache:
	var c := AirFieldCache.new()
	c.dir = DIR
	c.max_bytes = int(max_mb * AirFieldCache.BYTES_PER_MB)
	return c


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for f in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR.path_join(f))


## Узел AirRuntime на месте Онгудая (старт у Каянчи), кеш — DIR; запечённое — выключено.
func _runtime(atmo: Object) -> AirRuntime:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	loc.month = 7
	loc.day = 15
	var p := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	var pos := Vector3(p.x, (lw[0] as HeightLayer).sample(p.x, p.y), p.y)
	var rt := AirRuntime.new()
	rt.baked_enabled = false
	rt.cache_enabled = true
	rt.cache_override = _cache()
	_c = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = 25.0, sky = "clear", wind_ref = "start"}
	rt.setup(atmo, {detail = lw[0], water = lw[1], loc = loc}, _cond)
	rt.set_focus(null, pos)
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	return rt


func test_air_cache_hit_skips_solver() -> void:
	await Engine.get_main_loop().process_frame
	_clean()
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo)
	var key := rt.cache_key(_c)
	check(not key.is_empty(), "ключ места есть (данные Онгудая на диске)")
	check(key.start is Array, "старт в ключе: %s" % [key.start])
	check(not rt.cache_ready(), "записи ещё нет")
	check(_cache().store(K3.synthetic_set(), key, {status = "ok", inflow_k = 0.85}), "запись")
	check(rt.cache_ready(), "cache_ready: поле будет взято из кеша")
	var t0 := Time.get_ticks_usec()
	var ok: bool = await rt.load_field()
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	check(ok, "load_field: поле есть (%s)" % rt.last_error)
	check(rt.last_info.get("cache", false) == true, "last_info.cache")
	check(rt.cache_ready(), "cache_ready после загрузки — поле из кеша")
	check(atmo.calls == 1 and atmo.field is Array and (atmo.field as Array).size() == 3, "в атмосферу — 3 уровня")
	check(atmo.blend == 0.0, "при загрузке — без подмены")
	check(not rt.busy(), "расчёт не запущен")
	check(AirRuntime.needs_recompute(rt.current_conditions(), _c, 15.0) == "", "поле старта сразу не пересчитывается")
	check(is_equal_approx(rt.inflow_k, 0.85), "k притока из заголовка: %.3f" % rt.inflow_k)
	check(wall <= 1.0, "чтение и подача ≤ 1 с: %.3f с" % wall)
	check(not rt.cache_writing(), "поле из кеша заново не пишется")
	# те же условия — повторная загрузка не читает ничего
	var ok2: bool = await rt.load_field()
	check(ok2 and atmo.calls == 1, "то же место и условия — поле уже в атмосфере")
	rt.queue_free()
	_clean()


func test_air_cache_miss_paths() -> void:
	await Engine.get_main_loop().process_frame
	_clean()
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo)
	check(_cache().store(K3.synthetic_set(), rt.cache_key(_c), {status = "ok"}), "запись")
	# другие условия
	var c0 := _c.duplicate()
	_c.u10 = 3.5
	check(not rt.cache_ready(), "другой ветер — промах")
	_c = c0
	_c.hour = 12.3
	check(not rt.cache_ready(), "другой срок (12:18) — промах")
	_c = c0
	_c.hour = 12.2
	check(rt.cache_ready(), "тот же срок (12:12) — попадание")
	_c = c0
	# выключен
	rt.cache_enabled = false
	check(not rt.cache_ready(), "cache_enabled = false — не читает")
	var ok: bool = await rt.load_field()
	check(not ok and rt.last_info.get("cache", false) != true, "cache_enabled = false — обычный путь (headless: аналитика)")
	rt.cache_enabled = true
	rt.cache_override = _cache(0.0)
	check(not rt.cache_ready(), "max_mb = 0 — не читает")
	rt.queue_free()
	_clean()


## Запись поля загрузки из _apply: главный поток не ждёт упаковки; статус по итогу прохода; в полёте —
## не пишется.
func test_air_cache_store_from_load() -> void:
	await Engine.get_main_loop().process_frame
	_clean()
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo)
	var key := rt.cache_key(_c)
	var lv: Array[WindField] = K3.synthetic_set().levels
	rt._cache_key = key
	rt._loading = true
	rt._req = _c.duplicate()
	rt._req.merge({reason = "загрузка", iters = [10], warm = false, u_start10 = 3.0, u_start10_first = 3.4, not_converged = true})
	rt._k = 0.9
	var t0 := Time.get_ticks_usec()
	rt._apply(lv)
	var main_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(main_ms <= MAIN_MAX_MS, "_apply с запуском записи: %.1f мс ≤ %.0f" % [main_ms, MAIN_MAX_MS])
	rt.cache_wait()
	var look := _cache().lookup(key)
	check(look.reason == "", "поле загрузки записано (%s)" % look.reason)
	check(look.header.get("status") == "not_converged", "status not_converged")
	check(is_equal_approx(float(look.header.get("inflow_k", 0.0)), 0.9), "inflow_k в заголовке")
	# пересчёт в полёте — не пишется
	_clean()
	rt._cache_key = key
	rt._loading = false
	rt._req = _c.duplicate()
	rt._req.merge({reason = "срок", iters = [10], warm = true, u_start10 = 3.0, u_start10_first = 3.0})
	rt._apply(lv)
	rt.cache_wait()
	check(_cache().lookup(key).reason == AirFieldCache.MISS, "пересчёт в полёте не пишется")
	rt.queue_free()
	_clean()
