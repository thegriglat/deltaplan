class_name ClimateGrid
extends RefCounted
## Климат места из сеток ERA5 (контракт HH7, docs/contracts/haze-humidity.md): точка росы HH1, воздух 700 гПа HH2,
## Tmax и суточная амплитуда HH5, рост ветра/тропопауза/перистые HH6. Только чистые статические функции;
## сетки читаются один раз (brotli, int16 в PackedByteArray). Нет файла или битый заголовок — push_error один раз
## на файл, значения этой сетки из configs/weather_model.json → climate.fallback и upper_air.
##
##   var p := ClimateGrid.place({"lat": 51.87, "lon": 85.87, "month": 7, "day": 15, "valley_msl_m": 304})
##   p.td_c, p.td_sd_k, p.t700_c, p.z700_m, p.tx_c, p.dtr_k, p.gain_per_km

const HEADER := 64
const NODATA := -32768
const NLON := 360
const NLAT := 180
const NMONTH := 12
const SOUTH_CELL_MIN := -89.5
const LON0 := -179.5

## Сетка: [файл, magic, версия, блоков по месяцам nmonth·nlat·nlon, 2D-блоков nlat·nlon].
const SPECS := {
	"hh1": {"magic": "HHTD", "blocks3": 2, "blocks2": 1},
	"hh2": {"magic": "HHUA", "blocks3": 2, "blocks2": 0},
	"hh5": {"magic": "HHST", "blocks3": 2, "blocks2": 0},
	"hh6": {"magic": "HHUM", "blocks3": 3, "blocks2": 0},
}

static var paths := {
	"hh1": "res://data/climate/dew_point_1deg.bin",
	"hh2": "res://data/climate/upper_air_1deg.bin",
	"hh5": "res://data/climate/surface_t_1deg.bin",
	"hh6": "res://data/climate/upper_misc_1deg.bin",
}
## Загруженные сетки: имя → {state: "data"|"stub"|"none", raw, p: Dictionary параметров} (кэш).
static var _grids := {}


## Подменить пути файлов (тесты) и сбросить кэш; пустой словарь — вернуть пути по умолчанию.
static func set_paths(over: Dictionary) -> void:
	paths = {
		"hh1": "res://data/climate/dew_point_1deg.bin",
		"hh2": "res://data/climate/upper_air_1deg.bin",
		"hh5": "res://data/climate/surface_t_1deg.bin",
		"hh6": "res://data/climate/upper_misc_1deg.bin",
	}
	paths.merge(over, true)
	_grids.clear()


## Климат ячейки без поправки на высоту (HH7). Ключи — в docs/contracts/haze-humidity.md §HH7.
static func at(lat: float, lon: float, month: int, day: int = 15) -> Dictionary:
	var g1 := _grid("hh1")
	var g2 := _grid("hh2")
	var g5 := _grid("hh5")
	var g6 := _grid("hh6")
	var cfg := WeatherModel.config()
	var fb: Dictionary = cfg.get("climate", {}).get("fallback", {})
	var ua: Dictionary = cfg.get("upper_air", {})
	var out := {
		"td_c": 0.0, "td_sd_k": 0.0, "z_cell_m": 0.0,
		"t700_c": 0.0, "z700_m": 0.0,
		"tx_c": 0.0, "dtr_k": 0.0,
		"wr": 1.0, "trop_m": 0.0, "hcc": 0.0,
		"src": {
			"hh1": String(g1.state), "hh2": String(g2.state),
			"hh5": String(g5.state), "hh6": String(g6.state),
		},
	}
	var m := clampi(month, 1, 12) - 1
	var dim := float(SunClock.days_in_month(m + 1))
	var f := (float(day) - 15.0) / dim
	var m2 := posmod(m + (1 if f >= 0.0 else -1), 12)
	var wt := absf(f)  # вес соседнего месяца

	# --- пространство: 4 ячейки
	var x := fposmod(lon - LON0, 360.0)
	var i0 := int(floor(x))
	var fi := x - i0
	i0 = posmod(i0, NLON)
	var i1 := (i0 + 1) % NLON
	var y := clampf(lat, SOUTH_CELL_MIN, -SOUTH_CELL_MIN) - SOUTH_CELL_MIN
	var j0 := mini(int(floor(y)), NLAT - 2)
	var fj := y - j0
	var j1 := j0 + 1
	var cj := PackedInt32Array([j0, j0, j1, j1])
	var ci := PackedInt32Array([i0, i1, i0, i1])
	var cw := PackedFloat64Array(
		[(1.0 - fi) * (1.0 - fj), fi * (1.0 - fj), (1.0 - fi) * fj, fi * fj]
	)

	if g1.state != "none":
		var p: Dictionary = g1.p
		var raw: PackedByteArray = g1.raw
		var n3: int = p.n3
		var td := _time(raw, 0, m, m2, wt, cj, ci, cw)
		var sd := _time(raw, n3, m, m2, wt, cj, ci, cw)
		var z := _sample(raw, 2 * n3, cj, ci, cw)
		out.td_c = td * float(p.td_scale) + float(p.td_offset)
		out.td_sd_k = maxf(sd * float(p.sd_scale), 0.0)
		out.z_cell_m = z * float(p.z_scale)
	else:
		out.td_c = _fb_monthly(fb.get("td_c", [0.0]), month, day)
		out.td_sd_k = float(cfg.get("climate", {}).get("td_sd_fallback_k", 4.0))
		out.z_cell_m = 0.0
	if g2.state != "none":
		var p2: Dictionary = g2.p
		var raw2: PackedByteArray = g2.raw
		var n32: int = p2.n3
		out.t700_c = (
			_time(raw2, 0, m, m2, wt, cj, ci, cw) * float(p2.t_scale) + float(p2.t_offset)
		)
		out.z700_m = (
			_time(raw2, n32, m, m2, wt, cj, ci, cw) * float(p2.z_scale) + float(p2.z_offset)
		)
	else:
		out.t700_c = _fb_monthly(ua.get("temp_c", [0.0]), month, day)
		out.z700_m = float(ua.get("z_msl_m", 3000.0))
	if g5.state != "none":
		var p5: Dictionary = g5.p
		var raw5: PackedByteArray = g5.raw
		out.tx_c = (
			_time(raw5, 0, m, m2, wt, cj, ci, cw) * float(p5.tx_scale) + float(p5.tx_offset)
		)
		out.dtr_k = maxf(
			_time(raw5, int(p5.n3), m, m2, wt, cj, ci, cw) * float(p5.dtr_scale), 0.0
		)
	else:
		out.tx_c = _fb_monthly(cfg.get("typical_max_c", [20.0]), month, day)
		out.dtr_k = _fb_monthly(cfg.get("diurnal", {}).get("range_k", [10.0]), month, day)
	if g6.state != "none":
		var p6: Dictionary = g6.p
		var raw6: PackedByteArray = g6.raw
		var n36: int = p6.n3
		out.wr = _time(raw6, 0, m, m2, wt, cj, ci, cw) * float(p6.wr_scale)
		out.trop_m = _time(raw6, n36, m, m2, wt, cj, ci, cw) * float(p6.trop_scale)
		out.hcc = clampf(
			_time(raw6, 2 * n36, m, m2, wt, cj, ci, cw) * float(p6.hcc_scale), 0.0, 1.0
		)
	else:
		var gain := float(Config.value("atmosphere", "wind.altitude_gain_per_km", 0.6))
		out.wr = maxf(1.0 + gain * (float(out.z700_m) - float(out.z_cell_m)) / 1000.0, 0.3)
		out.trop_m = float(cfg.get("tropopause_msl_m", 11000.0))
		out.hcc = float(cfg.get("cirrus_base", 0.1))
	return out


## Климат места ctx {lat, lon, month, day, valley_msl_m}: at() плюс поправки на высоту долины (HH7).
static func place(ctx: Dictionary) -> Dictionary:
	var lat := float(ctx.get("lat", 52.0))
	var lon := float(ctx.get("lon", 0.0))
	var month := clampi(int(ctx.get("month", 7)), 1, 12)
	var day := int(ctx.get("day", 15))
	var r := at(lat, lon, month, day)
	var src: Dictionary = r.src
	var valley := float(ctx.get("valley_msl_m", 0.0))
	# Нет Z ячейки (HH1 не загружена) — таблицы относятся к самому месту: поправки нет.
	var z_cell := float(r.z_cell_m) if src.hh1 != "none" else valley
	r.z_cell_m = z_cell
	var dz_km := (valley - z_cell) / 1000.0
	var cl: Dictionary = WeatherModel.config().get("climate", {})
	var season := season_index(month, lat)
	r.td_c = float(r.td_c) + td_gradient(lat, season, cl) * dz_km
	if src.hh5 != "none":  # таблицы-запасные уже относятся к месту
		r.tx_c = float(r.tx_c) + belt_gradient(lat, season, cl.get("tx_gradient_k_per_km", {}), -6.3) * dz_km
		r.dtr_k = maxf(
			0.0, float(r.dtr_k) + belt_gradient(lat, season, cl.get("dtr_gradient_k_per_km", {}), -0.5) * dz_km
		)
	if src.hh6 == "none":
		r.gain_per_km = float(Config.value("atmosphere", "wind.altitude_gain_per_km", 0.6))
	else:
		r.gain_per_km = (
			(float(r.wr) - 1.0) * 1000.0 / maxf(float(r.z700_m) - z_cell, 500.0)
		)
	return r


## Градиент Td по высоте, К/км: 30–60° — по сезону, тропики (|φ| ≤ 20°) и прочее — своё (HH-1, dew_point/README).
static func td_gradient(lat: float, season: int, cl: Dictionary) -> float:
	return belt_gradient(lat, season, cl.get("td_gradient_k_per_km", {}), -4.0)


## Градиент по поясам: mid (30–60°) — массив по сезону, tropics (|φ| ≤ 20°), other — остальное; нет таблицы — default.
static func belt_gradient(lat: float, season: int, g: Variant, default: float) -> float:
	if not (g is Dictionary):
		return float(g) if (g is float or g is int) else default
	var a := absf(lat)
	if a >= 30.0 and a <= 60.0:
		var arr: Array = g.get("mid", [default])
		return float(arr[mini(season, arr.size() - 1)])
	if a <= 20.0:
		return float(g.get("tropics", default))
	return float(g.get("other", default))


## Физический сезон 0..3 = ДЯФ, МАМ, ИИА, СОН; в южном полушарии месяц сдвинут на 6.
static func season_index(month: int, lat: float) -> int:
	var m := clampi(month, 1, 12)
	if lat < 0.0:
		m = (m + 5) % 12 + 1
	return floori(float(m % 12) / 3.0)


## Пояс |φ| для таблиц td_day: индекс первой верхней границы bounds, не меньшей |φ| (выше — последний).
static func band_index(lat: float, bounds: Array) -> int:
	var a := absf(lat)
	for k in bounds.size():
		if a <= float(bounds[k]):
			return k
	return bounds.size() - 1


# --- внутреннее -----------------------------------------------------------------------------


static func _fb_monthly(arr: Array, month: int, day: int) -> float:
	return WeatherModel.monthly(arr, month, day)


## Билинейно, по двум месяцам: значение блока (в единицах int16, до масштаба); блок начинается с индекса base.
static func _time(
	raw: PackedByteArray, base: int, m: int, m2: int, wt: float,
	cj: PackedInt32Array, ci: PackedInt32Array, cw: PackedFloat64Array
) -> float:
	var a := _sample(raw, base + m * NLAT * NLON, cj, ci, cw)
	if wt <= 0.0:
		return a
	var b := _sample(raw, base + m2 * NLAT * NLON, cj, ci, cw)
	return lerpf(a, b, wt)


## Билинейно по 4 ячейкам блока (начало — индекс int16 base). Пропуск (−32768) исключает ячейку, веса
## перенормируются; все пропущены — ближайшая ячейка с данными в строке первой из ячеек.
static func _sample(
	raw: PackedByteArray, base: int,
	cj: PackedInt32Array, ci: PackedInt32Array, cw: PackedFloat64Array
) -> float:
	var s := 0.0
	var ws := 0.0
	for k in 4:
		var v := raw.decode_s16(2 * (base + cj[k] * NLON + ci[k]))
		if v != NODATA:
			s += v * cw[k]
			ws += cw[k]
	if ws > 1.0e-9:
		return s / ws
	# все пропущены: ближайшая ячейка с данными той же строки (по кругу)
	var row := base + cj[0] * NLON
	for d in range(1, int(NLON * 0.5) + 1):
		for sgn in [1, -1]:
			var v := raw.decode_s16(2 * (row + posmod(ci[0] + sgn * d, NLON)))
			if v != NODATA:
				return float(v)
	return 0.0


## Сетка из кэша (первое обращение — чтение и распаковка).
static func _grid(name: String) -> Dictionary:
	var g: Variant = _grids.get(name)
	if g != null:
		return g
	g = _load(name)
	_grids[name] = g
	return g


static func _none() -> Dictionary:
	return {"state": "none", "raw": PackedByteArray(), "p": {}}


static func _load(name: String) -> Dictionary:
	var path := String(paths[name])
	var spec: Dictionary = SPECS[name]
	if not FileAccess.file_exists(path):
		push_error("ClimateGrid: нет файла %s — значения из конфига" % path)
		return _none()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < HEADER:
		push_error("ClimateGrid: %s — короче заголовка" % path)
		return _none()
	if bytes.slice(0, 4).get_string_from_ascii() != String(spec.magic):
		push_error("ClimateGrid: %s — неверный magic" % path)
		return _none()
	var ver := bytes.decode_u16(4)
	var codec := bytes.decode_u16(6)
	if codec != 1 or bytes.decode_u16(8) != NLON or bytes.decode_u16(10) != NLAT \
			or bytes.decode_u16(12) != NMONTH:
		push_error("ClimateGrid: %s — неверная сетка/кодек" % path)
		return _none()
	var n3 := NMONTH * NLAT * NLON
	var n2 := NLAT * NLON
	var raw_size := int(bytes.decode_u32(48))
	var comp_size := int(bytes.decode_u32(52))
	if raw_size != 2 * (int(spec.blocks3) * n3 + int(spec.blocks2) * n2) \
			or bytes.size() != HEADER + comp_size:
		push_error("ClimateGrid: %s — неверный размер (raw %d, comp %d)" % [path, raw_size, comp_size])
		return _none()
	var raw := bytes.slice(HEADER).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	if raw.size() != raw_size:
		push_error("ClimateGrid: %s — не распаковалась" % path)
		return _none()
	var year0 := int(bytes.decode_u32(56))
	var p := {"n3": n3, "version": ver, "year0": year0}
	var stub := false
	match name:
		"hh1":
			p.td_scale = bytes.decode_float(32)
			p.td_offset = bytes.decode_float(36)
			p.sd_scale = bytes.decode_float(40)
			p.z_scale = bytes.decode_float(44)
		"hh2":
			p.t_scale = bytes.decode_float(32)
			p.t_offset = bytes.decode_float(36)
			p.z_scale = bytes.decode_float(40)
			p.z_offset = bytes.decode_float(44)
			stub = year0 == 0
		"hh5":
			p.tx_scale = bytes.decode_float(32)
			p.tx_offset = bytes.decode_float(36)
			p.dtr_scale = bytes.decode_float(40)
		"hh6":
			p.wr_scale = bytes.decode_float(32)
			p.trop_scale = bytes.decode_float(36)
			p.hcc_scale = bytes.decode_float(40)
			p.stub_mask = int(bytes.decode_u32(44))
			stub = p.stub_mask != 0
	if stub:
		print("ClimateGrid: %s — заглушка до CDS (%s)" % [path, p.get("stub_mask", "year0 = 0")])
	return {"state": "stub" if stub else "data", "raw": raw, "p": p}
