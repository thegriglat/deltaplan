extends TestCase
## Подготовка области в несколько потоков (FL-9) на GPU: поле Онгудая (место игры — Terrain, снимок
## поверхности, старт у Каянчи, область 400 м + окна) прежним путём в одном потоке
## (AirPlace.parallel = false) и новым — совпадает: побитно или |Δu, v, w| ≤ 1e-4 м/с, |Δθ| ≤ 1e-4 К.
## Кеш поля и запечённое поле выключены. tools/gpu_tests.sh --filter=air_prep_parallel. Числа — в вывод.

const AR := preload("res://tests/atmosphere/test_air_runtime_gpu.gd")
const START_LATLON := Vector2(50.78708, 86.23278)
const TOL_V := 1.0e-4
const TOL_T := 1.0e-4

var _c := {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = 25.0, sky = "clear", wind_ref = "start"}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


func _err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for q in a.size():
		e = maxf(e, absf(a[q] - b[q]))
	return e


## Поле места t путём par: [уровни, с загрузки, k притока] или [] — не посчиталось.
func _field(t: Terrain, par: bool) -> Array:
	AirPlace.parallel = par
	var loc := TestAirPlace.load_loc("ongudai")
	var place := AirRuntime.place_of(t, float(loc.get("utc_offset_h", NAN)), 7, 15)
	var detail: HeightLayer = place.detail
	var atmo := AR._atmo(detail)
	atmo.field.air_async = false
	var rt := AirRuntime.new()
	rt.baked_enabled = false
	rt.cache_enabled = false
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, place, _cond)
	var p := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	rt.set_focus(null, Vector3(p.x, detail.sample(p.x, p.y), p.y))
	var t0 := Time.get_ticks_usec()
	var ok: bool = await rt.load_field()
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	AirPlace.parallel = true
	check(ok, "поле посчитано (%s): %s" % ["новый путь" if par else "прежний путь", rt.last_error])
	var out := []
	if ok:
		out = [atmo.air_field.levels, wall, rt.inflow_k]
	rt.queue_free()
	return out


func test_air_prep_parallel_field_ongudai() -> void:
	await Engine.get_main_loop().process_frame
	var t := Terrain.new()
	t.location_id = ""
	t.load_location("ongudai")
	var a: Array = await _field(t, false)
	var b: Array = await _field(t, true)
	if a.is_empty() or b.is_empty():
		t.free()
		return
	var la: Array[WindField] = a[0]
	var lb: Array[WindField] = b[0]
	check(la.size() == lb.size(), "число уровней то же: %d / %d" % [la.size(), lb.size()])
	var ev := 0.0
	var et := 0.0
	var same := true
	for q in mini(la.size(), lb.size()):
		var fa: WindField = la[q]
		var fb: WindField = lb[q]
		ev = maxf(ev, maxf(_err(fa._vel, fb._vel), _err(fa._wconv, fb._wconv)))
		et = maxf(et, _err(fa._theta, fb._theta))
		same = (
			same
			and fa._vel == fb._vel
			and fa._wconv == fb._wconv
			and fa._theta == fb._theta
			and fa._hc == fb._hc
		)
		check(fa._hc == fb._hc, "рельеф уровня %d побитно" % q)
	check(ev <= TOL_V, "|Δu,v,w| %s ≤ %s м/с" % [ev, TOL_V])
	check(et <= TOL_T, "|Δθ| %s ≤ %s К" % [et, TOL_T])
	check(a[2] == b[2], "k притока тот же: %.6f / %.6f" % [a[2], b[2]])
	print(
		"  FL-9 поле Онгудая: побитно %s, |Δu,v,w| %s м/с, |Δθ| %s К; загрузка поля %.2f с → %.2f с; k %.4f"
		% [same, ev, et, a[1], b[1], b[2]]
	)
	t.free()
