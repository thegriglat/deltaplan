extends TestCase
## AirRuntime без GPU (air-phase P12): конвейер без сети; без GPU — поле из сборки фаз (P10) на CPU
## без Пикара, строка «фазы без Пикара», last_info с долями фаз и карта фаз для отладочного слоя;
## нет ни GPU, ни кода фаз — аналитика; конфиг air_model без engine/nn_*, новые ключи с _doc.
## Фазы — заглушка PhaseStub с API AirPhaseJob (P10 v2: run(case) -> Dictionary) до вливания AP-19.

const PHASES := ["A", "B", "C", "D", "F", "G", "H"]


class StubAtmo:
	extends RefCounted
	var field: Variant = null
	var calls := 0

	func set_air_field(f: Variant, _blend: float) -> void:
		field = f
		calls += 1


## Заглушка AirPhaseJob (P10 v2): фаза A везде, кроме квадрата F (заморожен) в углу; ω = 0,5 в
## полосе у квадрата; warm — однородный поток притока (u_a по направлению ветра), θ′ = 0.
class PhaseStub:
	extends RefCounted
	var calls := 0
	## Сторона квадрата F, клеток (0 — без механизмов).
	var block := 8

	func run(c: AirCase) -> Dictionary:
		calls += 1
		var nx := c.nx
		var ny := c.ny
		var kk := PHASES.size()
		var w := PackedFloat32Array()
		w.resize(kk * nx * ny)
		var om := PackedFloat32Array()
		om.resize(nx * ny)
		var fz := PackedByteArray()
		fz.resize(nx * ny)
		var nf := 0
		for j in ny:
			for i in nx:
				var q := j * nx + i
				var in_f := i < block and j < block
				var ph := 4 if in_f else 0
				w[ph * nx * ny + q] = 1.0
				fz[q] = 1 if in_f else 0
				nf += 1 if in_f else 0
				om[q] = 0.5 if (i < 2 * block and j < 2 * block and not in_f) else 1.0
		var d := c.dims()
		var n := d.x * d.y * d.z
		var u := PackedFloat32Array()
		u.resize(n)
		u.fill(c.u_a * c.ex)
		var v := PackedFloat32Array()
		v.resize(n)
		v.fill(c.u_a * c.ey)
		var z := PackedFloat32Array()
		z.resize(n)
		var fa := float(nf) / float(nx * ny)
		return {
			weights = w,
			omega = om,
			freeze = fz,
			warm = {u = u, v = v, w = z, th = z.duplicate(), p = z.duplicate()},
			mech_field = {},
			stats = {A = 1.0 - fa, F = fa},
			ms = 1.0,
		}


func _place() -> Dictionary:
	var lw := TestAirPlace.load_detail("ongudai")
	return {detail = lw[0], water = lw[1], loc = TestAirPlace.load_loc("ongudai")}


func _runtime(atmo: Object, place: Dictionary, stub: PhaseStub) -> AirRuntime:
	Config.reload()
	var rt := AirRuntime.new()
	if stub != null:
		rt.phase_factory = func(_g: AirGpu) -> Object: return stub
	rt.setup(atmo, place, func() -> Dictionary:
		return {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"})
	return rt


## Загрузка без дерева сцены: тот же конечный автомат, опрос вручную.
func _load(rt: AirRuntime) -> void:
	rt.focus_fn = func() -> Vector3: return Vector3.ZERO
	rt._begin(rt.conditions_fn.call(), "тест", true)
	var t0 := Time.get_ticks_msec()
	while rt.busy() and Time.get_ticks_msec() - t0 < 120000:
		rt._process(0.0)
		OS.delay_msec(5)


func test_config_without_nn() -> void:
	Config.reload()
	var am: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	check(not am.has("engine") and not am.has("engine_doc"), "air_model без engine")
	for k: String in am:
		check(not k.begins_with("nn_"), "air_model без nn_*: %s" % k)
	for k in ["omega_fallback_iters", "omega_fallback_value", "hybrid_checks"]:
		check(am.has(k), "ключ %s" % k)
		check(am.has(k + "_doc") or (am.get(k) is Dictionary and am[k].has("_doc")), "_doc у %s" % k)
	var hc: Dictionary = am.get("hybrid_checks", {})
	for k: String in hc:
		if not k.ends_with("_doc") and k != "_doc":
			check(hc.has(k + "_doc"), "_doc у hybrid_checks.%s" % k)
	var rt := AirRuntime.new()
	check(rt.engine() == "solver", "engine() — solver (подпись экрана загрузки)")
	rt.free()


## Без GPU и с фазами — поле из сборки фаз на CPU, один уровень, last_info и карта фаз.
func test_cpu_phase_field() -> void:
	var atmo := StubAtmo.new()
	var stub := PhaseStub.new()
	var rt := _runtime(atmo, _place(), stub)
	check(rt.gpu_reason() != "", "headless: GPU нет (%s)" % rt.gpu_reason())
	check(rt.unavailable_reason() == "", "с фазами расчёт доступен: %s" % rt.unavailable_reason())
	_load(rt)
	var li := rt.last_info
	check(rt.applied_count == 1, "поле подано: %s" % rt.last_error)
	check(stub.calls >= 1, "фазы посчитаны (%d)" % stub.calls)
	check(String(li.get("engine", "")) == "phase", "движок — фазы без Пикара: %s" % li.get("engine"))
	check(atmo.field is Array and (atmo.field as Array).size() == 1, "один уровень (окон без GPU нет)")
	if atmo.field is Array and not (atmo.field as Array).is_empty():
		var f: WindField = atmo.field[0]
		check(String(f.meta.get("source", "")) == "phase", "источник поля — phase")
		var s := f.sample(Vector3(0.0, 2500.0, 0.0))
		check(s.length() > 0.5 and s.length() < 40.0, "ветер сборки над стартом: %s" % s)
	var fr: Dictionary = li.get("phase_frac", {})
	check(fr.has("A") and fr.has("F"), "доли фаз в last_info: %s" % fr)
	check(not is_nan(float(li.get("phase_ms", NAN))), "время фаз в last_info")
	var pm := rt.phase_map
	check(int(pm.get("nx", 0)) > 0 and PackedFloat32Array(pm.get("weights", [])).size() == PHASES.size() * int(pm.nx) * int(pm.ny), "карта фаз для слоя")
	rt.free()


## Ни GPU, ни кода фаз — аналитика (как C9).
func test_no_gpu_no_phases_analytic() -> void:
	if ResourceLoader.exists(AirRuntime.PHASE_JOB_PATH):
		print("    skip: AirPhaseJob уже есть (AP-19) — без фаз не проверить")
		return
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo, _place(), null)
	check(rt.unavailable_reason() == "нет RenderingDevice: headless", "причина: %s" % rt.unavailable_reason())
	rt.free()


## Типы клеток на CPU: воздух — столько же, сколько неизвестных клеток AirCase (n_fluid).
func test_cell_codes() -> void:
	var p := _place()
	var c := AirPlace.domain_case(
		p.detail, p.water, p.loc, AirRuntime.DX, 12.0, 3.0, 150.0, NAN, "clear", true, 1.0
	)
	check(c != null and c.prepare(), "случай Онгудая")
	if c == null:
		return
	var tc := AirRuntime.cell_codes(c)
	var air := 0
	for t in tc:
		air += 1 if int(t) == 1 else 0
	check(air == c.n_fluid, "клеток воздуха %d = n_fluid %d" % [air, c.n_fluid])
