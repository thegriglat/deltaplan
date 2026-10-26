extends Node
## RW-6k: эталонный дамп фаз поля (GDScript: AirPhase.prepare + классификатор AirPhaseCpu) для
## сверки с Rust (rust/dp-air/src/field/phase/, тест tests/phase_classifier.rs).
##
## Случаи: (1) растры фикстур места tests/fixtures/wind/places/<имя>.{json,bin} (synthetic, ongudai),
## dx = 1200 м, U10 0,3 / 1,5 / 6 / 12 м/с, полдень и вечер, нагрев и облачность как в игре
## (AirPlace.cell_surface/surface_flux, AirCase.set_inflow); (2) случаи tests/atmosphere/test_air_phase.gd
## (синтетические холм/долина 24 × 24, make_case) — для утверждений теста. На каждый случай:
## вход prepare (то, что даёт AirCase: u_a, ex, ey, h_bl, w*, heat, z_i по столбцам, вес G) и
## результат — числа prepare, плоскости, веса обоих вариантов (после сглаживания, Σ = 1), маски заморозки.
##
##   tools/research/rust_wind/dump_phase.sh [--verify]    # под .dpcli/dpcli lock cpu
##
## Выход <out>/phase.json + phase.bin: массивы подряд (LE) в .bin, в json — arrays{имя: {dtype, offset,
## count}} (offset — в байтах); точные f64 скаляров — массив "<tag>/scal" (имена — scal_fields).

const T := preload("res://tests/atmosphere/test_air_phase.gd")
const FIX := "res://tests/fixtures/wind/places/"
## Место → (сторона области, м; dx, м). Онгудай — 2400 м: дамп ≤ 3 МБ (16 × 16 клеток).
const PLACES := {"synthetic": [14400.0, 1200.0], "ongudai": [38400.0, 2400.0]}
const U10S := [0.3, 1.5, 6.0, 12.0]
const HOURS := [[13.0, "noon"], [21.5, "eve"]]
const WDIR := 225.0
const SCAL_FIELDS := [
	"nx", "ny", "nz", "dx", "dz", "z_bot", "ex", "ey", "usat", "zsat", "alpha", "z0", "ustar", "tau", "u10",
	"z_i", "g_active", "g_dth_c", "heated", "n_bv", "fr", "n_eff", "zi", "gamw", "zi_agl", "hcd", "base", "nl",
	"b_fr", "b_u", "omega", "w_h", "w_ds", "w_d", "full", "u_over_n", "shadow_frac", "relief", "hmin", "mean_heat",
]

var _buf := PackedByteArray()
var _arrays := {}
var _cases := []


func _ready() -> void:
	var out_dir := ProjectSettings.globalize_path("res://rust/dp-air/tests/data/phase")
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := true
	for pname in PLACES:
		ok = _place(pname, float(PLACES[pname][0]), float(PLACES[pname][1])) and ok
	ok = _synth_cases() and ok
	var meta := {version = 1, scal_fields = SCAL_FIELDS, k = AirPhase.K, cases = _cases, arrays = _arrays}
	ok = ok and _write_atomic(out_dir + "/phase.bin", _buf)
	ok = ok and _write_atomic(out_dir + "/phase.json", (JSON.stringify(meta, "\t", true) + "\n").to_utf8_buffer())
	print("dump_phase: %d случаев, %d байт" % [_cases.size(), _buf.size()])
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
	return true


func _case(tag: String, c: AirCase, cfg: Dictionary, planes := true) -> bool:
	var p := AirPhase.prepare(c, cfg)
	if p.has("error"):
		push_error("prepare: " + String(p.error))
		return false
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var fin := []
	var frz := []
	for v in 2:
		fin.append(AirPhaseCpu.smooth(p, AirPhaseCpu.classify(p, v)))
		frz.append(AirPhaseCpu.finalize(p, v, fin[v]))
	var mh := 0.0
	for v in c.heat:
		mh += v / n2
	var sv := {
		nx = p.nx, ny = p.ny, nz = p.nz, dx = p.dx, dz = p.dz, z_bot = p.z_bot, ex = p.ex, ey = p.ey,
		usat = p.usat, zsat = p.zsat, alpha = p.alpha, z0 = p.z0, ustar = p.ustar, tau = p.tau, u10 = p.u10,
		z_i = c.z_i, g_active = 1.0 if p.g.active else 0.0, g_dth_c = p.g.get("dth_c", 0.0),
		heated = 1.0 if p.heated else 0.0, n_bv = p.n_bv, fr = p.fr, n_eff = p.n_eff, zi = p.zi,
		gamw = p.gamw, zi_agl = p.zi_agl, hcd = p.hcd, base = p.base, nl = p.zl.size(), b_fr = p.b_fr,
		b_u = p.b_u, omega = p.omega, w_h = p.w_h, w_ds = p.w_ds, w_d = p.w_d,
		full = 1.0 if p.full else 0.0, u_over_n = p.u_over_n, shadow_frac = p.shadow_frac,
		relief = p.relief, hmin = p.hmin, mean_heat = mh,
	}
	var scal := PackedFloat64Array()
	for k in SCAL_FIELDS:
		scal.append(float(sv[k]))
	_put(tag + "/scal", scal.to_byte_array(), "f64", scal.size())
	var zic := PackedFloat64Array()
	for q in n2:
		zic.append(c.z_i_of(q))
	_put(tag + "/hc", c.hc.to_byte_array(), "f64", n2)
	_put(tag + "/gam", c.gam.to_byte_array(), "f64", c.gam.size())
	_put(tag + "/heat", c.heat.to_byte_array(), "f64", c.heat.size())
	_put(tag + "/heat_used", c.heat_used.to_byte_array(), "f64", c.heat_used.size())
	_put(tag + "/h_bl", c.h_bl.to_byte_array(), "f64", c.h_bl.size())
	_put(tag + "/wst", c._wst.to_byte_array(), "f64", c._wst.size())
	_put(tag + "/zic", zic.to_byte_array(), "f64", n2)
	_put(tag + "/zl", p.zl.to_byte_array(), "f64", p.zl.size())
	_put(tag + "/gw", col.slice(AirPhase.CI_GW * n2, (AirPhase.CI_GW + 1) * n2).to_byte_array(), "f64", n2)
	for name: String in [] if not planes else ["HEFF", "T", "S", "GX", "GY", "SAL", "ZI", "HEAT", "HK"]:
		var ci := _ci(name)
		_put(tag + "/col_" + name.to_lower(), col.slice(ci * n2, (ci + 1) * n2).to_byte_array(), "f64", n2)
	_put(tag + "/w_h", (fin[1] as PackedFloat64Array).to_byte_array(), "f64", fin[1].size())
	_put(tag + "/w_m", (fin[0] as PackedFloat64Array).to_byte_array(), "f64", fin[0].size())
	_put(tag + "/frz_h", frz[1], "u8", n2)
	_put(tag + "/frz_m", frz[0], "u8", n2)
	_cases.append({tag = tag})
	print("dump_phase: %s Fr %.2f ω %.2f heated %s G %s mean_heat %.1f frozen_h %d" % [
		tag, p.fr, p.omega, p.heated, p.g.active, mh, _count(frz[1])
	])
	return true


func _count(b: PackedByteArray) -> int:
	var s := 0
	for v in b:
		s += v
	return s


func _ci(name: String) -> int:
	return {
		"HEFF": AirPhase.CI_HEFF, "T": AirPhase.CI_T, "S": AirPhase.CI_S, "GX": AirPhase.CI_GX,
		"GY": AirPhase.CI_GY, "SAL": AirPhase.CI_SAL, "ZI": AirPhase.CI_ZI, "HEAT": AirPhase.CI_HEAT,
		"HK": AirPhase.CI_HK,
	}[name]


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
