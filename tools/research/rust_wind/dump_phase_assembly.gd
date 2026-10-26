extends Node
## RW-6m: эталонный дамп фаз 3 — F (баланс θ′: скорость слоя перемешивания, θ′), G (сток: плоскости
## Прандтля/D8 и числа), тёплая сборка warm/mech_field(_mech) (центры → грани MAC), маска запасного
## пути и статистика — GDScript AirPhase.drainage/stats и AirPhaseCpu.{uml, theta, run_prepared} —
## для сверки с Rust (rust/dp-air/src/field/phase/{convection,drainage,assembly}.rs, тест
## tests/phase_assembly.rs).
##
## Случаи — те же, что в dump_phase.gd (RW-6k; входы тест берёт оттуда по тегу): фикстуры места
## (полдень и вечер — для G), U10 0,3 / 1,5 / 6 / 12 м/с, и синтетика test_air_phase.gd.
## На случай: числа стока (если G включён: плоскости CI_G* и diag), uml и θ′ (если есть нагрев),
## состояния warm (нагрев) и warm_mech (u, v, w, θ′ f32; каждое STRIDE-е значение, для FULL_TAGS —
## целиком), статистика, маска запасного пути.
##
##   tools/research/rust_wind/dump_phase_assembly.sh [--verify]    # под .dpcli/dpcli lock cpu
##
## Выход <out>/phase_assembly.json + phase_assembly.bin: массивы подряд (LE) в .bin, в json —
## arrays{имя: {dtype, offset, count}}.

const T := preload("res://tests/atmosphere/test_air_phase.gd")
const FIX := "res://tests/fixtures/wind/places/"
## Место → (сторона области, м; dx, м).
const PLACES := {"synthetic": [14400.0, 1200.0], "ongudai": [38400.0, 2400.0]}
const U10S := [0.3, 1.5, 6.0, 12.0]
const HOURS := [[13.0, "noon"], [21.5, "eve"]]
const WDIR := 225.0
const STRIDE := 7
const FULL_TAGS := ["t_gvalley"]
const STAT_FIELDS := [
	"fr", "n_bv", "u_over_n", "w_h_case", "w_d_strong", "w_d_case", "full_mech", "u_sat", "u10", "omega", "b_fr",
	"b_u", "frozen_frac", "frozen_frac_mech", "hc_dividing", "d_layers", "shadow_frac", "h_spread", "wstar_max",
	"wstar_f", "zi_agl",
]
const G_FIELDS := [
	"dth_c", "heat_mean", "umax_med", "l_med", "layer_frac", "d_layer_med", "uc_layer_med", "w_mean", "w_ge_frac",
]
const G_PLANES := ["GL", "GDTH", "GUS", "GON", "GLAY", "GD", "GUC", "GDX", "GDY", "GW"]
const G_CI := [
	AirPhase.CI_GL, AirPhase.CI_GDTH, AirPhase.CI_GUS, AirPhase.CI_GON, AirPhase.CI_GLAY, AirPhase.CI_GD,
	AirPhase.CI_GUC, AirPhase.CI_GDX, AirPhase.CI_GDY, AirPhase.CI_GW,
]
var _buf := PackedByteArray()
var _arrays := {}
var _cases := []


func _ready() -> void:
	var out_dir := ProjectSettings.globalize_path("res://rust/dp-air/tests/data/phase_assembly")
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := true
	for pname in PLACES:
		ok = _place(pname, float(PLACES[pname][0]), float(PLACES[pname][1])) and ok
	ok = _synth_cases() and ok
	var conv := PackedFloat64Array()
	for u: Dictionary in AirPhase.convection_profile(AirPhase.config()):
		conv.append_array(PackedFloat64Array([u.zr, u.sigma_w, u.w3, u.skew, u.a_up, u.w_up]))
	_put("convection", conv.to_byte_array(), "f64", conv.size())
	var meta := {
		version = 1, stride = STRIDE, stat_fields = STAT_FIELDS, g_fields = G_FIELDS, g_planes = G_PLANES,
		nonconv_mech_w = float(AirRuntime.phase_cfg("nonconv", "mech_w")), cases = _cases, arrays = _arrays,
	}
	ok = ok and _write_atomic(out_dir + "/phase_assembly.bin", _buf)
	ok = ok and _write_atomic(out_dir + "/phase_assembly.json", (JSON.stringify(meta, "\t", true) + "\n").to_utf8_buffer())
	print("dump_phase_assembly: %d случаев, %d байт" % [_cases.size(), _buf.size()])
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
		if not _case("t_" + String(r[0]), c, pcfg):
			return false
	return true


func _case(tag: String, c: AirCase, cfg: Dictionary) -> bool:
	var p := AirPhase.prepare(c, cfg)
	if p.has("error"):
		push_error("prepare: " + String(p.error))
		return false
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var g: Dictionary = p.g
	if g.active:
		var pl := PackedFloat64Array()
		for ci: int in G_CI:
			pl.append_array(col.slice(ci * n2, (ci + 1) * n2))
		_put(tag + "/g", pl.to_byte_array(), "f64", pl.size())
		var gd := PackedFloat64Array()
		for nm: String in G_FIELDS:
			gd.append(float(g[nm]))
		_put(tag + "/gdiag", gd.to_byte_array(), "f64", gd.size())
	var fin := []
	for v in 2:
		fin.append(AirPhaseCpu.smooth(p, AirPhaseCpu.classify(p, v)))
	var r := AirPhaseCpu.run_prepared(p)
	if p.heated:
		var um := AirPhaseCpu.uml(p, fin[AirPhase.V_H], AirPhaseCpu.synth(p), AirPhaseCpu.laplace(p))
		var th := AirPhaseCpu.theta(p, um)
		_put(tag + "/uml", um.to_byte_array(), "f64", n2)
		_put(tag + "/theta", th.to_byte_array(), "f64", n2)
	var full := tag in FULL_TAGS
	for pair: Array in [["h", r.warm], ["m", r.warm_mech]]:
		var st: Dictionary = pair[1]
		for nm: String in ["u", "v", "w", "th"]:
			var a: PackedFloat32Array = st[nm]
			var out := a
			if not full:
				out = PackedFloat32Array()
				for q in range(0, a.size(), STRIDE):
					out.append(a[q])
			_put("%s/warm_%s_%s" % [tag, pair[0], nm], out.to_byte_array(), "f32", out.size())
	var sv := PackedFloat64Array()
	for nm: String in STAT_FIELDS:
		sv.append(float(r.stats[nm]))
	for nm: String in AirPhase.PHASES:
		sv.append(float(r.stats.phase_frac[nm]))
	_put(tag + "/stats", sv.to_byte_array(), "f64", sv.size())
	var nc := AirRuntime.nonconv_mask(r, float(AirRuntime.phase_cfg("nonconv", "mech_w")))
	_put(tag + "/nonconv", nc, "u8", nc.size())
	_cases.append({tag = tag, g = bool(g.active)})
	print("dump_phase_assembly: %s Fr %.2f G %s heated %s N %d nonconv %d" % [tag, p.fr, g.active, p.heated, p.N, _count(nc)])
	return true


func _count(b: PackedByteArray) -> int:
	var s := 0
	for v in b:
		s += v
	return s


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
