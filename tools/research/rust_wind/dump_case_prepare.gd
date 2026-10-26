extends Node
## RW-6d: эталонный дамп случая области и плоскостей AirCase.prepare (col/lev/prm, kf, число
## неизвестных, скаляры замыкания) для сверки с Rust (rust/dp-air/src/field/case_prepare.rs,
## тест tests/case_prepare.rs).
##
## Растры — ТЕ ЖЕ, что у крейта: фикстуры места tests/fixtures/wind/places/<имя>.json+.bin.
## Случай собирается шагами AirPlace.domain_case (область L из PLACES: у Онгудая 38,4 км — для
## первого сценария результат ещё сверяется с самим domain_case; растр синтетики 20 км —
## область 14,4 км) и AirCase.set_zi_terrain/set_z0_map/set_inflow; нагрев — surface_flux.
## Ветер, час, небо и t_max — из tests/fixtures/wind/cases/<основа>.json (extra.field_conditions).
## Для каждого сценария, dx (400, 1200 м), режима (heat / mech = without_heat) и k (1; 0,6) —
## prepare(); дамп col/lev/prm целиком (если мало) либо хеш FNV-1a 64 по словам u32.
##
##   tools/research/rust_wind/dump_case_prepare.sh [--verify]    # под .dpcli/dpcli lock cpu
##
## Выход <out>/<место>_<dx>.json + .bin: массивы подряд в .bin (LE); в json — arrays{имя: {dtype,
## offset (байт), count}}, сценарии (условия W5, климат, входы случая) и наборы (плоскости).

const PLACES := {
	"ongudai":
	{
		l = 38400.0,
		scenarios =
		[
			{base = "ongudai_medium", hour = 13.0, sky = "clear", u10 = -1.0},
			{base = "ongudai_strong", hour = 21.0, sky = "partly", u10 = -1.0},
		]
	},
	"synthetic":
	{
		l = 14400.0,
		scenarios =
		[
			{base = "synth_medium", hour = 13.0, sky = "clear", u10 = -1.0},
			{base = "synth_strong", hour = 21.0, sky = "partly", u10 = -1.0},
			{base = "synth_medium", hour = 13.0, sky = "clear", u10 = 0.0},
		]
	},
}
const DXS := [400.0, 1200.0]
const KS := [1.0, 0.6]
## Плоскости целиком — если col не больше этого, байт; иначе только для первого сценария heat k = 1.
const FULL_MAX_COL_BYTES := 100000
const FIX := "res://tests/fixtures/wind/"


func _ready() -> void:
	var out_dir := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://rust/dp-air/tests/data/case_prepare")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := true
	for pname in PLACES:
		ok = _place(pname, out_dir) and ok
	get_tree().quit(0 if ok else 1)


func _place(pname: String, out_dir: String) -> bool:
	var hdr: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "places/" + pname + ".json"))
	var bin := FileAccess.get_file_as_bytes(FIX + "places/" + pname + ".bin")
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
		pname, w, h, float(g.spacing), float(g.origin_x), float(g.origin_z), heights
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
	var ok := true
	for dx: float in DXS:
		ok = _dump_one(pname, dx, detail, wimg, hdr.loc, sf, out_dir) and ok
	return ok


func _dump_one(
	pname: String, dx: float, detail: HeightLayer, wimg: Image, loc: Dictionary, sf: AirPlace.Surface,
	out_dir: String
) -> bool:
	var spec: Dictionary = PLACES[pname]
	var dom_l := float(spec.l)
	var nn := roundi(dom_l / dx)
	var x0 := -dom_l / 2.0
	var y0 := -dom_l / 2.0
	var hc := AirPlace.block_mean(detail, x0, y0, dx, nn, nn)
	if hc.is_empty():
		push_error("block_mean пуст: %s %s" % [pname, dx])
		return false
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
	var cells := AirPlace.cell_surface(sf, wimg, detail, x0, y0, dx, nn, nn)
	var z0 := AirPlace.cell_z0(cells)
	var wcfg: Dictionary = SurfaceHeat.config().get("water", {})

	var buf := PackedByteArray()
	var arrays := {}
	_put(buf, arrays, "hc", hc.to_byte_array(), "f64", hc.size())
	_put(buf, arrays, "z0_map", z0.to_byte_array(), "f64", z0.size())
	var scenarios := []
	var si := 0
	for sc: Dictionary in spec.scenarios:
		var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "cases/%s.json" % sc.base))
		var fc: Dictionary = base.extra.field_conditions
		var hour := float(sc.hour)
		var sky := String(sc.sky)
		var t_max := float(fc.t_max)
		var u10_raw := float(fc.u10) if float(sc.u10) < 0.0 else float(sc.u10)
		var kmh := u10_raw * 3.6
		var u10 := kmh / 3.6
		var wdir := float(fc.wdir)
		var d := AirPlace.day(ctx, hour, t_max, sky, cfg)
		var heat := AirPlace.surface_flux(hc, dx, nn, nn, d, ctx, cfg, cells, u10, t_max)
		var tag := "%s_h%02d_%s%s" % [String(sc.base), int(hour), sky, "_calm" if u10 == 0.0 else ""]
		var sets := []
		var first_gam := PackedFloat64Array()
		var first_zcol := PackedFloat32Array()
		var alpha := 0.0
		var maxp := 0.0
		for k: float in KS:
			var c := _case(hc, z0, heat, d, ctx, hour, u10, wdir, k, dx, nn, dz, zb, nz, x0, y0)
			if first_gam.is_empty():
				first_gam = c.gam
				first_zcol = c.z_i_col
				alpha = float(c.p.alpha)
				maxp = float(c.p.max_profile)
			for mode in ["heat", "mech"]:
				var cc: AirCase = c if mode == "heat" else c.without_heat()
				if not cc.prepare():
					push_error("prepare упал: %s %s %s" % [pname, dx, tag])
					return false
				var col_b := cc.col.to_byte_array()
				var full: bool = col_b.size() <= FULL_MAX_COL_BYTES or (si == 0 and mode == "heat" and k == 1.0)
				var rec := {
					mode = mode, k = k, full = full,
					hash_col = str(_fnv(col_b)), hash_lev = str(_fnv(cc.lev.to_byte_array())),
					hash_prm = str(_fnv(cc.prm.to_byte_array())),
					n_unk = Array(cc.n_unk), n_fluid = cc.n_fluid, cd = cc.cd, fixed_scale = cc.fixed_scale,
					ustar = cc.ustar, u_a = cc.u_a, ex = cc.ex, ey = cc.ey,
					h_mech = float(cc.closure_info.h_mech), wstar_max = float(cc.closure_info.wstar_max),
					h_max = float(cc.closure_info.h_max), z0 = float(cc.p.z0), alpha = float(cc.p.alpha),
					max_profile = float(cc.p.max_profile), u10 = cc.u10,
				}
				if full:
					var key := "%s_%s_k%d" % [tag, mode, roundi(k * 100.0)]
					_put(buf, arrays, "col_" + key, col_b, "f32", cc.col.size())
					_put(buf, arrays, "lev_" + key, cc.lev.to_byte_array(), "f32", cc.lev.size())
					_put(buf, arrays, "prm_" + key, cc.prm.to_byte_array(), "f32", cc.prm.size())
					rec.key = key
					_put(buf, arrays, "hused_" + key, cc.heat_used.to_byte_array(), "f64", cc.heat_used.size())
				sets.append(rec)
				# Онгудай, первый сценарий: те же плоскости из самого domain_case
				if pname == "ongudai" and si == 0 and mode == "heat" and k == 1.0:
					var dc := AirPlace.domain_case(
						detail, wimg, loc, dx, hour, u10, wdir, t_max, sky, true, 1.0, sf
					)
					if dc == null or not dc.prepare() or dc.col != cc.col or dc.lev != cc.lev or dc.prm != cc.prm:
						push_error("domain_case расходится со сборкой дампера: %s %s" % [pname, dx])
						return false
		_put(buf, arrays, "gam_" + tag, first_gam.to_byte_array(), "f64", first_gam.size())
		_put(buf, arrays, "z_i_col_" + tag, first_zcol.to_byte_array(), "f32", first_zcol.size())
		_put(buf, arrays, "heat_" + tag, heat.to_byte_array(), "f64", heat.size())
		scenarios.append({
			tag = tag, hour = hour, sky = sky, t_max = t_max, u10 = u10, wdir = wdir, z_i = d.z_i,
			alpha = alpha, max_profile = maxp,
			conditions = {
				forecast = {temperature_c = t_max, wind_speed_kmh = kmh, wind_from_deg = wdir, sky = sky},
				start_hour = hour, speed = 1.0, quantum_h = 0.5,
			},
			climate = _climate(ctx, wcfg), sets = sets,
		})
		si += 1
	var meta := {
		version = 1, place = pname, dx = dx, l = dom_l, nx = nn, ny = nn, nz = nz, dz = dz,
		z_bot = zb, x0 = x0, y0 = y0, ks = KS, scenarios = scenarios, arrays = arrays,
	}
	var base_path := "%s/%s_%d" % [out_dir, pname, roundi(dx)]
	return _write_atomic(base_path + ".bin", buf) and _write_atomic(
		base_path + ".json", (JSON.stringify(meta, "\t", true, true) + "\n").to_utf8_buffer()
	)


## Случай области теми же шагами, что AirPlace.domain_case (L другой у синтетики).
func _case(
	hc: PackedFloat64Array, z0: PackedFloat64Array, heat: PackedFloat64Array, d: Dictionary,
	ctx: Dictionary, hour: float, u10: float, wdir: float, k: float, dx: float, nn: int, dz: float,
	zb: float, nz: int, x0: float, y0: float
) -> AirCase:
	var c := AirCase.new()
	c.set_grid(dx, nn, nn, dz, zb, nz, x0, y0)
	c.hc = hc
	c.wdir = wdir
	c.z_i = d.z_i
	c.set_zi_terrain(float(ctx.get("valley_msl_m", 0.0)))
	c.set_z0_map(z0)
	c.set_inflow(u10, k, ctx, hour, float(d.cover))
	c.gam.resize(nz + 2)
	for kk in nz + 2:
		c.gam[kk] = AirPlace.gamma(d, c.zc(kk))
	c.heat = heat
	return c


## FNV-1a 64 по словам u32 (целочисленное переполнение GDScript — по модулю 2^64).
func _fnv(b: PackedByteArray) -> int:
	var h := -3750763034362895579  # 0xcbf29ce484222325
	for i in range(0, b.size(), 4):
		h = (h ^ b.decode_u32(i)) * 1099511628211
	return h


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
