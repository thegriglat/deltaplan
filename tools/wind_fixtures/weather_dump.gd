extends Node
## Дамп погоды из прогноза (RW-12b): эталон GDScript для rust/dp-air/tests/weather_derive.rs.
## На каждую строку: сырая ячейка ClimateGrid.at, контекст места (как AirPlace.context), прогноз, час,
## ClimateGrid.place (без и с start_msl_m) и полный словарь WeatherModel.derive.
## Запуск: weather_dump.sh [--out=<каталог>] | --verify (под замком cpu: .dpcli/dpcli lock cpu <имя> -- …).
## Выход: <out>/rows.jsonl (json lines, sort_keys, полная точность; NaN и inf -> null), manifest.json;
## weather_dump.sh сжимает rows.jsonl в rows.jsonl.zst.

const FIX := "res://tests/fixtures/wind"
const DEFAULT_OUT := "res://rust/dp-air/tests/data/weather_dump"

## Места: файл фикстуры, какие сетки ClimateGrid выключить (имя -> путь в никуда), полный набор дат и часов.
const PLACES := [
	{name = "ongudai", fixture = "ongudai", off = [], full = true},
	{name = "training_island", fixture = "training_island", off = [], full = true},
	{name = "volcano_island", fixture = "volcano_island", off = [], full = true},
	{name = "synthetic", fixture = "synthetic", off = ["hh1", "hh2", "hh5", "hh6"], full = true},
	{name = "ongudai_no_hh1", fixture = "ongudai", off = ["hh1"], full = false},
	{name = "ongudai_no_hh6", fixture = "ongudai", off = ["hh6"], full = false},
]
const EXTRA_DATES := [[1, 15], [4, 15], [10, 15]]
const HOURS_FULL := [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0]
const HOURS_PART := [8.0, 12.0, 16.0, 20.0]
const TEMPS := [5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 35.0]
const WINDS := [0.0, 10.0, 20.0, 30.0, 40.0]
const DIRS := [0.0, 90.0, 180.0, 270.0]
const SKIES := ["clear", "few", "scattered", "broken", "overcast", "partly"]

var _out := ""
var _rows := PackedStringArray()


func _ready() -> void:
	_out = ProjectSettings.globalize_path(DEFAULT_OUT)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var ok := _run()
	get_tree().quit(0 if ok else 1)


func _run() -> bool:
	var cfg := WeatherModel.config()
	var n_combo := 0
	for pd: Dictionary in PLACES:
		var layer: Variant = _load_layer(String(pd.fixture))
		if layer == null:
			return false
		var head: Dictionary = layer.head
		var paths := {}
		for g: String in pd.off:
			paths[g] = "res://tools/wind_fixtures/no_such_climate_%s.bin" % g
		ClimateGrid.set_paths(paths)
		var loc: Dictionary = head.loc
		var dates := [[int(loc.month), int(loc.day)]]
		if bool(pd.full):
			for d in EXTRA_DATES:
				if d not in dates:
					dates.append(d)
		var hours: Array = HOURS_FULL if bool(pd.full) else HOURS_PART
		var start_msl := float(head.start_sites[0].h_msl) if not (head.start_sites as Array).is_empty() else NAN
		for date in dates:
			var l := loc.duplicate()
			l.month = date[0]
			l.day = date[1]
			var ctx := AirPlace.context(layer.layer, l, cfg)
			var cell := ClimateGrid.at(float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day))
			var ctx_s := ctx.duplicate()
			ctx_s.start_msl_m = start_msl
			var base := {
				place = pd.name, ctx = ctx, start_msl_m = start_msl, cell = cell,
				place_nostart = ClimateGrid.place(ctx), place_start = ClimateGrid.place(ctx_s),
			}
			var nan_ctx := ctx.duplicate()
			nan_ctx.valley_msl_m = NAN
			var row0 := base.duplicate()
			row0.kind = "place_nan_valley"
			row0.place_nostart = ClimateGrid.place(nan_ctx)
			nan_ctx.start_msl_m = start_msl
			row0.place_start = ClimateGrid.place(nan_ctx)
			row0.ctx = nan_ctx
			_push(row0)
			for hour: float in [NAN] + hours:
				n_combo += 1
				for ti in TEMPS.size():
					for k in 4:
						var hi := 0 if is_nan(hour) else int(hour)
						var fc := {
							temperature_c = TEMPS[ti],
							wind_speed_kmh = WINDS[(ti + k + hi) % WINDS.size()],
							wind_from_deg = DIRS[k],
							sky = SKIES[(ti * 2 + k + hi) % SKIES.size()],
						}
						var row := base.duplicate()
						row.kind = "derive"
						row.hour = hour
						row.forecast = fc
						row.weather = WeatherModel.derive(fc, ctx, {}, hour)
						_push(row)
	ClimateGrid.set_paths({})
	_reference_rows()
	_write_bytes(_out.path_join("rows.jsonl"), ("\n".join(_rows) + "\n").to_utf8_buffer())
	var manifest := {
		format = "json lines (rows.jsonl.zst, zstd): kind=derive|place_nan_valley|reference; place, ctx (WeatherModel/AirPlace.context), start_msl_m, cell (ClimateGrid.at), place_nostart / place_start (ClimateGrid.place без и с start_msl_m), hour (null — разгар дня), forecast, weather (WeatherModel.derive(forecast, ctx, {}, hour)); NaN и inf -> null",
		godot = Engine.get_version_info().string,
		rows = _rows.size(),
		combos = n_combo,
		places = PLACES.map(func(p: Dictionary) -> String: return String(p.name)),
	}
	_write_bytes(_out.path_join("manifest.json"), (JSON.stringify(manifest, "\t", true, true) + "\n").to_utf8_buffer())
	print("weather_dump: готово, %d строк, %s" % [_rows.size(), _out])
	return true


## Опорные места тестов test_weather_model.gd: Алтай (reference_context, июль и апрель), Кэрнс, место без valley_msl_m.
func _reference_rows() -> void:
	var rc := WeatherModel.reference_context()
	var list := []
	for m in [7, 4]:
		var c := rc.duplicate()
		c.month = m
		list.append(c)
	list.append({lat = -16.9, lon = 145.8, month = 1, day = 15, valley_msl_m = 0.0, mean_msl_m = 0.0})
	list.append({lat = 51.9, lon = 85.9, month = 7, day = 15})
	for c: Dictionary in list:
		var cell := ClimateGrid.at(float(c.lat), float(c.lon), int(c.month), int(c.day))
		_push({kind = "reference", ctx = c, cell = cell, place_nostart = ClimateGrid.place(c)})


func _push(row: Dictionary) -> void:
	_rows.append(JSON.stringify(_clean(row), "", true, true))


## Слой рельефа места из фикстуры W8 (только высоты) и заголовок.
func _load_layer(name: String) -> Variant:
	var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
	var bin := FileAccess.get_file_as_bytes("%s/places/%s.bin" % [FIX, name])
	var w := int(head.grid.width)
	var h := int(head.grid.height)
	var n := w * h
	if bin.size() != 5 * n:
		push_error("weather_dump: размер %s.bin" % name)
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
	return v


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	DirAccess.rename_absolute(tmp, path)
