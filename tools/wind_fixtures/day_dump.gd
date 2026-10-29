extends Node
## Дамп хода дня и коэффициентов (RW-12c): эталон GDScript для rust/dp-air/tests/weather_day.rs.
## Строки (kind): "day" — AtmoDay (hour_at, weather_at, bracket, value_at, sun_at, source_at) над
## WeatherModel.derive по прогнозу, как Atmosphere._f_resolve; "day_state" — Atmosphere._apply_day по
## шагам (сетка state_update_interval_s); "coeffs" — Atmosphere._cache_coefficients, get_insolation,
## _wind_conditions; "blend" — траектория _update_weather/_blend. Запуск: day_dump.sh [--out=<каталог>] | --verify
## (под замком cpu: .dpcli/dpcli lock cpu <имя> -- …). Выход: rows.jsonl (json lines, sort_keys, полная точность;
## NaN и inf -> null), manifest.json; day_dump.sh сжимает rows.jsonl в rows.jsonl.zst.

const FIX := "res://tests/fixtures/wind"
const DEFAULT_OUT := "res://rust/dp-air/tests/data/day_dump"

const PLACES := [
	{name = "ongudai", fixture = "ongudai", off = []},
	{name = "training_island", fixture = "training_island", off = []},
	{name = "volcano_island", fixture = "volcano_island", off = []},
	{name = "synthetic", fixture = "synthetic", off = ["hh1", "hh2", "hh5", "hh6"]},
]
const FORECASTS := [
	{temperature_c = 28.0, wind_speed_kmh = 15.0, wind_from_deg = 270.0, sky = "scattered"},
	{temperature_c = 18.0, wind_speed_kmh = 30.0, wind_from_deg = 90.0, sky = "broken"},
	{temperature_c = 33.0, wind_speed_kmh = 5.0, wind_from_deg = 180.0, sky = "clear"},
]
## start_hour, speed, quantum_h, t0 (время атмосферы, с).
const TIMINGS := [
	{start_hour = 12.0, speed = 1.0, quantum_h = 0.016666666666666666, t0 = 0.0},
	{start_hour = 9.0, speed = 60.0, quantum_h = 0.25, t0 = 0.0},
	{start_hour = 19.5, speed = 60.0, quantum_h = 0.016666666666666666, t0 = 100.0},
	{start_hour = 5.0, speed = 1.0, quantum_h = 0.05, t0 = -50.0},
]
const T_OFFSETS := [-300.0, -1.0, 0.0, 0.1, 29.9, 30.0, 59.99, 60.0, 600.0, 3600.0, 7200.0, 20000.0, 40000.0]
const POINTS := [[0.0, 0.0], [1500.0, -800.0], [-3000.0, 2500.0]]
const VALUE_KEYS := [
	"background_sink_ms", "convective_turbulence_ms", "mech_turbulence_k", "thermal_edge_k",
	"cloudbase_agl_m", "cirrus_cover", "sky_cover", "no_such_key",
]
const PRESETS := ["weather/medium", "weather/storm", "weather/strong", "weather/wave", "weather/weak"]
const LEE_OPTIONAL := [
	"shear_layer_m", "danger_min_wind_ms", "danger_full_wind_ms", "danger_sink_per_wind",
	"danger_turbulence_per_wind", "burst_per_wind", "burst_scale_m", "burst_threshold", "burst_width",
	"rotor_reverse", "rotor_height_fraction", "rotor_max_amplitude_ms", "heat_kill_wm2", "heat_sigma_per_wstar",
]
const COEFF_VARS := [
	"_bg_sink", "_ground_fade", "_ridge_eff", "_ridge_decay", "_ridge_shift_k", "_ridge_shift_max",
	"_ridge_max", "_lee_depth", "_lee_relief", "_lee_sink", "_lee_turb", "_lee_wind_red", "_lee_shear",
	"_lee_danger_min", "_lee_danger_full", "_lee_danger_sink", "_lee_danger_turb", "_lee_burst",
	"_lee_burst_k", "_lee_burst_thr", "_lee_burst_width", "_lee_reverse", "_lee_rotor_h", "_lee_rotor_max",
	"_lee_heat_full", "_lee_heat_wstar_k", "_mech_k_base", "_mech_k", "_mech_boost", "_mech_h",
	"_vert_ratio", "_turb_max", "_conv_amp", "_conv_norm", "_wave_ref_agl", "_in_cloud_turb",
	"_in_cloud_eject", "_in_cloud_scale_k", "_edge_factor_base", "_edge_width", "_cloudbase_agl",
]
const BLEND_DTS := [0.1, 1.0, 0.5, 2.0, 5.0]

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
	var wm := WeatherModel.config()
	var acfg: Dictionary = Config.get_config("atmosphere")
	var world_time: Dictionary = Config.get_config("world").get("time", {})
	var derived_pool := []  # погода для строк coeffs и blend
	var n_day := 0
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
		var ctx := AirPlace.context(layer.layer, loc, wm)
		var cell := ClimateGrid.at(float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day))
		var fi := 0
		for fc: Dictionary in FORECASTS:
			var ti := 0
			for tm: Dictionary in TIMINGS:
				var ov := {}
				if fi == 1 and ti == 1:
					ov = {thermal_spacing_m = 777.0, cloud_size_factor = 1.3}
				var d := _make_day(fc, ctx, ov, tm, loc)
				var row := {
					kind = "day", place = pd.name, ctx = ctx, cell = cell, forecast = fc, overrides = ov,
					timing = tm, world_time = world_time, loc = loc,
					initial = d.initial, samples = [],
				}
				for off: float in T_OFFSETS:
					var t := float(tm.t0) + off
					var day: AtmoDay = d.day
					var b := day.bracket(t)
					var vals := {}
					for k: String in VALUE_KEYS:
						vals[k] = day.value_at(t, k, 0.7)
					var srcs := []
					for p: Array in POINTS:
						srcs.append(day.source_at(p[0], p[1], t))
					var sd := day.sun_at(t)
					row.samples.append({
						t = t, hour = day.hour_at(t), q = floori(day.hour_at(t) / day.quantum_h), f = b[2],
						weather = day.weather_at(t), w1 = b[1], value_at = vals, source = srcs,
						sun = [sd.x, sd.y, sd.z],
					})
				_push(row)
				n_day += 1
				if ti == 1 or (ti == 0 and fi == 0):
					_push(_day_state_row(String(pd.name), fc, ctx, ov, tm, loc, acfg))
				if ti == 1 and fi < 2:
					derived_pool.append({label = "%s fc%d h%.2f" % [pd.name, fi, tm.start_hour], w = d.initial})
					var d2 = _make_day(fc, ctx, ov, tm, loc).day
					derived_pool.append({label = "%s fc%d h+3" % [pd.name, fi], w = d2.weather_at(float(tm.t0) + 3.0 * 3600.0 / float(tm.speed))})
				ti += 1
			fi += 1
	ClimateGrid.set_paths({})
	_coeff_rows(acfg, derived_pool)
	_blend_rows(acfg, derived_pool)
	_write_bytes(_out.path_join("rows.jsonl"), ("\n".join(_rows) + "\n").to_utf8_buffer())
	var manifest := {
		format = "json lines (rows.jsonl.zst, zstd): kind=day (AtmoDay над derive: initial, samples[t, hour, q, f, weather=weather_at, w1, value_at, source, sun]) | day_state (Atmosphere._apply_day по шагам) | coeffs (_cache_coefficients и др.) | blend (_update_weather/_blend); NaN и inf -> null",
		godot = Engine.get_version_info().string,
		rows = _rows.size(),
		day_rows = n_day,
		places = PLACES.map(func(p: Dictionary) -> String: return String(p.name)),
	}
	_write_bytes(_out.path_join("manifest.json"), (JSON.stringify(manifest, "\t", true, true) + "\n").to_utf8_buffer())
	print("day_dump: готово, %d строк, %s" % [_rows.size(), _out])
	return true


## Тестовая сила источника: функция (x, z, час), местами выходит за 0..1 (проверка зажима).
static func test_source(x: float, z: float, h: float) -> float:
	return 0.5 + 0.0004 * x - 0.0003 * z + 0.03 * (h - 12.0)


## День как Atmosphere._f_resolve (ветка прогноза): погода по часу через derive, шаг сетки источников
## фиксирован по умолчанию-часу, переопределения поверх, без static_thermals.
func _make_day(fc: Dictionary, ctx: Dictionary, ov: Dictionary, tm: Dictionary, loc: Dictionary) -> Dictionary:
	var peak := float(WeatherModel.derive(fc, ctx).thermal_spacing_m)
	var derive_fn := func(h: float) -> Dictionary:
		var dw := WeatherModel.derive(fc, ctx, {}, h)
		dw.thermal_spacing_m = peak
		for k: Variant in ov:
			dw[k] = ov[k]
		dw.erase("static_thermals")
		return dw
	var d := AtmoDay.new()
	d.start_hour = float(tm.start_hour)
	d.t0 = float(tm.t0)
	d.speed = float(tm.speed)
	d.quantum_h = float(tm.quantum_h)
	d.weather_fn = derive_fn
	d.sun_fn = AtmoDay.sun_direction.bind(
		float(loc.get("center_lat", 52.0)), float(loc.get("center_lon", 0.0)),
		int(loc.get("month", 7)), int(loc.get("day", 15)), float(loc.get("utc_offset_h", NAN))
	)
	d.source_fn = test_source
	return {day = d, initial = derive_fn.call(float(tm.start_hour))}


## Atmosphere с ходом дня: _apply_day на сетке state_update_interval_s, как Atmosphere.step.
func _day_state_row(pname: String, fc: Dictionary, ctx: Dictionary, ov: Dictionary, tm: Dictionary, loc: Dictionary, acfg: Dictionary) -> Dictionary:
	var made := _make_day(fc, ctx, ov, tm, loc)
	var a := Atmosphere.new()
	a.configure(acfg, made.initial)
	var cnt := [0]
	a.weather_updated.connect(func() -> void: cnt[0] += 1)
	a.set_day(made.day)
	var interval := float(acfg.thermal.state_update_interval_s)
	var row := {
		kind = "day_state", place = pname, ctx = ctx, forecast = fc, overrides = ov, timing = tm,
		loc = loc, initial = made.initial, interval = interval, start = _state(a, cnt), steps = [],
	}
	var slot := -(1 << 62)
	var last_updates: int = row.start.updates
	var t := a.time_s
	for i in 200:
		var dt: float = [0.05, 0.3, 0.5, 1.0][i % 4]
		t += dt
		a.time_s = t
		var s := floori(t / interval)
		if s != slot:
			slot = s
			a._apply_day(s * interval)
		var st := _state(a, cnt)
		st.t = t
		if st.updates == last_updates:
			st.erase("weather")  # словарь меняется только со сменой шага погоды
		last_updates = st.updates
		row.steps.append(st)
	row.end_weather = a._weather
	a.free()
	return row


func _state(a: Atmosphere, cnt: Array) -> Dictionary:
	return {
		bg_sink = a._bg_sink, conv_amp = a._conv_amp, mech_k = a._mech_k,
		edge = a.field.get_edge_factor(), insolation = a.field.insolation,
		cloudbase_agl = a._cloudbase_agl, updates = cnt[0], weather = a._weather,
	}


func _coeffs(a: Atmosphere) -> Dictionary:
	var c := {}
	for v: String in COEFF_VARS:
		c[v.substr(1)] = a.get(v)
	c.edge_factor = a.field.get_edge_factor()
	c.insolation = a.field.insolation
	return c


func _coeff_rows(acfg: Dictionary, pool: Array) -> void:
	var list := []
	for p in PRESETS:
		list.append({label = p, w = Config.get_config(p)})
	list.append_array(pool)
	for variant in ["default", "lee_defaults"]:
		var ac := acfg.duplicate(true)
		if variant == "lee_defaults":
			for k in LEE_OPTIONAL:
				ac.lee.erase(k)
		for e: Dictionary in list:
			var a := Atmosphere.new()
			a.configure(ac, e.w)
			var wc := a._wind_conditions()
			_push({
				kind = "coeffs", label = e.label, variant = variant, weather = e.w, coeffs = _coeffs(a),
				insolation = a.get_insolation(), wind_conditions = [wc.x, wc.y],
				sun_dir = [a.field.sun_dir.x, a.field.sun_dir.y, a.field.sun_dir.z],
			})
			a.free()


func _blend_rows(acfg: Dictionary, pool: Array) -> void:
	var pairs := [
		["weather/weak", "weather/strong"], ["weather/medium", "weather/wave"], ["weather/storm", "weather/weak"],
	]
	var cases := []
	for pr: Array in pairs:
		for bs in [0.0, 60.0, 300.0]:
			cases.append({label = "%s -> %s" % pr, from = Config.get_config(pr[0]), to = Config.get_config(pr[1]), blend_s = bs})
	if pool.size() >= 2:
		# прогнозная погода: пара часов одного места; ветер и сетка источников у «до» должны сохраниться
		var w_to: Dictionary = pool[1].w.duplicate(true)
		w_to.wind_speed_kmh = 99.0
		cases.append({label = "derived " + String(pool[0].label), from = pool[0].w, to = w_to, blend_s = 120.0})
	for c: Dictionary in cases:
		var a := Atmosphere.new()
		a.configure(acfg, c.from)
		var cnt := [0]
		a.weather_updated.connect(func() -> void: cnt[0] += 1)
		var start := _coeffs(a)
		a._update_weather(c.to, float(c.blend_s))
		var row := {
			kind = "blend", label = c.label, blend_s = c.blend_s, from = c.from, to = c.to,
			start = start, after_update = _state(a, cnt), steps = [],
		}
		row.after_update.target_empty = a._target.is_empty()
		for i in 60:
			var dt: float = BLEND_DTS[i % BLEND_DTS.size()]
			if not a._target.is_empty():
				a._blend(1.0 - exp(-dt / a._blend_tau) if a._blend_tau > 0.0 else 1.0)
			var st := _state(a, cnt)
			st.erase("weather")
			st.dt = dt
			st.target_empty = a._target.is_empty()
			row.steps.append(st)
		row.end_weather = a._weather
		_push(row)
		a.free()


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
		push_error("day_dump: размер %s.bin" % name)
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
