extends TestCase
## Пикар на GPU (AM-03): замеры на Онгудае 400/200 м и тёплый старт (реальный рельеф).
## GPU: tools/gpu_tests.sh --filter=test_air_picard_bench; замеры — AIR_PICARD_BENCH=1
## (под flock /tmp/heat_ca_gpu.lock; AIR_PICARD_BENCH_DX=400|200, AIR_PICARD_BENCH_QUICK=1).
## Помощники — TestAirPicard (test_air_picard_gpu.gd).

const FIX_ONG := TestAirPicard.FIX_ONG


func needs_gpu() -> bool:
	return true


## Решить порциями (кадры), вернуть задачу (release — на вызывающем).
func _solve(c: AirCase, mech := false, warm := {}, loading := false) -> AirPicardJob:
	var job := AirPicardJob.new()
	job.case = c
	if loading:
		# экран загрузки: за кадр — порции подряд в пределах 40 мс главного потока
		job.chunk_ms = 30.0
		job.mech = mech
		job.warm = warm
		if not job.start():
			failures.append("start: " + job.error)
			return null
		var fr := 0
		while not job.is_done() and job.error == "" and fr < 100000:
			await Engine.get_main_loop().process_frame
			job.poll_slice(40.0)
			fr += 1
		check(job.is_done(), "%s: решено (%s)" % [c.label, job.error])
		return job
	job.mech = mech
	job.warm = warm
	if not job.start():
		failures.append("start: " + job.error)
		return null
	var frames := 0
	while not job.is_done() and job.error == "" and frames < 100000:
		await Engine.get_main_loop().process_frame
		job.poll()
		frames += 1
	check(job.is_done(), "%s: решено (%s)" % [c.label, job.error])
	return job


# ---------------------------------------------------------------- замеры (AIR_PICARD_BENCH=1)


static func _time_prog(g: AirGpu, prog: Array, reps: int) -> float:
	return TestAirGpuBlocks._time_program(g, prog, reps)


static func _part_mom(job: AirPicardJob) -> void:
	for comp in 3:
		job._mom(comp)


static func _part_zebra(job: AirPicardJob, dir: int) -> void:
	var b: Dictionary = job.buf
	for _s in int(job.case.p.mom_sweeps):
		for cx: Array in [[b.Cu, b.u], [b.Cv, b.v], [b.Cw, b.w]]:
			job.gpu.zebra(cx[0], cx[1], RID(), job.case.dims(), [dir], true)


static func _part_heat(job: AirPicardJob) -> void:
	for _s in int(job.case.p.heat_sweeps):
		job.gpu.zebra(job.buf.Cu, job.buf.th, RID(), job.case.dims(), [2, 0, 1], true)


func test_bench_ongudai() -> void:
	if OS.get_environment("AIR_PICARD_BENCH") != "1":
		return
	var only := OS.get_environment("AIR_PICARD_BENCH_DX")
	for dx in [400, 200]:
		if only != "" and only != str(dx):
			continue
		var m := TestAirPicard.load_fix(FIX_ONG + "ongudai_d%d_h12" % dx)
		# ---- разбивка итерации по ядрам (3 м/с, состояние после 20 итераций)
		var job := AirPicardJob.new()
		job.case = TestAirPicard.case_ongudai(m, 3.0)
		job.mech = false
		if not job.start():
			failures.append(job.error)
			return
		var g := job.gpu
		g.run(job._program("init"))
		var one := job._prog_iteration()
		for _i in 20:
			g.run(one)
		g.submit()
		g.sync()
		var parts := [
			["граничные условия", job._bc.bind(0)],
			["местное K (kloc)", job._kloc],
			["шаблоны импульса ×3", _part_mom.bind(job)],
			["прогонки импульса z (2×3 зебры)", _part_zebra.bind(job, 2)],
			["прогонки импульса x", _part_zebra.bind(job, 0)],
			["прогонки импульса y", _part_zebra.bind(job, 1)],
			["шаблон тепла", job._heat],
			["прогонки тепла z, x, y (4×)", _part_heat.bind(job)],
		]
		var rows := []
		var total := 0.0
		for pt in parts:
			var prog := g.record(pt[1])
			_time_prog(g, prog, 2)
			var ms := _time_prog(g, prog, 10)
			rows.append([pt[0], ms, prog.size()])
			total += ms
		var proj := job._prog_project(1, true)
		_time_prog(g, proj, 2)
		var vc := job.mg.program(job.buf.phi, job.buf.rhs)
		var ms_vc := _time_prog(g, vc, 10)
		var ms_pr := _time_prog(g, proj, 10)
		rows.append(["проекция: V-цикл (%d уровней)" % job.mg.levels.size(), ms_vc, vc.size()])
		rows.append(
			["проекция: ∇·u, центрирование, поправка", ms_pr - ms_vc, proj.size() - vc.size()]
		)
		total += ms_pr
		var whole := _time_prog(g, one, 5)
		var chk := job._prog_check()
		var ms_chk := _time_prog(g, chk, 5)
		print(
			(
				"  %d м (%dx%dx%d): ядро | мс на итерацию | доля | запусков"
				% [dx, job.case.nx_h, job.case.ny_h, job.case.nz_h]
			)
		)
		for r in rows:
			print("  %s | %.3f | %.0f %% | %d" % [r[0], r[1], 100.0 * r[1] / total, r[2]])
		print(
			(
				(
					"  сумма частей %.2f мс; итерация целиком %.2f мс (%d запусков); "
					+ "проверка %.2f мс (раз в 10 итераций)"
				)
				% [total, whole, one.size(), ms_chk]
			)
		)
		job.release()
		# ---- решения целиком (порциями, окно тестов)
		print(
			(
				(
					"  %d м: ветер | нагрев | итераций (эталон f32) | стена, с | GPU, с | "
					+ "мс/итерацию GPU | порций | макс. порция GPU, мс | CPU в poll Σ/макс, "
					+ "мс"
				)
				% dx
			)
		)
		var cases := [
			[0.0, false],
			[3.0, false],
			[6.0, false],
			[3.0, true],
			[3.0, false, true],
			[6.0, false, true],
			[3.0, true, true]
		]
		if OS.get_environment("AIR_PICARD_BENCH_QUICK") == "1":
			cases = [[3.0, false], [3.0, false, true]]
		for cse in cases:
			var c := TestAirPicard.case_ongudai(m, cse[0])
			var loading: bool = cse.size() > 2
			var jb: AirPicardJob = await _solve(c, cse[1], {}, loading)
			if jb == null or not jb.is_done():
				continue
			var it := 0
			var ref := []
			for r: Dictionary in jb.results:
				it += int(r.iters)
				ref.append(str(TestAirPicard._ref_iters(m, cse[0], r.heated, "float32")))
			print(
				(
					"  %d м/с | %s | %d (%s) | %.2f | %.2f | %.2f | %d | %.1f | %.0f / %.1f"
					% [
						int(cse[0]),
						(
							("пара (без + с)" if cse[1] else "с нагревом")
							+ (", загрузка" if loading else "")
						),
						it,
						" + ".join(ref),
						jb.wall_ms / 1000.0,
						jb.gpu_ms_total / 1000.0,
						jb.gpu_ms_total / maxf(it, 1),
						jb.chunks,
						jb.max_chunk_gpu_ms,
						jb.poll_cpu_ms,
						jb.max_poll_cpu_ms
					]
				)
			)
			var imax := 0
			for q in jb.chunk_log.size():
				if jb.chunk_log[q].y > jb.chunk_log[imax].y:
					imax = q
			print(
				(
					(
						"    наибольшая порция — №%d из %d: %d запусков, %.1f мс; главный "
						+ "поток: запись %.0f мс, ожидание sync %.0f мс"
					)
					% [
						imax,
						jb.chunks,
						int(jb.chunk_log[imax].x),
						jb.chunk_log[imax].y,
						jb.record_cpu_ms,
						jb.sync_wait_ms
					]
				)
			)
			check(
				jb.max_chunk_gpu_ms <= 50.0,
				"%d м: порция ≤ 50 мс (%.1f)" % [dx, jb.max_chunk_gpu_ms]
			)
			jb.release()


# ---------------------------------------------------------------- тёплый старт


## Тёплый старт от поля с давлением (Air.init_from: u, v, w, θ′, p + 4 V-цикла без изменения p):
## то же поле — остановка на первой проверке; соседнее время (12:00 → 12:30) — меньше итераций,
## чем с холодного старта, решение то же (до критерия остановки).
func test_warm_start() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var c12 := AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0)
	var j12: AirPicardJob = await _solve(c12)
	if j12 == null or not j12.is_done():
		return
	var st := j12.state()
	var it12 := j12.iterations()
	j12.release()
	var same: AirPicardJob = await _solve(
		AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0), false, st
	)
	var it_same := same.iterations() if same != null else -1
	check(it_same == 10, "то же поле с тёплого старта: %d итераций (≤ 10)" % it_same)
	if same != null:
		same.release()
	var cold: AirPicardJob = await _solve(
		AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.5, 3.0, 150.0)
	)
	var warm: AirPicardJob = await _solve(
		AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.5, 3.0, 150.0), false, st
	)
	if cold == null or warm == null:
		return
	var dv := 0.0
	for nm in ["u", "v", "w"]:
		dv = maxf(dv, TestAirPicard.max_abs_diff(cold.download(nm), warm.download(nm)))
	var dth := TestAirPicard.max_abs_diff(cold.download("th"), warm.download("th"))
	print(
		(
			(
				"  Онгудай 400 м, 3 м/с: 12:00 холодный %d итераций; то же тёплым %d; "
				+ "12:30 холодный %d, тёплый от 12:00 %d (−%.0f %%); max|Δu| "
				+ "холодный/тёплый %s м/с, max|Δθ′| %s К"
			)
			% [
				it12,
				it_same,
				cold.iterations(),
				warm.iterations(),
				100.0 * (1.0 - float(warm.iterations()) / cold.iterations()),
				TestAirPicard.sci(dv),
				TestAirPicard.sci(dth)
			]
		)
	)
	check(warm.iterations() < cold.iterations(), "тёплый старт экономит итерации")
	cold.release()
	warm.release()
