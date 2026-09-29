class_name TestAirGpuBlocks
extends TestCase
## Строительные блоки модели воздуха на GPU (AM-02) против эталона float64
## (tools/research/air3d/gpu_block_refs.py → tests/atmosphere/fixtures/air_model/blocks/).
## Нужен настоящий RenderingDevice: tools/gpu_tests.sh --filter=test_air_gpu.
## В headless пропускается.
## Замеры времени блоков: AIR_GPU_BENCH=1 tools/gpu_tests.sh --filter=test_air_gpu_blocks.

const FIX := "res://tests/atmosphere/fixtures/air_model/blocks/"
const TOL := 1e-5


func needs_gpu() -> bool:
	return true


static func load_case(name: String) -> Dictionary:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + name + ".json"))
	var all := FileAccess.get_file_as_bytes(FIX + name + ".bin").to_float32_array()
	var data := {}
	for k in meta.arrays:
		var o: Array = meta.arrays[k]
		data[k] = all.slice(int(o[0]), int(o[0]) + int(o[1]))
	meta.data = data
	var d: Array = meta.dims
	meta.v = Vector3i(int(d[0]), int(d[1]), int(d[2]))
	return meta


## max|a − b| / max|b|.
static func rel_err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	var m := 0.0
	for i in b.size():
		e = maxf(e, absf(a[i] - b[i]))
		m = maxf(m, absf(b[i]))
	return e / maxf(m, 1e-30)


## Число в виде 1.23e-06 (у % в GDScript нет %e).
static func sci(v: float) -> String:
	if v == 0.0 or is_nan(v) or is_inf(v):
		return str(v)
	var e := floori(log(absf(v)) / log(10.0))
	return "%.2fe%+03d" % [v / pow(10.0, e), e]


## a минус среднее по активным клеткам (float64 в GDScript).
static func centered(a: PackedFloat32Array, act: PackedFloat32Array) -> PackedFloat32Array:
	var sum := 0.0
	var cnt := 0.0
	for i in a.size():
		sum += a[i] * act[i]
		cnt += act[i]
	var m := sum / maxf(cnt, 1.0)
	var out := a.duplicate()
	for i in a.size():
		out[i] = (a[i] - m) * act[i]
	return out


func _gpu() -> AirGpu:
	var g := AirGpu.new()
	if not g.init():
		failures.append("AirGpu.init: " + g.error)
		return null
	return g


func _row(table: Array, block: String, size: String, err: float) -> void:
	table.append([block, size, err])
	check(err <= TOL, "%s %s: отн. ошибка %s > %s" % [block, size, sci(err), sci(TOL)])


func test_blocks_vs_reference() -> void:
	var g := _gpu()
	if g == null:
		return
	var table := []
	_vec_blocks(g, table)
	for name in ["lines", "lines_long", "lines_mp_x", "lines_mp_y"]:
		_line_blocks(g, name, table)
	_mg_blocks(g, table)
	g.release()
	print("  блок | размер | отн. ошибка")
	for r in table:
		print("  %s | %s | %s" % [r[0], r[1], sci(r[2])])


func _vec_blocks(g: AirGpu, table: Array) -> void:
	var c := load_case("vec")
	var dat: Dictionary = c.data
	var x: PackedFloat32Array = dat.x
	var n := x.size()
	var bx := g.buffer(n, x)
	var bp := g.buffer(n, dat.p)
	var y := g.buffer(n)
	var ops := [
		["axpy", AirGpu.Vec.AXPY, float(c.a), 0.0],
		["xpay", AirGpu.Vec.XPAY, float(c.b), 0.0],
		["axpby", AirGpu.Vec.AXPBY, 1.3, -0.4],
		["scale", AirGpu.Vec.SCALE, 2.5, 0.0],
		["mul", AirGpu.Vec.MUL, 1.0, 0.0],
	]
	for o in ops:
		g.upload(y, dat.y)
		g.vec(o[1], bx, y, n, o[2], o[3])
		g.submit()
		g.sync()
		_row(table, o[0], str(n), rel_err(g.download(y), dat[o[0]]))
	# редукции: сумма — относительно Σ|·| (у суммы разных знаков относительная ошибка не определена)
	var by := g.buffer(n, dat.y)
	var red: Dictionary = c.reductions
	var n2 := int(c.n2)
	g.reduce(AirGpu.Red.SUM, bp, n, 0)
	g.reduce(AirGpu.Red.SUM, bx, n, 1)
	g.reduce(AirGpu.Red.MAXABS, bx, n, 2)
	g.reduce(AirGpu.Red.DOT, bx, n, 3, by)
	g.reduce(AirGpu.Red.SUM, bp, n2, 4)
	g.reduce(AirGpu.Red.DOT, bx, n2, 5, by)
	g.submit()
	g.sync()
	var s := g.download(g.scalars, 6)
	var rows := [
		["sum (x>0)", s[0], red.sum_p, red.sum_p, n],
		["sum (±)", s[1], red.sum_x, red.sumabs_x, n],
		["max|x|", s[2], red.maxabs_x, red.maxabs_x, n],
		["dot", s[3], red.dot_xy, red.sumabs_xy, n],
		["sum (x>0)", s[4], red.sum_p_n2, red.sum_p_n2, n2],
		["dot", s[5], red.dot_xy_n2, red.sumabs_xy_n2, n2],
	]
	for r in rows:
		_row(table, r[0], str(r[4]), absf(r[1] - r[2]) / absf(r[3]))


func _line_blocks(g: AirGpu, name: String, table: Array) -> void:
	var c := load_case(name)
	var dat: Dictionary = c.data
	var d: Vector3i = c.v
	var n := d.x * d.y * d.z
	var sz := "%dx%dx%d" % [d.x, d.y, d.z]
	var bc := g.buffer(7 * n, dat.C)
	var bb := g.buffer(n, dat.b)
	var x := g.buffer(n)
	var xo := g.buffer(n)
	if dat.has("resid"):
		g.upload(x, dat.x0)
		g.stencil(bc, x, bb, xo, d)
		g.submit()
		g.sync()
		_row(table, "resid7", sz, rel_err(g.download(xo), dat.resid))
		g.stencil(bc, x, bb, xo, d, true)
		g.submit()
		g.sync()
		_row(table, "apply7", sz, rel_err(g.download(xo), dat.apply))
	for dir in 3:
		var nm: String = ["x", "y", "z"][dir]
		if not dat.has("zebra_" + nm):
			continue
		var kind := "многопр." if d[dir] > AirGpu.LINE_MAX else "разд."
		g.upload(x, dat.x0)
		g.line(bc, x, bb, d, dir, 0)
		g.line(bc, x, bb, d, dir, 1)
		g.submit()
		g.sync()
		_row(table, "прогонка %s зебра (%s, n=%d)" % [nm, kind, d[dir]], sz,
			rel_err(g.download(x), dat["zebra_" + nm]))
		g.upload(x, dat.x0)
		g.line(bc, x, bb, d, dir, -1, xo)
		g.submit()
		g.sync()
		_row(table, "прогонка %s все линии (%s)" % [nm, kind], sz,
			rel_err(g.download(xo), dat["all_" + nm]))


func _mg_blocks(g: AirGpu, table: Array) -> void:
	var c := load_case("mg")
	var dat: Dictionary = c.data
	var d: Vector3i = c.v
	var n := d.x * d.y * d.z
	var sz := "%dx%dx%d" % [d.x, d.y, d.z]
	var mg := AirMultigrid.new()
	var act := g.buffer(n, dat.act)
	mg.build(
		g, g.buffer(dat.cx.size(), dat.cx), g.buffer(dat.cy.size(), dat.cy),
		g.buffer(dat.cz.size(), dat.cz), act, d
	)
	var f := g.buffer(n, dat.f)
	var x := g.buffer(n)
	mg.vcycle(x, f)
	g.submit()
	g.sync()
	check(mg.levels.size() == (c.levels as Array).size(), "число уровней как в эталоне")
	_row(table, "шаблон уровня 0", sz, rel_err(g.download(mg.levels[0].c), dat.C0))
	_row(table, "шаблон уровня 1", "%dx%dx%d" % [d.x / 2, d.y / 2, d.z],
		rel_err(g.download(mg.levels[1].c), dat.C1))
	# φ при закрытых гранях определена с точностью до постоянной (Нейман): сравнение — после
	# вычитания среднего по активным клеткам (иначе меряется дрейф постоянной, а не решение)
	_row(table, "V-цикл ×1", sz, rel_err(centered(g.download(x), dat.act), centered(dat.x1, dat.act)))
	for _i in 4:
		mg.vcycle(x, f)
	g.submit()
	g.sync()
	_row(table, "V-цикл ×5", sz, rel_err(centered(g.download(x), dat.act), centered(dat.x5, dat.act)))
	table.append(["V-цикл ×5 без центрирования (справка)", sz, rel_err(g.download(x), dat.x5)])


# ---------------------------------------------------------------- повтор, порции, ошибки


## Синтетическая задача давления на сетке с маской (как mg_case эталона, K постоянный):
## гора по центру и подъём к востоку, все грани области закрыты (Нейман).
static func synthetic(d: Vector3i, dx := 100.0, dz := 50.0) -> Dictionary:
	var n := d.x * d.y * d.z
	var h := PackedFloat32Array()
	h.resize(d.x * d.y)
	for j in d.y:
		for i in d.x:
			var x := (i + 0.5) / d.x
			var y := (j + 0.5) / d.y
			h[j * d.x + i] = (
				0.45 * d.z * exp(-((x - 0.5) ** 2 + (y - 0.45) ** 2) / 0.04) + 1.2 * x
			)
	var act := PackedFloat32Array()
	act.resize(n)
	var f := PackedFloat32Array()
	f.resize(n)
	for k in d.z:
		for j in d.y:
			for i in d.x:
				var q := (k * d.y + j) * d.x + i
				var a := 1.0 if k + 0.5 >= h[j * d.x + i] else 0.0
				act[q] = a
				f[q] = a * 1e-3 * sin(0.37 * i + 0.21 * j * j + 0.5 * k)
	var kk := 120.0
	var cx := PackedFloat32Array()
	cx.resize(d.z * d.y * (d.x + 1))
	var cy := PackedFloat32Array()
	cy.resize(d.z * (d.y + 1) * d.x)
	var cz := PackedFloat32Array()
	cz.resize((d.z + 1) * d.y * d.x)
	var hx := kk / (dx * dx)
	var hz := kk / (dz * dz)
	for k in d.z:
		for j in d.y:
			for i in d.x:
				var q := (k * d.y + j) * d.x + i
				if act[q] == 0.0:
					continue
				if i > 0 and act[q - 1] != 0.0:
					cx[(k * d.y + j) * (d.x + 1) + i] = hx
				if j > 0 and act[q - d.x] != 0.0:
					cy[(k * (d.y + 1) + j) * d.x + i] = hx
				if k > 0 and act[q - d.x * d.y] != 0.0:
					cz[q] = hz
	return {cx = cx, cy = cy, cz = cz, act = act, f = f}


static func poisson_job(d: Vector3i, prob: Dictionary) -> AirPoissonJob:
	var job := AirPoissonJob.new()
	job.dims = d
	job.cx = prob.cx
	job.cy = prob.cy
	job.cz = prob.cz
	job.active = prob.act
	job.rhs = prob.f
	return job


## Прогон набора блоков; вывод — байты результатов (для побитного сравнения).
func _run_once() -> PackedByteArray:
	var g := _gpu()
	if g == null:
		return PackedByteArray()
	var out := PackedByteArray()
	var c := load_case("lines")
	var dat: Dictionary = c.data
	var d: Vector3i = c.v
	var n := d.x * d.y * d.z
	var bc := g.buffer(7 * n, dat.C)
	var bb := g.buffer(n, dat.b)
	var x := g.buffer(n, dat.x0)
	for _i in 3:
		g.zebra(bc, x, bb, d)
	g.reduce(AirGpu.Red.DOT, x, n, 0, bb)
	g.reduce(AirGpu.Red.SUM, x, n, 1)
	g.reduce(AirGpu.Red.MAXABS, x, n, 2)
	var m := load_case("mg")
	var md: Dictionary = m.data
	var mv: Vector3i = m.v
	var mn := mv.x * mv.y * mv.z
	var mg := AirMultigrid.new()
	mg.build(
		g, g.buffer(md.cx.size(), md.cx), g.buffer(md.cy.size(), md.cy),
		g.buffer(md.cz.size(), md.cz), g.buffer(mn, md.act), mv
	)
	var f := g.buffer(mn, md.f)
	var phi := g.buffer(mn)
	for _i in 3:
		mg.vcycle(phi, f)
	g.submit()
	g.sync()
	out.append_array(g.download(x).to_byte_array())
	out.append_array(g.download(g.scalars, 3).to_byte_array())
	out.append_array(g.download(phi).to_byte_array())
	g.release()
	return out


func test_two_runs_bitwise_equal() -> void:
	var a := _run_once()
	var b := _run_once()
	check(not a.is_empty(), "есть результат")
	check(a == b, "два прогона побитно одинаковы (%d байт)" % a.size())


## Порции через AirGpuJob: сходится, ни одна порция > 30 мс по меткам GPU, главный поток
## почти не ждёт в sync().
func test_job_chunks() -> void:
	# третий случай — бюджет 2 мс: V-цикл режется между кадрами (как на слабой карте)
	for cse in [[Vector3i(96, 96, 48), 30.0], [Vector3i(192, 192, 48), 30.0],
			[Vector3i(192, 192, 48), 2.0]]:
		var d: Vector3i = cse[0]
		var job := poisson_job(d, synthetic(d))
		job.chunk_ms = cse[1]
		job.tol = 1e-4
		var ok := job.start()
		check(ok, "start: " + job.error)
		if not ok:
			return
		var frames := 0
		var t0 := Time.get_ticks_msec()
		while not job.is_done() and job.error == "" and frames < 2000:
			await Engine.get_main_loop().process_frame
			job.poll()
			frames += 1
		var wall := Time.get_ticks_msec() - t0
		var gpu_sum := 0.0
		for e in job.chunk_log:
			gpu_sum += e.y
		print(
			(
				"  %s, бюджет %d мс: %s, V-циклов %d, порций %d, кадров %d, стена %d мс, "
				+ "GPU Σ %.1f мс, "
				+ "макс. порция %.2f мс, макс. ожидание sync %.2f мс, невязка %s"
			)
			% [
				d, cse[1], "готово" if job.is_done() else job.error, job.steps_done, job.chunks, frames,
				wall, gpu_sum, job.max_chunk_gpu_ms, job.max_sync_wait_ms, sci(job.residual)
			]
		)
		check(job.is_done(), "%s: сошлось (%s)" % [d, job.error])
		check(job.max_chunk_gpu_ms > 0.0, "метки времени GPU доступны")
		# программный Vulkan на CPU (lavapipe): один запуск ядра дольше 30 мс — не проверяем
		if not job.gpu.rd.get_device_name().contains("llvmpipe"):
			check(job.max_chunk_gpu_ms <= 30.0, "%s: порция ≤ 30 мс" % d)
		job.release()


func test_errors_are_reported() -> void:
	var g := AirGpu.new()
	check(not g.init(["air_no_such_kernel"]), "нет ядра — false")
	check(g.error.contains("нет ядра"), "понятная ошибка: " + g.error)
	g.release()
	var d := Vector3i(16, 16, 8)
	var job := poisson_job(d, synthetic(d))
	job.timeout_s = 0.0
	var got := []
	job.failed.connect(func(m: String) -> void: got.append(m))
	check(job.start(), "start")
	job.poll()
	await Engine.get_main_loop().process_frame
	job.poll()
	check(job.error.contains("таймаут"), "таймаут: " + job.error)
	check(got.size() == 1, "сигнал failed один раз")
	job.release()


# ---------------------------------------------------------------- замеры (AIR_GPU_BENCH=1)


## GPU-время одного повтора программы, мс (по меткам времени).
static func _time_program(g: AirGpu, prog: Array, reps: int) -> float:
	g.stamp("air_bench_begin")
	for _i in reps:
		g.run(prog)
	g.stamp("air_bench_end")
	g.submit()
	g.sync()
	var t0 := -1
	var t1 := -1
	for i in g.rd.get_captured_timestamps_count():
		var nm := g.rd.get_captured_timestamp_name(i)
		if nm == "air_bench_begin":
			t0 = g.rd.get_captured_timestamp_gpu_time(i)
		elif nm == "air_bench_end":
			t1 = g.rd.get_captured_timestamp_gpu_time(i)
	return (t1 - t0) / 1e6 / reps if t0 >= 0 and t1 >= t0 else -1.0


func test_bench_blocks() -> void:
	if OS.get_environment("AIR_GPU_BENCH") != "1":
		return
	var g := _gpu()
	if g == null:
		return
	print("  размер | блок | мс | ГБ/с (оценка по минимуму трафика) | запусков")
	for d in [Vector3i(96, 96, 48), Vector3i(192, 192, 48), Vector3i(64, 64, 112)]:
		var n: int = d.x * d.y * d.z
		var prob := synthetic(d)
		var mg := AirMultigrid.new()
		mg.build(
			g, g.buffer(prob.cx.size(), prob.cx), g.buffer(prob.cy.size(), prob.cy),
			g.buffer(prob.cz.size(), prob.cz), g.buffer(n, prob.act), d
		)
		var c: RID = mg.levels[0].c
		var f := g.buffer(n, prob.f)
		var x := g.buffer(n)
		var y := g.buffer(n)
		var r := g.buffer(n)
		var blocks := [
			["axpy", func() -> void: g.axpy(0.5, f, y, n), 12.0],
			["dot (2 прохода)", func() -> void: g.reduce(AirGpu.Red.DOT, f, n, 0, y), 8.0],
			["resid7", func() -> void: g.stencil(c, x, f, r, d), 40.0],
			["прогонка z зебра", func() -> void: g.zebra(c, x, f, d, [2]), 40.0],
			["прогонка x зебра", func() -> void: g.zebra(c, x, f, d, [0]), 40.0],
			["прогонка y зебра", func() -> void: g.zebra(c, x, f, d, [1]), 40.0],
			["прогонка x все линии", func() -> void: g.line(c, x, f, d, 0, -1, r), 40.0],
		]
		for bl in blocks:
			var prog := g.record(bl[1])
			_time_program(g, prog, 3)
			_bench_row(d, bl[0], _time_program(g, prog, 20), bl[2] * n, prog.size())
		var vc := mg.program(x, f)
		_time_program(g, vc, 3)
		_bench_row(d, "V-цикл (%d уровней)" % mg.levels.size(), _time_program(g, vc, 20), 0.0, vc.size())
		var mg2 := AirMultigrid.new()  # грубый уровень запусками, не одной группой — для сравнения
		mg2.levels = mg.levels
		mg2.gpu = g
		mg2.coarse_one_group_max = 0
		var vc2 := mg2.program(x, f)
		_time_program(g, vc2, 3)
		_bench_row(d, "V-цикл, грубый запусками", _time_program(g, vc2, 20), 0.0, vc2.size())
	g.release()


static func _bench_row(d: Vector3i, name: String, ms: float, bytes: float, disp: int) -> void:
	var gbs := "—"
	if bytes > 0.0 and ms > 0.0:
		gbs = "%.0f" % (bytes / (ms * 1e-3) / 1e9)
	print("  %dx%dx%d | %s | %.3f | %s | %d" % [d.x, d.y, d.z, name, ms, gbs, disp])
