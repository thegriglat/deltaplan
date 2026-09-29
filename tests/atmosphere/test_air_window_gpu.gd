class_name TestAirWindow
extends TestCase
## Окна клипмапа на GPU (AM-04) против эталона AM-01 (air.py, окно от родителя, float64):
## tests/atmosphere/fixtures/air_model/window/ (генератор tools/research/air3d/window_gpu_refs.py).
## Цепочка как в игре: область 400 м на GPU (вход — fixtures/air_model/picard/) → окно 100 м →
## окно 50 м; решения парой (без нагрева → w_mech, с нагревом). Нужен настоящий RenderingDevice:
## tools/gpu_tests.sh --filter=test_air_window (под flock /tmp/heat_ca_gpu.lock при замерах).

const FIX_W := "res://tests/atmosphere/fixtures/air_model/window/"
const FIX_ONG := TestAirPicard.FIX_ONG

var _rt_gaps: Array[float] = []
var _rt_t := 0
var _rt_cond := {}


func needs_gpu() -> bool:
	return true


## Окно из фикстуры (вход ровно тот, что у air.py).
static func window_from_fixture(m: Dictionary, u10: float) -> AirWindowCase:
	var c := AirWindowCase.new()
	c.set_grid(
		float(m.dx),
		int(m.nx),
		int(m.ny),
		float(m.dz),
		float(m.z_bot),
		int(m.nz),
		float(m.x0),
		float(m.y0)
	)
	var dat: Dictionary = m.data
	c.hc = PackedFloat64Array(Array(dat.hc))
	c.heat = PackedFloat64Array(Array(dat.H))
	c.gam = PackedFloat64Array(Array(dat.gam))
	c.z_i = float(m.z_i)
	c.u10 = u10
	c.wdir = float(m.wdir)
	c.label = "окно %d м, %d м/с" % [int(m.dx), int(u10)]
	# параметры, с которыми посчитан эталон (λ/h = 0,1 до калибровки AM-09)
	var prm: Dictionary = m.get("params", {})
	for key in prm:
		c.p[key] = prm[key]
	return c


## Решить задачу порциями: loading — poll_slice(40) (экран загрузки), иначе poll() раз в кадр.
func run_job(job: AirPicardJob, loading := false) -> bool:
	if not job.start():
		failures.append("start: " + job.error)
		return false
	var fr := 0
	while not job.is_done() and job.error == "" and fr < 100000:
		await Engine.get_main_loop().process_frame
		if loading:
			job.poll_slice(40.0)
		else:
			job.poll()
		fr += 1
	check(job.is_done(), "%s: решено (%s)" % [job.case.label, job.error])
	return job.is_done()


func solve_domain(u10: float, loading := false) -> AirPicardJob:
	var m := TestAirPicard.load_fix(FIX_ONG + "ongudai_d400_h12")
	var job := AirPicardJob.new()
	job.case = TestAirPicard.case_ongudai(m, u10)
	job.mech = true
	if loading:
		job.chunk_ms = 30.0
	if not await run_job(job, loading):
		job.release()
		return null
	return job


func solve_window(
	c: AirWindowCase, parent: Dictionary, prev := {}, loading := false
) -> AirWindowJob:
	var job := AirWindowJob.new()
	job.case = c
	job.mech = true
	job.parent = parent
	job.prev = prev
	if loading:
		job.chunk_ms = 30.0
	if not await run_job(job, loading):
		job.release()
		return null
	return job


static func ref_run(m: Dictionary, u10: float, heat: bool, dtype: String) -> Dictionary:
	for r: Dictionary in m.runs:
		if float(r.U10) == u10 and bool(r.heat) == heat and String(r.dtype) == dtype:
			return r
	return {}


## Сверка окна с эталоном: итерации, поле у старта и у западного края, грани западной границы,
## выборка как в игре, баланс тепла, ∇·u. Печатает строку таблицы.
func compare(job: AirWindowJob, m: Dictionary, u10: float) -> void:
	var tag := "U%d_" % int(u10)
	var wd: Dictionary = m.winds[tag]
	var dat: Dictionary = m.data
	var us := float(wd.u_scale)
	var row := []
	for q in 2:
		var r: Dictionary = job.results[q]
		var heat := q == 1
		var r64 := ref_run(m, u10, heat, "float64")
		var r32 := ref_run(m, u10, heat, "float32")
		row.append(
			(
				"%s: %d итер. (эталон f64 %d, f32 %d)"
				% ["с нагревом" if heat else "без нагрева", r.iters, r64.iters, r32.iters]
			)
		)
		check(r.status == "ok", "%s: сошлось (%s)" % [r.label, r.status])
		check(absi(int(r.iters) - int(r64.iters)) <= 20, "%s: итераций как в эталоне" % r.label)
	var worst := 0.0
	var worst_th := 0.0
	for crop in ["start", "edge"]:
		var cr: Dictionary = wd["crop_" + crop]
		var cen := TestAirPicard._centers(job, int(cr.i0), int(cr.j0), int(cr.n))
		for nm in ["u", "v", "w_mech", "w_conv", "theta"]:
			var e := TestAirPicard.max_abs_diff(cen[nm], dat[tag + crop + "_" + nm])
			if nm == "theta":
				worst_th = maxf(worst_th, e)
			else:
				worst = maxf(worst, e)
	check(worst <= 1e-3 * us, "поле окна: max|Δ| %s > 1e-3·%.2f" % [TestAirPicard.sci(worst), us])
	check(worst_th <= 0.05, "θ′ окна: max|Δ| %s К" % TestAirPicard.sci(worst_th))
	# грани u западной границы (i = 1) — после поправки потока
	var u := job.download("u")
	var c := job.case
	var wu := PackedFloat32Array()
	wu.resize(c.nz_h * c.ny_h)
	for k in c.nz_h:
		for j in c.ny_h:
			wu[k * c.ny_h + j] = u[(k * c.ny_h + j) * c.nx_h + 1]
	var e_b := NAN
	if dat.has(tag + "west_u"):
		e_b = TestAirPicard.max_abs_diff(wu, dat[tag + "west_u"])
		check(e_b <= 1e-3 * us, "граница окна (грани u на западе): %s" % TestAirPicard.sci(e_b))
	var corr := job.nest_corr()
	var hb := heat_budget(job)
	var rb: Dictionary = wd.heat_budget
	check(absf(hb.rel) <= 2.0 * absf(float(rb.rel)) + 1e-4, "баланс тепла окна как в эталоне")
	var r1: Dictionary = job.results[1]
	var dref: Array = wd.div_rms
	print(
		(
			(
				"  окно %d м, %d м/с | %s | поле max|Δ|/|u₀| %s, θ′ %s К | граница %s | "
				+ "поправка потока %s (эталон %s) м/с | ∇·u СКО %s (эталон %s) | баланс тепла %s "
				+ "(эталон %s) | стена %.0f мс, GPU %.0f мс, макс. порция %.1f мс"
			)
			% [
				int(c.dx),
				int(u10),
				"; ".join(row),
				TestAirPicard.sci(worst / us),
				TestAirPicard.sci(worst_th),
				TestAirPicard.sci(e_b / us),
				TestAirPicard.sci(corr),
				TestAirPicard.sci(
					float((wd.nest_corr as Array)[0]) if wd.has("nest_corr") else NAN
				),
				TestAirPicard.sci(r1.div_rms),
				TestAirPicard.sci(float(dref[0])),
				TestAirPicard.sci(hb.rel),
				TestAirPicard.sci(float(rb.rel)),
				job.wall_ms,
				job.gpu_ms_total,
				job.max_chunk_gpu_ms
			]
		)
	)
	# выборка как в игре (WindField окна) над стартом
	job.field_async()
	var f: WindField = await job.field_ready
	check(f != null, "WindField окна построен")
	if f == null:
		return
	var parts := []
	for p: Dictionary in wd.probes:
		var pos := Vector3(float(p.game[0]), float(p.game[1]), float(p.game[2]))
		var s := f.sample(pos)
		var got := {
			u = s.x,
			v = -s.z,
			w_mech = s.y,
			w_conv = f.sample_w_conv(pos),
			theta = f.sample_theta(pos)
		}
		var fr: Dictionary = p.field
		var e := 0.0
		for k in got:
			var tol := 0.05 if k == "theta" else 1e-3 * us
			check(
				absf(got[k] - float(fr[k])) <= tol,
				(
					"окно, %d м над стартом: %s %.5f против %.5f"
					% [int(p.agl), k, got[k], float(fr[k])]
				)
			)
			if k != "theta":
				e = maxf(e, absf(got[k] - float(fr[k])))
		parts.append("%d м %s" % [int(p.agl), TestAirPicard.sci(e)])
	print("    выборка WindField над стартом, max|Δ| u,v,w: %s" % ", ".join(parts))


## Баланс θ′ окна (Air.heat_budget): как TestAirPicard.heat_budget, губка тянет к θ_b родителя.
static func heat_budget(job: AirPicardJob) -> Dictionary:
	var hb := TestAirPicard.heat_budget(job)
	var c := job.case
	var thb := job.download("thb")
	var spc := job.download("spc")
	var tc := job.download("tcode")
	var vol := c.dx * c.dx * c.dz
	var s := 0.0
	for q in thb.size():
		if int(tc[q]) & 3 == 1:
			s += thb[q] * spc[q] * vol
	hb.sponge -= s
	var res: float = hb.q_in + hb.bg - hb.cool - hb.sponge - hb.outflow
	var scale: float = (
		absf(hb.q_in) + absf(hb.bg) + absf(hb.cool) + absf(hb.sponge) + absf(hb.outflow)
	)
	hb.residual = res
	hb.rel = res / scale if scale > 0.0 else 0.0
	return hb


func test_window_vs_reference() -> void:
	var m100 := TestAirPicard.load_fix(FIX_W + "ongudai_w100_h12")
	var m50 := TestAirPicard.load_fix(FIX_W + "ongudai_w50_h12")
	for u10 in [3.0, 6.0]:
		var dom: AirPicardJob = await solve_domain(u10)
		if dom == null:
			return
		var pd := dom.parent_data()
		dom.release()
		var w1: AirWindowJob = await solve_window(window_from_fixture(m100, u10), pd)
		if w1 == null:
			return
		await compare(w1, m100, u10)
		if u10 == 3.0:
			var pd1 := w1.parent_data()
			var w5: AirWindowJob = await solve_window(window_from_fixture(m50, u10), pd1)
			if w5 != null:
				await compare(w5, m50, u10)
				w5.release()
		w1.release()


func test_window_two_runs_bitwise_equal() -> void:
	var dom: AirPicardJob = await solve_domain(3.0)
	if dom == null:
		return
	var pd := dom.parent_data()
	dom.release()
	var m100 := TestAirPicard.load_fix(FIX_W + "ongudai_w100_h12")
	var out := []
	for _r in 2:
		var job: AirWindowJob = await solve_window(window_from_fixture(m100, 3.0), pd)
		if job == null:
			return
		var b := PackedByteArray()
		for nm in ["u", "v", "w", "th", "p", "wmech"]:
			b.append_array(job.download(nm).to_byte_array())
		out.append([b, job.results[0].iters, job.results[1].iters])
		job.release()
	check(out[0][0] == out[1][0], "два прогона окна побитно одинаковы (%d байт)" % out[0][0].size())
	check(out[0][1] == out[1][1] and out[0][2] == out[1][2], "итераций одинаково")


# ---------------------------------------------------------------- клипмап: загрузка и сдвиг


## Ждать, пока клипмап посчитает очередь; кадры — poll() (игра) или poll_slice(40) (загрузка).
## Возвращает [стена мс, наибольший кадр мс, наибольшее время poll мс, кадров].
func run_clipmap(cm: AirClipmap, loading: bool, pilot := Vector3(NAN, 0, 0)) -> Array:
	var t0 := Time.get_ticks_usec()
	var t_prev := t0
	var worst := 0.0
	var worst_poll := 0.0
	var fr := 0
	while (cm.is_busy() or fr == 0) and Time.get_ticks_usec() - t0 < 120000000:
		await Engine.get_main_loop().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - t_prev) / 1000.0)
		t_prev = now
		var tp := Time.get_ticks_usec()
		if not is_nan(pilot.x):
			cm.update(pilot)
		if loading:
			cm.poll_slice(40.0)
		else:
			cm.poll()
		worst_poll = maxf(worst_poll, (Time.get_ticks_usec() - tp) / 1000.0)
		fr += 1
	return [(Time.get_ticks_usec() - t0) / 1000.0, worst, worst_poll, fr]


func test_clipmap_load_and_shift() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	if lw.size() != 2:
		failures.append("нет слоя detail Онгудая")
		return
	var loc := TestAirPlace.load_loc("ongudai")
	var m100 := TestAirPicard.load_fix(FIX_W + "ongudai_w100_h12")
	var site := Vector2(float(m100.site.x), float(m100.site.y))
	var dc := AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0)
	var dom := AirPicardJob.new()
	dom.case = dc
	dom.mech = true
	dom.chunk_ms = 30.0
	if not await run_job(dom, true):
		return
	var df := dom.field()
	var cm := AirClipmap.new()
	cm.setup(lw[0], lw[1], loc, 12.0, 3.0, 150.0)
	var got: Array = []
	cm.levels_changed.connect(func(lv: Array[WindField]) -> void: got.append(lv))
	cm.failed.connect(func(msg: String) -> void: failures.append("клипмап: " + msg))
	cm.set_domain(dom, df)
	dom.release()
	# загрузка: все окна с центром на старте (экран загрузки)
	cm.start(site)
	var r := await run_clipmap(cm, true)
	check(cm.is_ready(), "окна посчитаны при загрузке")
	check(got.size() == 1 and (got[0] as Array).size() == 3, "набор: окно 50, окно 100, область")
	if got.is_empty():
		return
	var lv: Array = got[0]
	check(
		lv[0].dx == 50.0 and lv[1].dx == 100.0 and lv[2].dx == 400.0, "уровни от мелкого к грубому"
	)
	print("  загрузка окон (poll_slice 40): стена %.0f мс, наибольший кадр %.0f мс" % [r[0], r[1]])
	seam(lv, lw[0], site)
	# полёт: пилот ушёл на 1 км к востоку (сдвиг окна 50 м), затем на 2 км (сдвиг 100 м и 50 м)
	var fly := []
	for dx_m in [1000.0, 2000.0]:
		var pilot := Vector3(site.x + dx_m, 2000.0, -site.y)
		cm.update(pilot)
		check(cm.is_busy(), "сдвиг окна начат (%d м от старта)" % int(dx_m))
		var rf := await run_clipmap(cm, false, pilot)
		fly.append(rf)
		check(rf[1] <= 100.0, "сдвиг окна без кадра > 100 мс: %.0f мс" % rf[1])
		var c50 := cm.window_center(1)
		check(
			absf(c50.x - pilot.x) <= 50.0 and absf(c50.y + pilot.z) <= 50.0,
			"окно 50 м — у пилота после сдвига"
		)
		print(
			(
				"  сдвиг к %d м: стена %.0f мс, кадров %d, наибольший кадр %.0f мс, наибольший poll %.1f мс"
				% [int(dx_m), rf[0], rf[3], rf[1], rf[2]]
			)
		)
	check(got.size() == 3, "после каждого сдвига — новый набор уровней")
	for h: Dictionary in cm.history:
		print(
			(
				(
					"    окно %d м (%s, %s) — %s%s: итераций %s, %s; подготовка %.0f мс, стена %.0f мс, "
					+ "GPU %.0f мс, порций %d, макс. порция %.1f мс, макс. poll %.1f мс, start %.0f мс, "
					+ "итог %.0f мс"
				)
				% [
					int(h.dx),
					h.x0,
					h.y0,
					h.reason,
					" (тёплый)" if h.warm else "",
					str(h.iters),
					h.status,
					h.prep_ms,
					h.wall_ms,
					h.gpu_ms,
					h.chunks,
					h.max_chunk_ms,
					h.poll_max_ms,
					h.start_ms,
					h.finish_ms
				]
			)
		)
		check(h.max_chunk_ms <= 50.0, "порция ≤ 50 мс")
	cm.release()


## Стык уровней: профиль вдоль линии на восток от старта через края окон 50 м (+1,6 км) и 100 м
## (+3,2 км) на 50 и 300 м над землёй. На краю окна (начало полосы края, 5 клеток внутрь) —
## разница уровня с более грубым в % от скорости грубого: её выборка сглаживает на 5 клеток, это
## и есть наибольший «скачок». AIR_CLIPMAP_DUMP=1 — CSV в tools/research/air_clipmap/out/
## (картинка — tools/research/air_clipmap/seam_plot.py).
func seam(lv: Array, layer: HeightLayer, site: Vector2) -> void:
	var fs := AirFieldSet.new()
	var typed: Array[WindField] = []
	for f: WindField in lv:
		typed.append(f)
	fs.set_field(typed, 0.0)
	var rows := PackedStringArray(["x_m,agl,ground,u,v,w,frac,s50,w50,s100,w100,s400,w400"])
	for agl in [50.0, 300.0]:
		var prev := Vector3.INF
		var worst_step := 0.0
		var prof: Array[Vector3] = []
		var xs := PackedFloat64Array()
		for q in 501:
			var x := site.x - 500.0 + 10.0 * q
			var gz := -site.y
			var g := layer.sample(x, gz)
			var pos := Vector3(x, g + agl, gz)
			var v := fs.sample(pos, g)
			var line := (
				"%.1f,%.0f,%.2f,%.5f,%.5f,%.5f,%.4f" % [x - site.x, agl, g, v.x, -v.z, v.y, v.w]
			)
			for f: WindField in typed:
				var sv := f.sample(pos, g)
				line += ",%.5f,%.5f" % [Vector2(sv.x, sv.z).length(), sv.y]
			rows.append(line)
			var cur := Vector3(v.x, v.y, v.z)
			prof.append(cur)
			xs.append(x)
			if prev != Vector3.INF:
				worst_step = maxf(worst_step, (cur - prev).length())
			prev = cur
		# разница уровней у восточной грани мелкого (центр крайней клетки: граница окна —
		# от грубого, зона релаксации) и в начале полосы края (edge_cells клеток внутрь: там
		# мелкий решает сам, разница — разрешение сетки; выборка сглаживает её на полосе)
		var parts := []
		for q in 2:
			var fine: WindField = typed[q]
			var coarse: WindField = typed[q + 1]
			var ds := []
			for inset: float in [0.5, fine.edge_cells]:
				var xe := fine.x0 + (fine.nx - inset) * fine.dx
				var g := layer.sample(xe, -site.y)
				var pos := Vector3(xe, g + agl, -site.y)
				var a := fine.sample(pos, g)
				var b := coarse.sample(pos, g)
				ds.append((a - b).length() / maxf(Vector2(b.x, b.z).length(), 0.5))
			parts.append(
				(
					"%d→%d м: у грани %.1f %%, в %d клетках %.1f %%"
					% [
						int(fine.dx),
						int(coarse.dx),
						100.0 * ds[0],
						int(fine.edge_cells),
						100.0 * ds[1]
					]
				)
			)
			# что видит пилот: изменение смешанного поля за 50 м (% скорости) в полосе края против
			# того же внутри мелкого окна (рельеф) — стык не даёт скачка больше 5 % сверх рельефа
			var face := fine.x0 + fine.nx * fine.dx
			var band := fine.edge_cells * fine.dx
			var st_seam := _max_step(prof, xs, face - band - 50.0, face + 50.0)
			var st_in := _max_step(prof, xs, face - 3.0 * band, face - band - 50.0)
			parts[-1] += (
				", за 50 м: стык %.1f %%, внутри %.1f %%" % [100.0 * st_seam, 100.0 * st_in]
			)
			check(
				st_seam <= maxf(st_in, 0.0) + 0.05,
				"стык %d→%d м на %d м: %.1f %% за 50 м" % [fine.dx, coarse.dx, agl, 100.0 * st_seam]
			)
		print(
			(
				"  стык уровней, %d м над землёй: %s; наибольший шаг профиля за 10 м %.3f м/с"
				% [int(agl), ", ".join(parts), worst_step]
			)
		)
	if OS.get_environment("AIR_CLIPMAP_DUMP") == "1":
		var dir := ProjectSettings.globalize_path("res://tools/research/air_clipmap/out")
		DirAccess.make_dir_recursive_absolute(dir)
		var fa := FileAccess.open(dir.path_join("seam_kayancha_h12_U3.csv"), FileAccess.WRITE)
		fa.store_string("\n".join(rows) + "\n")
		fa.close()


## Наибольшее изменение профиля за 50 м (5 отсчётов) в [a, b], доля местной скорости.
static func _max_step(prof: Array[Vector3], xs: PackedFloat64Array, a: float, b: float) -> float:
	var m := 0.0
	for q in prof.size() - 5:
		if xs[q] < a or xs[q + 5] > b:
			continue
		var sp := maxf(Vector2(prof[q].x, prof[q].z).length(), 0.5)
		m = maxf(m, (prof[q + 5] - prof[q]).length() / sp)
	return m


# ---------------------------------------------------------------- AirRuntime с окнами (C9 + C7)

func _rt_frame() -> void:
	var now := Time.get_ticks_usec()
	if _rt_t > 0:
		_rt_gaps.append((now - _rt_t) / 1000.0)
	_rt_t = now


func _rt_watch(on: bool) -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if on:
		_rt_gaps.clear()
		_rt_t = 0
		tree.process_frame.connect(_rt_frame)
		return 0.0
	tree.process_frame.disconnect(_rt_frame)
	var mx := 0.0
	for g in _rt_gaps:
		mx = maxf(mx, g)
	return mx


func _rt_conditions() -> Dictionary:
	return _rt_cond


func test_runtime_with_windows() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var detail: HeightLayer = lw[0]
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(3.0)
	w.wind_from_deg = 150.0
	w.thermal_mode = "static"
	w.static_thermals = []
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_thermal_mode("static")
	atmo.turbulence_enabled = false
	atmo.step(0.01)
	_rt_cond = {hour = 12.0, u10 = 3.0, wdir = 150.0, t_max = NAN, sky = "clear"}
	var m100 := TestAirPicard.load_fix(FIX_W + "ongudai_w100_h12")
	var start := Vector3(float(m100.site.x), 0.0, -float(m100.site.y))
	start.y = detail.sample(start.x, start.z)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var host := Node.new()  # «Game»: полёт — когда шагает физику
	host.set_physics_process(false)
	var pilot := Node3D.new()
	host.add_child(pilot)
	tree.root.add_child(host)
	var rt := AirRuntime.new()
	tree.root.add_child(rt)
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _rt_conditions)
	rt.set_focus(pilot, start)
	_rt_watch(true)
	var ok: bool = await rt.load_field()
	var fmax := _rt_watch(false)
	check(ok, "поле с окнами при загрузке: %s" % rt.last_error)
	var lv: Array[WindField] = atmo.air_field.levels
	check(
		lv.size() == 3 and lv[0].dx == 50.0 and lv[1].dx == 100.0 and lv[2].dx == 400.0,
		"в атмосфере: окно 50, окно 100, область"
	)
	var li := rt.last_info
	print(
		(
			"  AirRuntime, загрузка с окнами: %.2f с стены, кадр max %.0f мс, AirRuntime за кадр max %.0f мс"
			% [float(li.get("wall_s", 0)), fmax, float(li.get("main_max_ms", 0))]
		)
	)
	# атмосфера 3 с без сдвига: первая сборка источников термиков по полю (AM-07, ~0,4 с на
	# главном потоке через ~1 с) — не относится к окнам, в замер сдвига не входит
	var tc0 := Time.get_ticks_msec()
	var atmo_first := 0.0
	while Time.get_ticks_msec() - tc0 < 3000:
		await tree.process_frame
		var tb := Time.get_ticks_usec()
		atmo.step(1.0 / 60.0)
		atmo_first = maxf(atmo_first, (Time.get_ticks_usec() - tb) / 1000.0)
	print("    без сдвига: шаг атмосферы max %.0f мс (термики по полю)" % atmo_first)
	# полёт: пилот ушёл на 1 км к востоку → сдвиг окна 50 м
	host.set_physics_process(true)
	rt.recompute_enabled = true
	pilot.global_position = start + Vector3(1000.0, 300.0, 0.0)
	_rt_watch(true)
	var t0 := Time.get_ticks_msec()
	var atmo_ms := 0.0
	while rt.shift_count < 1 and Time.get_ticks_msec() - t0 < 30000:
		await tree.process_frame
		var ta := Time.get_ticks_usec()
		atmo.step(1.0 / 60.0)
		atmo_ms = maxf(atmo_ms, (Time.get_ticks_usec() - ta) / 1000.0)
	fmax = _rt_watch(false)
	print(
		(
			"    шаг атмосферы max %.0f мс, AirRuntime за кадр max %.0f мс"
			% [atmo_ms, rt.get("_main_ms")]
		)
	)
	check(rt.shift_count == 1, "окно сдвинулось за пилотом")
	lv = atmo.air_field.levels
	check(
		lv.size() == 3 and absf(lv[0].center_xz().x - pilot.global_position.x) <= 50.0,
		"окно 50 м — у пилота"
	)
	print(
		(
			"  сдвиг за пилотом: %.2f с до подачи, кадр max %.0f мс"
			% [(Time.get_ticks_msec() - t0) / 1000.0, fmax]
		)
	)
	check(fmax <= 100.0, "сдвиг без кадра > 100 мс (%.0f)" % fmax)
	# пересчёт по сроку: область + окна на прежних местах (тёплый старт)
	_rt_cond.hour = 12.26
	_rt_watch(true)
	t0 = Time.get_ticks_msec()
	while rt.applied_count < 2 and rt.failed_count == 0 and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
		atmo.step(1.0 / 60.0)
	fmax = _rt_watch(false)
	li = rt.last_info
	check(rt.applied_count == 2 and li.has("windows"), "пересчёт по сроку — с окнами")
	check(atmo.air_field.levels.size() == 3, "после пересчёта — три уровня")
	print(
		(
			"  пересчёт 12:15 с окнами: %.2f с стены, итераций области %s, окна %s; кадр max %.0f мс"
			% [
				float(li.get("wall_s", 0)),
				li.get("iters"),
				(li.get("windows", []) as Array).map(AirRuntime._window_text),
				fmax
			]
		)
	)
	check(fmax <= 100.0, "пересчёт без кадра > 100 мс (%.0f)" % fmax)
	rt.stop()
	rt.queue_free()
	host.queue_free()
	atmo.free()
