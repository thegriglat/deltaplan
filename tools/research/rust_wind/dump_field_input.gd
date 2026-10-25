extends Node
## RW-6b: эталонный дамп входа области Пикара (GDScript: AirPlace) для сверки с Rust
## (rust/dp-air/src/field/place_input.rs, тест tests/field_input.rs).
##
## Читает ТЕ ЖЕ растры, что крейт: фикстуры места tests/fixtures/wind/places/<имя>.json+.bin
## (высоты после int16-шкалы, water, cls, moist). Из них строит HeightLayer и AirPlace.Surface и
## считает вход функциями игры: block_mean, cell_surface, cell_z0, day/gamma, AirCase.set_zi_terrain.
## У Онгудая (область 38,4 км) результат ещё сверяется с AirPlace.domain_case.
## У синтетики растр 20 км — область L = 14,4 км вокруг начала координат (domain_case с DOMAIN_L не годится).
##
##   tools/research/rust_wind/dump_field_input.sh [--verify]    # под .dpcli/dpcli lock cpu
##
## Выход <out>/<место>_<dx>.json + .bin: массивы подряд в .bin (LE), в json — arrays{имя: {dtype, offset,
## count}} (offset — в байтах); числа json — Godot JSON.stringify; точные f64 дня — в массиве "scal".

const PLACES := {"ongudai": 38400.0, "synthetic": 14400.0}
const DXS := [400.0, 1200.0]
## Варианты погоды дня: час, облачность (t_max — обычный для даты).
const VARIANTS := [[13.0, "clear"], [8.0, "overcast"]]
const FIX := "res://tests/fixtures/wind/places/"


func _ready() -> void:
	var out_dir := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).substr(6)
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://rust/dp-air/tests/data/field_input")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var ok := true
	for pname in PLACES:
		ok = _place(pname, float(PLACES[pname]), out_dir) and ok
	get_tree().quit(0 if ok else 1)


func _place(pname: String, dom_l: float, out_dir: String) -> bool:
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
	var loc: Dictionary = hdr.loc
	var ok := true
	for dx: float in DXS:
		ok = _dump_one(pname, dom_l, dx, detail, wimg, loc, sf, out_dir) and ok
	return ok


func _dump_one(
	pname: String, dom_l: float, dx: float, detail: HeightLayer, wimg: Image, loc: Dictionary,
	sf: AirPlace.Surface, out_dir: String
) -> bool:
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
	var t_max := WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg, ctx)
	var cells := AirPlace.cell_surface(sf, wimg, detail, x0, y0, dx, nn, nn)
	var z0 := AirPlace.cell_z0(cells)
	var wf := AirPlace.water_fraction(wimg, detail, x0, y0, dx, nn, nn)
	var scfg := SurfaceHeat.config()
	var classes: Dictionary = scfg.classes
	var z0_cls := PackedFloat64Array()
	for k in SurfaceLayer.CLASS_COUNT:
		z0_cls.append(float(classes[SurfaceLayer.CLASS_NAMES[k]].z0_m))
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})

	var buf := PackedByteArray()
	var arrays := {}
	_put(buf, arrays, "hc", hc.to_byte_array(), "f64", hc.size())
	_put(buf, arrays, "z0_map", z0.to_byte_array(), "f64", z0.size())
	_put(buf, arrays, "cell_fr", cells.fr.to_byte_array(), "f32", cells.fr.size())
	_put(buf, arrays, "cell_m", cells.m.to_byte_array(), "f32", cells.m.size())
	_put(buf, arrays, "water_fraction", wf.to_byte_array(), "f64", wf.size())
	var scal := PackedFloat64Array()
	var variants := []
	for vr: Array in VARIANTS:
		var hour := float(vr[0])
		var sky := String(vr[1])
		var d := AirPlace.day(ctx, hour, t_max, sky, cfg)
		var c := AirCase.new()
		c.set_grid(dx, nn, nn, dz, zb, nz, x0, y0)
		c.hc = hc
		c.z_i = d.z_i
		c.set_zi_terrain(float(ctx.get("valley_msl_m", 0.0)))
		c.gam.resize(nz + 2)
		for k in nz + 2:
			c.gam[k] = AirPlace.gamma(d, c.zc(k))
		var cap_inf: bool = is_inf(d.cap)
		var si := scal.size()
		scal.append_array(
			PackedFloat64Array([
				d.t, 0.0 if cap_inf else d.cap, float(ctx.valley_msl_m), d.t_u, d.z_u, d.gam, d.t_min,
				d.t_res, d.t_full, d.dep, float(cfg.get("parcel_excess_k", 1.0)), d.theta_s, d.z_i
			])
		)
		var tag := "%s_%s" % [str(hour), sky]
		_put(buf, arrays, "gam_" + tag, c.gam.to_byte_array(), "f64", c.gam.size())
		_put(buf, arrays, "z_i_col_" + tag, c.z_i_col.to_byte_array(), "f32", c.z_i_col.size())
		variants.append({tag = tag, hour = hour, sky = sky, scal = si, cap_inf = cap_inf})
		# Онгудай: вход тем же кодом, что игра (domain_case), побитно
		if pname == "ongudai" and dom_l == AirPlace.DOMAIN_L and tag == "13.0_clear":
			var dc := AirPlace.domain_case(
				detail, wimg, loc, dx, hour, 3.0, 150.0, NAN, sky, false, 1.0, sf
			)
			if (
				dc == null or dc.hc != hc or dc.gam != c.gam or dc.z_i != c.z_i
				or dc.z_i_col != c.z_i_col or dc.z0_map != z0 or dc.nz != nz or dc.z_bot != zb
			):
				push_error("domain_case расходится с разбором дампера: %s %s" % [pname, dx])
				return false
	_put(buf, arrays, "scal", scal.to_byte_array(), "f64", scal.size())
	var meta := {
		version = 1, place = pname, dx = dx, l = dom_l, nx = nn, ny = nn, nz = nz, dz = dz,
		z_bot = zb, x0 = x0, y0 = y0, class_count = SurfaceLayer.CLASS_COUNT,
		cfg = {
			zi_alpha = float(ac.get("zi_terrain_alpha", 0.0)),
			zi_smooth_m = float(ac.get("zi_terrain_smooth_m", 5000.0)),
			zi_min = 300.0,
			m_norm = float(scfg.get("moisture", {}).get("m_norm", 0.5)),
			z0_m = Array(z0_cls),
		},
		scal_fields = [
			"t", "cap", "valley_msl_m", "t_u", "z_u_km", "gam_u", "t_min", "t_res", "t_full", "dep_km",
			"parcel_excess_k", "theta_s", "z_i"
		],
		variants = variants,
		arrays = arrays,
	}
	var base := "%s/%s_%d" % [out_dir, pname, roundi(dx)]
	return _write_atomic(base + ".bin", buf) and _write_atomic(
		base + ".json", (JSON.stringify(meta, "\t", true) + "\n").to_utf8_buffer()
	)


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
