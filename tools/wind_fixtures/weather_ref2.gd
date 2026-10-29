extends Node
## Эталоны погоды E1–E10 с живого GD-кода (RW-14b) для rust/dp-air: дыры, не закрытые weather_dump/day_dump
## (docs/research/rust-wind-stage3/rw14-weather.md, «Эталоны»). Логика GD не меняется — только вызовы.
## Запуск: weather_ref2.sh [--out=<каталог>] | --check (под замком cpu: .dpcli/dpcli lock cpu <имя> -- …).
## Выход: <out>/e<N>_<имя>.jsonl (json lines, sort_keys, полная точность; NaN и inf -> null), manifest.json;
## weather_ref2.sh сжимает каждый jsonl в .jsonl.zst. Одна строка = один вызов: kind, входы, результат.
## Входы-варианты сеток ClimateGrid (E1) — копии настоящих файлов data/climate/*.bin с правкой заголовка
## (поле variant строки описывает правку; Rust-тест делает её сам).

const FIX := "res://tests/fixtures/wind"
const DEFAULT_OUT := "res://rust/dp-air/tests/data/RW-14b"
const TMP := "user://weather_ref2_grids"

## Места с рельефом-растром (фикстуры W8): имя, фикстура, какие сетки выключить.
const PLACES := [
	{name = "ongudai", fixture = "ongudai", off = []},
	{name = "training_island", fixture = "training_island", off = []},
	{name = "volcano_island", fixture = "volcano_island", off = []},
	{name = "synthetic", fixture = "synthetic", off = ["hh1", "hh2", "hh5", "hh6"]},
]
const GRIDS := ["hh1", "hh2", "hh5", "hh6"]
const GRID_FILES := {
	"hh1": "res://data/climate/dew_point_1deg.bin", "hh2": "res://data/climate/upper_air_1deg.bin",
	"hh5": "res://data/climate/surface_t_1deg.bin", "hh6": "res://data/climate/upper_misc_1deg.bin",
}
const SYNTH_DIR := "res://rust/dp-air/tests/data/RW-14b/grids/"
const SYNTH_FILES := {"hh1": "dew_point_1deg_nodata.bin", "hh2": "upper_air_1deg_nodata.bin", "hh5": "surface_t_1deg_nodata.bin", "hh6": "upper_misc_1deg_nodata.bin"}
const NO_FILE := "res://tools/wind_fixtures/no_such_climate_%s.bin"

var _out := ""
var _files := {}  ## имя набора -> PackedStringArray строк
var _notes := {}  ## имя набора -> {what, why, inputs}
var _seed := 12345
var _places := []  ## [{name, head, layer, ctx, ...}]


func _ready() -> void:
	_out = ProjectSettings.globalize_path(DEFAULT_OUT)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var ok := _run()
	get_tree().quit(0 if ok else 1)


func _run() -> bool:
	for pd: Dictionary in PLACES:
		var layer: Variant = _load_layer(String(pd.fixture))
		if layer == null:
			return false
		var ctx := AirPlace.context(layer.layer, layer.head.loc, WeatherModel.config())
		_places.append({name = pd.name, off = pd.off, head = layer.head, layer = layer.layer, ctx = ctx})
	ClimateGrid.set_paths({})
	_e1()
	ClimateGrid.set_paths({})
	_e2()
	ClimateGrid.set_paths({})
	_e3()
	_e4()
	_e5()
	_e6()
	ClimateGrid.set_paths({})
	_e7()
	_e8()
	_e9()
	_e10()
	ClimateGrid.set_paths({})
	var sets := []
	var names := _files.keys()
	names.sort()
	var total := 0
	for n: String in names:
		var rows: PackedStringArray = _files[n]
		_write_bytes(_out.path_join(n + ".jsonl"), ("\n".join(rows) + "\n").to_utf8_buffer())
		var note: Dictionary = _notes[n]
		sets.append({file = n + ".jsonl.zst", rows = rows.size(), what = note.what, why = note.why, inputs = note.inputs})
		total += rows.size()
	var manifest := {
		format = "json lines (<file>.jsonl.zst, zstd): одна строка = один вызов GD, kind + входы + результат; NaN и inf -> null; ключи отсортированы",
		godot = Engine.get_version_info().string,
		rows = total,
		sets = sets,
		grid_variants = "E1 variant: real | stub_<имя> | none_* — копия data/climate/<файл>.bin с правкой заголовка (patch в строке); none_missing — путь в никуда",
	}
	_write_bytes(_out.path_join("manifest.json"), (JSON.stringify(manifest, "\t", true, true) + "\n").to_utf8_buffer())
	_remove_tmp()
	print("weather_ref2: готово, %d наборов, %d строк, %s" % [sets.size(), total, _out])
	return true


# ------------------------------------------------------------------ E1 ClimateGrid.at

func _e1() -> void:
	var f := "e1_climate_at"
	_begin(f, "ClimateGrid.at(lat, lon, month, day) целиком (все ключи и src)",
		"новый код читает и распаковывает сетки сам",
		"решётка lat −89.5+7k × lon −179.9+4.9k × 12 мес (день 15; 1/28/31 в части месяцев); углы (полюса, антимеридиан, обёртка lon); дрожащие точки; ячейки с пропусками −32768 (частичные и все четыре) в 4 сетках; варианты сеток: stub, none")
	var lats := []
	for k in 26:
		lats.append(-89.5 + 7.0 * k)
	lats.append(89.5)
	var lons := []
	for k in 74:
		lons.append(-179.9 + 4.9 * k)
	for lat: float in lats:
		for lon: float in lons:
			for m in range(1, 13):
				_e1_row(f, "grid", lat, lon, m, 15, "real")
	# дни 1/28/31 на границах месяцев (середина года и зима, февраль)
	for lat: float in [-46.5, -4.5, 23.5, 51.5, 79.5]:
		for lon: float in [-100.4, 86.13, 150.1]:
			for md: Array in [[1, 1], [1, 31], [2, 1], [2, 28], [3, 31], [6, 1], [7, 28], [12, 1], [12, 31]]:
				_e1_row(f, "days", lat, lon, md[0], md[1], "real")
	# углы
	var corner_lat := [-90.0, -89.99, -89.5, -89.0, 89.0, 89.5, 89.99, 90.0, -91.0, 95.0, 200.0]
	var corner_lon := [-180.0, -179.5, -179.0, 0.0, 179.0, 179.5, 179.99, 180.0, 181.0, -181.0, 360.0, 540.3, -540.7]
	for lat: float in corner_lat:
		for lon: float in corner_lon:
			for m in [1, 7]:
				_e1_row(f, "corner", lat, lon, m, 15, "real")
	for lat: float in [-30.0, 0.0, 60.0]:
		for lon: float in [179.0, 179.6, 179.99, -179.99, -179.6]:
			_e1_row(f, "antimeridian", lat, lon, 4, 28, "real")
	# дрожащие точки
	for i in 360:
		var lat := _rnd() * 179.0 - 89.5
		var lon := _rnd() * 360.0 - 180.0
		var dd: int = [1, 15, 28][i % 3]
		_e1_row(f, "jitter", lat, lon, i % 12 + 1, dd, "real")
	# ячейки с пропусками: синтетические сетки с дырами −32768 (grids/*_nodata.bin, regrid в weather_ref2.sh)
	var synth := {}
	for g: String in GRIDS:
		synth[g] = SYNTH_DIR + SYNTH_FILES[g]
	ClimateGrid.set_paths(synth)
	for g: String in GRIDS:
		_e1_nodata(f, g)
	# строки-пустоты синтетики: 140–141 (месяцы с m%2==0), 150–151 пусты кроме i=77 (m%3==0), полюса (месяцы 7+)
	for lon: float in [-179.0, -100.3, 0.0, 77.0 - 179.5 + 0.4, 100.7, 179.6]:
		for m in range(1, 13):
			_e1_row(f, "synth_row", 51.0 + 0.3, lon, m, 15, "synth_nodata_all")
			_e1_row(f, "synth_row", 61.0 + 0.3, lon, m, 15, "synth_nodata_all")
			_e1_row(f, "synth_row", -89.2, lon, m, 15, "synth_nodata_all")
			_e1_row(f, "synth_row", 89.5, lon, m, 15, "synth_nodata_all")
	for lat in range(-90, 91, 10):
		for lon in range(-180, 181, 30):
			for m in range(1, 13):
				_e1_row(f, "synth_grid", lat + 0.37, lon + 0.21, m, 15, "synth_nodata_all")
	for g: String in GRIDS:
		ClimateGrid.set_paths({g: SYNTH_DIR + SYNTH_FILES[g]})
		for lat in [-89.9, -60.3, 0.4, 20.5, 60.6, 89.9]:
			for lon in [-179.9, 0.2, 100.5, 179.9]:
				for m in [1, 7, 12]:
					_e1_row(f, "synth_one", lat, lon, m, 15, "synth_nodata_" + g)
	ClimateGrid.set_paths({})
	# варианты сеток (stub / none)
	_e1_variants(f)
	ClimateGrid.set_paths({})


func _e1_row(f: String, kind: String, lat: float, lon: float, m: int, d: int, variant: String, extra: Dictionary = {}) -> void:
	var row := {kind = kind, lat = lat, lon = lon, month = m, day = d, variant = variant}
	row.merge(extra)
	row.at = ClimateGrid.at(lat, lon, m, d)
	_push(f, row)


## Точки в ячейках с пропусками NODATA: частичные (1–3 из 4 углов) и все четыре; по каждой сетке и блоку.
func _e1_nodata(f: String, g: String) -> void:
	var grid: Dictionary = ClimateGrid._grid(g)
	if String(grid.state) == "none":
		return
	var raw: PackedByteArray = grid.raw
	var n3 := ClimateGrid.NMONTH * ClimateGrid.NLAT * ClimateGrid.NLON
	var nl := ClimateGrid.NLAT * ClimateGrid.NLON
	var spec: Dictionary = ClimateGrid.SPECS[g]
	var blocks3: int = spec.blocks3
	var part := []
	var full := []
	for b in blocks3 + int(spec.blocks2):
		for m in (ClimateGrid.NMONTH if b < blocks3 else 1):
			var base: int = b * n3 + m * nl
			var cnt := 0
			var step := 1
			for j in range(0, ClimateGrid.NLAT - 1, 1):
				for i in range(0, ClimateGrid.NLON, 1):
					var k := j * ClimateGrid.NLON + i
					if raw.decode_s16(2 * (base + k)) != ClimateGrid.NODATA:
						continue
					var i1 := (i + 1) % ClimateGrid.NLON
					var c := 1
					for kk in [j * ClimateGrid.NLON + i1, (j + 1) * ClimateGrid.NLON + i, (j + 1) * ClimateGrid.NLON + i1]:
						if raw.decode_s16(2 * (base + kk)) == ClimateGrid.NODATA:
							c += 1
					var e := {b = b, m = m + 1, j = j, i = i}
					if c == 4:
						full.append(e)
					elif (k + m) % step == 0:
						part.append(e)
	_pick_rows(f, g, "nodata_full", full, 60)
	_pick_rows(f, g, "nodata_part", part, 60)


func _pick_rows(f: String, g: String, kind: String, list: Array, n: int) -> void:
	if list.is_empty():
		return
	var stride := maxi(list.size() / n, 1)
	var cnt := 0
	for idx in range(0, list.size(), stride):
		if cnt >= n:
			break
		cnt += 1
		var e: Dictionary = list[idx]
		# точка внутри ячейки (j, i): lat = −89.5 + j + fj, lon = −179.5 + i + fi
		var fj := 0.25 + 0.5 * float(cnt % 2)
		var fi := 0.7 - 0.4 * float(cnt % 3) / 2.0
		var lat: float = -89.5 + e.j + fj
		var lon: float = -179.5 + e.i + fi
		if lon > 180.0:
			lon -= 360.0
		_e1_row(f, kind, lat, lon, e.m, 15, "synth_nodata_all", {grid = g, block = e.b, cell_j = e.j, cell_i = e.i})


## Варианты заголовка: stub (hh2 year0 = 0; hh6 stub_mask ≠ 0), year0 = 0 у остальных (не заглушка), none.
func _e1_variants(f: String) -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	var variants := [
		{name = "stub_year0", grid = "hh2", patch = [{off = 56, size = 4, value = 0}]},
		{name = "stub_mask1", grid = "hh6", patch = [{off = 44, size = 4, value = 1}]},
		{name = "stub_mask7", grid = "hh6", patch = [{off = 44, size = 4, value = 7}]},
		{name = "year0_zero", grid = "hh1", patch = [{off = 56, size = 4, value = 0}]},
		{name = "year0_zero", grid = "hh5", patch = [{off = 56, size = 4, value = 0}]},
		{name = "year0_zero", grid = "hh6", patch = [{off = 56, size = 4, value = 0}]},
		{name = "none_missing", grid = "hh1", missing = true},
		{name = "none_missing", grid = "hh2", missing = true},
		{name = "none_missing", grid = "hh5", missing = true},
		{name = "none_missing", grid = "hh6", missing = true},
		{name = "none_short", grid = "hh1", truncate = 10},
		{name = "none_short", grid = "hh5", truncate = 63},
		{name = "none_magic", grid = "hh2", patch = [{off = 0, size = 1, value = 0x58}]},
		{name = "none_magic", grid = "hh6", patch = [{off = 1, size = 1, value = 0x58}]},
		{name = "none_codec", grid = "hh1", patch = [{off = 6, size = 2, value = 2}]},
		{name = "none_dims", grid = "hh5", patch = [{off = 8, size = 2, value = 359}]},
		{name = "none_dims", grid = "hh2", patch = [{off = 12, size = 2, value = 11}]},
		{name = "none_raw_size", grid = "hh6", patch = [{off = 48, size = 4, value = 1000}]},
		{name = "none_comp_size", grid = "hh1", patch = [{off = 52, size = 4, value = 1000}]},
		{name = "none_trailing", grid = "hh5", append = 1},
		{name = "none_cut_tail", grid = "hh2", truncate_tail = 1},
		{name = "none_garbage_body", grid = "hh6", garbage_body = true},
	]
	var pts := []
	for lat: float in [-80.2, -33.3, 0.6, 27.4, 51.87, 70.7]:
		for lon: float in [-150.3, 5.5, 86.13, 179.8]:
			pts.append([lat, lon])
	for v: Dictionary in variants:
		var g: String = v.grid
		var path := _variant_file(v)
		ClimateGrid.set_paths({g: path})
		var patch: Variant = v.get("patch", [])
		var desc := {
			grid = g,
			patch = patch,
			missing = v.get("missing", false),
			truncate = v.get("truncate", -1),
			truncate_tail = v.get("truncate_tail", 0),
			append = v.get("append", 0),
			garbage_body = v.get("garbage_body", false),
		}
		for p: Array in pts:
			for md: Array in [[1, 15], [7, 1], [10, 28]]:
				_e1_row(f, "variant", p[0], p[1], md[0], md[1], String(v.name), desc)
		ClimateGrid.set_paths({})


func _variant_file(v: Dictionary) -> String:
	var g: String = v.grid
	if v.get("missing", false):
		return NO_FILE % g
	var bytes := FileAccess.get_file_as_bytes(GRID_FILES[g])
	if v.has("truncate"):
		bytes = bytes.slice(0, int(v.truncate))
	if v.has("truncate_tail"):
		bytes = bytes.slice(0, bytes.size() - int(v.truncate_tail))
	if v.has("append"):
		for k in int(v.append):
			bytes.append(0)
	if v.get("garbage_body", false):
		for k in range(64, mini(bytes.size(), 64 + 4096)):
			bytes[k] = (k * 131 + 7) & 0xFF
	for p: Dictionary in v.get("patch", []):
		match int(p.size):
			1: bytes.encode_u8(int(p.off), int(p.value))
			2: bytes.encode_u16(int(p.off), int(p.value))
			4: bytes.encode_u32(int(p.off), int(p.value))
	var path := TMP.path_join("%s_%s.bin" % [g, v.name])
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_buffer(bytes)
	fa.close()
	return path


# ------------------------------------------------------------------ E2 ClimateGrid.place

func _e2() -> void:
	var f := "e2_climate_place"
	_begin(f, "ClimateGrid.place(ctx) на дне долины: valley_msl_m × start_msl_m (рост ветра gain_per_km), + season_index/band_index/td_gradient/belt_gradient",
		"поправки на высоту; сейчас сверено на нескольких ячейках",
		"lat −60…70 (тропики, умеренные, прочие пояса, оба полушария) × lon × месяцы 1/4/7/10 × valley_msl_m {−100, 0, 500, 3000, NaN, нет ключа} × start_msl_m {нет, = долине, +300, −50, +4000}; варианты без hh1/hh5/hh6")
	var lats := [-60.0, -40.0, -25.0, -10.0, 0.0, 10.0, 25.0, 40.0, 55.0, 70.0]
	var lons := [-120.0, 10.0, 86.13, 150.0]
	var valleys := [-100.0, 0.0, 500.0, 3000.0]
	for lat: float in lats:
		for lon: float in lons:
			for m in [1, 4, 7, 10]:
				for v: float in valleys:
					for s in 5:
						var ctx := {lat = lat, lon = lon, month = m, day = 15, valley_msl_m = v}
						match s:
							1: ctx.start_msl_m = v
							2: ctx.start_msl_m = v + 300.0
							3: ctx.start_msl_m = v - 50.0
							4: ctx.start_msl_m = v + 4000.0
						_push(f, {kind = "place", variant = "real", ctx = ctx, place = ClimateGrid.place(ctx)})
	# без valley_msl_m / NaN / с одним start / пропуски ключей
	for lat: float in [-35.0, 15.0, 51.87]:
		for variant: Array in [
			[{lat = lat, lon = 86.0, month = 7, day = 15}, "no_valley"],
			[{lat = lat, lon = 86.0, month = 7, day = 15, valley_msl_m = NAN}, "nan_valley"],
			[{lat = lat, lon = 86.0, month = 7, day = 15, valley_msl_m = NAN, start_msl_m = 900.0}, "nan_valley_start"],
			[{lat = lat, lon = 86.0, month = 7, day = 15, start_msl_m = 900.0}, "start_only"],
			[{lat = lat}, "lat_only"],
			[{}, "empty"],
			[{lat = lat, lon = 86.0, month = 0, day = 40, valley_msl_m = 1000.0}, "month_out"],
			[{lat = lat, lon = 86.0, month = 13, day = -5, valley_msl_m = 1000.0}, "month_out2"],
		]:
			_push(f, {kind = "place_edge", variant = variant[1], ctx = variant[0], place = ClimateGrid.place(variant[0])})
	# сетки выключены (src none): поправки по запасным таблицам
	for off: Array in [["hh1"], ["hh5"], ["hh6"], ["hh2"], ["hh1", "hh6"], ["hh1", "hh2", "hh5", "hh6"]]:
		var paths := {}
		for g: String in off:
			paths[g] = NO_FILE % g
		ClimateGrid.set_paths(paths)
		for lat: float in [-40.0, 10.0, 51.87, 66.0]:
			for v: float in [-100.0, 500.0, 3000.0]:
				for s in 3:
					var ctx := {lat = lat, lon = 86.13, month = 7, day = 15, valley_msl_m = v}
					if s == 1:
						ctx.start_msl_m = v + 300.0
					elif s == 2:
						ctx.start_msl_m = 2.0 * v + 2000.0
					_push(f, {kind = "place_off", off = off, ctx = ctx, place = ClimateGrid.place(ctx)})
		ClimateGrid.set_paths({})
	# мелкие функции
	var cl: Dictionary = WeatherModel.config().get("climate", {})
	for lat in range(-90, 91, 5):
		for m in range(0, 14):
			_push(f, {kind = "season_index", lat = float(lat), month = m, out = ClimateGrid.season_index(m, float(lat))})
	for lat in range(-90, 91, 3):
		for s in 4:
			_push(f, {
				kind = "gradients", lat = float(lat), season = s,
				td_gradient = ClimateGrid.td_gradient(float(lat), s, cl),
				belt_tx = ClimateGrid.belt_gradient(float(lat), s, cl.get("tx_gradient_k_per_km", {}), -6.31),
				belt_dtr = ClimateGrid.belt_gradient(float(lat), s, cl.get("dtr_gradient_k_per_km", {}), -0.48),
			})
	var bounds: Array = WeatherModel.config().get("hcc_sky", {}).get("bands_abs_lat", [20, 40, 60, 75])
	for lat in range(-90, 91, 1):
		_push(f, {kind = "band_index", lat = float(lat), bounds = bounds, out = ClimateGrid.band_index(float(lat), bounds)})


# ------------------------------------------------------------------ E3 SurfaceHeat температуры

func _contexts() -> Array:
	## 8 мест: 4 фикстуры (контекст как AirPlace.context), опорное Алтай, Кэрнс (тропики, юг), полярное, бездатное.
	var list := []
	for p: Dictionary in _places:
		list.append({name = p.name, ctx = p.ctx})
	var rc := WeatherModel.reference_context()
	list.append({name = "reference", ctx = rc})
	list.append({name = "cairns", ctx = {lat = -16.9, lon = 145.8, month = 1, day = 15, valley_msl_m = 0.0, mean_msl_m = 0.0, utc_offset_h = 10.0}})
	list.append({name = "svalbard", ctx = {lat = 78.2, lon = 15.6, month = 6, day = 21, valley_msl_m = 20.0, mean_msl_m = 300.0, utc_offset_h = 1.0}})
	list.append({name = "no_valley", ctx = {lat = 40.0, lon = 30.0, month = 7, day = 15, utc_offset_h = NAN}})
	return list


func _e3() -> void:
	var f := "e3_surface_temp"
	_begin(f, "SurfaceHeat.air_temp_c (hour, t_max, z) и water_temp_c (month, day, z) по месту, месяцу, часу, высоте",
		"публичные функции без дампа; воздушной нет в Rust вообще",
		"8 мест × 12 месяцев (день 15) × часы 0…23 (+0.5) × z {долина−200, долина, долина+1000, 4000}; t_max = typical_max_c места; wcfg = surface_heat.water")
	var wcfg: Dictionary = SurfaceHeat.config().water
	var wm := WeatherModel.config()
	for pl: Dictionary in _contexts():
		var base: Dictionary = pl.ctx
		var valley := float(base.get("valley_msl_m", 0.0))
		var zs := [valley - 200.0, valley, valley + 1000.0, 4000.0]
		for m in range(1, 13):
			var ctx := base.duplicate()
			ctx.month = m
			ctx.day = 15
			var t_max := WeatherModel.typical_max_c(m, 15, wm, ctx)
			for z: float in zs:
				_push(f, {
					kind = "water", place = pl.name, ctx = ctx, month = m, day = 15, z = z,
					out = SurfaceHeat.water_temp_c(m, 15, z, ctx, wcfg),
				})
				for h in range(0, 24):
					for dh in [0.0, 0.5]:
						var hour: float = h + dh
						_push(f, {
							kind = "air", place = pl.name, ctx = ctx, hour = hour, t_max = t_max, z = z,
							out = SurfaceHeat.air_temp_c(hour, t_max, z, ctx, wcfg),
						})
		# даты у границ года для воды (lag_days, переход через год)
		for md: Array in [[1, 1], [1, 10], [1, 31], [2, 1], [3, 1], [12, 31]]:
			var ctx2 := base.duplicate()
			ctx2.month = md[0]
			ctx2.day = md[1]
			for z: float in zs:
				_push(f, {
					kind = "water_edge", place = pl.name, ctx = ctx2, month = md[0], day = md[1], z = z,
					out = SurfaceHeat.water_temp_c(md[0], md[1], z, ctx2, wcfg),
				})


# ------------------------------------------------------------------ E4 WeatherModel: меню и суточный ход

func _e4() -> void:
	var f := "e4_weather_diurnal"
	_begin(f, "WeatherModel.typical_max_c, diurnal_range_k, diurnal_state (sunrise_h/sunset_h/peak_h внутри) с ctx и без",
		"меню, цель полёта",
		"typical_max_c: с {lat, lon}, без ctx, ctx без valley_msl_m, зажим [ui.temperature_c]; diurnal_range_k: ctx без lat/lon, с cp; diurnal_state: 10 мест × месяцы × часы −1…25 × t_max, полярный день/ночь, utc NaN/число")
	var wm := WeatherModel.config()
	var ctxs := _contexts()
	var polar := [
		{name = "polar_day", ctx = {lat = 80.0, lon = 10.0, month = 6, day = 21, valley_msl_m = 0.0, utc_offset_h = 1.0}},
		{name = "polar_night", ctx = {lat = 80.0, lon = 10.0, month = 12, day = 21, valley_msl_m = 0.0, utc_offset_h = 1.0}},
		{name = "south_pole", ctx = {lat = -89.0, lon = 0.0, month = 1, day = 15, valley_msl_m = 2800.0, utc_offset_h = NAN}},
		{name = "no_lat_lon", ctx = {month = 7, day = 15}},
		{name = "empty", ctx = {}},
	]
	ctxs.append_array(polar)
	# typical_max_c
	for pl: Dictionary in ctxs:
		for m in range(1, 13):
			for d in [1, 15, 28, 31]:
				var ctx: Dictionary = pl.ctx
				var inputs := {month = m, day = d, ctx = ctx}
				_push(f, {kind = "typical_max", place = pl.name, month = m, day = d, ctx = ctx, out = WeatherModel.typical_max_c(m, d, wm, ctx)})
				if pl.ctx.has("lat") and pl.ctx.has("lon"):
					var nov := ctx.duplicate()
					nov.erase("valley_msl_m")
					_push(f, {kind = "typical_max_no_valley", place = pl.name, month = m, day = d, ctx = nov, out = WeatherModel.typical_max_c(m, d, wm, nov)})
				_push(f, {kind = "typical_max_no_ctx", month = m, day = d, ctx = {}, out = WeatherModel.typical_max_c(m, d, wm, {})})
				inputs.clear()
	# зажим диапазона: высокая и холодная ячейки
	for ctx: Dictionary in [
		{lat = 25.0, lon = 45.0, valley_msl_m = 0.0},  # аравийская жара
		{lat = -78.0, lon = 106.0, valley_msl_m = 3400.0},  # Восток
		{lat = 36.5, lon = -116.9, valley_msl_m = -80.0},  # Долина Смерти
		{lat = 67.0, lon = 135.0, valley_msl_m = 100.0},  # Верхоянск
	]:
		for m in range(1, 13):
			_push(f, {kind = "typical_max_clamp", month = m, day = 15, ctx = ctx, out = WeatherModel.typical_max_c(m, 15, wm, ctx)})
	# diurnal_range_k
	for pl: Dictionary in ctxs:
		var ctx: Dictionary = pl.ctx
		_push(f, {kind = "range", place = pl.name, ctx = ctx, out = WeatherModel.diurnal_range_k(ctx, wm)})
		if ctx.has("lat") and ctx.has("lon"):
			var cp := ClimateGrid.place(ctx)
			_push(f, {kind = "range_cp", place = pl.name, ctx = ctx, cp = cp, out = WeatherModel.diurnal_range_k(ctx, wm, cp)})
	for m in range(0, 14):
		for d in [1, 15, 31]:
			var ctx := {month = m, day = d}
			_push(f, {kind = "range_table", ctx = ctx, out = WeatherModel.diurnal_range_k(ctx, wm)})
	# diurnal_state
	var hours := [-1.0, 0.0, 2.0, 4.5, 5.99, 6.0, 7.0, 8.0, 9.5, 11.0, 12.0, 13.0, 14.5, 16.0, 17.0, 18.0, 19.0, 20.0, 21.5, 23.0, 24.0, 25.0]
	for pl: Dictionary in ctxs:
		for m in [1, 3, 6, 7, 9, 12]:
			var ctx: Dictionary = pl.ctx.duplicate()
			ctx.month = m
			ctx.day = 15
			var t_max := WeatherModel.typical_max_c(m, 15, wm, ctx)
			for tm in [t_max, 8.0, 36.0]:
				for h: float in hours:
					_push(f, {
						kind = "state", place = pl.name, ctx = ctx, t_max = tm, hour = h,
						out = WeatherModel.diurnal_state(tm, h, ctx, wm),
					})
	# cp передан явно (cp.dtr_k) и utc: число vs NaN при одном месте
	for h: float in hours:
		for utc in [NAN, 0.0, 7.0, -4.0, 12.0]:
			var ctx := {lat = 51.87, lon = 85.87, month = 7, day = 15, valley_msl_m = 304.0, utc_offset_h = utc}
			var cp := ClimateGrid.place(ctx)
			_push(f, {kind = "state_cp", ctx = ctx, cp = cp, t_max = 27.0, hour = h, out = WeatherModel.diurnal_state(27.0, h, ctx, wm, cp)})


# ------------------------------------------------------------------ E5 мелочи WeatherModel

func _e5() -> void:
	var f := "e5_weather_small"
	_begin(f, "WeatherModel.sky_params, haze_k_rh, sun_block_cover, monthly, lerp_table, interp_rows, reference_context, noon_elevation_deg, td_noise, cirrus_base_cover",
		"мелочи, которых нет в дампе отдельно",
		"таблицы по месяцам и дням 1/15/31 (+ вне диапазона), все sky.options + неизвестные, t×td с переходом через 0 и Td > T, lerp/interp по таблицам конфига за краями")
	var wm := WeatherModel.config()
	_push(f, {kind = "reference_context", out = WeatherModel.reference_context()})
	_push(f, {kind = "reference_context_cfg", cfg_empty = true, out = WeatherModel.reference_context({})})
	var skies: Array = (wm.sky as Dictionary).get("options", []).duplicate()
	skies.append_array(["few", "scattered", "broken", "", "unknown", "CLEAR"])
	for s: String in skies:
		_push(f, {kind = "sky_params", sky = s, out = WeatherModel.sky_params(s)})
	# haze_k_rh
	for t in range(-30, 46, 5):
		for dd in range(-40, 12, 3):
			var td: float = t + dd - 0.5
			_push(f, {kind = "haze", t_c = float(t), td_c = td, out = WeatherModel.haze_k_rh(float(t), td)})
	for t: float in [-0.001, 0.0, 0.001, 0.5, -0.5]:
		for td: float in [-0.001, 0.0, 0.001, -10.0, 5.0]:
			_push(f, {kind = "haze_zero", t_c = t, td_c = td, out = WeatherModel.haze_k_rh(t, td)})
	# sun_block_cover
	var covers := [-0.5, 0.0, 0.2, 0.5, 0.8, 1.0, 1.5]
	for a: float in covers:
		for b: float in covers:
			_push(f, {kind = "sun_block", w = {cirrus_cover = a, sky_cover = b}, out = WeatherModel.sun_block_cover({cirrus_cover = a, sky_cover = b})})
	_push(f, {kind = "sun_block", w = {}, out = WeatherModel.sun_block_cover({})})
	_push(f, {kind = "sun_block", w = {cirrus_cover = 0.4}, out = WeatherModel.sun_block_cover({cirrus_cover = 0.4})})
	_push(f, {kind = "sun_block", w = {sky_cover = 0.4}, out = WeatherModel.sun_block_cover({sky_cover = 0.4})})
	# monthly: таблицы конфига и крайние массивы
	var tables := {
		typical_max_c = wm.typical_max_c,
		upper_air_temp_c = (wm.upper_air as Dictionary).temp_c,
		diurnal_range_k = (wm.diurnal as Dictionary).range_k,
		td_fallback = (wm.climate as Dictionary).fallback.td_c,
		single = [4.5],
		empty = [],
		eleven = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
		long = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14],
	}
	for name: String in tables:
		var arr: Array = tables[name]
		for m in range(-1, 15):
			for d in [0, 1, 8, 14, 15, 16, 22, 28, 29, 30, 31, 40]:
				_push(f, {kind = "monthly", table = name, arr = arr, month = m, day = d, out = WeatherModel.monthly(arr, m, d)})
	for name: String in tables:
		var arr: Array = tables[name]
		for m in range(1, 13):
			_push(f, {kind = "monthly_default_day", table = name, arr = arr, month = m, out = WeatherModel.monthly(arr, m)})
	# lerp_table
	var lt := [
		[[0.0, 10.0, 30.0], [1.0, 2.0, 5.0]],
		[[0.0], [3.0]],
		[[-5.0, 0.0, 0.0, 5.0], [0.0, 1.0, 2.0, 3.0]],
		[(wm.wind_factors as Dictionary).wind_kmh, (wm.wind_factors as Dictionary).strength],
		[(wm.wind_factors as Dictionary).wind_kmh, (wm.wind_factors as Dictionary).duty],
		[(wm.wind_factors as Dictionary).dust_wind_kmh, (wm.wind_factors as Dictionary).dust],
		[(wm.extreme_by_top_agl as Dictionary).top_agl_m, (wm.extreme_by_top_agl as Dictionary).chance],
	]
	for tab: Array in lt:
		var xs: Array = tab[0]
		var lo: float = float(xs[0]) - 7.0
		var hi: float = float(xs[xs.size() - 1]) + 7.0
		for k in 41:
			var x := lo + (hi - lo) * k / 40.0
			_push(f, {kind = "lerp_table", xs = xs, ys = tab[1], x = x, out = WeatherModel.lerp_table(xs, tab[1], x)})
		for x in xs:
			_push(f, {kind = "lerp_table", xs = xs, ys = tab[1], x = float(x), out = WeatherModel.lerp_table(xs, tab[1], float(x))})
	# interp_rows
	for spec: Array in [["anchors_by_top_agl", "top_agl_m"], ["clouds_by_margin", "margin_m"]]:
		var rows: Array = wm[spec[0]]
		var lo: float = float(rows[0][spec[1]]) - 300.0
		var hi: float = float(rows[rows.size() - 1][spec[1]]) + 300.0
		for k in 61:
			var x := lo + (hi - lo) * k / 60.0
			_push(f, {kind = "interp_rows", rows_key = spec[0], key = spec[1], x = x, out = WeatherModel.interp_rows(rows, spec[1], x)})
		for r: Dictionary in rows:
			var x: float = float(r[spec[1]])
			_push(f, {kind = "interp_rows", rows_key = spec[0], key = spec[1], x = x, out = WeatherModel.interp_rows(rows, spec[1], x)})
	_push(f, {kind = "interp_rows_empty", out = WeatherModel.interp_rows([], "k", 1.0)})
	# noon_elevation_deg, td_noise
	for lat in range(-90, 91, 15):
		for m in [1, 3, 6, 9, 12]:
			_push(f, {kind = "noon_elevation", lat = float(lat), month = m, day = 15, out = WeatherModel.noon_elevation_deg(float(lat), m, 15)})
	for m in range(1, 13):
		for d in [1, 15, 28]:
			for pt: Array in [[51.87, 85.87], [-16.9, 145.8], [0.0, 0.0], [-89.0, 179.9], [43.2, 34.0]]:
				_push(f, {kind = "td_noise", month = m, day = d, lat = pt[0], lon = pt[1], out = WeatherModel.td_noise(m, d, pt[0], pt[1])})
	# cirrus_base_cover: cp (place) × sky × пояс
	for lat: float in [-80.0, -50.0, -30.0, -10.0, 10.0, 30.0, 50.0, 65.0, 80.0]:
		for m in [1, 4, 7, 10]:
			var ctx := {lat = lat, lon = 86.0, month = m, day = 15, valley_msl_m = 500.0}
			var cp := ClimateGrid.place(ctx)
			for s: String in skies:
				_push(f, {kind = "cirrus_base", ctx = ctx, sky = s, cp = cp, out = WeatherModel.cirrus_base_cover(cp, s, ctx, wm)})
	ClimateGrid.set_paths({"hh6": NO_FILE % "hh6"})
	for s: String in ["clear", "partly"]:
		var ctx2 := {lat = 51.0, lon = 86.0, month = 7, day = 15, valley_msl_m = 500.0}
		var cp2 := ClimateGrid.place(ctx2)
		_push(f, {kind = "cirrus_base_hh6_none", ctx = ctx2, sky = s, cp = cp2, out = WeatherModel.cirrus_base_cover(cp2, s, ctx2, wm)})
	ClimateGrid.set_paths({})


# ------------------------------------------------------------------ E6 ground_context: функция vs растр

func _e6() -> void:
	var f := "e6_ground_context"
	_begin(f, "WeatherModel.ground_context через terrain.height_at и через растр 25 м (HeightLayer.sample) — разность valley/mean",
		"дыра риска 2: расхождение функции и растра 25 м (только измерение, допуска нет)",
		"Онгудай (terrain недоступен без data/locations/ongudai — terrain = null), учебный остров, вулкан × радиус {2 км, 10 км, 15 км, 19 км} × число точек {15, 31} × процентиль {0.1, 0.25}; ctx пасхалки = easter_eggs.json (10 км, 15, 0.1)")
	var egg: Dictionary = Config.get_config("easter_eggs")
	var rad_egg := float(egg.get("valley_radius_m", 10000.0))
	var radii := [2000.0, rad_egg, 15000.0, 19000.0]
	var ids := ["ongudai", "training_island", "volcano_island"]
	for id: String in ids:
		var layer: HeightLayer = null
		for p: Dictionary in _places:
			if p.name == id:
				layer = p.layer
		var terrain := Terrain.new()
		add_child(terrain)
		# не бандловое место (Онгудай) Terrain собирает из сети — не трогаем
		var ok := Locations.is_bundled(id) and terrain.load_location(id)
		var tag := "terrain" if ok else "no_terrain"
		for r: float in radii:
			for n in [15, 31]:
				for pc in [0.1, 0.25]:
					var raster := WeatherModel.ground_context(layer.sample, r, n, pc)
					var row := {
						kind = "ground", place = id, source = tag, radius_m = r, samples = n, percentile = pc,
						raster = raster,
						is_egg = (r == rad_egg and n == 15 and pc == 0.1),
					}
					if ok:
						var tctx := WeatherModel.ground_context(terrain.height_at, r, n, pc)
						row.terrain = tctx
						row.diff = {
							valley_msl_m = float(tctx.valley_msl_m) - float(raster.valley_msl_m),
							mean_msl_m = float(tctx.mean_msl_m) - float(raster.mean_msl_m),
						}
						row.terrain_center_lat = terrain.center_lat
						row.terrain_center_lon = terrain.center_lon
					_push(f, row)
		# сами высоты в точках круга: разность функции и растра
		if ok:
			var diffs := []
			for j in range(-8, 9):
				for i in range(-8, 9):
					var x := i * 1100.0 + 13.0
					var z := j * 1100.0 - 7.0
					diffs.append({x = x, z = z, terrain = terrain.height_at(x, z), raster = layer.sample(x, z)})
			_push(f, {kind = "height_samples", place = id, samples = diffs})
		terrain.queue_free()
	ClimateGrid.set_paths({})


# ------------------------------------------------------------------ E7 achievement_feed.temp_at_altitude

func _e7() -> void:
	var f := "e7_temp_at_altitude"
	_begin(f, "AchievementFeed.temp_at_altitude(w, alt_msl, month, day) на погоде WeatherModel.derive",
		"живая формула профиля температуры",
		"6 погод (derive: 4 места × прогнозы, час NaN и 13; w._derived хранится сокращённо) × высоты 0…6000 шаг 250 × 4 даты; плюс w без _derived и без valley_msl_m")
	var wm := WeatherModel.config()
	var fcs := [
		{temperature_c = 30.0, wind_speed_kmh = 15.0, wind_from_deg = 270.0, sky = "clear"},
		{temperature_c = 12.0, wind_speed_kmh = 30.0, wind_from_deg = 90.0, sky = "overcast"},
	]
	var ws := []
	for pl: Dictionary in _places.slice(0, 3):
		var hour := NAN if ws.size() % 2 == 0 else 13.0
		var fc: Dictionary = fcs[ws.size() % 2]
		ws.append({place = pl.name, ctx = pl.ctx, forecast = fc, hour = hour, w = WeatherModel.derive(fc, pl.ctx, wm, hour)})
	var pl2: Dictionary = _places[0]
	for hour: float in [NAN, 8.0, 16.0]:
		if ws.size() >= 6:
			break
		var fc: Dictionary = fcs[ws.size() % 2]
		ws.append({place = pl2.name, ctx = pl2.ctx, forecast = fc, hour = hour, w = WeatherModel.derive(fc, pl2.ctx, wm, hour)})
	var dates := [[1, 15], [4, 1], [7, 31], [12, 20]]
	for e: Dictionary in ws:
		var d: Dictionary = e.w._derived
		var dv := {temperature_c = d.get("temperature_c"), valley_msl_m = d.get("valley_msl_m")}
		for md: Array in dates:
			for k in 25:
				var alt: float = 250.0 * k
				_push(f, {
					kind = "profile", place = e.place, forecast = e.forecast, hour = e.hour, derived = dv,
					alt_msl = alt, month = md[0], day = md[1],
					out = AchievementFeed.temp_at_altitude(e.w, alt, md[0], md[1]),
				})
	for w: Dictionary in [{}, {_derived = {}}, {_derived = {temperature_c = 20.0}}, {_derived = {valley_msl_m = 300.0}}, {_derived = {temperature_c = 20.0, valley_msl_m = 300.0}}]:
		for alt: float in [-100.0, 0.0, 300.0, 3000.0, 9000.0, 20000.0]:
			for md: Array in [[0, 15], [7, 15], [13, 1]]:
				_push(f, {kind = "profile_edge", derived = w.get("_derived", null), alt_msl = alt, month = md[0], day = md[1], out = AchievementFeed.temp_at_altitude(w, alt, md[0], md[1])})


# ------------------------------------------------------------------ E8 goal_estimator.weather_for

func _e8() -> void:
	var f := "e8_goal_weather"
	_begin(f, "GoalEstimator.weather_for(FlightSettings) (+ контекст места _context)",
		"цель полёта: derive + diurnal_state без рельефа",
		"12+ FlightSettings: встроенные места (altai, askarovo, aushkul, ongudai, training_island, volcano_island, wilotree_park), точка с карты, месяцы, небо, часы, ветер/температура")
	var cases := [
		{loc = "altai", m = 7, d = 15, sky = "clear", t = 26.0, w = 10.8, from = 270.0, hour = 13.0},
		{loc = "altai", m = 4, d = 3, sky = "partly", t = 12.0, w = 25.0, from = 90.0, hour = 9.0},
		{loc = "ongudai", m = 7, d = 15, sky = "overcast", t = 22.0, w = 18.0, from = 151.0, hour = 11.0},
		{loc = "ongudai", m = 1, d = 28, sky = "clear", t = 3.0, w = 5.0, from = 0.0, hour = 12.0},
		{loc = "training_island", m = 1, d = 15, sky = "clear", t = 20.0, w = 30.0, from = 180.0, hour = 15.0},
		{loc = "volcano_island", m = 1, d = 15, sky = "partly", t = 30.0, w = 12.0, from = 45.0, hour = 17.5},
		{loc = "askarovo", m = 8, d = 30, sky = "clear", t = 27.0, w = 8.0, from = 225.0, hour = 19.0},
		{loc = "aushkul", m = 5, d = 1, sky = "overcast", t = 15.0, w = 0.0, from = 315.0, hour = 7.0},
		{loc = "wilotree_park", m = 12, d = 31, sky = "partly", t = 24.0, w = 14.0, from = 135.0, hour = 14.0},
		{loc = "wilotree_park", m = 6, d = 21, sky = "clear", t = 36.0, w = 20.0, from = 90.0, hour = 10.0},
		{loc = "", m = 7, d = 1, sky = "clear", t = 28.0, w = 15.0, from = 270.0, hour = 13.0, pick = [-16.9, 145.8]},
		{loc = "", m = 12, d = 15, sky = "partly", t = 5.0, w = 20.0, from = 0.0, hour = 12.0, pick = [64.1, -21.9]},
		{loc = "altai", m = 7, d = 15, sky = "clear", t = 30.0, w = 10.0, from = 270.0, hour = 21.0},
		{loc = "altai", m = 7, d = 15, sky = "clear", t = 30.0, w = 10.0, from = 270.0, hour = 5.0},
		{loc = "no_such_place", m = 3, d = 10, sky = "overcast", t = 10.0, w = 10.0, from = 10.0, hour = 12.0},
	]
	var wc := WeatherModel.config()
	for c: Dictionary in cases:
		var s := FlightSettings.new()
		s.location_id = c.loc
		s.month = c.m
		s.day = c.d
		s.sky = c.sky
		s.temperature_c = c.t
		s.wind_speed_kmh = c.w
		s.wind_from_deg = c.from
		s.start_hour = c.hour
		if c.has("pick"):
			s.pick_lat = c.pick[0]
			s.pick_lon = c.pick[1]
		var loc := Locations.config(s.location_id)
		_push(f, {
			kind = "weather_for", settings = c,
			builtin = Locations.is_builtin(s.location_id),
			loc_center_lat = loc.get("center_lat"), loc_center_lon = loc.get("center_lon"), loc_utc_offset_h = loc.get("utc_offset_h"),
			ctx = GoalEstimator._context(s, wc),
			forecast = s.forecast(),
			out = GoalEstimator.weather_for(s),
		})


# ------------------------------------------------------------------ E9 AtmoDay.sun_direction / hour_at

func _e9() -> void:
	var f := "e9_atmo_day"
	_begin(f, "AtmoDay.sun_direction(hour, lat, lon, month, day, utc) и AtmoDay.hour_at(t) с зажимом world.time",
		"пограничные часы, utc NaN",
		"lat −60…80 шаг 20 × lon {−120, 86.13} × месяцы {1, 4, 7, 10} × часы −1…25 (+ долевые) × utc {NaN, 7, −5}; hour_at: start_hour × speed × t0 × t, min/max_hour из world.json")
	var tcfg: Dictionary = Config.get_config("world").get("time", {})
	var hours := []
	for h in range(-1, 26):
		hours.append(float(h))
	hours.append_array([5.99, 6.01, 19.99, 20.01, 0.25, 23.75, 12.5])
	for lat in range(-60, 81, 20):
		for lon: float in [-120.0, 86.13]:
			for m in [1, 4, 7, 10]:
				for utc in [NAN, 7.0, -5.0]:
					for h: float in hours:
						var v := AtmoDay.sun_direction(h, float(lat), lon, m, 15, utc)
						_push(f, {kind = "sun", hour = h, lat = float(lat), lon = lon, month = m, day = 15, utc_offset_h = utc, out = v})
	for lat in [-89, 89]:
		for m in [6, 12]:
			for h in [0.0, 6.0, 12.0, 18.0]:
				_push(f, {kind = "sun_pole", hour = h, lat = float(lat), lon = 0.0, month = m, day = 21, utc_offset_h = NAN, out = AtmoDay.sun_direction(h, float(lat), 0.0, m, 21, NAN)})
	var ts := [-1000.0, -300.0, -1.0, 0.0, 0.5, 1.0, 60.0, 600.0, 3600.0, 7200.0, 20000.0, 50000.0, 1.0e6]
	for sh in [0.0, 5.0, 5.99, 6.0, 12.0, 13.0, 19.5, 20.0, 23.0, 30.0, -3.0]:
		for sp in [0.0, 1.0, 60.0, 600.0, -1.0]:
			for t0 in [0.0, 100.0, -50.0]:
				var d := AtmoDay.new()
				d.start_hour = sh
				d.speed = sp
				d.t0 = t0
				for t: float in ts:
					_push(f, {kind = "hour_at", start_hour = sh, speed = sp, t0 = t0, t = t, min_hour = tcfg.get("min_hour"), max_hour = tcfg.get("max_hour"), out = d.hour_at(t)})


# ------------------------------------------------------------------ E10 SurfaceHeat потоки, SurfaceHeating

func _e10() -> void:
	var f := "e10_heat_flux"
	_begin(f, "SurfaceHeat.shortwave/land_flux/water_flux/built_night_flux/mix_flux по сетке; SurfaceHeating.directions/built_night/sun_at/sunset_h по часам",
		"в Rust юнит-тестов потока нет",
		"классы 0…8 × cos_inc × cover × влажность m; mix_flux: чистые классы, смеси, нулевые доли, вода/лёд, застройка ночью; SurfaceHeating: места × даты × часы 0…24 (+ выкл.)")
	var cfg := SurfaceHeat.config()
	var ncls := SurfaceLayer.CLASS_COUNT
	var covers := [0.0, 0.3, 0.7, 1.0]
	# shortwave
	for cos_inc: float in [-0.3, 0.0, 0.25, 0.6, 0.95, 1.0]:
		for sin_el: float in [-0.2, 0.0, 0.05, 0.3, 0.7, 1.0]:
			for cv: float in covers:
				_push(f, {kind = "shortwave", cos_inc = cos_inc, sin_el = sin_el, cover = cv, out = SurfaceHeat.shortwave(cos_inc, sin_el, cv, 1.0, cfg)})
	for kt in range(0, 41):
		var k: float = kt / 40.0
		_push(f, {kind = "diffuse_fraction", k_t = k, out = SurfaceHeat.diffuse_fraction(k)})
	for cv: float in [-0.2, 0.0, 0.5, 1.0, 1.4]:
		_push(f, {kind = "long_wave", cover = cv, out = SurfaceHeat.long_wave(cv, cfg)})
	# land_flux и bowen по классам
	var ms := [0.0, 0.2, 0.25, 0.3, 0.47, 0.6, 0.7, 0.85, 1.0]
	for c in ncls:
		for m: float in ms:
			_push(f, {kind = "bowen", cls = c, m = m, out = SurfaceHeat.bowen(c, m, cfg)})
			if c == SurfaceHeat.WATER_CLASS:
				continue
			for kd: float in [0.0, 150.0, 450.0, 800.0, 1000.0]:
				for cv: float in covers:
					_push(f, {kind = "land_flux", cls = c, k_down = kd, cover = cv, m = m, out = SurfaceHeat.land_flux(c, kd, cv, m, cfg)})
	# water_flux / плотность
	for z: float in [0.0, 500.0, 3000.0, -100.0]:
		_push(f, {kind = "air_density", z = z, out = SurfaceHeat.air_density_factor(z, cfg)})
		for tw: float in [2.0, 15.0, 25.0]:
			for ta: float in [-5.0, 15.0, 30.0]:
				for u: float in [0.0, 0.5, 1.0, 4.0, 9.0]:
					_push(f, {kind = "water_flux", t_water_c = tw, t_air_c = ta, u_ms = u, z_m = z, out = SurfaceHeat.water_flux(tw, ta, u, cfg, z)})
	# built_night_flux
	for sin_s: float in [0.0, 0.2, 0.6]:
		for dt: float in [0.0, 0.5, 1.5, 4.0, 12.0]:
			for cv: float in [0.0, 0.8]:
				for m: float in [0.2, 0.5]:
					var night := {sin_s = sin_s, dt_h = dt}
					_push(f, {kind = "built_night_flux", night = night, cover = cv, m = m, out = SurfaceHeat.built_night_flux(night, cv, m, cfg)})
	# mix_flux: направления солнца по классам (12 ч, лето 52°) и разные нормали
	var sun_a := PackedVector3Array()
	var sun_b := PackedVector3Array()
	sun_a.resize(ncls)
	sun_b.resize(ncls)
	for k in ncls:
		sun_a[k] = TerrainGeo.sun_direction(180.0 + 6.0 * k, 55.0 - 3.0 * k)
		sun_b[k] = Vector3.ZERO if k % 3 == 0 else TerrainGeo.sun_direction(90.0 + 10.0 * k, 12.0 + k)
	var normals := [Vector3(0, 1, 0), Vector3(-0.3, 0.9, 0.1).normalized(), Vector3(0.6, 0.6, -0.4).normalized(), Vector3(0.2, -0.1, 0.7)]
	var fr_list := []
	for c in ncls:
		var a := PackedFloat32Array()
		a.resize(ncls)
		a[c] = 1.0
		fr_list.append({name = "pure_%d" % c, fracs = a})
	for mix: Array in [[0.5, 0.5, 0, 0, 0, 0, 0, 0, 0], [0, 0.2, 0.2, 0.2, 0.2, 0.2, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0.4, 0.3, 0.3], [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.2], [0.3, 0, 0, 0, 0, 0, 0.7, 0, 0], [0, 0, 0, 0, 0, 0, 0.6, 0.4, 0], [2, 0, 4, 0, 0, 0, 0, 2, 0], [0, 0, 0, 0, 0, 0, 0, 0, 0], [-0.5, 0.5, 0.5, 0, 0, 0, 0, 0, 0]]:
		var a := PackedFloat32Array()
		a.resize(ncls)
		for k in ncls:
			a[k] = mix[k]
		fr_list.append({name = "mix", fracs = a})
	var waters := [{}, {t_water_c = 18.0, t_air_c = 25.0, u_ms = 3.0}, {t_water_c = 18.0, t_air_c = 25.0, u_ms = 3.0, z_m = 1500.0}, {t_water_c = -1.0, t_air_c = -6.0, u_ms = 2.0}, {t_water_c = 0.0}, {t_water_c = 10.0}]
	var nights := [{}, {sin_s = 0.35, dt_h = 1.2}, {sin_s = 0.0, dt_h = 8.0}]
	for fr: Dictionary in fr_list:
		for ni in normals.size():
			for sun_i in 2:
				var cs: PackedVector3Array = sun_a if sun_i == 0 else sun_b
				for cv: float in [0.0, 0.6]:
					for m: float in [0.2, 0.5, 0.8]:
						for wi in waters.size():
							for nj in nights.size():
								# полный перебор не нужен: водa/ночь перебираем у части сочетаний
								if (wi != 0 or nj != 0) and (ni > 1 or sun_i == 1 or m != 0.5):
									continue
								var sky := {cover = cv, sky_heat = 1.0}
								if nj > 0:
									sky.night = nights[nj]
								var out := SurfaceHeat.mix_flux(fr.fracs, 0, normals[ni], cs, m, sky, waters[wi], cfg)
								_push(f, {
									kind = "mix_flux", name = fr.name, fracs = fr.fracs, normal = normals[ni], class_sun = cs,
									m = m, sky = sky, water = waters[wi], out = out,
								})
	# с ненулевым смещением off в массиве долей
	var big := PackedFloat32Array()
	big.resize(3 * ncls)
	for k in ncls:
		big[ncls + k] = 1.0 / ncls
	big[2 * ncls + SurfaceLayer.GRASS] = 1.0
	for off in [0, ncls, 2 * ncls]:
		_push(f, {kind = "mix_flux_off", fracs = big, off = off, normal = Vector3(0, 1, 0), class_sun = sun_a, m = 0.5, sky = {cover = 0.2}, out = SurfaceHeat.mix_flux(big, off, Vector3(0, 1, 0), sun_a, 0.5, {cover = 0.2}, {}, cfg)})
	# SurfaceHeating по часам
	var wmc := WeatherModel.config()
	var disabled := wmc.duplicate(true)
	(disabled.heating as Dictionary).enabled = false
	var spots := [
		{name = "altai_jul", lat = 51.87, lon = 85.87, month = 7, day = 15, utc = 7.0},
		{name = "altai_dec", lat = 51.87, lon = 85.87, month = 12, day = 21, utc = 7.0},
		{name = "cairns_jan", lat = -16.9, lon = 145.8, month = 1, day = 15, utc = 10.0},
		{name = "solar_time", lat = 40.0, lon = 30.0, month = 3, day = 21, utc = NAN},
		{name = "polar_day", lat = 80.0, lon = 10.0, month = 6, day = 21, utc = 1.0},
		{name = "polar_night", lat = 80.0, lon = 10.0, month = 12, day = 21, utc = 1.0},
		{name = "equator", lat = 0.0, lon = 120.0, month = 9, day = 23, utc = 8.0},
	]
	for sp: Dictionary in spots:
		for cfgs in 2:
			var hs := SurfaceHeating.new()
			hs.setup(sp.lat, sp.lon, sp.month, sp.day, sp.utc, wmc if cfgs == 0 else disabled)
			_push(f, {kind = "heating_setup", spot = sp, enabled = hs.enabled, lags_h = hs.lags_h, sunset_h = hs.sunset_h, doy = hs.doy})
			for k in 61:
				var hour: float = -1.0 + 26.0 * k / 60.0
				_push(f, {
					kind = "heating", spot = sp, enabled = hs.enabled, hour = hour,
					directions = hs.directions(hour), sun = hs.sun_at(hour), built_night = hs.built_night(hour),
				})
			for hour: float in [hs.sunset_h - 0.01, hs.sunset_h, hs.sunset_h + 0.01, hs.sunset_h + 3.0]:
				if is_nan(hour):
					continue
				_push(f, {kind = "heating", spot = sp, enabled = hs.enabled, hour = hour, directions = hs.directions(hour), sun = hs.sun_at(hour), built_night = hs.built_night(hour)})


# ------------------------------------------------------------------ служебное

func _begin(f: String, what: String, why: String, inputs: String) -> void:
	_files[f] = PackedStringArray()
	_notes[f] = {what = what, why = why, inputs = inputs}


func _push(f: String, row: Dictionary) -> void:
	var rows: PackedStringArray = _files[f]
	rows.append(JSON.stringify(_clean(row), "", true, true))
	_files[f] = rows


## Детерминированный ГСЧ 0..1 (LCG), не зависит от RandomNumberGenerator Godot.
func _rnd() -> float:
	_seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
	return float(_seed) / 2147483648.0


## Слой рельефа места из фикстуры W8 (только высоты) и заголовок.
func _load_layer(name: String) -> Variant:
	var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
	var bin := FileAccess.get_file_as_bytes("%s/places/%s.bin" % [FIX, name])
	var w := int(head.grid.width)
	var h := int(head.grid.height)
	var n := w * h
	if bin.size() != 5 * n:
		push_error("weather_ref2: размер %s.bin" % name)
		return null
	var h_off := float(head.h_offset)
	var h_scale := float(head.h_scale)
	var hs := PackedFloat32Array()
	hs.resize(n)
	for k in n:
		hs[k] = h_off + bin.decode_s16(2 * k) * h_scale
	var layer := HeightLayer.from_heights(
		name, w, h, float(head.grid.spacing), float(head.grid.origin_x), float(head.grid.origin_z), hs
	)
	return {head = head, layer = layer}


func _clean(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return v if is_finite(v) else null
		TYPE_DICTIONARY:
			var o := {}
			for k in v:
				o[k] = _clean(v[k])
			return o
		TYPE_ARRAY:
			var o := []
			for e in v:
				o.append(_clean(e))
			return o
		TYPE_VECTOR2:
			return [_clean(v.x), _clean(v.y)]
		TYPE_VECTOR3:
			return [_clean(v.x), _clean(v.y), _clean(v.z)]
		TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_PACKED_VECTOR3_ARRAY:
			var o := []
			for e: Vector3 in v:
				o.append(_clean(e))
			return o
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var o := []
			for e in v:
				o.append(_clean(float(e)))
			return o
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return Array(v)
		TYPE_STRING_NAME:
			return String(v)
	return v


func _remove_tmp() -> void:
	var d := DirAccess.open(TMP)
	if d == null:
		return
	for fn in d.get_files():
		d.remove(fn)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	DirAccess.rename_absolute(tmp, path)
