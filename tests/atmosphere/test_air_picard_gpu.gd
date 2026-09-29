class_name TestAirPicard
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
			c.p[key] = prm[key] if prm[key] != null else NAN
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
	rows.append([name, "местное K (kloc) K", e_nu])
	rows.append([name, "местное K (kloc) K_h", e_nuh])
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
		var cb := unpack(g.download(b["C" + nm]))
		rows.append([name, "шаблон импульса C_" + nm, rel_err(cb[0], dat["Cm_" + nm])])
		rows.append([name, "шаблон импульса b_" + nm, rel_err(cb[1], dat["bm_" + nm])])
	# ---- 4. прогонки импульса
	var d := c.dims()
	_put(job, {Cu = pack(dat.Cm_u, dat.bm_u), u = dat.bc_u})
	g.zebra(b.Cu, b.u, RID(), d, [2, 0, 1], true)
	_run(job)
	rows.append([name, "прогонка u (z, x, y) ×1", rel_err(g.download(b.u), dat.sweep1_u)])
	_put(job, {
		Cu = pack(dat.Cm_u, dat.bm_u), Cv = pack(dat.Cm_v, dat.bm_v), Cw = pack(dat.Cm_w, dat.bm_w),
		u = dat.bc_u, v = dat.bc_v, w = dat.in_w
	})
	for _s in int(c.p.mom_sweeps):
		g.zebra(b.Cu, b.u, RID(), d, [2, 0, 1], true)
		g.zebra(b.Cv, b.v, RID(), d, [2, 0, 1], true)
		g.zebra(b.Cw, b.w, RID(), d, [2, 0, 1], true)
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
	var ch := unpack(g.download(b.Cu))
	rows.append([name, "шаблон тепла C", rel_err(ch[0], dat.Ch)])
	rows.append([name, "шаблон тепла b", rel_err(ch[1], dat.bh)])
	_put(job, {Cu = pack(dat.Ch, dat.bh), th = dat.in_th})
	for _s in int(c.p.heat_sweeps):
		g.zebra(b.Cu, b.th, RID(), d, [2, 0, 1], true)
	_run(job)
	rows.append([name, "шаг тепла θ′", rel_err(g.download(b.th), dat.heat_th)])


## Шаблон 7 плоскостей + b → строкой на точку (C0..C6, b).
static func pack(c: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var n := b.size()
	var out := PackedFloat32Array()
	out.resize(8 * n)
	for i in n:
		for o in 7:
			out[8 * i + o] = c[o * n + i]
		out[8 * i + 7] = b[i]
	return out


## Обратно: [C (7 плоскостей), b].
static func unpack(p: PackedFloat32Array) -> Array:
	var n := p.size() / 8
	var c := PackedFloat32Array()
	c.resize(7 * n)
	var b := PackedFloat32Array()
	b.resize(n)
	for i in n:
		for o in 7:
			c[o * n + i] = p[8 * i + o]
		b[i] = p[8 * i + 7]
	return [c, b]


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


func test_solutions_vs_reference() -> void:
	print("  случай | итераций GPU / эталон | max|Δu|/|u₀| | max|Δθ′|, К | ∇·u СКО GPU / эталон | стена, мс | GPU, мс | макс. порция, мс")
	for name in CASES:
		var m := load_fix(FIX + name)
		var c := case_from_fixture(m)
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
		print("  %s | %d / %d | %s | %s | %s / %s | %.0f | %.1f | %.2f" % [
			name, r.iters, int(sol.iters), sci(dv / u0), sci(dth),
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


# ---------------------------------------------------------------- Онгудай 400 м (реальный рельеф)


## Случай из эталона Онгудая (вход — ровно тот, что у air.py; AirPlace даёт его же, test_air_place).
static func case_ongudai(m: Dictionary, U10: float) -> AirCase:
	var c := AirCase.new()
	c.set_grid(float(m.dx), int(m.nx), int(m.ny), float(m.dz), float(m.z_bot), int(m.nz), float(m.x0), float(m.y0))
	var dat: Dictionary = m.data
	c.hc = PackedFloat64Array(Array(dat.hc))
	c.heat = PackedFloat64Array(Array(dat.H))
	c.gam = PackedFloat64Array(Array(dat.gam))
	c.z_i = float(m.z_i)
	c.U10 = U10
	c.wdir = float(m.wdir)
	c.label = "Онгудай %d м, %d м/с" % [int(m.dx), int(U10)]
	return c


static func _ref_iters(m: Dictionary, U10: float, heat: bool, dtype: String) -> int:
	for r: Dictionary in m.runs:
		if float(r.U10) == U10 and bool(r.heat) == heat and String(r.dtype) == dtype:
			return int(r.iters)
	return -1


func test_ongudai_d400_vs_reference() -> void:
	var m := load_fix(FIX_ONG + "ongudai_d400_h12")
	var job: AirPicardJob = await _solve(case_ongudai(m, 3.0), true)
	if job == null or not job.is_done():
		return
	var c := job.case
	var dat: Dictionary = m.data
	var us := float(m.u_scale)
	# итерации: без нагрева, с нагревом — против эталона float64 и float32
	for q in 2:
		var r: Dictionary = job.results[q]
		var heat := q == 1
		print("  %s: %s, итераций %d (эталон f64 %d, f32 %d), ∇·u СКО %s (эталон %s)" % [
			r.label, r.status, r.iters, _ref_iters(m, 3.0, heat, "float64"),
			_ref_iters(m, 3.0, heat, "float32"), sci(r.div_rms), sci(float(m.div_rms[1 - q]))])
		check(r.status == "ok", "%s сошлось" % r.label)
		check(absi(int(r.iters) - _ref_iters(m, 3.0, heat, "float64")) <= 20, "%s: итераций как в эталоне" % r.label)
	# поле в центрах у старта Каянча (16 × 16 столбцов)
	var cr: Dictionary = m.crop
	var cen := _centers(job, int(cr.i0), int(cr.j0), int(cr.n))
	var row := []
	for nm in ["u", "v", "w_mech", "w_conv", "theta"]:
		var e := max_abs_diff(cen[nm], dat["crop_" + nm])
		row.append("%s %s" % [nm, sci(e)])
		if nm == "theta":
			check(e <= 0.05, "θ′ у старта: %s К" % sci(e))
		else:
			check(e <= 1e-3 * us, "%s у старта: %s > 1e-3·%.2f" % [nm, sci(e), us])
	print("  поле у старта (16×16×%d), max|Δ|: %s; |u₀| = %.2f м/с" % [c.nz, ", ".join(row), us])
	# выборка как в игре над стартом (WindField)
	var t_f := Time.get_ticks_msec()
	job.field_async()
	var f: WindField = await job.field_ready
	print("  WindField (field_async): %d мс до сигнала" % (Time.get_ticks_msec() - t_f))
	check(f != null, "WindField построен")
	if f != null:
		check(f.meta.has("z_i") and (f.meta.heat as PackedFloat32Array).size() == c.nx * c.ny
			and (f.meta.gam as PackedFloat32Array).size() == c.nz and f.meta.has("u10"),
			"meta поля — вход термиков (heat, z_i, gam, u10)")
	if f != null:
		for p: Dictionary in m.probes:
			var pos := Vector3(float(p.game[0]), float(p.game[1]), float(p.game[2]))
			var s := f.sample(pos)
			var got := {u = s.x, v = -s.z, w_mech = s.y, w_conv = f.sample_w_conv(pos), theta = f.sample_theta(pos)}
			var fr: Dictionary = p.field
			var parts := []
			for k in got:
				parts.append("%s %.4f/%.4f" % [k, got[k], float(fr[k])])
				var tol := 0.05 if k == "theta" else 1e-3 * us
				check(absf(got[k] - float(fr[k])) <= tol, "Каянча %d м: %s %.5f против %.5f" % [int(p.agl), k, got[k], float(fr[k])])
			print("  Каянча, %d м над землёй (GPU/эталон): %s" % [int(p.agl), ", ".join(parts)])
	var hb := heat_budget(job)
	var rb: Dictionary = m.heat_budget
	print("  баланс тепла GPU: нагрев %s, фон %s, выхолаживание %s, губка %s, вынос %s, невязка отн. %s (эталон %s)" % [
		sci(hb.q_in), sci(hb.bg), sci(hb.cool), sci(hb.sponge), sci(hb.outflow), sci(hb.rel), sci(float(rb.rel))])
	check(absf(hb.rel) <= 2.0 * absf(float(rb.rel)) + 1e-4, "баланс тепла как в эталоне")
	print("  стена %.0f мс, GPU %.1f мс, порций %d, макс. порция %.2f мс" % [job.wall_ms, job.gpu_ms_total, job.chunks, job.max_chunk_gpu_ms])
	job.release()


## Центры клеток (как Air.centers / WindField.from_mac) в столбцах [i0, i0+n) × [j0, j0+n), все уровни.
static func _centers(job: AirPicardJob, i0: int, j0: int, n: int) -> Dictionary:
	var c := job.case
	var u := job.download("u")
	var v := job.download("v")
	var w := job.download("w")
	var wm := job.download("wmech")
	var th := job.download("th")
	var tc := job.download("tcode")
	var out := {}
	for nm in ["u", "v", "w_mech", "w_conv", "theta"]:
		var a := PackedFloat32Array()
		a.resize(c.nz * n * n)
		out[nm] = a
	var sy := c.NX
	var sz := c.NX * c.NY
	for k in c.nz:
		for j in n:
			for i in n:
				var h := ((k + 1) * c.NY + j0 + j + 1) * c.NX + i0 + i + 1
				var q := (k * n + j) * n + i
				if int(tc[h]) & 3 != 1:
					continue
				out.u[q] = 0.5 * (u[h] + u[h + 1])
				out.v[q] = 0.5 * (v[h] + v[h + sy])
				var wmc := 0.5 * (wm[h] + wm[h + sz])
				out.w_mech[q] = wmc
				out.w_conv[q] = 0.5 * (w[h] + w[h + sz]) - wmc
				out.theta[q] = th[h]
	return out


## Баланс θ′ (К·м³/с) как Air.heat_budget эталона: нагрев + фон = выхолаживание + губка + вынос.
static func heat_budget(job: AirPicardJob) -> Dictionary:
	var c := job.case
	var th := job.download("th")
	var w := job.download("w")
	var u := job.download("u")
	var v := job.download("v")
	var q := job.download("Q")
	var spc := job.download("spc")
	var nu := job.download("nu")
	var tc := job.download("tcode")
	var NX := c.NX
	var NY := c.NY
	var NZ := c.NZ
	var sz := NX * NY
	var V := c.dx * c.dx * c.dz
	var q_in := 0.0
	var cool := 0.0
	var spg := 0.0
	var bg := 0.0
	var out := 0.0
	var dif := 0.0
	var a_side := c.dx * c.dz
	var a_top := c.dx * c.dx
	for idx in th.size():
		var t := int(tc[idx])
		var cell := t & 3
		var k := idx / sz
		if cell == 1:
			q_in += q[idx] * V
			cool += th[idx] * V / float(c.p.tau_cool)
			spg += th[idx] * spc[idx] * V
			if k < NZ - 1:
				bg -= c.gam[k] * 0.5 * (w[idx] + w[idx + sz]) * V
			# диффузия через границу области (сосед — ореол), K — как в эталоне
			var i := idx % NX
			var j := (idx / NX) % NY
			for sh in [[1, i < NX - 1, c.dx, a_side], [-1, i > 0, c.dx, a_side], [NX, j < NY - 1, c.dx, a_side],
					[-NX, j > 0, c.dx, a_side], [sz, k < NZ - 1, c.dz, a_top], [-sz, k > 0, c.dz, a_top]]:
				if not sh[1]:
					continue
				var nb: int = idx + int(sh[0])
				if int(tc[nb]) & 3 == 2:
					dif += 0.5 * (nu[idx] + nu[nb]) * (th[idx] - th[nb]) / float(sh[2]) * float(sh[3])
		# грани типа 2: перенос θ′ через границу (против потока)
		for ax in 3:
			var ty := (t >> (2 + 2 * ax)) & 3
			if ty != 2:
				continue
			var st: int = [1, NX, sz][ax]
			var fld: PackedFloat32Array = [u, v, w][ax]
			var s := -1.0 if cell == 1 else 1.0
			var un := fld[idx] * s
			var inner := idx if s < 0 else idx - st
			var outer := idx - st if s < 0 else idx
			var thb := th[inner] if un > 0 else th[outer]
			out += un * thb * (a_top if ax == 2 else a_side)
	out += dif
	var res := q_in + bg - cool - spg - out
	var scale := absf(q_in) + absf(bg) + absf(cool) + absf(spg) + absf(out)
	return {q_in = q_in, bg = bg, cool = cool, sponge = spg, outflow = out, residual = res, rel = res / scale if scale > 0 else 0.0}


# ---------------------------------------------------------------- замеры (AIR_PICARD_BENCH=1)


static func _time_prog(g: AirGpu, prog: Array, reps: int) -> float:
	return TestAirGpuBlocks._time_program(g, prog, reps)


func test_bench_ongudai() -> void:
	if OS.get_environment("AIR_PICARD_BENCH") != "1":
		return
	var only := OS.get_environment("AIR_PICARD_BENCH_DX")
	for dx in [400, 200]:
		if only != "" and only != str(dx):
			continue
		var m := load_fix(FIX_ONG + "ongudai_d%d_h12" % dx)
		# ---- разбивка итерации по ядрам (3 м/с, состояние после 20 итераций)
		var job := AirPicardJob.new()
		job.case = case_ongudai(m, 3.0)
		job.mech = false
		if not job.start():
			failures.append(job.error)
			return
		var g := job.gpu
		var p := job.case.p
		var d := job.case.dims()
		g.run(job._program("init"))
		var one := job._prog_iteration()
		for _i in 20:
			g.run(one)
		g.submit()
		g.sync()
		var parts := [
			["граничные условия", func() -> void: job._bc(0)],
			["местное K (kloc)", func() -> void: job._kloc()],
			["шаблоны импульса ×3", func() -> void:
				job._mom(0)
				job._mom(1)
				job._mom(2)],
			["прогонки импульса z (2×3 зебры)", func() -> void:
				for _s in int(p.mom_sweeps):
					for cx in [[job.buf.Cu, job.buf.u], [job.buf.Cv, job.buf.v], [job.buf.Cw, job.buf.w]]:
						g.zebra(cx[0], cx[1], RID(), d, [2], true)],
			["прогонки импульса x", func() -> void:
				for _s in int(p.mom_sweeps):
					for cx in [[job.buf.Cu, job.buf.u], [job.buf.Cv, job.buf.v], [job.buf.Cw, job.buf.w]]:
						g.zebra(cx[0], cx[1], RID(), d, [0], true)],
			["прогонки импульса y", func() -> void:
				for _s in int(p.mom_sweeps):
					for cx in [[job.buf.Cu, job.buf.u], [job.buf.Cv, job.buf.v], [job.buf.Cw, job.buf.w]]:
						g.zebra(cx[0], cx[1], RID(), d, [1], true)],
			["шаблон тепла", func() -> void: job._heat()],
			["прогонки тепла z, x, y (4×)", func() -> void:
				for _s in int(p.heat_sweeps):
					g.zebra(job.buf.Cu, job.buf.th, RID(), d, [2, 0, 1], true)],
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
		rows.append(["проекция: ∇·u, центрирование, поправка", ms_pr - ms_vc, proj.size() - vc.size()])
		total += ms_pr
		var whole := _time_prog(g, one, 5)
		var chk := job._prog_check()
		var ms_chk := _time_prog(g, chk, 5)
		print("  %d м (%dx%dx%d): ядро | мс на итерацию | доля | запусков" % [dx, d.x, d.y, d.z])
		for r in rows:
			print("  %s | %.3f | %.0f %% | %d" % [r[0], r[1], 100.0 * r[1] / total, r[2]])
		print("  сумма частей %.2f мс; итерация целиком %.2f мс (%d запусков); проверка %.2f мс (раз в 10 итераций)" % [
			total, whole, one.size(), ms_chk])
		job.release()
		# ---- решения целиком (порциями, окно тестов)
		print("  %d м: ветер | нагрев | итераций (эталон f32) | стена, с | GPU, с | мс/итерацию GPU | порций | макс. порция GPU, мс | CPU в poll Σ/макс, мс" % dx)
		var cases := [[0.0, false], [3.0, false], [6.0, false], [3.0, true], [3.0, false, true], [6.0, false, true], [3.0, true, true]]
		if OS.get_environment("AIR_PICARD_BENCH_QUICK") == "1":
			cases = [[3.0, false], [3.0, false, true]]
		for cse in cases:
			var c := case_ongudai(m, cse[0])
			var loading: bool = cse.size() > 2
			var jb: AirPicardJob = await _solve(c, cse[1], {}, loading)
			if jb == null or not jb.is_done():
				continue
			var it := 0
			var ref := []
			for r: Dictionary in jb.results:
				it += int(r.iters)
				ref.append(str(_ref_iters(m, cse[0], r.heated, "float32")))
			print("  %d м/с | %s | %d (%s) | %.2f | %.2f | %.2f | %d | %.1f | %.0f / %.1f" % [
				int(cse[0]), ("пара (без + с)" if cse[1] else "с нагревом") + (", загрузка" if loading else ""), it, " + ".join(ref),
				jb.wall_ms / 1000.0, jb.gpu_ms_total / 1000.0, jb.gpu_ms_total / maxf(it, 1),
				jb.chunks, jb.max_chunk_gpu_ms, jb.poll_cpu_ms, jb.max_poll_cpu_ms])
			var imax := 0
			for q in jb.chunk_log.size():
				if jb.chunk_log[q].y > jb.chunk_log[imax].y:
					imax = q
			print("    наибольшая порция — №%d из %d: %d запусков, %.1f мс; главный поток: запись %.0f мс, ожидание sync %.0f мс" % [imax, jb.chunks, int(jb.chunk_log[imax].x), jb.chunk_log[imax].y, jb.record_cpu_ms, jb.sync_wait_ms])
			check(jb.max_chunk_gpu_ms <= 50.0, "%d м: порция ≤ 50 мс (%.1f)" % [dx, jb.max_chunk_gpu_ms])
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
	var same: AirPicardJob = await _solve(AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0), false, st)
	var it_same := same.iterations() if same != null else -1
	check(it_same == 10, "то же поле с тёплого старта: %d итераций (≤ 10)" % it_same)
	if same != null:
		same.release()
	var c13 := func() -> AirCase: return AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.5, 3.0, 150.0)
	var cold: AirPicardJob = await _solve(c13.call())
	var warm: AirPicardJob = await _solve(c13.call(), false, st)
	if cold == null or warm == null:
		return
	var dv := 0.0
	for nm in ["u", "v", "w"]:
		dv = maxf(dv, max_abs_diff(cold.download(nm), warm.download(nm)))
	var dth := max_abs_diff(cold.download("th"), warm.download("th"))
	print("  Онгудай 400 м, 3 м/с: 12:00 холодный %d итераций; то же тёплым %d; 12:30 холодный %d, тёплый от 12:00 %d (−%.0f %%); max|Δu| холодный/тёплый %s м/с, max|Δθ′| %s К" % [
		it12, it_same, cold.iterations(), warm.iterations(),
		100.0 * (1.0 - float(warm.iterations()) / cold.iterations()), sci(dv), sci(dth)])
	check(warm.iterations() < cold.iterations(), "тёплый старт экономит итерации")
	cold.release()
	warm.release()
