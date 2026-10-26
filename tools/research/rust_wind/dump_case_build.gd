extends Node
## RW-6e: эталонный дамп буферов игры после K_SETUP (air_picard.glsl:K_SETUP) для сверки с
## Rust (rust/dp-air/src/field/case_build.rs, тест tests/case_build.rs).
##
## Нужен настоящий RenderingDevice (не headless): tools/research/rust_wind/dump_case_build.sh.
## Случаи собираются теми же шагами, что в dump_case_prepare.gd (его функции берутся из
## экземпляра скрипта): Онгудай 400 м (heat, mech) — выход выборкой с шагом STRIDE + хеш FNV-1a
## всего буфера; синтетика 1200 м (heat, mech, штиль) — выход целиком. Вход ядра — col/lev/prm
## случая после prepare() — кладётся рядом (f32), чтобы Rust собрал PreparedPlanes без цепочки.
## Для каждого случая: AirPicardJob.start() выполняет подготовку и K_SETUP, буферы читаются
## после submit/sync.
##
## Выход <out>/build.json + build.bin (как у dump_case_prepare: arrays{имя: {dtype, offset, count}}).

const CP := preload("res://tools/research/rust_wind/dump_case_prepare.gd")
const FIX := "res://tests/fixtures/wind/"
const STRIDE := 101
const OUT_BUFS := ["tcode", "ubu", "ubv", "spu", "spw", "spc", "kbg", "Q", "Kx", "Ky", "Kz"]
## Растр места, сторона области, dx, сценарий, штиль (u10 = 0), режимы, выход целиком.
const SPECS := [
	{place = "ongudai", l = 38400.0, dx = 400.0, base = "ongudai_medium", hour = 13.0, sky = "clear", u10 = -1.0, modes = ["heat", "mech"], full = false},
	{place = "synthetic", l = 14400.0, dx = 1200.0, base = "synth_medium", hour = 13.0, sky = "clear", u10 = -1.0, modes = ["heat", "mech"], full = true},
	{place = "synthetic", l = 14400.0, dx = 1200.0, base = "synth_medium", hour = 13.0, sky = "clear", u10 = 0.0, modes = ["heat"], full = true},
]

var _cp: Node


func _ready() -> void:
	var out_dir := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://rust/dp-air/tests/data/case_build")
	DirAccess.make_dir_recursive_absolute(out_dir)
	_cp = CP.new()
	var buf := PackedByteArray()
	var arrays := {}
	var cases := []
	var ok := true
	for spec: Dictionary in SPECS:
		ok = _spec(spec, buf, arrays, cases) and ok
	var meta := {version = 1, stride = STRIDE, out_bufs = OUT_BUFS, cases = cases, arrays = arrays}
	ok = (
		ok
		and _cp._write_atomic(out_dir + "/build.bin", buf)
		and _cp._write_atomic(out_dir + "/build.json", (JSON.stringify(meta, "\t", true, true) + "\n").to_utf8_buffer())
	)
	_cp.free()
	get_tree().quit(0 if ok else 1)


func _spec(spec: Dictionary, buf: PackedByteArray, arrays: Dictionary, cases: Array) -> bool:
	var pname: String = spec.place
	var dx: float = spec.dx
	var hdr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "places/" + pname + ".json"))
	var bin := FileAccess.get_file_as_bytes(FIX + "places/" + pname + ".bin")
	var g: Dictionary = hdr.grid
	var w := int(g.width)
	var h := int(g.height)
	var n := w * h
	var heights := PackedFloat32Array()
	heights.resize(n)
	for q in n:
		heights[q] = float(hdr.h_offset) + bin.decode_s16(2 * q) * float(hdr.h_scale)
	var water_u8 := bin.slice(2 * n, 3 * n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for q in n:
		moist[q] = bin[4 * n + q] / 255.0
	var detail := HeightLayer.from_heights(
		pname, w, h, float(g.spacing), float(g.origin_x), float(g.origin_z), heights
	)
	var sf := AirPlace.Surface.new()
	sf.origin_x = float(g.origin_x)
	sf.origin_z = float(g.origin_z)
	sf.width = w
	sf.height = h
	sf.cls = bin.slice(3 * n, 4 * n)
	sf.moist = moist
	var wbytes := PackedByteArray()
	wbytes.resize(n)
	for q in n:
		wbytes[q] = 255 if water_u8[q] > 0 else 0
	var wimg := Image.create_from_data(w, h, false, Image.FORMAT_L8, wbytes)
	var loc: Dictionary = hdr.loc

	var dom_l: float = spec.l
	var nn := roundi(dom_l / dx)
	var x0 := -dom_l / 2.0
	var hc := AirPlace.block_mean(detail, x0, x0, dx, nn, nn)
	var dz := 105.0 if dx >= 200.0 else dx / 2.0
	var lo := INF
	var hi := -INF
	for v in hc:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var zb := floorf(lo / dz) * dz - dz
	var nz := ceili((hi + AirPlace.TOP_ABOVE - zb) / dz)
	nz += nz % 2
	var cfg := WeatherModel.config()
	var ctx := AirPlace.context(detail, loc, cfg)
	var cells := AirPlace.cell_surface(sf, wimg, detail, x0, x0, dx, nn, nn)
	var z0 := AirPlace.cell_z0(cells)

	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "cases/%s.json" % spec.base))
	var fc: Dictionary = base.extra.field_conditions
	var hour := float(spec.hour)
	var t_max := float(fc.t_max)
	var u10 := float(fc.u10) if float(spec.u10) < 0.0 else float(spec.u10)
	var wdir := float(fc.wdir)
	var d := AirPlace.day(ctx, hour, t_max, String(spec.sky), cfg)
	var heat := AirPlace.surface_flux(hc, dx, nn, nn, d, ctx, cfg, cells, u10, t_max)
	var c: AirCase = _cp._case(hc, z0, heat, d, ctx, hour, u10, wdir, 1.0, dx, nn, dz, zb, nz, x0, x0)
	for mode: String in spec.modes:
		var cc: AirCase = c if mode == "heat" else c.without_heat()
		var tag := "%s_%d_%s%s" % [pname, roundi(dx), mode, "_calm" if u10 == 0.0 else ""]
		if not _one(tag, cc, bool(spec.full), buf, arrays, cases, pname, dx, u10):
			return false
	return true


func _one(
	tag: String, cc: AirCase, full: bool, buf: PackedByteArray, arrays: Dictionary, cases: Array,
	pname: String, dx: float, u10: float
) -> bool:
	var job := AirPicardJob.new()
	job.case = cc
	job.mech = false
	if not job.start():
		push_error("AirPicardJob.start: %s (%s)" % [job.error, tag])
		return false
	job.gpu.submit()
	job.gpu.sync()
	var hashes := {}
	for nm: String in OUT_BUFS:
		var a: PackedFloat32Array = job.gpu.download(job.buf[nm])
		if a.size() != job._n:
			push_error("размер буфера %s: %d != %d (%s)" % [nm, a.size(), job._n, tag])
			return false
		hashes[nm] = str(_cp._fnv(a.to_byte_array()))
		if full:
			_cp._put(buf, arrays, "%s/%s" % [tag, nm], a.to_byte_array(), "f32", a.size())
		else:
			var s := PackedFloat32Array()
			for q in range(0, a.size(), STRIDE):
				s.append(a[q])
			_cp._put(buf, arrays, "%s/%s" % [tag, nm], s.to_byte_array(), "f32", s.size())
	job.release()
	# вход ядра — как загружено на GPU
	_cp._put(buf, arrays, "%s/col" % tag, cc.col.to_byte_array(), "f32", cc.col.size())
	_cp._put(buf, arrays, "%s/lev" % tag, cc.lev.to_byte_array(), "f32", cc.lev.size())
	_cp._put(buf, arrays, "%s/prm" % tag, cc.prm.to_byte_array(), "f32", cc.prm.size())
	cases.append({
		tag = tag, place = pname, dx = dx, full = full, u10 = u10,
		nx = cc.nx, ny = cc.ny, nz = cc.nz, dz = cc.dz, z_bot = cc.z_bot, x0 = cc.x0, y0 = cc.y0,
		cd = cc.cd, u_a = cc.u_a, z0 = float(cc.p.z0), hashes = hashes,
	})
	return true
