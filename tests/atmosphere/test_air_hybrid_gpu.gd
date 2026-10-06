extends TestCase
## air-phase P14 v2 (A/B/C, время): на местах игры, где холодный Пикар сходится, гибрид (фазы P10 →
## тёплый старт от сборки, карта ω, заморозка колонн механизмов, запасное правило — P11) приходит к
## тому же полю в клетках фаз A/B/C (max|Δu_h| ≤ du_max_frac·U_sat или средняя ≤ du_mean_frac·U_sat;
## зоны подъёма/опускания — те же по площади) за меньшее число итераций. Время пересчёта (фазы, Пикар,
## проекция-сшивка) — в лог и build/dp/AP-20/timing.json; оценка RX 5600 XT — по пропускной
## способности памяти (оговорка в timing.json). Допуски и места — configs/atmosphere.json →
## air_model.hybrid_checks (до блока air_phase.checks AP-19).
## Фазы: AirPhaseJob (AP-19), нет — заглушка PhaseStub (test_air_runtime.gd): тогда проверяется
## только совпадение поля (тёплый старт заглушки — однородный поток, итераций не меньше).
## tools/gpu_tests.sh --filter=air_hybrid (под dp lock gpu).

const RuntimeTest := preload("res://tests/atmosphere/test_air_runtime.gd")
const TIMING := "res://build/dp/AP-20/timing.json"


func needs_gpu() -> bool:
	return true


func _cfg() -> Dictionary:
	return Config.get_config("atmosphere").air_model.hybrid_checks


func _phase(c: AirCase) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var ph := {}
	var real := ResourceLoader.exists(AirRuntime.PHASE_JOB_PATH)
	if real:
		var pj: Object = (load(AirRuntime.PHASE_JOB_PATH) as Script).new(null)
		ph = pj.call("run", c)
	else:
		var st := RuntimeTest.PhaseStub.new()
		st.block = 0
		ph = st.run(c)
	ph.cpu_ms = (Time.get_ticks_usec() - t0) / 1000.0
	ph.real = real
	return ph


func _solve(c: AirCase, ph: Dictionary) -> AirPicardJob:
	var job := AirPicardJob.new()
	job.case = c
	job.mech = true
	if not ph.is_empty():
		job.warm = ph.get("warm", {})
		job.omega_map = ph.get("omega", PackedFloat32Array())
		job.freeze_mask = ph.get("freeze", PackedByteArray())
		job.freeze_field = ph.get("mech_field", {})
		var am: Dictionary = Config.get_config("atmosphere").air_model
		job.omega_fallback = Vector2(float(am.omega_fallback_iters), float(am.omega_fallback_value))
	if not job.start():
		failures.append("start: " + job.error)
		return null
	var frames := 0
	while not job.is_done() and job.error == "" and frames < 200000:
		await Engine.get_main_loop().process_frame
		job.poll_slice(40.0)
		frames += 1
	check(job.is_done(), "%s: решено (%s)" % [c.label, job.error])
	return job if job.is_done() else null


## Клетки сравнения: воздух, ниже agl_max над землёй, сумма весов A, B, C ≥ abc_min_weight.
static func abc_cells(c: AirCase, ph: Dictionary, cfg: Dictionary) -> PackedInt32Array:
	var w: PackedFloat32Array = ph.get("weights", PackedFloat32Array())
	var names: Array = AirRuntime._phase_names()
	var n2 := c.nx * c.ny
	var out := PackedInt32Array()
	var tc := AirRuntime.cell_codes(c)
	var d := c.dims()
	for j in c.ny:
		for i in c.nx:
			var q := j * c.nx + i
			var abc := 0.0
			for k in names.size():
				if String(names[k]) in ["A", "B", "C"] and w.size() == names.size() * n2:
					abc += w[k * n2 + q]
			if abc < float(cfg.abc_min_weight):
				continue
			for k in range(1, d.z - 1):
				var g := (k * d.y + j + 1) * d.x + i + 1
				if int(tc[g]) == 1 and c.zc(k) - c.hc[q] <= float(cfg.agl_max_m):
					out.append(g)
	return out


## |Δu_h| в центрах клеток (среднее граней) по списку клеток: (max, среднее).
static func du_stats(a: Dictionary, b: Dictionary, cells: PackedInt32Array, nx_h: int, nyx: int) -> Vector2:
	var mx := 0.0
	var s := 0.0
	for g in cells:
		var ua: float = 0.5 * (a.u[g] + a.u[g + 1])
		var va: float = 0.5 * (a.v[g] + a.v[g + nx_h])
		var ub: float = 0.5 * (b.u[g] + b.u[g + 1])
		var vb: float = 0.5 * (b.v[g] + b.v[g + nx_h])
		var e := Vector2(ua - ub, va - vb).length()
		mx = maxf(mx, e)
		s += e
	return Vector2(mx, s / maxf(cells.size(), 1))


## Доли клеток-зон подъёма и опускания w_mech в слое zone_agl_m (среди A/B/C-колонн).
static func zone_fracs(c: AirCase, wm: PackedFloat32Array, cells: PackedInt32Array, cfg: Dictionary) -> Vector2:
	var lo: float = cfg.zone_agl_m[0]
	var hi: float = cfg.zone_agl_m[1]
	var thr := float(cfg.zone_w_ms)
	var d := c.dims()
	var nyx := d.x * d.y
	var up := 0
	var dn := 0
	var n := 0
	for g in cells:
		var k := g / nyx
		var q := (((g % nyx) / d.x) - 1) * c.nx + (g % d.x) - 1
		var agl := c.zc(k) - c.hc[q]
		if agl < lo or agl > hi:
			continue
		var w := 0.5 * (wm[g] + wm[g + nyx])
		n += 1
		up += 1 if w > thr else 0
		dn += 1 if w < -thr else 0
	return Vector2(up, dn) / maxf(n, 1)


func test_hybrid_vs_cold() -> void:
	var cfg := _cfg()
	var rows := []
	var places: Array = cfg.places
	var winds: Array = cfg.u10_ms
	for pid: String in places:
		var lw := TestAirPlace.load_detail(pid)
		if lw.is_empty():
			check(false, "нет места %s" % pid)
			continue
		var loc := TestAirPlace.load_loc(pid)
		for u10: float in winds:
			var mk := func() -> AirCase:
				return AirPlace.domain_case(
					lw[0], lw[1], loc, AirRuntime.DX, float(cfg.hour), u10, 150.0, NAN, "clear", true, 1.0
				)
			var c_cold: AirCase = mk.call()
			if c_cold == null:
				check(false, "%s: случай не собрался" % pid)
				continue
			c_cold.label = "%s %.0f м/с" % [pid, u10]
			var cold: AirPicardJob = await _solve(c_cold, {})
			if cold == null:
				continue
			var st_cold: Array = cold.results.map(func(r: Dictionary) -> String: return String(r.status))
			var c_h: AirCase = mk.call()
			c_h.label = c_cold.label + " гибрид"
			c_h.prepare()
			var ph := _phase(c_h)
			var hyb: AirPicardJob = await _solve(c_h, ph)
			if hyb == null:
				cold.release()
				continue
			var row := _compare(c_cold, cold, hyb, ph, cfg)
			row.cold_status = st_cold
			rows.append(row)
			print("    %s" % JSON.stringify(row))
			if st_cold.all(func(s: String) -> bool: return s == "ok"):
				var ok_field := float(row.du_max_u) <= float(cfg.du_max_frac) or float(row.du_mean_u) <= float(cfg.du_mean_frac)
				check(ok_field, "%s: поле как у холодного (max %.3f U, ср. %.3f U)" % [c_cold.label, row.du_max_u, row.du_mean_u])
				check(float(row.zone_up_diff) <= float(cfg.zone_frac_tol) and float(row.zone_dn_diff) <= float(cfg.zone_frac_tol), "%s: зоны подъёма/опускания те же %s" % [c_cold.label, [row.zone_up_diff, row.zone_dn_diff]])
				if bool(ph.real):
					check(int(row.iters_hybrid_sum) < int(row.iters_cold_sum), "%s: итераций меньше (%d < %d)" % [c_cold.label, row.iters_hybrid_sum, row.iters_cold_sum])
			else:
				print("    %s: холодный Пикар не сошёлся (%s) — не эталон (P9 v2)" % [c_cold.label, st_cold])
			cold.release()
			hyb.release()
	_write_timing(rows, cfg)


func _compare(c: AirCase, cold: AirPicardJob, hyb: AirPicardJob, ph: Dictionary, cfg: Dictionary) -> Dictionary:
	var cells := abc_cells(c, ph, cfg)
	var d := c.dims()
	var sc := cold.state(false)
	var sh := hyb.state(false)
	var du := du_stats(sc, sh, cells, d.x, d.x * d.y)
	var us := maxf(c.u_a, 0.1)
	var zc := zone_fracs(c, cold.state(true).w, cells, cfg)
	var zh := zone_fracs(c, hyb.state(true).w, cells, cfg)
	var ic := 0
	var ih := 0
	for r: Dictionary in cold.results:
		ic += int(r.iters)
	for r: Dictionary in hyb.results:
		ih += int(r.iters)
	var hr: Dictionary = hyb.results[-1]
	return {
		place = c.label,
		u_sat = us,
		abc_cells = cells.size(),
		du_max_u = du.x / us,
		du_mean_u = du.y / us,
		zone_up = [zc.x, zh.x],
		zone_dn = [zc.y, zh.y],
		zone_up_diff = absf(zc.x - zh.x),
		zone_dn_diff = absf(zc.y - zh.y),
		iters_cold = cold.results.map(func(r: Dictionary) -> int: return int(r.iters)),
		iters_hybrid = hyb.results.map(func(r: Dictionary) -> int: return int(r.iters)),
		iters_cold_sum = ic,
		iters_hybrid_sum = ih,
		hybrid_status = hyb.results.map(func(r: Dictionary) -> String: return String(r.status)),
		omega_fallback_used = bool(hr.omega_fallback_used),
		frozen_frac = float(hr.frozen_frac),
		phases_real = bool(ph.real),
		phase_frac = ph.get("stats", {}),
		ms_phase = float(ph.get("ms", ph.cpu_ms)) if (ph.get("ms") is float or ph.get("ms") is int) else float(ph.cpu_ms),
		ms_cold = {gpu = cold.gpu_ms_total, wall = cold.wall_ms, stages = cold.phase_gpu_ms},
		ms_hybrid = {gpu = hyb.gpu_ms_total, wall = hyb.wall_ms, stages = hyb.phase_gpu_ms},
	}


func _write_timing(rows: Array, cfg: Dictionary) -> void:
	var rd := RenderingServer.get_rendering_device()
	var dev := rd.get_device_name() if rd != null else "?"
	var k_lo := float(cfg.bw_ref_gbs) / float(cfg.bw_target_gbs[1])
	var k_hi := float(cfg.bw_ref_gbs) / float(cfg.bw_target_gbs[0])
	var est := []
	for r: Dictionary in rows:
		var t := float(r.ms_phase) + float(r.ms_hybrid.gpu)
		est.append({place = r.place, ms_measured = t, ms_rx5600xt = [t * k_lo, t * k_hi]})
	var out := {
		device = dev,
		rows = rows,
		rx5600xt = est,
		note = (
			"Оценка RX 5600 XT = замер × %s/%s ГБ/с (пропускная способность памяти); не учтены "
			% [cfg.bw_ref_gbs, cfg.bw_target_gbs]
			+ "разница вычислений, кэша, драйвера и что фазы считались на CPU (ms_phase — CPU, не GPU)."
		),
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TIMING).get_base_dir())
	var f := FileAccess.open(ProjectSettings.globalize_path(TIMING), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  "))
	print("    timing → %s (%s)" % [TIMING, dev])
