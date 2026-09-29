extends TestCase
## Пикар на GPU (AM-03) против эталона AM-01 (tools/research/air3d/air.py, float64):
## tests/atmosphere/fixtures/air_model/ref/ — вход итерации и выход каждого блока + решение до
## критерия. Нужен настоящий RenderingDevice: tools/gpu_tests.sh --filter=test_air_picard.
## Замеры (Онгудай 400/200 м): AIR_PICARD_BENCH=1 tools/gpu_tests.sh --filter=test_air_picard
## (под flock /tmp/heat_ca_gpu.lock). В headless пропускается.

const FIX := "res://tests/atmosphere/fixtures/air_model/ref/"
const FIX_ONG := "res://tests/atmosphere/fixtures/air_model/picard/"
const CASES := ["flat_wind", "agnesi", "heated_slope", "saddle"]
const TOL_BLOCK := 1e-5


func needs_gpu() -> bool:
	return true


static func load_fix(path: String) -> Dictionary:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + ".json"))
	var all := FileAccess.get_file_as_bytes(path + ".bin").to_float32_array()
	var data := {}
	for k in meta.arrays:
		var o: Array = meta.arrays[k]
		data[k] = all.slice(int(o[0]), int(o[0]) + int(o[1]))
	meta.data = data
	return meta


## Случай эталона → AirCase (поток тепла восстанавливается из Q: Σ_k Q·Δz = H/ρc_p по столбцу).
static func case_from_fixture(m: Dictionary) -> AirCase:
	var c := AirCase.new()
	c.set_grid(
		float(m.dx), int(m.nx), int(m.ny), float(m.dz), float(m.z_bot), int(m.nz), float(m.x0),
		float(m.y0)
	)
	var dat: Dictionary = m.data
	c.hc = PackedFloat64Array(Array(dat.hc))
	c.gam = PackedFloat64Array(Array(dat.gam))
	var cp: Dictionary = m.case_params
	c.U10 = float(cp.U10)
	c.wdir = float(cp.wdir)
	c.z_i = float(cp.z_i) if cp.z_i != null else NAN
	c.taper = false
	c.label = String(m.case)
	var q: PackedFloat32Array = dat.Q
	var nx := int(m.nx)
	var ny := int(m.ny)
	var NX := nx + 2
	var NY := ny + 2
	var NZ := int(m.nz) + 2
	var h := PackedFloat64Array()
	h.resize(nx * ny)
	var any := false
	for j in ny:
		for i in nx:
			var s := 0.0
			for k in NZ:
				s += q[(k * NY + j + 1) * NX + i + 1]
			h[j * nx + i] = s * float(m.dz) * AirCase.RHO_CP
			any = any or s != 0.0
	if any:
		c.heat = h
	var prm: Dictionary = m.params
	for key in c.p:
		if prm.has(key):
			c.p[key] = prm[key]
	return c


## max|a − b| / max|b| (по маске, если есть).
static func rel_err(a: PackedFloat32Array, b: PackedFloat32Array, mask := PackedByteArray()) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	var m := 0.0
	for i in b.size():
		if not mask.is_empty() and mask[i] == 0:
			continue
		e = maxf(e, absf(a[i] - b[i]))
		m = maxf(m, absf(b[i]))
	return e / maxf(m, 1e-30)


static func max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array, mask := PackedByteArray()) -> float:
	var e := 0.0
	for i in b.size():
		if not mask.is_empty() and mask[i] == 0:
			continue
		e = maxf(e, absf(a[i] - b[i]))
	return e


static func sci(v: float) -> String:
	if v == 0.0 or is_nan(v) or is_inf(v):
		return str(v)
	var e := floori(log(absf(v)) / log(10.0))
	return "%.2fe%+03d" % [v / pow(10.0, e), e]


## a минус среднее по маске.
static func centered(a: PackedFloat32Array, act: PackedFloat32Array) -> PackedFloat32Array:
	var sum := 0.0
	var cnt := 0.0
	for i in a.size():
		sum += a[i] * act[i]
		cnt += act[i]
	var mm := sum / maxf(cnt, 1.0)
	var out := a.duplicate()
	for i in a.size():
		out[i] = (a[i] - mm) * act[i]
	return out


func _start(c: AirCase) -> AirPicardJob:
	var job := AirPicardJob.new()
	job.case = c
	job.mech = false
	if not job.start():
		failures.append("start: " + job.error)
		return null
	return job


static func _run(job: AirPicardJob) -> void:
	job.gpu.submit()
	job.gpu.sync()


# ---------------------------------------------------------------- блоки одной итерации


func test_blocks_vs_reference() -> void:
	var rows := []
	for name in CASES:
		var m := load_fix(FIX + name)
		var job := _start(case_from_fixture(m))
		if job == null:
			return
		_blocks(job, m, rows)
		job.release()
	print("  случай | блок | отн. ошибка")
	for r in rows:
		print("  %s | %s | %s" % [r[0], r[1], sci(r[2])])
	for r in rows:
		if r.size() > 3:
			continue
		check(r[2] <= TOL_BLOCK, "%s %s: %s > %s" % [r[0], r[1], sci(r[2]), sci(TOL_BLOCK)])


func _blocks(job: AirPicardJob, m: Dictionary, rows: Array) -> void:
	var dat: Dictionary = m.data
	var g := job.gpu
	var b: Dictionary = job.buf
	var name := String(m.case)
	var n := job._n
	_run(job)
	# ---- подготовка: типы — точно, остальное — отн. ошибка
	var tc := g.download(b.tcode)
	var bad := 0
	for q in n:
		var t := int(tc[q])
		if (
			t & 3 != int(dat.cell[q]) or (t >> 2) & 3 != int(dat.tu[q])
			or (t >> 4) & 3 != int(dat.tv[q]) or (t >> 6) & 3 != int(dat.tw[q])
		):
			bad += 1
	rows.append([name, "типы клеток и граней (несовпадений)", float(bad)])
	var ub_ref: PackedFloat32Array = dat.ubg.duplicate()
	var vb_ref: PackedFloat32Array = dat.vbg.duplicate()
	for q in (dat.b_u as PackedFloat32Array).size():
		ub_ref[int(dat.b_u[q])] = dat.fixed_u[q]
	for q in (dat.b_v as PackedFloat32Array).size():
		vb_ref[int(dat.b_v[q])] = dat.fixed_v[q]
	for pair in [["ubu", ub_ref, "U_b и граница u"], ["ubv", vb_ref, "U_b и граница v"],
			["spu", dat.sp_u, "губка s"], ["spw", dat.sp_w, "губка s_w"], ["spc", dat.spc, "губка s_θ"],
			["kbg", dat.nu_bg, "K_b"], ["Q", dat.Q, "нагрев Q"], ["Kx", dat.Kx, "K_x проекции"],
			["Ky", dat.Ky, "K_y проекции"], ["Kz", dat.Kz, "K_z проекции"]]:
		rows.append([name, "подготовка: " + pair[2], rel_err(g.download(b[pair[0]]), pair[1])])
	var c := job.case
	var nyx := c.NX * c.NY
	rows.append([name, "подготовка: λ", rel_err(c.col.slice(11 * nyx, 12 * nyx), dat.lam)])
	rows.append([name, "подготовка: c_pl", rel_err(c.lev.slice(2 * c.NZ, 3 * c.NZ), dat.cplz)])
	# ---- 1. граничные условия
	_put(job, {u = dat.in_u, v = dat.in_v, w = dat.in_w, th = dat.in_th, p = dat.in_p})
	job._bc(0)
	_run(job)
	rows.append([name, "граничные условия u", rel_err(g.download(b.u), dat.bc_u)])
	rows.append([name, "граничные условия v", rel_err(g.download(b.v), dat.bc_v)])
	# ---- 2. местное K
	_put(job, {u = dat.bc_u, v = dat.bc_v, w = dat.in_w, th = dat.in_th, nu = dat.nu_in, nuh = dat.nuh_in})
	job._kloc()
	_run(job)
	var e_nu := rel_err(g.download(b.nu), dat.kloc_nu)
	var e_nuh := rel_err(g.download(b.nuh), dat.kloc_nuh)
	if not _lam_symmetric(c):
		# эталон читает λ транспонированным (ошибка air.py, см. AirCase.ref_lam_transposed):
		# по спецификации — справка, проверка — с λ так, как её читает эталон
		rows.append([name, "местное K по спецификации (справка: λ эталона транспонирована)", maxf(e_nu, e_nuh), 0])
		c.ref_lam_transposed = true
		c.prepare()
		g.upload(b.col, c.col)
		_put(job, {u = dat.bc_u, v = dat.bc_v, w = dat.in_w, th = dat.in_th, nu = dat.nu_in, nuh = dat.nuh_in})
		job._kloc()
		_run(job)
		e_nu = rel_err(g.download(b.nu), dat.kloc_nu)
		e_nuh = rel_err(g.download(b.nuh), dat.kloc_nuh)
		c.ref_lam_transposed = false
		c.prepare()
		g.upload(b.col, c.col)
		name += " (λᵀ)"
	rows.append([name, "местное K (kloc) K", e_nu])
	rows.append([name, "местное K (kloc) K_h", e_nuh])
	name = String(m.case)
	# ---- 3. шаблоны импульса
	_put(job, {
		u = dat.bc_u, v = dat.bc_v, w = dat.in_w, th = dat.in_th, p = dat.in_p, nu = dat.kloc_nu,
		nuh = dat.kloc_nuh
	})
	for comp in 3:
		job._mom(comp)
	_run(job)
	for comp in 3:
		var nm: String = ["u", "v", "w"][comp]
		rows.append([name, "шаблон импульса C_" + nm, rel_err(g.download(b["C" + nm]), dat["Cm_" + nm])])
		rows.append([name, "шаблон импульса b_" + nm, rel_err(g.download(b["b" + nm]), dat["bm_" + nm])])
	# ---- 4. прогонки импульса
	var d := c.dims()
	_put(job, {Cu = dat.Cm_u, bu = dat.bm_u, u = dat.bc_u})
	g.zebra(b.Cu, b.u, b.bu, d)
	_run(job)
	rows.append([name, "прогонка u (z, x, y) ×1", rel_err(g.download(b.u), dat.sweep1_u)])
	_put(job, {
		Cu = dat.Cm_u, bu = dat.bm_u, Cv = dat.Cm_v, bv = dat.bm_v, Cw = dat.Cm_w, bw = dat.bm_w,
		u = dat.bc_u, v = dat.bc_v, w = dat.in_w
	})
	for _s in int(c.p.mom_sweeps):
		g.zebra(b.Cu, b.u, b.bu, d)
		g.zebra(b.Cv, b.v, b.bv, d)
		g.zebra(b.Cw, b.w, b.bw, d)
	_run(job)
	for nm in ["u", "v", "w"]:
		rows.append([name, "шаг импульса " + nm, rel_err(g.download(b[nm]), dat["mom_" + nm])])
	# ---- 5. проекция
	_put(job, {u = dat.mom_u, v = dat.mom_v, w = dat.mom_w})
	job._div()
	_run(job)
	var div_gpu := g.download(b.rhs)
	# эталон div_star — от неокруглённых f64-скоростей: на ровном потоке ∇·u* ~ 1e-7 и округление
	# входа до f32 (6e-8·|u|/Δx) уже ~1e-3 от него — справка; проверка — против f64 от тех же входов
	rows.append([name, "∇·u* против эталона (справка: пол округления входа)", rel_err(div_gpu, dat.div_star), 0])
	# та же разность в float64 от тех же (округлённых до f32) скоростей — пол входа
	var div_cpu := _div_cpu(c, dat.mom_u, dat.mom_v, dat.mom_w, g.download(b.tcode))
	rows.append([name, "∇·u* (f64 от тех же входов)", rel_err(div_gpu, div_cpu)])
	var nf := float(c.n_fluid)
	var act := g.download(b.act)
	_put(job, {rhs = dat.div_star})
	g.reduce(AirGpu.Red.SUM, b.rhs, job._ni, 0)
	g.axpy(-1.0 / nf, b.act, b.rhs, job._ni, 0)
	_run(job)
	rows.append([name, "правая часть (минус среднее)", rel_err(g.download(b.rhs), dat.proj_rhs)])
	_put(job, {rhs = dat.proj_rhs})
	g.fill(b.phi, job._ni)
	job.mg.vcycle(b.phi, b.rhs)
	_run(job)
	var phi := g.download(b.phi)
	rows.append([name, "V-цикл ×1 (φ минус среднее)", rel_err(centered(phi, act), centered(dat.vcycle_phi_raw, act))])
	rows.append([name, "V-цикл ×1 без центрирования (справка)", rel_err(phi, dat.vcycle_phi_raw), 0])
	_put(job, {phi = dat.vcycle_phi_raw})
	g.reduce(AirGpu.Red.DOT, b.phi, job._ni, 1, b.act)
	g.axpy(-1.0 / nf, b.act, b.phi, job._ni, 1)
	_run(job)
	rows.append([name, "φ минус среднее", rel_err(g.download(b.phi), _interior(c, dat.proj_phi))])
	_put(job, {
		u = dat.mom_u, v = dat.mom_v, w = dat.mom_w, p = dat.in_p, phi = _interior(c, dat.proj_phi)
	})
	job._proj(true)
	_run(job)
	for nm in ["u", "v", "w", "p"]:
		rows.append([name, "проекция " + nm, rel_err(g.download(b[nm]), dat["proj_" + nm])])
	_put(job, {u = dat.proj_u, v = dat.proj_v, w = dat.proj_w})
	job._div()
	_run(job)
	var da := g.download(b.rhs)
	var dmax := 0.0
	for q in da.size():
		dmax = maxf(dmax, absf(da[q]))
	var dref: PackedFloat32Array = dat.div_after
	var dmr := 0.0
	for q in dref.size():
		dmr = maxf(dmr, absf(dref[q]))
	rows.append([name, "∇·u после проекции: max|GPU| %s, max|эталон| %s (справка)" % [sci(dmax), sci(dmr)], 0.0, 0])
	# ---- 6. тепло
	_put(job, {
		u = dat.proj_u, v = dat.proj_v, w = dat.proj_w, th = dat.in_th, nu = dat.kloc_nu,
		nuh = dat.kloc_nuh
	})
	job._heat()
	_run(job)
	rows.append([name, "шаблон тепла C", rel_err(g.download(b.Cu), dat.Ch)])
	rows.append([name, "шаблон тепла b", rel_err(g.download(b.bu), dat.bh)])
	_put(job, {Cu = dat.Ch, bu = dat.bh, th = dat.in_th})
	for _s in int(c.p.heat_sweeps):
		g.zebra(b.Cu, b.th, b.bu, d)
	_run(job)
	rows.append([name, "шаг тепла θ′", rel_err(g.download(b.th), dat.heat_th)])


static func _lam_symmetric(c: AirCase) -> bool:
	var uniform := true
	for q in c.h_bl.size():
		uniform = uniform and c.h_bl[q] == c.h_bl[0]
	if uniform:
		return true
	if c.nx != c.ny:
		return false
	for j in c.ny:
		for i in c.nx:
			if absf(c.h_bl[j * c.nx + i] - c.h_bl[i * c.nx + j]) > 1e-9 * c.h_bl[j * c.nx + i]:
				return false
	return true


func _put(job: AirPicardJob, arrays: Dictionary) -> void:
	for k in arrays:
		job.gpu.upload(job.buf[k], arrays[k])


## Внутренняя часть массива с ореолом (nz, ny, nx).
static func _interior(c: AirCase, a: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(c.nx * c.ny * c.nz)
	for k in c.nz:
		for j in c.ny:
			for i in c.nx:
				out[(k * c.ny + j) * c.nx + i] = a[((k + 1) * c.NY + j + 1) * c.NX + i + 1]
	return out


static func _div_cpu(
	c: AirCase, u: PackedFloat32Array, v: PackedFloat32Array, w: PackedFloat32Array,
	tc: PackedFloat32Array
) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(c.nx * c.ny * c.nz)
	for k in c.nz:
		for j in c.ny:
			for i in c.nx:
				var g := ((k + 1) * c.NY + j + 1) * c.NX + i + 1
				if int(tc[g]) & 3 != 1:
					continue
				var du := (float(u[g + 1]) - u[g]) / c.dx
				var dv := (float(v[g + c.NX]) - v[g]) / c.dx
				var dw := (float(w[g + c.NX * c.NY]) - w[g]) / c.dz
				out[(k * c.ny + j) * c.nx + i] = du + dv + dw
	return out


# ---------------------------------------------------------------- решение до критерия


## Решить порциями (кадры), вернуть задачу (release — на вызывающем).
func _solve(c: AirCase, mech := false, warm := {}) -> AirPicardJob:
	var job := AirPicardJob.new()
	job.case = c
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


func test_solutions_vs_reference() -> void:
	print("  случай | итераций GPU / эталон | max|Δu|/|u₀| | max|Δθ′|, К | ∇·u СКО GPU / эталон | стена, мс | GPU, мс | макс. порция, мс")
	for name in CASES:
		var m := load_fix(FIX + name)
		var c := case_from_fixture(m)
		c.prepare()
		var tr := not _lam_symmetric(c)
		c.ref_lam_transposed = tr
		var job: AirPicardJob = await _solve(c)
		if job == null or not job.is_done():
			if job:
				job.release()
			continue
		var dat: Dictionary = m.data
		var sol: Dictionary = m.solution
		var u0 := maxf(float(m.case_params.U_aloft), float(sol.max_speed))
		var dv := 0.0
		for nm in ["u", "v", "w"]:
			dv = maxf(dv, max_abs_diff(job.download(nm), dat["sol_" + nm]))
		var dth := max_abs_diff(job.download("th"), dat.sol_th)
		var r: Dictionary = job.results[-1]
		var fr: Dictionary = sol.final_residuals
		print("  %s%s | %d / %d | %s | %s | %s / %s | %.0f | %.1f | %.2f" % [
			name, " (λᵀ как эталон)" if tr else "", r.iters, int(sol.iters), sci(dv / u0), sci(dth),
			sci(r.div_rms), sci(_div_rms_ref(c, dat)), job.wall_ms, job.gpu_ms_total, job.max_chunk_gpu_ms
		])
		check(r.status == "ok", "%s: статус %s" % [name, r.status])
		check(dv <= 1e-3 * u0, "%s: max|Δu| %s > 1e-3·|u₀|" % [name, sci(dv)])
		check(dth <= 0.05, "%s: max|Δθ′| %s > 0,05 К" % [name, sci(dth)])
		check(absi(int(r.iters) - int(sol.iters)) <= maxi(20, int(sol.iters) / 10), "%s: итераций %d против %d" % [name, r.iters, sol.iters])
		job.release()


## СКО ∇·u решения эталона (sol_*, после finalize) — в float64 по массивам фикстуры.
static func _div_rms_ref(c: AirCase, dat: Dictionary) -> float:
	var d := _div_cpu_f64(c, dat.sol_u, dat.sol_v, dat.sol_w, dat.cell)
	return d


static func _div_cpu_f64(
	c: AirCase, u: PackedFloat32Array, v: PackedFloat32Array, w: PackedFloat32Array,
	cell: PackedFloat32Array
) -> float:
	var s := 0.0
	var n := 0
	for k in c.nz:
		for j in c.ny:
			for i in c.nx:
				var g := ((k + 1) * c.NY + j + 1) * c.NX + i + 1
				if int(cell[g]) != 1:
					continue
				var dd := (float(u[g + 1]) - u[g]) / c.dx + (float(v[g + c.NX]) - v[g]) / c.dx + (float(w[g + c.NX * c.NY]) - w[g]) / c.dz
				s += dd * dd
				n += 1
	return sqrt(s / maxf(n, 1))


func test_two_runs_bitwise_equal() -> void:
	var out := []
	for _r in 2:
		var m := load_fix(FIX + "saddle")
		var job: AirPicardJob = await _solve(case_from_fixture(m))
		if job == null:
			return
		var b := PackedByteArray()
		for nm in ["u", "v", "w", "th", "p"]:
			b.append_array(job.download(nm).to_byte_array())
		out.append([b, job.iterations()])
		job.release()
	check(out[0][0] == out[1][0], "два прогона побитно одинаковы (%d байт)" % out[0][0].size())
	check(out[0][1] == out[1][1], "итераций одинаково")
