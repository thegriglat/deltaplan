extends Node
## RW-6n: эталонный дамп окон клипмапа 100/50 м из GDScript и GPU игры (AirWindowCase,
## AirWindowJob) для сверки с Rust (rust/dp-air/src/field/window.rs, rust/dp-air/src/level.rs,
## тест tests/window.rs).
##
## Цепочка как в игре (AirClipmap): область 400 м на GPU (Онгудай, условия ongudai_medium) →
## окно 100 м у старта (родитель — область) → окно 50 м (родитель — окно 100 м; z_i столбцов —
## от поля области, как в клипмапе) → окно 100 м, сдвинутое на 16 клеток к востоку (тёплый старт
## от окна 100 м). Растры места — те же фикстуры, что у дамперов RW-6d/6e.
##
## Пишет два набора в <out>:
##   inputs.json + inputs.bin — вход окон и плоскости prepare (чисто CPU, побитно воспроизводится):
##       рельеф, поток тепла, gam, z_i по столбцам (от родителя), карта z0, col/lev/prm пар mech/heat,
##       условия и климат (для цепочки W5 → окно в Rust);
##   gpu.json + gpu.bin.zst — результат GPU (воспроизводится в допусках): родитель, обрезанный до
##       нужного окну (поля u, v, w, θ′, θ′_d с нагревом и без, типы клеток), типы клеток окна
##       tcode, граница после поправки потока (ubu, ubv, ubw, thb, thbd — срез плоскостей k), поток
##       и площадь граничных граней (net, area), итерации пары, коробки итогового поля вокруг
##       центра окна; для сдвинутого окна — прошлое решение окна (heat, целиком) и состояние сразу
##       после старта со сдвигом (K_BC init + K_SHIFT, до V-циклов).
##
##   tools/research/rust_wind/dump_window.sh [--verify]    # GPU: не headless, под .dpcli/dpcli lock gpu
## Аргументы: --out=<каталог> [--ref=<каталог с gpu.json для сверки в допусках>].

const FIX := "res://tests/fixtures/wind/"
const PLACE := "ongudai"
const BASE := "ongudai_medium"
const SHIFT_CELLS := 16  # сдвиг окна 100 м: 0,25 стороны (клипмап сдвигает при уходе дальше)
const BOX_N := 17  # коробка итогового поля, клеток (с ореолом, вокруг центра окна)
const TOL := 1e-4  # допуск пересъёмки GPU-массивов, от наибольшего |значения| массива

var _in_buf := PackedByteArray()
var _in_arr := {}
var _gpu_buf := PackedByteArray()
var _gpu_arr := {}
var _gpu: AirGpu = null


class DumpShiftJob:
	extends AirWindowJob
	## Окно до V-циклов: старт «границы + сдвиг» (K_BC init=1, K_SHIFT) без проекции; задача
	## кончается сразу после этого шага — буферы несут состояние старта.

	func _program(key: String) -> Array:
		if key == "winit":
			if not _progs.has("wdump"):
				_progs["wdump"] = gpu.record(_rec_warm_init)
			return _progs["wdump"]
		return super._program(key)

	func _after_sync() -> bool:
		var was_init := _phase == Phase.INIT
		var done := super._after_sync()
		return done or was_init


func _ready() -> void:
	var out_dir := ""
	var ref_dir := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
		elif String(a).begins_with("--ref="):
			ref_dir = String(a).substr(6)
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://rust/dp-air/tests/data/window")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := await _run(out_dir)
	if ok and ref_dir != "":
		ok = _verify(out_dir, ref_dir)
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- место и условия


func _run(out_dir: String) -> bool:
	var hdr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "places/" + PLACE + ".json"))
	var bin := FileAccess.get_file_as_bytes(FIX + "places/" + PLACE + ".bin")
	var g: Dictionary = hdr.grid
	var w := int(g.width)
	var h := int(g.height)
	var n := w * h
	var off := float(hdr.h_offset)
	var sc := float(hdr.h_scale)
	var heights := PackedFloat32Array()
	heights.resize(n)
	for q in n:
		heights[q] = off + bin.decode_s16(2 * q) * sc
	var water_u8 := bin.slice(2 * n, 3 * n)
	var cls := bin.slice(3 * n, 4 * n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for q in n:
		moist[q] = bin[4 * n + q] / 255.0
	var detail := HeightLayer.from_heights(
		PLACE, w, h, float(g.spacing), float(g.origin_x), float(g.origin_z), heights
	)
	var sf := AirPlace.Surface.new()
	sf.origin_x = float(g.origin_x)
	sf.origin_z = float(g.origin_z)
	sf.width = w
	sf.height = h
	sf.cls = cls
	sf.moist = moist
	var wbytes := PackedByteArray()
	wbytes.resize(n)
	for q in n:
		wbytes[q] = 255 if water_u8[q] > 0 else 0
	var wimg := Image.create_from_data(w, h, false, Image.FORMAT_L8, wbytes)
	var loc: Dictionary = hdr.loc

	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "cases/%s.json" % BASE))
	var fc: Dictionary = base.extra.field_conditions
	var hour := float(fc.hour)
	var sky := String(fc.sky)
	var t_max := float(fc.t_max)
	var u10 := float(fc.u10)
	var wdir := float(fc.wdir)
	var cfg := WeatherModel.config()
	var ctx := AirPlace.context(detail, loc, cfg)
	var wcfg: Dictionary = SurfaceHeat.config().get("water", {})
	var site: Dictionary = hdr.start_sites[0]
	var cx := float(site.x)
	var cy := -float(site.z)  # ось решателя y = −z мира

	# область 400 м на GPU: родитель окна 100 м и поле для z_i столбцов
	var area_case := AirPlace.domain_case(detail, wimg, loc, 400.0, hour, u10, wdir, t_max, sky, true, 1.0, sf)
	if area_case == null:
		push_error("область не собрана")
		return false
	var ajob := AirPicardJob.new()
	ajob.case = area_case
	ajob.mech = true
	if not ajob.start() or not ajob.run_blocking():
		push_error("область: " + ajob.error)
		return false
	var area_pd := ajob.parent_data()
	var area_field := ajob.field()
	var area_iters := [int(ajob.results[0].iters), int(ajob.results[-1].iters)]
	ajob.release()
	if area_field == null:
		push_error("поле области не собрано")
		return false

	_gpu = AirGpu.new()
	if not _gpu.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES + AirWindowJob.WINDOW_SHADERS):
		push_error("GPU: " + _gpu.error)
		return false

	var meta_in := {
		version = 1, place = PLACE, base = BASE, hour = hour, sky = sky, t_max = t_max, u10 = u10,
		wdir = wdir, center = [cx, cy], shift_cells = SHIFT_CELLS, area_iters = area_iters,
		conditions = {
			forecast = {temperature_c = t_max, wind_speed_kmh = u10 * 3.6, wind_from_deg = wdir, sky = sky},
			start_hour = hour, speed = 1.0, quantum_h = 0.5,
		},
		climate = _climate(ctx, wcfg),
		area = {
			dx = 400.0, x0 = area_case.x0, y0 = area_case.y0, nx = area_case.nx, ny = area_case.ny,
			z_i = area_field.z_i(), alpha_on = area_field.zi_alpha() > 0.0,
		},
		windows = [],
	}
	var azc := area_field.z_i_col()
	_put(_in_buf, _in_arr, "area_z_i_col", azc.to_byte_array(), "f32", azc.size())
	var meta_gpu := {version = 1, windows = []}

	var args := {
		detail = detail, wimg = wimg, loc = loc, hour = hour, u10 = u10, wdir = wdir, t_max = t_max,
		sky = sky, ctx = ctx, sf = sf, field = area_field,
	}
	# окно 100 м у старта
	var w100 := await _window("w100", 100.0, null, cx, cy, area_pd, {}, args, meta_in, meta_gpu)
	if w100.is_empty():
		return false
	# окно 50 м: родитель — окно 100 м
	var w50 := await _window("w50", 50.0, null, cx, cy, w100.pd, {}, args, meta_in, meta_gpu)
	if w50.is_empty():
		return false
	# окно 100 м, сдвинутое: тёплый старт от окна 100 м
	var w100s := await _window(
		"w100s", 100.0, w100.case, cx, cy, area_pd, w100.st, args, meta_in, meta_gpu
	)
	if w100s.is_empty():
		return false
	_gpu.release()
	_gpu = null

	meta_in.arrays = _in_arr
	meta_gpu.arrays = _gpu_arr
	meta_gpu.raw_bytes = _gpu_buf.size()
	var ok := _write_atomic(out_dir + "/inputs.bin", _in_buf)
	ok = _write_atomic(out_dir + "/inputs.json", (JSON.stringify(meta_in, "\t", true, true) + "\n").to_utf8_buffer()) and ok
	var packed := _gpu_buf.compress(FileAccess.COMPRESSION_ZSTD)
	ok = _write_atomic(out_dir + "/gpu.bin.zst", packed) and ok
	ok = _write_atomic(out_dir + "/gpu.json", (JSON.stringify(meta_gpu, "\t", true, true) + "\n").to_utf8_buffer()) and ok
	print("dump_window: gpu.bin %d байт, в zstd %d байт; inputs.bin %d байт" % [_gpu_buf.size(), packed.size(), _in_buf.size()])
	return ok


# ---------------------------------------------------------------- одно окно


## Окно: вход и плоскости (CPU) → пара mech/heat на GPU → граница, итоги. shift_from — случай
## прошлого окна (для сдвинутого: его угол + SHIFT_CELLS клеток), prev — его window_state().
## Возвращает {case, pd (parent_data для окна мельче), st (window_state)}; пусто — ошибка.
func _window(
	tag: String, dx: float, shift_from: AirWindowCase, cx: float, cy: float, parent: Dictionary,
	prev: Dictionary, a: Dictionary, meta_in: Dictionary, meta_gpu: Dictionary
) -> Dictionary:
	var x0: float
	var y0: float
	if shift_from != null:
		x0 = shift_from.x0 + SHIFT_CELLS * dx
		y0 = shift_from.y0
	else:
		var half := 0.5 * AirWindowCase.N_WINDOW * dx
		x0 = roundf((cx - half) / 25.0) * 25.0
		y0 = roundf((cy - half) / 25.0) * 25.0
	var c := AirWindowCase.window_at(
		a.detail, a.wimg, a.loc, dx, x0, y0, a.hour, a.u10, a.wdir, a.t_max, a.sky, true, a.ctx,
		AirWindowCase.N_WINDOW, 1.0, a.sf, a.field
	)
	if c == null or not c.prepare_pair():
		push_error("%s: случай не собран" % tag)
		return {}
	var mc := c.without_heat()
	var rec_in := _input_record(tag, c, mc)
	meta_in.windows.append(rec_in)

	# GPU: пара (итерации, граница тепловой части, поле), затем mech отдельно (граница mech)
	var pair := AirWindowJob.new()
	pair.case = c
	pair.mech = true
	pair.parent = parent
	pair.prev = prev
	pair.shared_gpu = true
	if not await _run_job(pair):
		return {}
	var rec := {
		tag = tag, dx = dx, x0 = x0, y0 = y0,
		iters = {mech = int(pair.results[0].iters), heat = int(pair.results[1].iters)},
		status = {mech = String(pair.results[0].status), heat = String(pair.results[1].status)},
		warm = not prev.is_empty(), sets = [],
	}
	var dims := c.dims()  # с ореолом
	rec.dims = [dims.x, dims.y, dims.z]
	var tcb := pair.download("tcode")
	_put(_gpu_buf, _gpu_arr, tag + "_tcode", _to_u8(tcb), "u8", tcb.size())
	rec.tcode = tag + "_tcode"
	var crop := _crop_parent(parent, c)
	var pk := tag + "_par"
	rec.parent = crop.meta
	_put(_gpu_buf, _gpu_arr, pk + "_tc", _to_u8(crop.tc), "u8", crop.tc.size())
	for sname in ["heat", "mech"]:
		for ch in ["u", "v", "w", "th", "thd"]:
			var arr: PackedFloat32Array = crop[sname][ch]
			_put(_gpu_buf, _gpu_arr, "%s_%s_%s" % [pk, sname, ch], arr.to_byte_array(), "f32", arr.size())
	var planes := _slab_planes(dims.z)
	rec.planes = planes
	var heat_set := _set_record(tag, "heat", pair, dims, planes, pair.results[1])
	rec.sets.append(heat_set)
	var st := pair.window_state()
	var pd := pair.parent_data()
	# коробки итогового поля: heat = state(false), mech = state(true)
	_dump_box(tag, "heat", st.heat, dims, heat_set)
	var mech_state := pair.state(true)
	pair.release()
	# mech: своя задача (граница mech и поле сравнения); у сдвинутого окна — только heat (объём)
	if prev.is_empty():
		var mj := AirWindowJob.new()
		mj.case = mc
		mj.mech = false
		mj.parent = parent
		mj.shared_gpu = true
		if not await _run_job(mj):
			return {}
		var mech_set := _set_record(tag, "mech", mj, dims, planes, mj.results[0])
		rec.sets.append(mech_set)
		_dump_box(tag, "mech", mech_state, dims, mech_set)
		mj.release()
	# сдвинутое окно: состояние сразу после старта со сдвигом (heat), без V-циклов
	if not prev.is_empty():
		var sj := DumpShiftJob.new()
		sj.case = c
		sj.mech = false
		sj.parent = parent
		sj.prev = prev
		sj.shared_gpu = true
		if not sj.start(_gpu) or not sj.run_blocking():
			push_error("%s: сдвиг: %s" % [tag, sj.error])
			return {}
		var sh := {
			from = "w100", shift = [SHIFT_CELLS, 0, int(round((c.z_bot - float(prev.grid.z_bot)) / c.dz))],
			planes = planes, arrays = {}, old = {},
		}
		for ch in ["u", "v", "w", "th", "thd", "p"]:
			var arr: PackedFloat32Array = sj.download(ch)
			var key := "%s_shift_%s" % [tag, ch]
			var slab := _slab(arr, dims.x * dims.y, planes)
			_put(_gpu_buf, _gpu_arr, key, slab.to_byte_array(), "f32", slab.size())
			sh.arrays[ch] = key
			var old_arr: PackedFloat32Array = prev.heat[ch]
			var okey := "%s_old_%s" % [tag, ch]
			_put(_gpu_buf, _gpu_arr, okey, old_arr.to_byte_array(), "f32", old_arr.size())
			sh.old[ch] = okey
		var og: Dictionary = prev.grid
		sh.old_grid = og
		sh.old_dims = [int(og.nx) + 2, int(og.ny) + 2, int(og.nz) + 2]
		rec.shift = sh
		sj.release()
	meta_gpu.windows.append(rec)
	return {case = c, pd = pd, st = st}


func _run_job(job: AirWindowJob) -> bool:
	if not job.start(_gpu):
		push_error("start: " + job.error)
		return false
	if not job.run_blocking():
		push_error("решение: " + job.error)
		return false
	return true


## Граница (после поправки потока) выбранных плоскостей, поток, итоги решения набора.
func _set_record(tag: String, mode: String, job: AirWindowJob, dims: Vector3i, planes: Array, res: Dictionary) -> Dictionary:
	var nyx := dims.x * dims.y
	var sc := job.gpu.download(job.gpu.scalars, 2, AirWindowJob.S_NET)
	var rec := {
		mode = mode, net = sc[0], area = sc[1], corr = job.nest_corr(), iters = int(res.iters),
		status = String(res.status), arrays = {},
	}
	for nm in ["ubu", "ubv", "ubw", "thb", "thbd"]:
		var slab := _slab(job.download(nm), nyx, planes)
		var key := "%s_%s_%s" % [tag, mode, nm]
		_put(_gpu_buf, _gpu_arr, key, slab.to_byte_array(), "f32", slab.size())
		rec.arrays[nm] = key
	return rec


## Коробка итогового поля (u, v, w, θ′, θ′_d) вокруг центра окна, все плоскости k.
func _dump_box(tag: String, mode: String, st: Dictionary, dims: Vector3i, rec: Dictionary) -> void:
	var i0 := (dims.x - BOX_N) >> 1
	var j0 := (dims.y - BOX_N) >> 1
	rec.box = {i0 = i0, j0 = j0, n = BOX_N, arrays = {}}
	for ch in ["u", "v", "w", "th", "thd"]:
		var src: PackedFloat32Array = st[ch]
		var out := PackedFloat32Array()
		for k in dims.z:
			for j in BOX_N:
				var base := (k * dims.y + j0 + j) * dims.x + i0
				out.append_array(src.slice(base, base + BOX_N))
		var key := "%s_%s_box_%s" % [tag, mode, ch]
		_put(_gpu_buf, _gpu_arr, key, out.to_byte_array(), "f32", out.size())
		rec.box.arrays[ch] = key


## Плоскости k, по которым сверяется граница: нижние (рельеф), редкие в середине, верхние
## (граничные грани w).
func _slab_planes(nz_h: int) -> Array:
	var out := []
	for k in nz_h:
		if k < 12 or k % 8 == 0 or k >= nz_h - 3:
			out.append(k)
	return out


func _slab(a: PackedFloat32Array, nyx: int, planes: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k: int in planes:
		out.append_array(a.slice(k * nyx, (k + 1) * nyx))
	return out


func _to_u8(a: PackedFloat32Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(a.size())
	for q in a.size():
		b[q] = int(a[q])
	return b


# ---------------------------------------------------------------- родитель, обрезанный окну


## Диапазон индексов родителя (с ореолом), который читает K_NEST для окна: от
## ⌊min f⌋ − 1 до ⌊max f⌋ + 3 (угол трилинейки + соседняя грань центра + запас); края — края
## родителя (зажим индекса ядра там сохраняется).
func _span(o: float, r: float, n_w: int, n_p: int) -> Vector2i:
	var fmin := clampf(o - r + 0.5, 0.0, n_p - 1.0001)
	var fmax := clampf(o + (n_w - 1.5) * r + 0.5, 0.0, n_p - 1.0001)
	return Vector2i(maxi(0, int(fmin) - 1), mini(n_p - 1, int(fmax) + 3))


func _crop_parent(pd: Dictionary, c: AirWindowCase) -> Dictionary:
	var g: Dictionary = pd.grid
	var pnx := int(g.nx) + 2
	var pny := int(g.ny) + 2
	var pnz := int(g.nz) + 2
	var pdx := float(g.dx)
	var pdz := float(g.dz)
	var rx := c.dx / pdx
	var rz := c.dz / pdz
	var ox := (c.x0 - float(g.x0)) / pdx
	var oy := (c.y0 - float(g.y0)) / pdx
	var oz := (c.z_bot - float(g.z_bot)) / pdz
	var sx := _span(ox, rx, c.nx + 2, pnx)
	var sy := _span(oy, rx, c.ny + 2, pny)
	var sz := _span(oz, rz, c.nz + 2, pnz)
	var ni := sx.y - sx.x + 1
	var nj := sy.y - sy.x + 1
	var nk := sz.y - sz.x + 1
	var out := {
		tc = _cut(pd.tc, pnx, pny, sx, sy, sz),
		heat = {},
		mech = {},
		meta = {
			grid = {
				dx = pdx, dz = pdz, x0 = float(g.x0) + sx.x * pdx, y0 = float(g.y0) + sy.x * pdx,
				z_bot = float(g.z_bot) + sz.x * pdz, nx = ni - 2, ny = nj - 2, nz = nk - 2,
			},
			dims = [ni, nj, nk], origin = [sx.x, sy.x, sz.x],
		},
	}
	for sname in ["heat", "mech"]:
		for ch in ["u", "v", "w", "th", "thd"]:
			out[sname][ch] = _cut(pd[sname][ch], pnx, pny, sx, sy, sz)
	return out


func _cut(a: PackedFloat32Array, pnx: int, pny: int, sx: Vector2i, sy: Vector2i, sz: Vector2i) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in range(sz.x, sz.y + 1):
		for j in range(sy.x, sy.y + 1):
			var base := (k * pny + j) * pnx
			out.append_array(a.slice(base + sx.x, base + sx.y + 1))
	return out


# ---------------------------------------------------------------- вход окна и плоскости (CPU)


func _input_record(tag: String, c: AirWindowCase, mc: AirCase) -> Dictionary:
	var rec := {
		tag = tag, dx = c.dx, dz = c.dz, x0 = c.x0, y0 = c.y0, z_bot = c.z_bot, nx = c.nx, ny = c.ny,
		nz = c.nz, z_i = c.z_i, alpha = float(c.p.alpha), max_profile = float(c.p.max_profile),
		u10 = c.u10, u10_menu = c.u10_menu, wdir = c.wdir, sets = [],
	}
	_put(_in_buf, _in_arr, tag + "_hc", c.hc.to_byte_array(), "f64", c.hc.size())
	_put(_in_buf, _in_arr, tag + "_z0_map", c.z0_map.to_byte_array(), "f64", c.z0_map.size())
	_put(_in_buf, _in_arr, tag + "_heat", c.heat.to_byte_array(), "f64", c.heat.size())
	_put(_in_buf, _in_arr, tag + "_gam", c.gam.to_byte_array(), "f64", c.gam.size())
	_put(_in_buf, _in_arr, tag + "_z_i_col", c.z_i_col.to_byte_array(), "f32", c.z_i_col.size())
	for mode in ["heat", "mech"]:
		var cc: AirCase = c if mode == "heat" else mc
		var key := "%s_%s" % [tag, mode]
		_put(_in_buf, _in_arr, "col_" + key, cc.col.to_byte_array(), "f32", cc.col.size())
		_put(_in_buf, _in_arr, "lev_" + key, cc.lev.to_byte_array(), "f32", cc.lev.size())
		_put(_in_buf, _in_arr, "prm_" + key, cc.prm.to_byte_array(), "f32", cc.prm.size())
		_put(_in_buf, _in_arr, "hused_" + key, cc.heat_used.to_byte_array(), "f64", cc.heat_used.size())
		rec.sets.append({
			mode = mode, key = key, n_unk = Array(cc.n_unk), n_fluid = cc.n_fluid, cd = cc.cd,
			fixed_scale = cc.fixed_scale, ustar = cc.ustar, u_a = cc.u_a, ex = cc.ex, ey = cc.ey,
			h_mech = float(cc.closure_info.h_mech), wstar_max = float(cc.closure_info.wstar_max),
			h_max = float(cc.closure_info.h_max), z0 = float(cc.p.z0), alpha = float(cc.p.alpha),
			max_profile = float(cc.p.max_profile), u10 = cc.u10,
		})
	return rec


## Климат ячейки (ClimateGrid.at, без поправки на высоту) на дату места и на дату воды.
func _climate(ctx: Dictionary, wcfg: Dictionary) -> Array:
	var doy := SunClock.day_of_year(int(ctx.month), int(ctx.day)) - int(round(float(wcfg.get("lag_days", 30.0))))
	if doy < 1:
		doy += 365
	var md := SurfaceHeat._month_day(doy)
	var out := []
	for date in [Vector2i(int(ctx.month), int(ctx.day)), md]:
		var at := ClimateGrid.at(float(ctx.lat), float(ctx.lon), date.x, date.y)
		out.append({
			month = date.x, day = date.y, tx_c = at.tx_c, dtr_k = at.dtr_k, z_cell_m = at.z_cell_m,
			has_hh1 = String(at.src.hh1) != "none", has_hh5 = String(at.src.hh5) != "none",
		})
	return out


# ---------------------------------------------------------------- сверка пересъёмки (--ref)


## Пересъёмка GPU-части против записанной: итерации — |Δ| ≤ max(20, iters/10), массивы —
## max|Δ| ≤ TOL · max|эталон массива| (типы u8 — точно).
func _verify(out_dir: String, ref_dir: String) -> bool:
	var a: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out_dir + "/gpu.json"))
	var b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ref_dir + "/gpu.json"))
	var ba := FileAccess.get_file_as_bytes(out_dir + "/gpu.bin.zst").decompress(int(a.raw_bytes), FileAccess.COMPRESSION_ZSTD)
	var bb := FileAccess.get_file_as_bytes(ref_dir + "/gpu.bin.zst").decompress(int(b.raw_bytes), FileAccess.COMPRESSION_ZSTD)
	var ok := true
	for q in a.windows.size():
		var wa: Dictionary = a.windows[q]
		var wb: Dictionary = b.windows[q]
		for k in ["mech", "heat"]:
			var ia := int(wa.iters[k])
			var ib := int(wb.iters[k])
			if absi(ia - ib) > maxi(20, int(ib * 0.1)):
				print("verify: %s %s итераций %d, записано %d" % [wa.tag, k, ia, ib])
				ok = false
	var worst := 0.0
	for key: String in b.arrays:
		var ma: Dictionary = a.arrays.get(key, {})
		var mb: Dictionary = b.arrays[key]
		if ma.is_empty() or int(ma.count) != int(mb.count) or ma.dtype != mb.dtype:
			print("verify: нет или другой размер: " + key)
			ok = false
			continue
		var w := 1 if mb.dtype == "u8" else (8 if mb.dtype == "f64" else 4)
		var sa := ba.slice(int(ma.offset), int(ma.offset) + w * int(ma.count))
		var sb := bb.slice(int(mb.offset), int(mb.offset) + w * int(mb.count))
		if mb.dtype == "u8":
			if sa != sb:
				print("verify: расходится " + key)
				ok = false
			continue
		var fa := sa.to_float32_array()
		var fb := sb.to_float32_array()
		var mx := 0.0
		var d := 0.0
		for i in fb.size():
			mx = maxf(mx, absf(fb[i]))
			d = maxf(d, absf(fa[i] - fb[i]))
		worst = maxf(worst, d / maxf(mx, 1e-6))
		if d > TOL * maxf(mx, 1e-6):
			print("verify: %s: max|Δ| %.3e при max|значение| %.3e" % [key, d, mx])
			ok = false
	print("verify: GPU-часть: наибольшее отличие %.2e от масштаба массива (допуск %.0e)" % [worst, TOL])
	return ok


# ---------------------------------------------------------------- запись


func _put(buf: PackedByteArray, arrays: Dictionary, key: String, bytes: PackedByteArray, dtype: String, count: int) -> void:
	arrays[key] = {dtype = dtype, offset = buf.size(), count = count}
	buf.append_array(bytes)


func _write_atomic(path: String, data: PackedByteArray) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("не открыт " + tmp)
		return false
	f.store_buffer(data)
	f.close()
	return DirAccess.rename_absolute(tmp, path) == OK
