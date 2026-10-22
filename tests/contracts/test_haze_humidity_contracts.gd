extends TestCase
## Контракты haze-humidity (docs/contracts/haze-humidity.md): версии в заголовках, формат сеток HH1 (точка росы)
## HH2 (воздух 700 гПа), HH5 (Tmax и суточная амплитуда), HH6 (ветер, тропопауза, перистые).

const DOC := "res://docs/contracts/haze-humidity.md"
const VERSIONS := {"HH1": 1, "HH2": 2, "HH3": 1, "HH4": 3, "HH5": 1, "HH6": 2, "HH7": 1}
const GRID := "res://data/climate/dew_point_1deg.bin"
const UPPER := "res://data/climate/upper_air_1deg.bin"
const SURFACE := "res://data/climate/surface_t_1deg.bin"
const MISC := "res://data/climate/upper_misc_1deg.bin"
const HEADER := 64
## Эталон brotli: bytes(range(64)) * 4, Python brotli.compress(quality=11).
const BROTLI_REF := "G/8A6GVxXMo7xDJEw0S6YYJNHLv3VweECWVcSKWNdT7ElEttfcy1z30/Ag=="
const NODATA := -32768
const PERF_LIMIT_US := 300.0


func skip_reason(method: String) -> String:
	if method == "test_grid_format" and not FileAccess.file_exists(GRID):
		return "нет сетки %s — кладёт HH-1" % GRID
	if method == "test_upper_air_format" and not FileAccess.file_exists(UPPER):
		return "нет сетки %s — кладёт HH-1b" % UPPER
	if method == "test_surface_t_format" and not FileAccess.file_exists(SURFACE):
		return "нет сетки %s — кладёт HH-1e" % SURFACE
	if method == "test_upper_misc_format" and not FileAccess.file_exists(MISC):
		return "нет сетки %s — кладёт HH-1f" % MISC
	return ""


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (HH\\d+)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	for id: String in VERSIONS:
		check(found.get(id, 0) == VERSIONS[id], "%s (v%d) в заголовках: %s" % [id, VERSIONS[id], found])


func test_brotli_native() -> void:
	var c := Marshalls.base64_to_raw(BROTLI_REF)
	var raw := c.decompress(256, FileAccess.COMPRESSION_BROTLI)
	check(raw.size() == 256, "brotli: 256 байт, получено %d" % raw.size())
	var ok := raw.size() == 256
	for k in mini(raw.size(), 256):
		if raw[k] != k % 64:
			ok = false
			break
	check(ok, "brotli: байты совпадают с эталоном")


func test_grid_format() -> void:
	var f := FileAccess.open(GRID, FileAccess.READ)
	check(f != null, "сетка открывается")
	if f == null:
		return
	f.big_endian = false
	var file_len := f.get_length()
	check(f.get_buffer(4).get_string_from_ascii() == "HHTD", "magic HHTD")
	check(f.get_16() == 1, "version 1")
	check(f.get_16() == 1, "codec 1 (brotli)")
	var nlon := f.get_16()
	var nlat := f.get_16()
	var nmonth := f.get_16()
	check(nlon == 360 and nlat == 180 and nmonth == 12, "360×180×12: %d×%d×%d" % [nlon, nlat, nmonth])
	f.get_16()
	approx(f.get_float(), -179.5, 1e-4, "lon0_deg")
	approx(f.get_float(), -89.5, 1e-4, "lat0_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlon_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlat_deg")
	var td_scale := f.get_float()
	var td_offset := f.get_float()
	var sd_scale := f.get_float()
	var z_scale := f.get_float()
	check(td_scale > 0.0 and sd_scale > 0.0 and z_scale > 0.0, "масштабы > 0")
	var raw_size := f.get_32()
	var comp_size := f.get_32()
	var year0 := f.get_32()
	var year1 := f.get_32()
	check(year0 >= 1940 and year1 >= year0, "годы климатологии %d–%d" % [year0, year1])
	var n3 := nmonth * nlat * nlon
	var n2 := nlat * nlon
	check(raw_size == 2 * (2 * n3 + n2), "raw_size по формуле")
	check(file_len == HEADER + comp_size, "размер файла = 64 + comp_size")
	check(f.get_position() == HEADER, "заголовок 64 байта")
	var raw := f.get_buffer(comp_size).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	check(raw.size() == raw_size, "распаковано %d из %d" % [raw.size(), raw_size])
	if raw.size() != raw_size:
		return
	var bad := {"td": 0, "sd": 0, "z": 0, "nodata": 0}
	for k in n3:
		var v := raw.decode_s16(2 * k)
		if v == NODATA:
			bad.nodata += 1
		elif not (v * td_scale + td_offset >= -80.0 and v * td_scale + td_offset <= 40.0):
			bad.td += 1
		var s := raw.decode_s16(2 * (n3 + k))
		if s != NODATA and not (s * sd_scale >= 0.0 and s * sd_scale <= 20.0):
			bad.sd += 1
	for k in n2:
		var z := raw.decode_s16(2 * (2 * n3 + k))
		if z != NODATA and not (z * z_scale >= -500.0 and z * z_scale <= 7000.0):
			bad.z += 1
	check(bad.td == 0 and bad.sd == 0 and bad.z == 0, "значения вне диапазонов: %s" % bad)


func test_upper_air_format() -> void:
	var f := FileAccess.open(UPPER, FileAccess.READ)
	check(f != null, "сетка 700 гПа открывается")
	if f == null:
		return
	f.big_endian = false
	var file_len := f.get_length()
	check(f.get_buffer(4).get_string_from_ascii() == "HHUA", "magic HHUA")
	check(f.get_16() == 1, "version 1")
	check(f.get_16() == 1, "codec 1 (brotli)")
	var nlon := f.get_16()
	var nlat := f.get_16()
	var nmonth := f.get_16()
	check(nlon == 360 and nlat == 180 and nmonth == 12, "360×180×12: %d×%d×%d" % [nlon, nlat, nmonth])
	check(f.get_16() == 700, "level_hpa 700")
	approx(f.get_float(), -179.5, 1e-4, "lon0_deg")
	approx(f.get_float(), -89.5, 1e-4, "lat0_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlon_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlat_deg")
	var t_scale := f.get_float()
	var t_offset := f.get_float()
	var z_scale := f.get_float()
	var z_offset := f.get_float()
	check(t_scale > 0.0 and z_scale > 0.0, "масштабы > 0")
	var raw_size := f.get_32()
	var comp_size := f.get_32()
	var year0 := f.get_32()
	var year1 := f.get_32()
	var stub := year0 == 0 and year1 == 0
	check(stub or (year0 >= 1940 and year1 >= year0), "годы климатологии %d–%d (0–0 — заглушка)" % [year0, year1])
	var n3 := nmonth * nlat * nlon
	check(raw_size == 2 * 2 * n3, "raw_size по формуле")
	check(file_len == HEADER + comp_size, "размер файла = 64 + comp_size")
	check(f.get_position() == HEADER, "заголовок 64 байта")
	var raw := f.get_buffer(comp_size).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	check(raw.size() == raw_size, "распаковано %d из %d" % [raw.size(), raw_size])
	if raw.size() != raw_size:
		return
	var bad := {"t": 0, "z": 0, "nodata": 0}
	for k in n3:
		var v := raw.decode_s16(2 * k)
		var z := raw.decode_s16(2 * (n3 + k))
		if v == NODATA or z == NODATA:
			bad.nodata += 1
			continue
		var t_c := v * t_scale + t_offset
		if not (t_c >= -60.0 and t_c <= 30.0):
			bad.t += 1
		var z_m := z * z_scale + z_offset
		if not (z_m >= 2000.0 and z_m <= 3500.0):
			bad.z += 1
	check(bad.t == 0 and bad.z == 0 and bad.nodata == 0, "значения вне диапазонов: %s" % bad)


func test_surface_t_format() -> void:
	var f := FileAccess.open(SURFACE, FileAccess.READ)
	check(f != null, "сетка Tmax открывается")
	if f == null:
		return
	f.big_endian = false
	var file_len := f.get_length()
	check(f.get_buffer(4).get_string_from_ascii() == "HHST", "magic HHST")
	check(f.get_16() == 1, "version 1")
	check(f.get_16() == 1, "codec 1 (brotli)")
	var nlon := f.get_16()
	var nlat := f.get_16()
	var nmonth := f.get_16()
	check(nlon == 360 and nlat == 180 and nmonth == 12, "360×180×12: %d×%d×%d" % [nlon, nlat, nmonth])
	var steps := f.get_16()
	check(steps >= 4 and steps <= 24, "steps_per_day 4..24: %d" % steps)
	approx(f.get_float(), -179.5, 1e-4, "lon0_deg")
	approx(f.get_float(), -89.5, 1e-4, "lat0_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlon_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlat_deg")
	var tx_scale := f.get_float()
	var tx_offset := f.get_float()
	var dtr_scale := f.get_float()
	f.get_float()
	check(tx_scale > 0.0 and dtr_scale > 0.0, "масштабы > 0")
	var raw_size := f.get_32()
	var comp_size := f.get_32()
	var year0 := f.get_32()
	var year1 := f.get_32()
	check(year0 >= 1940 and year1 >= year0, "годы климатологии %d–%d" % [year0, year1])
	var n3 := nmonth * nlat * nlon
	check(raw_size == 2 * 2 * n3, "raw_size по формуле")
	check(file_len == HEADER + comp_size, "размер файла = 64 + comp_size")
	check(f.get_position() == HEADER, "заголовок 64 байта")
	var raw := f.get_buffer(comp_size).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	check(raw.size() == raw_size, "распаковано %d из %d" % [raw.size(), raw_size])
	if raw.size() != raw_size:
		return
	var bad := {"tx": 0, "dtr": 0, "nodata": 0}
	for k in n3:
		var v := raw.decode_s16(2 * k)
		var r := raw.decode_s16(2 * (n3 + k))
		if v == NODATA or r == NODATA:
			bad.nodata += 1
			continue
		var tx := v * tx_scale + tx_offset
		if not (tx >= -70.0 and tx <= 55.0):
			bad.tx += 1
		var dtr := r * dtr_scale
		if not (dtr >= 0.0 and dtr <= 30.0):
			bad.dtr += 1
	check(bad.tx == 0 and bad.dtr == 0 and bad.nodata == 0, "значения вне диапазонов: %s" % bad)


func test_upper_misc_format() -> void:
	var f := FileAccess.open(MISC, FileAccess.READ)
	check(f != null, "сетка HH6 открывается")
	if f == null:
		return
	f.big_endian = false
	var file_len := f.get_length()
	check(f.get_buffer(4).get_string_from_ascii() == "HHUM", "magic HHUM")
	check(f.get_16() == 1, "version 1")
	check(f.get_16() == 1, "codec 1 (brotli)")
	var nlon := f.get_16()
	var nlat := f.get_16()
	var nmonth := f.get_16()
	check(nlon == 360 and nlat == 180 and nmonth == 12, "360×180×12: %d×%d×%d" % [nlon, nlat, nmonth])
	check(f.get_16() == 700, "level_hpa 700")
	approx(f.get_float(), -179.5, 1e-4, "lon0_deg")
	approx(f.get_float(), -89.5, 1e-4, "lat0_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlon_deg")
	approx(f.get_float(), 1.0, 1e-6, "dlat_deg")
	var wr_scale := f.get_float()
	var trop_scale := f.get_float()
	var hcc_scale := f.get_float()
	var stub_mask := f.get_32()
	check(stub_mask >= 0 and stub_mask <= 7, "stub_mask 0..7: %d" % stub_mask)
	check(wr_scale > 0.0 and trop_scale > 0.0 and hcc_scale > 0.0, "масштабы > 0")
	var raw_size := f.get_32()
	var comp_size := f.get_32()
	var year0 := f.get_32()
	var year1 := f.get_32()
	check(year0 >= 1940 and year1 >= year0, "годы климатологии %d–%d" % [year0, year1])
	var n3 := nmonth * nlat * nlon
	check(raw_size == 2 * 3 * n3, "raw_size по формуле")
	check(file_len == HEADER + comp_size, "размер файла = 64 + comp_size")
	check(f.get_position() == HEADER, "заголовок 64 байта")
	var raw := f.get_buffer(comp_size).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	check(raw.size() == raw_size, "распаковано %d из %d" % [raw.size(), raw_size])
	if raw.size() != raw_size:
		return
	var bad := {"wr": 0, "trop": 0, "hcc": 0, "nodata": 0}
	for k in n3:
		var a := raw.decode_s16(2 * k)
		var b := raw.decode_s16(2 * (n3 + k))
		var c := raw.decode_s16(2 * (2 * n3 + k))
		if a == NODATA or b == NODATA or c == NODATA:
			bad.nodata += 1
			continue
		var wr := a * wr_scale
		if not (wr >= 0.3 and wr <= 10.0):
			bad.wr += 1
		var trop := b * trop_scale
		if not (trop >= 6000.0 and trop <= 19000.0):
			bad.trop += 1
		var hcc := c * hcc_scale
		if not (hcc >= 0.0 and hcc <= 1.0):
			bad.hcc += 1
	check(bad.wr == 0 and bad.trop == 0 and bad.hcc == 0 and bad.nodata == 0, "значения вне диапазонов: %s" % bad)



# --- HH7: ClimateGrid ----------------------------------------------------------------------------

const AT_KEYS := ["td_c", "td_sd_k", "z_cell_m", "t700_c", "z700_m", "tx_c", "dtr_k", "wr", "trop_m", "hcc"]


func test_climate_grid_keys() -> void:
	ClimateGrid.set_paths({})
	var r := ClimateGrid.at(51.9, 85.9, 7, 15)
	for k: String in AT_KEYS:
		check(r.has(k) and typeof(r[k]) == TYPE_FLOAT, "at: ключ %s (float)" % k)
	var src: Dictionary = r.src
	for g in ["hh1", "hh2", "hh5", "hh6"]:
		check(["data", "stub", "none"].has(src.get(g, "")), "src.%s" % g)
	var p := ClimateGrid.place({"lat": 51.9, "lon": 85.9, "month": 7, "day": 15, "valley_msl_m": 304.0})
	check(p.has("gain_per_km") and float(p.gain_per_km) > 0.0, "place: gain_per_km > 0")
	check(float(p.t700_c) == float(r.t700_c) and float(p.hcc) == float(r.hcc), "place: 700 гПа и hcc без поправки")
	var p2 := ClimateGrid.place({"lat": 51.9, "lon": 85.9, "month": 7, "day": 15, "valley_msl_m": 304.0})
	check(p.hash() == p2.hash(), "place детерминирован")


func test_climate_grid_altai_raw() -> void:
	ClimateGrid.set_paths({})
	if not FileAccess.file_exists(GRID):
		return
	var r := ClimateGrid.at(51.9, 85.9, 7, 15)
	if r.src.hh1 != "data":
		return
	# независимый разбор: распаковка и билинейно по 4 ячейкам июля
	var b := FileAccess.get_file_as_bytes(GRID)
	var raw := b.slice(HEADER).decompress(b.decode_u32(48), FileAccess.COMPRESSION_BROTLI)
	var sc := b.decode_float(32)
	var off := b.decode_float(36)
	var x := 85.9 + 179.5
	var y := 51.9 + 89.5
	var i0 := int(floor(x))
	var j0 := int(floor(y))
	var fi := x - i0
	var fj := y - j0
	var acc := 0.0
	for dj in 2:
		for di in 2:
			var v := raw.decode_s16(2 * ((6 * 180 + j0 + dj) * 360 + i0 + di))
			acc += (v * sc + off) * (fi if di == 1 else 1.0 - fi) * (fj if dj == 1 else 1.0 - fj)
	approx(float(r.td_c), acc, 0.05, "Алтай, июль: td_c по сырым байтам")


func test_climate_grid_bilinear_and_wrap() -> void:
	ClimateGrid.set_paths({})
	if not FileAccess.file_exists(GRID):
		return
	# в центре ячейки — значение ячейки; соседние точки в 0.01° — почти то же
	var a := ClimateGrid.at(51.5, 85.5, 7, 15)
	var b := ClimateGrid.at(51.51, 85.51, 7, 15)
	approx(float(a.td_c), float(b.td_c), 0.1, "в пределах 0.01° значение почти то же")
	# долгота ±180 — без разрыва
	var w := ClimateGrid.at(10.0, 179.99, 7, 15)
	var e := ClimateGrid.at(10.0, -179.99, 7, 15)
	approx(float(w.td_c), float(e.td_c), 0.5, "±180°: нет разрыва по Td")
	check(float(ClimateGrid.at(10.0, 540.0, 7, 15).td_c) == float(ClimateGrid.at(10.0, 180.0, 7, 15).td_c), "долгота по кругу")


func test_climate_grid_month_continuity() -> void:
	ClimateGrid.set_paths({})
	var d31 := ClimateGrid.at(51.9, 85.9, 12, 31)
	var j1 := ClimateGrid.at(51.9, 85.9, 1, 1)
	approx(float(d31.td_c), float(j1.td_c), 0.6, "декабрь ↔ январь непрерывно (Td)")
	approx(float(d31.tx_c), float(j1.tx_c), 1.0, "декабрь ↔ январь непрерывно (Tx)")
	var m := ClimateGrid.at(51.9, 85.9, 7, 15)
	var n := ClimateGrid.at(51.9, 85.9, 7, 16)
	approx(float(m.td_c), float(n.td_c), 0.5, "день за днём — плавно")


func test_climate_grid_no_file() -> void:
	var cfg := WeatherModel.config()
	ClimateGrid.set_paths({
		"hh1": "res://data/climate/__none1.bin", "hh2": "res://data/climate/__none2.bin",
		"hh5": "res://data/climate/__none5.bin", "hh6": "res://data/climate/__none6.bin",
	})
	var r := ClimateGrid.at(51.9, 85.9, 7, 15)
	ClimateGrid.set_paths({})
	for g in ["hh1", "hh2", "hh5", "hh6"]:
		check(r.src[g] == "none", "нет файла: src.%s = none" % g)
	approx(float(r.td_c), float(cfg.climate.fallback.td_c[6]), 1e-6, "td_c из конфига")
	approx(float(r.td_sd_k), float(cfg.climate.td_sd_fallback_k), 1e-6, "σ из конфига")
	approx(float(r.t700_c), float(cfg.upper_air.temp_c[6]), 1e-6, "t700 из upper_air")
	approx(float(r.z700_m), float(cfg.upper_air.z_msl_m), 1e-6, "z700 из upper_air")
	approx(float(r.tx_c), float(cfg.typical_max_c[6]), 1e-6, "tx из typical_max_c")
	approx(float(r.dtr_k), float(cfg.diurnal.range_k[6]), 1e-6, "dtr из diurnal.range_k")
	approx(float(r.trop_m), float(cfg.tropopause_msl_m), 1e-6, "тропопауза из конфига")


func test_climate_grid_speed() -> void:
	ClimateGrid.set_paths({})
	ClimateGrid.at(40.0, 30.0, 7, 15)  # загрузка
	var n := 500
	var t0 := Time.get_ticks_usec()
	for k in n:
		ClimateGrid.at(40.0 + k * 0.01, 30.0 + k * 0.013, 1 + k % 12, 1 + k % 28)
	var us := float(Time.get_ticks_usec() - t0) / n
	print("  ClimateGrid.at: %.1f мкс" % us)
	check(us < PERF_LIMIT_US, "at() %.1f мкс < %.0f" % [us, PERF_LIMIT_US])


## Градиенты Tx/DTR по поясам (HH-1e): 30–60° — по сезону, тропики, прочее — глобальный год.
func test_climate_grid_belt_gradients() -> void:
	var cl: Dictionary = WeatherModel.config().climate
	approx(ClimateGrid.belt_gradient(52.0, 1, cl.tx_gradient_k_per_km, 0.0), -7.8, 1e-9, "Tx 30–60°, МАМ")
	approx(ClimateGrid.belt_gradient(-17.0, 0, cl.tx_gradient_k_per_km, 0.0), -5.43, 1e-9, "Tx тропики")
	approx(ClimateGrid.belt_gradient(25.0, 0, cl.dtr_gradient_k_per_km, 0.0), -0.5, 1e-9, "DTR прочее")
	approx(ClimateGrid.belt_gradient(52.0, 0, {}, -6.3), -6.3, 1e-9, "нет таблицы — по умолчанию")
