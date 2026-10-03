extends TestCase
## ON-5 (O5, O6): AirRuntime engine = nn на малой сети tiny_p2v4. Поле строится (сетка, оси, единицы,
## AGL → MSL), отказы дают аналитику без падения, три варианта настройки, порядок поиска файла сети.
## Без GPU. Расширение не собрано — пропуск.

const TINY := "res://tests/air_onnx/fixtures/tiny_p2v4.onnx"
const OnnxTest := preload("res://tests/air_onnx/test_air_onnx.gd")
const DUMMY := "res://native/air_onnx/test/dummy_two_inputs.onnx"


class StubAtmo:
	extends RefCounted
	var field: Variant = null
	var calls := 0

	func set_air_field(f: Variant, _blend: float) -> void:
		field = f
		calls += 1


static func _skip(test: String) -> bool:
	var why: String = OnnxTest._ensure_extension()
	if why == "skip":
		print("    skip air_nn_runtime::%s: расширение не собрано (native/air_onnx/build.sh)" % test)
		return true
	return false


func _place() -> Dictionary:
	var lw := TestAirPlace.load_detail("ongudai")
	return {detail = lw[0], water = lw[1], loc = TestAirPlace.load_loc("ongudai")}


## Конфиг атмосферы с правкой air_model; Config.reload() — снаружи.
func _cfg(over: Dictionary) -> void:
	var cfg := Config.get_config("atmosphere")
	for k: String in over:
		cfg.air_model[k] = over[k]


func _runtime(over: Dictionary, atmo: Object, place: Dictionary) -> AirRuntime:
	Config.reload()
	_cfg(over)
	var rt := AirRuntime.new()
	rt.setup(atmo, place, func() -> Dictionary:
		return {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"})
	return rt


## Загрузка без дерева сцены: тот же конечный автомат, опрос вручную.
func _load(rt: AirRuntime, focus := true) -> void:
	if focus:
		rt.focus_fn = func() -> Vector3: return Vector3.ZERO
	rt._begin(rt.conditions_fn.call(), "тест", true)
	var t0 := Time.get_ticks_msec()
	while rt.busy() and Time.get_ticks_msec() - t0 < 60000:
		rt._process(0.0)
		OS.delay_msec(5)


func test_field_from_tiny_net() -> void:
	if _skip("field"):
		return
	var place := _place()
	var atmo := StubAtmo.new()
	var rt := _runtime({engine = "nn", nn_model = TINY}, atmo, place)
	check(rt.unavailable_reason() == "", "сеть доступна: «%s»" % rt.unavailable_reason())
	check(rt._device() == null, "GPU не берётся")
	_load(rt)
	check(rt.last_error == "", "без ошибки: «%s»" % rt.last_error)
	check(atmo.field is Array and (atmo.field as Array).size() == 1, "один уровень в атмосфере")
	if not (atmo.field is Array) or (atmo.field as Array).is_empty():
		rt.free()
		Config.reload()
		return
	var f: WindField = atmo.field[0]
	check(f.nx == 96 and f.ny == 96 and f.dx == 400.0, "сетка 96×96, 400 м")
	check(f.nz >= 2 and f.dz == 105.0, "высота — как у решателя (dz %s, nz %d)" % [f.dz, f.nz])
	check(String(f.meta.source) == "nn:tiny_p2v4.onnx", "source: %s" % f.meta.source)
	check(AirThermals.has_inputs(f), "для термиков есть heat, z_i, gam")
	var info := rt.last_info
	check(info.engine == "nn" and info.nn_model == TINY, "last_info: engine, nn_model")
	check(info.has("nn_clamped") and info.nn_ms > 0.0, "last_info: nn_clamped, nn_ms")
	check(int(info.passes) == 2, "два прохода k (старт задан): %s" % info.passes)
	check(rt.inflow_k >= AirRuntime.INFLOW_K_MIN and rt.inflow_k <= AirRuntime.INFLOW_K_MAX, "k в пределах")
	print("    nn: k %.3f, этапы %s, проходов %d" % [rt.inflow_k, info.nn_stages, info.passes])
	# конечные значения, ограничители
	var bad := 0
	var vmax := 0.0
	for z in [0.0, 300.0, 1000.0]:
		for q in 20:
			var p := Vector3(-8000.0 + 800.0 * q, f.z_bot + 600.0 + z, 3000.0 - 300.0 * q)
			var s := f.sample(p, f.z_bot)
			if not (is_finite(s.x) and is_finite(s.y) and is_finite(s.z)):
				bad += 1
			vmax = maxf(vmax, Vector3(s.x, s.y, s.z).length())
	check(bad == 0 and vmax <= 40.0, "выборка конечна, ≤ 40 м/с (bad %d, max %.1f)" % [bad, vmax])
	rt.free()
	Config.reload()


## Правила O5: канал → u/v/w_mech/w_conv/theta, AGL → MSL. Синтетический выход to_physical.
func test_assemble_axes_and_units() -> void:
	var place := _place()
	var case := AirPlace.domain_case(place.detail, place.water, place.loc, 400.0, 12.0, 3.0, 150.0)
	check(case != null, "случай")
	if case == null:
		return
	var nn := case.nx * case.ny
	var na := AirNnPrep.AGL.size()
	var m := PackedFloat32Array()
	var h := PackedFloat32Array()
	m.resize(3 * na * nn)
	h.resize(4 * na * nn)
	# u = 0,01·AGL, v = −0,02·AGL, w(h) = 0,5 + 0,001·AGL, w(m) = 0,2, θ′ = 0,001·AGL
	for a in na:
		var ag := float(AirNnPrep.AGL[a])
		for p in nn:
			h[a * nn + p] = 0.01 * ag
			h[(na + a) * nn + p] = -0.02 * ag
			h[(2 * na + a) * nn + p] = 0.5 + 0.001 * ag
			h[(3 * na + a) * nn + p] = 0.001 * ag
			m[(2 * na + a) * nn + p] = 0.2
	var meta := {U10 = 3.0, alpha = 0.2, mp = 1.5, k = 0, r = 0.0, S = 3.0, hc_mean = 0.0}
	var f := AirNnField.assemble(case, {m = m, h = h}, meta, 1.0e6, 1.0e6)
	check(f != null, "поле собрано")
	if f == null:
		return
	var checked := 0
	for p in [48 * 96 + 48, 10 * 96 + 70, 80 * 96 + 20]:
		var hp := case.hc[p]
		for k in f.nz:
			var a_m := f.z_bot + (k + 0.5) * f.dz - hp
			var q: int = (k * f.ny) * f.nx + p
			var u := f._vel[q * 3]
			var v := f._vel[q * 3 + 1]
			var wm := f._vel[q * 3 + 2]
			if a_m < 0.0:
				check(u == 0.0 and v == 0.0 and wm == 0.0 and f._theta[q] == 0.0, "под землёй — нули")
			elif a_m <= 2000.0:
				var ae := maxf(a_m, 25.0)
				if absf(u - 0.01 * ae) > 1e-3 or absf(v + 0.02 * ae) > 1e-3 or absf(wm - 0.2) > 1e-4:
					failures.append("u,v,w_mech на a=%.0f: %.3f %.3f %.3f" % [a_m, u, v, wm])
				if absf(f._wconv[q] - (0.3 + 0.001 * ae)) > 1e-3 or absf(f._theta[q] - 0.001 * ae) > 1e-4:
					failures.append("w_conv, θ′ на a=%.0f: %.4f %.4f" % [a_m, f._wconv[q], f._theta[q]])
				checked += 1
			elif a_m >= 3000.0:
				var ub := AirNnPrep.ubg(a_m, 0.2, 1.5, 3.0)
				var wd := deg_to_rad(case.wdir)
				if absf(u + ub * sin(wd)) > 1e-3 or absf(v + ub * cos(wd)) > 1e-3 or absf(wm) > 1e-6 or absf(f._theta[q]) > 1e-6:
					failures.append("выше 3000 м — приток: a=%.0f u %.3f v %.3f" % [a_m, u, v])
				checked += 1
	check(checked > 20, "проверено клеток: %d" % checked)


func test_failures_fall_back_to_analytic() -> void:
	if _skip("failures"):
		return
	var place := _place()
	# нет файла
	var atmo := StubAtmo.new()
	var rt := _runtime({engine = "nn", nn_model = "res://data/air_nn/нет_такого.onnx"}, atmo, place)
	var why := rt.unavailable_reason()
	check(why.begins_with("нейросеть: нет файла"), "нет файла: «%s»" % why)
	rt.free()
	# формат ≠ O1 (модель-пустышка с двумя выходами) — отказ при загрузке: аналитика, без падения
	atmo = StubAtmo.new()
	rt = _runtime({engine = "nn", nn_model = DUMMY}, atmo, place)
	check(rt.unavailable_reason() == "", "файл есть: «%s»" % rt.unavailable_reason())
	_load(rt, false)
	check(rt.last_error.begins_with("нейросеть: формат"), "формат: «%s»" % rt.last_error)
	check(rt.last_info.is_empty() and rt.applied_count == 0, "поле не подано")
	rt.free()
	# --air-nn-model задан и не существует — отказ, не молчаливая подмена
	var r := AirNnField.resolve_path({nn_model = TINY})
	check(r.path == TINY and r.why == "", "по умолчанию — nn_model конфига")
	Config.reload()


## Режим solver не затронут: без GPU (headless) — прежняя причина.
func test_solver_unchanged() -> void:
	var place := _place()
	var rt := _runtime({engine = "solver"}, StubAtmo.new(), place)
	check(rt.engine() == "solver", "engine solver по умолчанию")
	check(rt.unavailable_reason() == "нет RenderingDevice: headless", "headless: «%s»" % rt.unavailable_reason())
	rt.free()
	rt = _runtime({engine = "nn", enabled = "off"}, StubAtmo.new(), place)
	check(rt.unavailable_reason() == "air_model.enabled = off", "off важнее engine")
	rt.free()
	Config.reload()
