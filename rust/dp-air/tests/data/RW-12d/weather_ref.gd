extends Node
## Эталоны RW-12d: (1) сырая ячейка климата мест (W5 v8: loc.climate_cell/climate_cell_lag, ClimateGrid.at);
## (2) погода дневных случаев ongudai_day_* (cases/<имя>.weather.json, W8 v2) — Atmosphere._apply_day на
## моментах случая тем же путём, что Atmosphere._f_resolve (ветка прогноза, t0 = 0).
## Запуск: weather_ref.sh [--out=<каталог>] (под замком cpu). Выход: climate_cells.json, <случай>.weather.json.

const FIX := "res://tests/fixtures/wind"
const CASES := ["ongudai_day_1", "ongudai_day_2", "ongudai_day_3"]

var _out := ""


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://rust/dp-air/tests/data/RW-12d/out")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var ok := _cells() and _cases()
	get_tree().quit(0 if ok else 1)


## Места фикстур с loc.climate: ячейка на дату места и на дату сдвига воды (как air_place_data.gd).
func _cells() -> bool:
	var res := {}
	var lag := int(round(float(SurfaceHeat.config().get("water", {}).get("lag_days", 30.0))))
	for name in ["ongudai", "training_island", "volcano_island"]:
		var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
		var loc: Dictionary = head.loc
		var lat := float(loc.center_lat)
		var lon := float(loc.center_lon)
		var month := int(loc.get("month", 7))
		var day := int(loc.get("day", 15))
		var doy := SunClock.day_of_year(month, day) - lag
		if doy < 1:
			doy += 365
		var md := SurfaceHeat._month_day(doy)
		res[name] = {
			climate_cell = ClimateGrid.at(lat, lon, month, day),
			climate_cell_lag = ClimateGrid.at(lat, lon, int(md.x), int(md.y)),
			lag_days = lag,
		}
	_write("climate_cells.json", JSON.stringify(_clean(res), "\t", true, true) + "\n")
	return true


func _cases() -> bool:
	var wm := WeatherModel.config()
	var acfg: Dictionary = Config.get_config("atmosphere")
	var interval := float(acfg.thermal.state_update_interval_s)
	for cname: String in CASES:
		var case: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/cases/%s.json" % [FIX, cname]))
		var cond: Dictionary = case.conditions
		var layer: Variant = _load_layer(String(case.place))
		if layer == null:
			return false
		var loc: Dictionary = layer.head.loc
		var ctx := AirPlace.context(layer.layer, loc, wm)
		var fc: Dictionary = cond.forecast
		var ov: Dictionary = cond.get("overrides", {})
		var peak := float(WeatherModel.derive(fc, ctx).thermal_spacing_m)
		var derive_fn := func(h: float) -> Dictionary:
			var dw := WeatherModel.derive(fc, ctx, {}, h)
			dw.thermal_spacing_m = peak
			for k: Variant in ov:
				dw[k] = ov[k]
			dw.erase("static_thermals")
			return dw
		var d := AtmoDay.new()
		d.start_hour = float(cond.start_hour)
		d.t0 = 0.0
		d.speed = float(cond.speed)
		d.quantum_h = float(cond.quantum_h)
		d.weather_fn = derive_fn
		d.sun_fn = AtmoDay.sun_direction.bind(
			float(loc.center_lat), float(loc.center_lon), int(loc.month), int(loc.day), float(loc.utc_offset_h)
		)
		var a := Atmosphere.new()
		a.configure(acfg, derive_fn.call(float(cond.start_hour)))
		a.set_day(d)
		var day := {}
		for t: float in case.times_s:
			a.time_s = t
			a._apply_day(floorf(t / interval) * interval)
			var wc := a._wind_conditions()
			var s := d.sun_at(t)
			day["%.9f" % d.hour_at(t)] = {
				t = t, hour = d.hour_at(t), weather = a._weather,
				bg_sink = a._bg_sink, conv_amp = a._conv_amp, mech_k = a._mech_k,
				edge_factor = a.field.get_edge_factor(), field_insolation = a.field.insolation,
				cloudbase_agl = a._cloudbase_agl, get_insolation = a.get_insolation(),
				wind_conditions = [wc.x, wc.y], sun_at = [s.x, s.y, s.z],
			}
		a.free()
		var out := {
			version = 1,
			generator = "RW-12d weather_ref.gd (Atmosphere._apply_day на моментах случая; derive: ctx из растра места, час — разгар дня)",
			derive = WeatherModel.derive(fc, ctx),
			day = day,
		}
		_write("%s.weather.json" % cname, JSON.stringify(_clean(out), "\t", true, true) + "\n")
	return true


func _load_layer(name: String) -> Variant:
	var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
	var bin := FileAccess.get_file_as_bytes("%s/places/%s.bin" % [FIX, name])
	var w := int(head.grid.width)
	var h := int(head.grid.height)
	var n := w * h
	if bin.size() != 5 * n:
		push_error("weather_ref: размер %s.bin" % name)
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


func _write(fname: String, text: String) -> void:
	var f := FileAccess.open(_out.path_join(fname), FileAccess.WRITE)
	f.store_string(text)
	f.close()
