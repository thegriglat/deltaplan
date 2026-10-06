extends TestCase
## Фазы поля на GPU (P10 / P14, AirPhaseJob + air_phase.glsl): GPU = CPU (max|Δ|/max|CPU| ≤
## air_phase.checks.gpu_cpu_rel по weights/omega/warm), детерминизм (повтор побитно), порциями
## start/poll = run, общий AirGpu (ядра фаз добавляются к уже открытому). Места: синтетические
## (холм с нагревом, блокирование со слоями D, крутой хребет со срывом, вечерняя долина) и Онгудай
## 400 м (рельеф игры). Время фаз GPU/CPU — в лог и build/dp/AP-19/timing.json.
## GPU: tools/gpu_tests.sh --filter=air_phase_gpu (под dp lock gpu).

const T := preload("res://tests/atmosphere/test_air_phase.gd")
const FIX_ONG := "res://tests/atmosphere/fixtures/air_model/picard/"
const KEYS := ["u", "v", "w", "th"]

var _timing := {}


func needs_gpu() -> bool:
	return true


static func rel(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var d := 0.0
	var m := 0.0
	for q in a.size():
		d = maxf(d, absf(a[q] - b[q]))
		m = maxf(m, absf(b[q]))
	return d / maxf(m, 1e-12)


func _cases() -> Array:
	var out := [
		T.make_case(400.0, 4.0, 200.0, 1200.0, 0.01, 250.0, 32),
		T.make_case(600.0, 1.5, 0.0, 0.0, 0.01, 300.0, 32),
		T.make_case(-400.0, 0.5, -40.0, 0.0, 0.02, 270.0, 32),
	]
	# крутой хребет: срыв за бровкой (огибающая 12°)
	var c := T.make_case(1200.0, 6.0, 0.0, 0.0, 0.01, 270.0, 32)
	out.append(c)
	var m := TestAirPicard.load_fix(FIX_ONG + "ongudai_d400_h12")
	out.append(TestAirPicard.case_ongudai(m, 3.0))
	return out


func _compare(lbl: String, g: Dictionary, c: Dictionary, tol: float) -> float:
	var worst := 0.0
	var rows := []
	for key in ["weights", "weights_mech", "omega"]:
		var e := rel(g[key], c[key])
		rows.append("%s %s" % [key, String.num_scientific(e)])
		worst = maxf(worst, e)
	for wk in ["warm", "warm_mech"]:
		for k in KEYS:
			var e := rel(g[wk][k], c[wk][k])
			rows.append("%s.%s %s" % [wk, k, String.num_scientific(e)])
			worst = maxf(worst, e)
	# где расходятся веса: фаза, клетка, значения
	for key in ["weights", "weights_mech"]:
		var a: PackedFloat32Array = g[key]
		var b: PackedFloat32Array = c[key]
		var n2 := b.size() / AirPhase.K
		var best := -1.0
		var at := 0
		for q in b.size():
			if absf(a[q] - b[q]) > best:
				best = absf(a[q] - b[q])
				at = q
		print("  %s: max|Δ| %s — фаза %s, клетка %d (j %d, i %d): GPU %.4f CPU %.4f" % [
			key, String.num_scientific(best), AirPhase.PHASES[at / n2], at % n2, (at % n2) / int(sqrt(n2)), at % int(sqrt(n2)), a[at], b[at]
		])
	var fz_ok: bool = g.freeze == c.freeze and g.freeze_mech == c.freeze_mech
	print("air_phase_gpu %s: max %s; %s; заморозка %s" % [lbl, String.num_scientific(worst), ", ".join(rows), "=" if fz_ok else "≠"])
	check(worst <= tol, "%s: GPU = CPU (%s ≤ %s)" % [lbl, String.num_scientific(worst), tol])
	check(fz_ok, "%s: маска заморозки GPU = CPU" % lbl)
	return worst


func test_gpu_equals_cpu() -> void:
	var conf := T.cfg()
	var tol := float(conf.checks.gpu_cpu_rel)
	var gpu := AirGpu.new()
	if not gpu.init():
		failures.append("AirGpu: " + gpu.error)
		return
	var rows := []
	for c: AirCase in _cases():
		var t0 := Time.get_ticks_usec()
		var rc := AirPhaseCpu.run(c, conf)
		var cpu_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var job := AirPhaseJob.new(gpu)
		job.cfg = conf
		t0 = Time.get_ticks_usec()
		var rg := job.run(c)
		var wall := (Time.get_ticks_usec() - t0) / 1000.0
		if rg.has("error") or rc.has("error"):
			failures.append("%s: %s / %s" % [c.label, rg.get("error", ""), rc.get("error", "")])
			job.release()
			continue
		var e := _compare(c.label, rg, rc, tol)
		# повтор на том же устройстве — побитно
		var job2 := AirPhaseJob.new(gpu)
		job2.cfg = conf
		var rg2 := job2.run(c)
		check(rg2.weights == rg.weights and rg2.warm.u == rg.warm.u and rg2.warm.th == rg.warm.th, "%s: детерминизм GPU" % c.label)
		job2.release()
		var st: Dictionary = rg.stats
		var row := {
			label = c.label,
			nx = c.nx,
			nz = c.nz,
			gpu_ms = rg.ms_parts.gpu,
			prepare_ms = rg.ms_parts.prepare,
			download_ms = rg.ms_parts.download,
			wall_gpu_path_ms = wall,
			cpu_ms = cpu_ms,
			cpu_parts = rc.ms_parts,
			rel_err = e,
			fr = st.fr,
			omega = st.omega,
			phase_frac = st.phase_frac,
			frozen_frac = st.frozen_frac,
			chunks = job.chunks,
		}
		print("air_phase_gpu %s: GPU %.1f мс (+ подготовка %.0f, чтение %.0f), CPU %.0f мс; Fr %.2f ω %.2f доли %s" % [
			c.label, row.gpu_ms, row.prepare_ms, row.download_ms, cpu_ms, st.fr, st.omega, st.phase_frac
		])
		rows.append(row)
		job.release()
	gpu.release()
	_timing.cases = rows
	_save_timing()


func test_chunks_and_own_device() -> void:
	# порциями (кадры) на собственном AirGpu = синхронный run на общем
	var conf := T.cfg()
	var c := T.make_case(500.0, 3.0, 150.0, 1000.0, 0.01, 230.0, 32)
	var job := AirPhaseJob.new()
	job.cfg = conf
	job.case = c
	check(job.start(), "start: %s" % job.error)
	var fr := 0
	while not job.is_done() and job.error == "" and fr < 10000:
		await Engine.get_main_loop().process_frame
		job.poll()
		fr += 1
	check(job.is_done(), "порциями — готово (%s)" % job.error)
	if not job.is_done():
		job.release()
		return
	var a := job.result()
	print("air_phase_gpu порциями: кадров %d, порций %d, max порция %.2f мс GPU, GPU %.2f мс" % [
		fr, job.chunks, job.max_chunk_gpu_ms, a.ms_parts.gpu
	])
	job.release()
	var gpu := AirGpu.new()
	if not gpu.init():
		failures.append("AirGpu: " + gpu.error)
		return
	var job2 := AirPhaseJob.new(gpu)
	job2.cfg = conf
	var b := job2.run(c)
	job2.release()
	gpu.release()
	check(a.weights == b.weights and a.warm.u == b.warm.u, "порциями = подряд (побитно)")


func _save_timing() -> void:
	# оценка RX 5600 XT — замер × пропускная способность памяти 504 / (288…336) ГБ/с (P14; упор — память и запуски)
	var k_lo := 504.0 / 336.0
	var k_hi := 504.0 / 288.0
	for row: Dictionary in _timing.get("cases", []):
		row.gpu_ms_rx5600xt_est = [row.gpu_ms * k_lo, row.gpu_ms * k_hi]
	_timing.note = "gpu_ms — GPU-время ядер фаз (метки AirGpuJob); оценка RX 5600 XT — × 504/(288…336) ГБ/с, без учёта L2 и запусков"
	var dir := ProjectSettings.globalize_path("res://build/dp/AP-19")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "/timing.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_timing, "  "))
		f.close()
		print("air_phase_gpu: время — %s/timing.json" % dir)
