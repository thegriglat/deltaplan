extends TestCase
## Выбор тёплого старта Пикара в игре (AP-20, по прогону P14): на местах и ветрах проверки
## (air_model.hybrid_checks) — итерации пары решений (без нагрева, с нагревом) и итоговое поле.
## Старт задаётся обоим решениям (warm — без нагрева, warm_heat — с нагревом); у всех — заморозка
## колонн и запасное правило ω от фаз, ω = 1, кроме *_map (карта ω фаз с первой итерации):
##   cold     — холодный с фона (эталон поля, без фаз);
##   cold_ph  — холодный, заморозка и запасное правило от фаз;
##   cold_map — то же с картой ω фаз (вклад карты ω);
##   asm      — от сборки по фазам (warm_mech / warm);
##   heur     — от поля «Эвристики» (аналитика атмосферы: профиль, склоновый подъём, подветренная зона);
##   prev     — от решения на 15 игровых минут раньше (только для сведения: при загрузке его нет);
##   coarseM  — от грубого Пикара (клетка ×M, холодный, ω = 1): центры → 400 м билинейно, уровни по
##              высоте, грани — среднее; цена = итерации грубой ×1/M² + доводка.
## Итог — в лог и build/dp/AP-20/warmstart.json; проверка — поле каждого старта как у холодного
## (допуски P14 v2); итерации — в отчёт и выбор air_model.picard_start.
## Запуск: AIR_WARMSTART=1 tools/gpu_tests.sh --filter=air_warmstart (под dp lock gpu).

const OUT := "res://build/dp/AP-20/warmstart.json"
const HybridTest := preload("res://tests/atmosphere/test_air_hybrid_gpu.gd")


func needs_gpu() -> bool:
	return true


func _phase(g: AirGpu, c: AirCase) -> Dictionary:
	var pj := AirPhaseJob.new(g)
	var ph := pj.run(c)
	pj.release()
	return ph


func _solve(c: AirCase, ph: Dictionary, warm: Array, omega1: bool) -> AirPicardJob:
	var job := AirPicardJob.new()
	job.case = c
	job.mech = true
	job.warm = warm[0] if warm.size() > 0 else {}
	job.warm_heat = warm[1] if warm.size() > 1 else {}
	if not ph.is_empty():
		if not omega1:
			job.omega_map = ph.get("omega", PackedFloat32Array())
		job.freeze_mask = ph.get("freeze", PackedByteArray())
		job.freeze_mask_mech = ph.get("freeze_mech", PackedByteArray())
		job.freeze_field = ph.get("mech_field", {})
		job.freeze_field_mech = ph.get("mech_field_mech", {})
		job.omega_fallback = Vector2(
			float(AirRuntime.phase_cfg("omega", "fallback_iters")),
			float(AirRuntime.phase_cfg("omega", "fallback_omega"))
		)
	if not job.start():
		failures.append("start: " + job.error)
		return null
	job.run_blocking()
	return job


## Поле «Эвристики» на сетке случая (раскладка warm): аналитика атмосферы в центрах клеток воздуха,
## грани — среднее соседних центров; θ′, p = 0.
static func coarse_warm(c: AirCase, cc: AirCase, st: Dictionary) -> Dictionary:
	return AirRuntime.coarse_warm(c, cc, st)


static func heuristic_warm(c: AirCase, detail: HeightLayer, u10: float, wdir: float) -> Dictionary:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(u10)
	w.wind_from_deg = wdir
	w.thermal_mode = "static"
	w.static_thermals = []
	var a := Atmosphere.new()
	a.visuals_enabled = false
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	cfg.air_model.enabled = "off"
	a.configure(cfg, w)
	a.set_ground(func(x: float, z: float) -> float: return detail.sample(x, z), func(_x: float, _z: float) -> float: return 1.0)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	var d := c.dims()
	var nyx := d.x * d.y
	var n := nyx * d.z
	var tc := HybridTest.cell_codes(c)
	var cu := PackedFloat32Array()
	var cv := PackedFloat32Array()
	var cw := PackedFloat32Array()
	for arr: PackedFloat32Array in [cu, cv, cw]:
		arr.resize(n)
	for k in d.z:
		var z := c.zc(k)
		for j in d.y:
			for i in d.x:
				var g := (k * d.y + j) * d.x + i
				if int(tc[g]) == 0:
					continue
				var x := c.x0 + (i - 0.5) * c.dx
				var y := c.y0 + (j - 0.5) * c.dx
				var v: Vector3 = a.air_velocity_at(Vector3(x, z, -y))
				cu[g] = v.x
				cv[g] = -v.z
				cw[g] = v.y
	a.free()
	var u := PackedFloat32Array()
	var vv := PackedFloat32Array()
	var ww := PackedFloat32Array()
	for arr: PackedFloat32Array in [u, vv, ww]:
		arr.resize(n)
	for g in n:
		var i := g % d.x
		var j := (g / d.x) % d.y
		var k := g / nyx
		u[g] = 0.5 * (cu[g] + cu[g - 1]) if i > 0 else cu[g]
		vv[g] = 0.5 * (cv[g] + cv[g - d.x]) if j > 0 else cv[g]
		ww[g] = 0.5 * (cw[g] + cw[g - nyx]) if k > 0 else cw[g]
	var zero := PackedFloat32Array()
	zero.resize(n)
	return {u = u, v = vv, w = ww, th = zero, p = zero.duplicate()}


func test_warm_start_variants() -> void:
	if OS.get_environment("AIR_WARMSTART") != "1":
		print("    skip: сравнение стартов — по AIR_WARMSTART=1 (≈ 1,5 ч: поле «Эвристики» строится на CPU)")
		return
	var hc: Dictionary = Config.get_config("atmosphere").air_model.hybrid_checks
	var g := AirGpu.new()
	if not g.init(AirGpu.SHADERS + AirPhaseJob._names()):
		check(false, "RD фаз: %s" % g.error)
		return
	var rows := []
	for pid: String in hc.places:
		var lw := TestAirPlace.load_detail(pid)
		var loc := TestAirPlace.load_loc(pid)
		for u10: float in hc.u10_ms:
			var mk := func(hour: float) -> AirCase:
				var cc := AirPlace.domain_case(lw[0], lw[1], loc, AirRuntime.DX, hour, u10, 150.0, NAN, "clear", true, 1.0)
				return AirRuntime.PreparedCase.from_case(cc)
			var hour := float(hc.hour)
			var c0: AirCase = mk.call(hour)
			var ph := _phase(g, c0)
			var ref := _solve(mk.call(hour), {}, [], true)
			var row := {place = "%s %.0f м/с" % [pid, u10], omega = ph.omega[0], frozen = (ph.get("stats", {}) as Dictionary).get("phase_frac", {})}
			var t0 := Time.get_ticks_usec()
			var heur := heuristic_warm(c0, lw[0], u10, 150.0)
			row.heur_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
			var coarse := {}
			for m: int in hc.coarse_factors:
				var cc0 := AirPlace.domain_case(lw[0], lw[1], loc, AirRuntime.DX * m, hour, u10, 150.0, NAN, "clear", true, 1.0)
				var ccase := AirRuntime.PreparedCase.from_case(cc0)
				var cj := _solve(ccase, {}, [], true)
				coarse[m] = {
					warm = [coarse_warm(c0, ccase, cj.state(true)), coarse_warm(c0, ccase, cj.state(false))],
					iters = cj.results.map(func(r: Dictionary) -> int: return int(r.iters)),
					gpu_ms = cj.gpu_ms_total,
				}
				cj.release()
			var prev_job := _solve(mk.call(hour - 0.25), ph, [], true)
			var prev := [prev_job.state(true), prev_job.state(false)]
			prev_job.release()
			var variants := {
				cold = [{}, [], true],
				cold_ph = [ph, [], true],
				cold_map = [ph, [], false],
				asm = [ph, [ph.get("warm_mech", {}), ph.get("warm", {})], true],
				heur = [ph, [heur, heur], true],
				prev = [ph, prev, true],
			}
			for m: int in coarse:
				variants["coarse%d" % m] = [ph, coarse[m].warm, true]
			var cells := HybridTest.abc_cells(c0, ph, hc)
			var d := c0.dims()
			var us := maxf(c0.u_a, 0.1)
			var sref := ref.state(false)
			for key: String in variants:
				var vv: Array = variants[key]
				var job := ref if key == "cold" else _solve(mk.call(hour), vv[0], vv[1], vv[2])
				var du := HybridTest.du_stats(sref, job.state(false), cells, d.x, d.x * d.y)
				row[key] = {
					iters = job.results.map(func(r: Dictionary) -> int: return int(r.iters)),
					status = job.results.map(func(r: Dictionary) -> String: return String(r.status)),
					du_max_u = du.x / us,
					du_mean_u = du.y / us,
					gpu_ms = job.gpu_ms_total,
				}
				if key.begins_with("coarse"):
					var m := int(key.substr(6))
					row[key].coarse_iters = coarse[m].iters
					row[key].coarse_gpu_ms = coarse[m].gpu_ms
					row[key].cost = float(row[key].iters[0] + row[key].iters[1]) + float(coarse[m].iters[0] + coarse[m].iters[1]) / float(m * m)
				else:
					row[key].cost = float(row[key].iters[0] + row[key].iters[1])
				if key != "cold":
					job.release()
			ref.release()
			rows.append(row)
			print("    %s" % JSON.stringify(row))
	g.release()
	var sums := {}
	for r: Dictionary in rows:
		for key: String in r:
			if not r[key] is Dictionary or not (r[key] as Dictionary).has("cost"):
				continue
			sums[key] = float(sums.get(key, 0.0)) + float(r[key].cost)
			check(float(r[key].du_max_u) <= float(hc.du_max_frac) or float(r[key].du_mean_u) <= float(hc.du_mean_frac), "%s %s: поле как у холодного" % [r.place, key])
	print("    итерации, сумма по местам: %s" % JSON.stringify(sums))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT).get_base_dir())
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({rows = rows, iters_sum = sums}, "  "))
