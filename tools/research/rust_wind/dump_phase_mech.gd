extends Node
## RW-6l: эталонный дамп механизмов A (линейная теория), B (пузырь срыва), D (слои Лапласа), H
## (через D) — GDScript AirPhaseCpu.{synth, laplace, mech} — для сверки с Rust
## (rust/dp-air/src/field/phase/{linear,bubble,layers,calm,mech}.rs, тест tests/phase_mech.rs).
##
## Случаи — те же, что в dump_phase.gd (RW-6k; входы тест берёт оттуда по тегу): фикстуры места
## (полдень; вечер — тот же механизм), U10 0,3 / 1,5 / 6 / 12 м/с, и синтетика test_air_phase.gd.
## На случай: поля механизмов в точках (каждый MECH_STRIDE-й столбец и все столбцы под огибающей срыва (h_eff − h_c > 1 м) × MECH_HEIGHTS + высота
## H_c − 20 м) — 10 чисел AirPhaseCpu.mech; для "synthetic" (12 × 12) и t_contract целиком: моды,
## слой возмущений A (synth), слои Лапласа (laplace).
##
##   tools/research/rust_wind/dump_phase_mech.sh [--verify]    # под .dpcli/dpcli lock cpu
##
## Выход <out>/phase_mech.json + phase_mech.bin: массивы подряд (LE) в .bin, в json — arrays{имя:
## {dtype, offset, count}}.

const T := preload("res://tests/atmosphere/test_air_phase.gd")
const FIX := "res://tests/fixtures/wind/places/"
## Место → (сторона области, м; dx, м). Онгудай — 2400 м: дамп ≤ 3 МБ (16 × 16 клеток).
const PLACES := {"synthetic": [14400.0, 1200.0], "ongudai": [38400.0, 2400.0]}
const U10S := [0.3, 1.5, 6.0, 12.0]
const HOURS := [[13.0, "noon"]]
const WDIR := 225.0
const ENV_ANGLE := 1.0
const MECH_STRIDE := 3
const MECH_HEIGHTS := [0.5, 3.0, 10.0, 30.0, 60.0, 120.0, 400.0, 1200.0]
const FULL_TAGS := ["synthetic_noon_u0.3", "synthetic_noon_u1.5", "synthetic_noon_u6.0", "synthetic_noon_u12.0", "t_contract"]
var _buf := PackedByteArray()
var _arrays := {}
var _cases := []


func _ready() -> void:
	var out_dir := ProjectSettings.globalize_path("res://rust/dp-air/tests/data/phase_mech")
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := true
	for pname in PLACES:
		ok = _place(pname, float(PLACES[pname][0]), float(PLACES[pname][1])) and ok
	ok = _synth_cases() and ok
	var meta := {version = 1, sor_iters = int(AirPhase.cv(AirPhase.config(), "d", "sor_iters")), stride = MECH_STRIDE, heights = MECH_HEIGHTS, cases = _cases, arrays = _arrays}
	ok = ok and _write_atomic(out_dir + "/phase_mech.bin", _buf)
	ok = ok and _write_atomic(out_dir + "/phase_mech.json", (JSON.stringify(meta, "\t", true) + "\n").to_utf8_buffer())
	print("dump_phase_mech: %d случаев, %d байт" % [_cases.size(), _buf.size()])
	get_tree().quit(0 if ok else 1)


func _place(pname: String, dom_l: float, dx: float) -> bool:
	var hdr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + pname + ".json"))
	var bin := FileAccess.get_file_as_bytes(FIX + pname + ".bin")
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
	var moist := PackedFloat32Array()
	moist.resize(n)
	for q in n:
		moist[q] = bin[4 * n + q] / 255.0
	var detail := HeightLayer.from_heights(pname, w, h, float(g.spacing), float(g.origin_x), float(g.origin_z), heights)
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
	var nn := roundi(dom_l / dx)
	var x0 := -dom_l / 2.0
	var hc := AirPlace.block_mean(detail, x0, x0, dx, nn, nn)
	if hc.is_empty():
		push_error("block_mean пуст: " + pname)
		return false
	var dz := 105.0
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
	var t_max := WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg, ctx)
	var cells := AirPlace.cell_surface(sf, wimg, detail, x0, x0, dx, nn, nn)
	var z0 := AirPlace.cell_z0(cells)
	var pcfg := AirPhase.config()
	for hr: Array in HOURS:
		var d := AirPlace.day(ctx, float(hr[0]), t_max, "clear", cfg)
		for u10: float in U10S:
			var c := AirCase.new()
			c.set_grid(dx, nn, nn, dz, zb, nz, x0, x0)
			c.hc = hc
			c.wdir = WDIR
			c.z_i = d.z_i
			c.set_zi_terrain(float(ctx.get("valley_msl_m", 0.0)))
			c.set_z0_map(z0)
			c.set_inflow(u10, 1.0, ctx, float(hr[0]), float(d.cover))
			c.gam.resize(nz + 2)
			for k in nz + 2:
				c.gam[k] = AirPlace.gamma(d, c.zc(k))
			c.heat = AirPlace.surface_flux(hc, dx, nn, nn, d, ctx, cfg, cells, u10, t_max)
			if not _case("%s_%s_u%s" % [pname, hr[1], str(u10)], c, pcfg):
				return false
	return true


func _synth_cases() -> bool:
	var pcfg := AirPhase.config()
	var rows := [
		["ax_u0.3", 500.0, 0.3, 0.0, 0.0, 0.01, 270.0],
		["ax_u1.5", 500.0, 1.5, 0.0, 0.0, 0.01, 270.0],
		["ax_u12", 500.0, 12.0, 0.0, 0.0, 0.01, 270.0],
		["contract", 400.0, 4.0, 150.0, 1200.0, 0.01, 270.0],
		["fconv", 150.0, 1.2, 250.0, 1500.0, 0.003, 270.0],
		["gvalley", -400.0, 0.5, -40.0, 0.0, 0.02, 270.0],
		["hstat", 300.0, 0.3, 0.0, 0.0, 0.01, 270.0],
		["det", 400.0, 3.0, 120.0, 1000.0, 0.01, 200.0],
	]
	for r: Array in rows:
		var c := T.make_case(float(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5]), float(r[6]))
		if not _case("t_" + String(r[0]), c, pcfg, String(r[0]) == "contract"):
			return false
	# крутая огибающая срыва (угол 1° вместо 12°): под ней много клеток — пузырь B участвует в сверке
	var env_cfg := pcfg.duplicate(true)
	env_cfg.classifier.b_env_angle_deg = ENV_ANGLE
	var ce := T.make_case(400.0, 4.0, 150.0, 1200.0, 0.01, 270.0)
	if not _case("t_contract_env", ce, env_cfg):
		return false
	return true


func _case(tag: String, c: AirCase, cfg: Dictionary, _planes := true) -> bool:
	var p := AirPhase.prepare(c, cfg)
	if p.has("error"):
		push_error("prepare: " + String(p.error))
		return false
	var n2: int = p.n2
	var a: PackedFloat32Array = p.prm
	var sl := AirPhaseCpu.synth(p)
	var lap := AirPhaseCpu.laplace(p)
	var col: PackedFloat64Array = p.col
	var out := PackedFloat64Array()
	var ncol := 0
	for ci in n2:
		var hc := col[AirPhase.CI_HC * n2 + ci]
		if ci % MECH_STRIDE != 0 and col[AirPhase.CI_HEFF * n2 + ci] - hc <= 1.0:
			continue
		ncol += 1
		var zs := []
		for h: float in MECH_HEIGHTS:
			zs.append(hc + h)
		zs.append(p.hcd - 20.0)
		for z: float in zs:
			out.append_array(AirPhaseCpu.mech(p, a, sl, lap, ci, z))
	_put(tag + "/mech", out.to_byte_array(), "f64", out.size())
	if tag in FULL_TAGS:
		_put(tag + "/modes", (p.modes as PackedFloat64Array).to_byte_array(), "f64", p.modes.size())
		_put(tag + "/slab", sl.to_byte_array(), "f64", sl.size())
		_put(tag + "/lap", lap.to_byte_array(), "f64", lap.size())
	_cases.append({tag = tag})
	print("dump_phase_mech: %s Fr %.2f nl %d hcd %.0f нlev %d" % [tag, p.fr, p.zl.size(), p.hcd, p.lev.size()])
	return true


func _put(key: String, bytes: PackedByteArray, dtype: String, count: int) -> void:
	_arrays[key] = {dtype = dtype, offset = _buf.size(), count = count}
	_buf.append_array(bytes)


func _write_atomic(path: String, data: PackedByteArray) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("не открыт " + tmp)
		return false
	f.store_buffer(data)
	f.close()
	return DirAccess.rename_absolute(tmp, path) == OK
