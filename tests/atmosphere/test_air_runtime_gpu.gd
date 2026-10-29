extends TestCase
## AirRuntime на GPU (AM-06Б, контракт C9): конвейер фазы → Пикар на GPU (P12). Загрузка поля,
## пересчёт по сроку и при смене ветра — расчёт в крейте (RW-7), см. ниже. Атмосфера здесь — только
## приёмник поля (set_air_field). Помощник _atmo используют запечённые GPU-тесты.
## tools/gpu_tests.sh --filter=test_air_runtime (под flock /tmp/heat_ca_gpu.lock).

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


static func _atmo(_detail: HeightLayer) -> Atmosphere:
	# Атмосфера — только приёмник поля AirRuntime (set_air_field / air_field); воздух — в крейте
	# (W2 v4).
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"))
	return a


# test_ongudai_runtime (загрузка, пересчёт по сроку и при смене ветра, подмена поля в атмосфере,
# кадр во
# время расчёта) — расчёт поля в игре ведёт крейт (RW-7); эквиваленты — rust/dp-air/tests/runtime.rs
# (ongudai_loads_ready_release, recompute_on_slot_blends_monotonically_and_ends_at_the_new_field,
# condition_change_recomputes_from_the_moment_of_change,
# queries_never_block_on_the_solve_and_survive_garbage,
# t4a_iterations_ongudai_release) и acceptance.rs.


func test_phase_picard_pipeline() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var detail: HeightLayer = lw[0]
	var atmo := _atmo(detail)
	_c = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"}
	var rt := AirRuntime.new()
	await Engine.get_main_loop().process_frame
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
	var ok: bool = await rt.load_field()
	var li := rt.last_info
	print("  фазы+Пикар: %s" % JSON.stringify({
		engine = li.get("engine"), iters = li.get("iters"), phase_frac = li.get("phase_frac"),
		phase_ms = li.get("phase_ms"), frozen_frac = li.get("frozen_frac"),
		omega_fallback_used = li.get("omega_fallback_used"), picard_ms = li.get("picard_ms"),
		wall_s = li.get("wall_s"), windows = str(li.get("windows", [])),
	}))
	check(ok, "поле посчитано: %s" % rt.last_error)
	check(String(li.get("engine", "")) == "phase+picard", "движок — фазы+Пикар: %s" % li.get("engine"))
	check(li.has("phase_frac") and li.has("frozen_frac") and li.has("omega_fallback_used"), "last_info P12")
	check(not (li.get("phase_frac", {}) as Dictionary).is_empty(), "доли фаз от AirPhaseJob")
	check(not rt.phase_map.is_empty(), "карта фаз для слоя")
	rt.queue_free()
	atmo.free()
