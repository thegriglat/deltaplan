extends TestCase
## Контракты haze-humidity (docs/contracts/haze-humidity.md): версии в заголовках, формат сеток HH1 (точка росы)
## и HH2 (воздух 700 гПа).

const DOC := "res://docs/contracts/haze-humidity.md"
const VERSIONS := {"HH1": 1, "HH2": 1, "HH3": 1, "HH4": 1}
const GRID := "res://data/climate/dew_point_1deg.bin"
const UPPER := "res://data/climate/upper_air_1deg.bin"
const HEADER := 64
## Эталон brotli: bytes(range(64)) * 4, Python brotli.compress(quality=11).
const BROTLI_REF := "G/8A6GVxXMo7xDJEw0S6YYJNHLv3VweECWVcSKWNdT7ElEttfcy1z30/Ag=="
const NODATA := -32768


func skip_reason(method: String) -> String:
	if method == "test_grid_format" and not FileAccess.file_exists(GRID):
		return "нет сетки %s — кладёт HH-1" % GRID
	if method == "test_upper_air_format" and not FileAccess.file_exists(UPPER):
		return "нет сетки %s — кладёт HH-1b" % UPPER
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
	check(year0 >= 1940 and year1 >= year0, "годы климатологии %d–%d" % [year0, year1])
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
