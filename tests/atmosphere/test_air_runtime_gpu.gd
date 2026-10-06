extends TestCase
## AirRuntime на GPU (AM-06Б, контракт C9): поле Онгудая (область 400 м) при загрузке — готово, в
## атмосфере, выборка у старта совпадает с AirPicardJob напрямую; пересчёт в полёте по сроку
## (тёплый старт) и при смене ветра; кадр во время расчёта.
## tools/gpu_tests.sh --filter=test_air_runtime (под flock /tmp/heat_ca_gpu.lock).
## AIR_RUNTIME_TRACE=<файл.csv> — ещё и ход w в точке у старта через пересчёт (график:
## tools/research/air_runtime/plot_blend.py).

const START_LATLON := Vector2(50.78708, 86.23278)  # kayancha_south

var _c := {}
var _gaps: Array[float] = []
var _t_frame := 0
## Ход w в точке: прошлое значение и наибольший шаг между соседними строками (шаг ≤ 0,1 с).
var _prev_w := NAN
var _max_jump := 0.0
## Наибольший шаг атмосферы в пересчёте, мс (сборка источников термиков по новому полю — AM-07).
var _atmo_ms := 0.0


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	if _t_frame > 0:
		_gaps.append((now - _t_frame) / 1000.0)
	_t_frame = now


func _gap_stats() -> Vector2:
	var mx := 0.0
	var s := 0.0
	for g in _gaps:
		mx = maxf(mx, g)
		s += g
	return Vector2(mx, s / maxf(_gaps.size(), 1))


func _watch(on: bool) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if on:
		_gaps.clear()
		_t_frame = 0
		tree.process_frame.connect(_on_frame)
	elif tree.process_frame.is_connected(_on_frame):
		tree.process_frame.disconnect(_on_frame)


static func _atmo(detail: HeightLayer) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(3.0)
	w.wind_from_deg = 150.0
	w.thermal_mode = "static"
	w.static_thermals = []
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(func(x: float, z: float) -> float: return detail.sample(x, z), _sun)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	return a


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _wait_applied(rt: AirRuntime, n: int, limit_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while rt.applied_count < n and (Time.get_ticks_msec() - t0) / 1000.0 < limit_s:
		await Engine.get_main_loop().process_frame
		if rt.failed_count > 0:
			break
	return rt.applied_count >= n


func test_ongudai_runtime() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var detail: HeightLayer = lw[0]
	var atmo := _atmo(detail)
	_c = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"}
	var rt := AirRuntime.new()
	await Engine.get_main_loop().process_frame  # корень занят в _ready — добавить после кадра
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
	check(rt.unavailable_reason() == "", "расчёт доступен: %s" % rt.unavailable_reason())
	# ---- загрузка
	_watch(true)
	var ok: bool = await rt.load_field()
	_watch(false)
	var g := _gap_stats()
	var li := rt.last_info
	print(
		(
			(
				"  загрузка: %.2f с стены (GPU %.2f с, итераций %s), кадр max %.0f мс, средний %.0f мс; "
				+ "главный поток max %.1f мс, запуск задачи %.0f мс, опрос max %.1f мс"
			)
			% [
				float(li.get("wall_s", 0)),
				float(li.get("gpu_s", 0)),
				li.get("iters"),
				g.x,
				g.y,
				float(li.get("main_max_ms", 0)),
				float(li.get("start_ms", 0)),
				float(li.get("poll_max_ms", 0))
			]
		)
	)
	check(ok, "поле посчитано: %s" % rt.last_error)
	if not ok:
		rt.queue_free()
		atmo.free()
		return
	check(atmo.is_air_field_on(), "поле в атмосфере")
	check(atmo.air_field.blend_fraction() == 1.0, "при загрузке — без подмены")
	check(g.x <= 100.0, "кадр загрузки ≤ 100 мс (%.0f)" % g.x)
	# ---- выборка у старта против AirPicardJob напрямую
	var job := AirPicardJob.new()
	job.case = AirPlace.domain_case(detail, lw[1], loc, 400.0, 12.0, 3.0, 150.0)
	job.mech = true
	check(job.start() and job.run_blocking(), "прямой расчёт: %s" % job.error)
	var fd := job.field()
	job.release()
	var fr: WindField = atmo.air_field.levels[0]
	var st := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	var e := 0.0
	for dxz: Vector2 in [Vector2.ZERO, Vector2(300, 0), Vector2(0, 300), Vector2(-500, -500)]:
		for agl in [10.0, 50.0, 150.0, 400.0]:
			var x := st.x + dxz.x
			var z := st.y + dxz.y
			var h := detail.sample(x, z)
			var p := Vector3(x, h + agl, z)
			e = maxf(e, (fr.sample(p, h) - fd.sample(p, h)).length())
			e = maxf(e, absf(fr.sample_w_conv(p, h) - fd.sample_w_conv(p, h)))
	print("  у старта: max|поле AirRuntime − AirPicardJob| = %s м/с" % TestAirPicard.sci(e))
	check(e <= 1.0e-6, "выборка у старта = AirPicardJob напрямую (%s)" % TestAirPicard.sci(e))
	var trace := OS.get_environment("AIR_RUNTIME_TRACE")
	var pt := _strongest_w(fr, detail, st)
	print("  точка хода w: (%.0f, %.0f, %.0f), w_mech %.2f м/с" % [pt.x, pt.y, pt.z, fr.sample(pt).y])
	var rows: Array[String] = ["t_s,w_mech,w_conv,w_mean,frac,event"]
	_prev_w = NAN
	_max_jump = 0.0
	var t_atm := [0.0]
	# ---- пересчёт по сроку (12:15), тёплый старт
	rt.recompute_enabled = true
	_c.hour = 12.26
	_watch(true)
	var fired := await _recompute_traced(rt, 2, atmo, pt, detail, rows, t_atm, "срок 12:15")
	_watch(false)
	g = _gap_stats()
	li = rt.last_info
	_print_recompute("срок", li, g)
	check(fired, "пересчёт по сроку: %s" % rt.last_error)
	check(String(li.get("reason", "")).begins_with("срок"), "причина — срок: %s" % li.get("reason"))
	check(bool(li.get("warm", false)), "тёплый старт")
	check(absf(float(li.get("hour", 0)) - 12.25) < 1e-6, "час поля — начало срока 12:15")
	_check_frame(li)
	# подмена идёт, выборка непрерывна; вторая подмена посреди первой (Р7) — без скачка
	await _blend_trace(atmo, pt, detail, rows, t_atm, 20.0)
	_c.u10 = 4.0
	_watch(true)
	fired = await _recompute_traced(rt, 3, atmo, pt, detail, rows, t_atm, "ветер 4 м/с")
	_watch(false)
	g = _gap_stats()
	li = rt.last_info
	_print_recompute("смена ветра", li, g)
	check(fired, "пересчёт при смене ветра")
	check(li.get("reason") == "смена ветра", "причина — смена ветра: %s" % li.get("reason"))
	_check_frame(li)
	await _blend_trace(atmo, pt, detail, rows, t_atm, 80.0)
	print("  наибольший шаг w (≤ 0,1 с) через подмены: %.4f м/с" % _max_jump)
	check(_max_jump < 0.02, "подмена плавная: шаг w %.4f м/с" % _max_jump)
	if trace != "":
		var fa := FileAccess.open(trace, FileAccess.WRITE)
		fa.store_string("\n".join(rows) + "\n")
		fa.close()
		print("  ход w: %s" % trace)
	rt.stop()
	rt.queue_free()
	atmo.free()


## Доля кадра AirRuntime (опрос, запуск задачи, чтение буферов) ≤ 100 мс; шаг атмосферы —
## отдельно (сборка источников термиков по новому полю на главном потоке — AM-07/AM-11).
func _check_frame(li: Dictionary) -> void:
	var ms := float(li.get("main_max_ms", 1e9))
	check(ms <= 100.0, "AirRuntime за кадр ≤ 100 мс (%.0f)" % ms)
	print("    шаг атмосферы max %.0f мс" % _atmo_ms)


func _print_recompute(label: String, li: Dictionary, g: Vector2) -> void:
	print(
		(
			(
				"  пересчёт (%s): %.2f с стены (GPU %.2f с, итераций %s, тёплый %s), кадр max %.0f"
				+ " мс, средний %.0f мс; главный поток max %.1f мс, запуск задачи %.0f мс, опрос"
				+ " max %.1f мс, порция GPU max %.1f мс"
			)
			% [
				label,
				float(li.get("wall_s", 0)),
				float(li.get("gpu_s", 0)),
				li.get("iters"),
				li.get("warm"),
				g.x,
				g.y,
				float(li.get("main_max_ms", 0)),
				float(li.get("start_ms", 0)),
				float(li.get("poll_max_ms", 0)),
				float(li.get("chunk_max_ms", 0))
			]
		)
	)


## Ждать n-е поле; атмосфера идёт реальным временем кадров (подмена начинается при подаче).
func _recompute_traced(
	rt: AirRuntime,
	n: int,
	atmo: Atmosphere,
	pt: Vector3,
	detail: HeightLayer,
	rows: Array[String],
	t_atm: Array,
	event: String
) -> bool:
	var t0 := Time.get_ticks_usec()
	var last := t0
	_atmo_ms = 0.0
	_row(atmo, pt, detail, rows, t_atm[0], event + ": запрос")
	while rt.applied_count < n and rt.failed_count == 0 and (last - t0) / 1e6 < 60.0:
		await Engine.get_main_loop().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		var ta := Time.get_ticks_usec()
		atmo.step(dt)
		_atmo_ms = maxf(_atmo_ms, (Time.get_ticks_usec() - ta) / 1000.0)
		t_atm[0] += dt
		_row(atmo, pt, detail, rows, t_atm[0], "")
	_row(atmo, pt, detail, rows, t_atm[0], event + ": поле подано")
	return rt.applied_count >= n


## Атмосфера вперёд на dur с шагом 0,1 с (без ожидания кадров).
func _blend_trace(
	atmo: Atmosphere, pt: Vector3, detail: HeightLayer, rows: Array[String], t_atm: Array, dur: float
) -> void:
	for _i in roundi(dur / 0.1):
		atmo.step(0.1)
		t_atm[0] += 0.1
		_row(atmo, pt, detail, rows, t_atm[0], "")
	await Engine.get_main_loop().process_frame


func _row(
	atmo: Atmosphere, pt: Vector3, detail: HeightLayer, rows: Array[String], t: float, ev: String
) -> void:
	var h := detail.sample(pt.x, pt.z)
	var fw := atmo.air_field.sample(pt, h)
	var wc := atmo.air_field.sample_w_conv(pt, h)
	var va := atmo.mean_wind_at(pt)
	if not is_nan(_prev_w):
		_max_jump = maxf(_max_jump, absf(fw.y - _prev_w))
	_prev_w = fw.y
	rows.append(
		"%.3f,%.5f,%.5f,%.5f,%.4f,%s" % [t, fw.y, wc.x, va.y, atmo.air_field.blend_fraction(), ev]
	)


## Точка у старта (± 4 км, 100 м над землёй) с наибольшим |w_mech| поля — там подмена заметна.
static func _strongest_w(f: WindField, detail: HeightLayer, st: Vector2) -> Vector3:
	var best := Vector3(st.x, detail.sample(st.x, st.y) + 100.0, st.y)
	var bw := 0.0
	for i in range(-10, 11):
		for j in range(-10, 11):
			var x := st.x + i * 400.0
			var z := st.y + j * 400.0
			var h := detail.sample(x, z)
			var p := Vector3(x, h + 100.0, z)
			var w := absf(f.sample(p, h).y)
			if w > bw:
				bw = w
				best = p
	return best


## P12: конвейер фазы → Пикар на GPU (фазы — AirPhaseJob AP-19 или заглушка): поле подано,
## last_info — движок, доли фаз, заморозка, итерации; окна — как раньше.
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
