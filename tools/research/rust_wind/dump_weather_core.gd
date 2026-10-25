extends Node
## RW-6c: дамп погоды и солнца для поля — эталон GDScript для rust/dp-air/tests/weather_core.rs.
## Те же функции, что игра (AirPlace.context/day/block_mean/cell_surface/cell_z0/surface_flux,
## WeatherModel, SurfaceHeat, SurfaceHeating, SunClock, WindProfile), на растрах места из
## tests/fixtures/wind/places/ (синтетика и Онгудай) вместо колбэков detail.sample и снимка
## поверхности. Условия — из tests/fixtures/wind/cases/<имя>.json (extra.field_conditions) с часом
## и небом из таблицы SCENARIOS. Климат ERA5 — ClimateGrid.at на нужные даты (в дампе).
##
## Запуск (CPU, Godot — под замком):
##   .dpcli/dpcli lock cpu rw6c --no-tmux -- tools/research/rust_wind/dump_weather_core.sh
##   tools/research/rust_wind/dump_weather_core.sh --verify    # пересъёмка и побитное сравнение
## Выход: <out>/<место>.json + .bin (растры области, f32 LE подряд), <сценарий>.json + .bin
## (поток тепла f32), misc.json (сетки солнца и профиля ветра). Числа json — полная точность.

const FIX := "res://tests/fixtures/wind"
const DEFAULT_OUT := "res://rust/dp-air/tests/data/weather_core"

## Место → область (x0, y0 — юго-западный угол, м; n клеток по 400 м) и случай-основа условий.
const PLACES := {
	"synthetic": {x0 = -8400.0, y0 = -7200.0, n = 48, base = "synth_medium"},
	"ongudai": {x0 = -19200.0, y0 = -19200.0, n = 96, base = "ongudai_medium"},
}
const DX := 400.0
## Сценарии: место, месяц, день (0 — из места), час, небо, дневной максимум (NAN — из основы).
const SCENARIOS := [
	{place = "synthetic", month = 0, day = 0, hour = 9.0, sky = "clear", t_max = NAN},
	{place = "synthetic", month = 0, day = 0, hour = 13.0, sky = "clear", t_max = NAN},
	{place = "synthetic", month = 0, day = 0, hour = 9.0, sky = "overcast", t_max = NAN},
	{place = "synthetic", month = 0, day = 0, hour = 13.0, sky = "overcast", t_max = NAN},
	{place = "ongudai", month = 0, day = 0, hour = 9.0, sky = "clear", t_max = NAN},
	{place = "ongudai", month = 0, day = 0, hour = 13.0, sky = "clear", t_max = NAN},
	{place = "ongudai", month = 0, day = 0, hour = 9.0, sky = "overcast", t_max = NAN},
	{place = "ongudai", month = 0, day = 0, hour = 13.0, sky = "overcast", t_max = NAN},
	{place = "ongudai", month = 0, day = 0, hour = 21.0, sky = "partly", t_max = NAN},
	{place = "ongudai", month = 1, day = 15, hour = 12.0, sky = "clear", t_max = -5.0},
	{place = "ongudai", month = 8, day = 20, hour = 14.0, sky = "partly", t_max = 33.0},
]

var _out := ""


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
	var places := {}
	for name: String in PLACES:
		var pl := _load_place(name)
		if pl.is_empty():
			return false
		places[name] = pl
		_dump_place(name, pl)
	var misc := _misc()
	_write_json(_out.path_join("misc.json"), misc)
	for sc: Dictionary in SCENARIOS:
		_dump_scenario(sc, places[sc.place], cfg)
	print("dump_weather_core: готово, %s" % _out)
	return true


## Место из фикстуры W8: заголовок, слой рельефа, снимок поверхности (как AirPlace.Surface).
func _load_place(name: String) -> Dictionary:
	var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
	var bin := FileAccess.get_file_as_bytes("%s/places/%s.bin" % [FIX, name])
	var w := int(head.grid.width)
	var h := int(head.grid.height)
	var n := w * h
	if bin.size() != 5 * n:
		push_error("dump_weather_core: размер %s.bin" % name)
		return {}
	var h_off := float(head.h_offset)
	var h_scale := float(head.h_scale)
	var hs := PackedFloat32Array()
	hs.resize(n)
	for k in n:
		hs[k] = h_off + bin.decode_s16(2 * k) * h_scale
	var cls := bin.slice(3 * n, 4 * n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for k in n:
		moist[k] = bin[4 * n + k] / 255.0
	var layer := HeightLayer.from_heights(
		name, w, h, float(head.grid.spacing), float(head.grid.origin_x), float(head.grid.origin_z), hs
	)
	var sf := AirPlace.Surface.new()
	sf.origin_x = float(head.grid.origin_x)
	sf.origin_z = float(head.grid.origin_z)
	sf.width = w
	sf.height = h
	sf.cls = cls
	sf.moist = moist
	var dom: Dictionary = PLACES[name]
	var nn := int(dom.n)
	var hc := AirPlace.block_mean(layer, float(dom.x0), float(dom.y0), DX, nn, nn)
	var cells := AirPlace.cell_surface(sf, null, layer, float(dom.x0), float(dom.y0), DX, nn, nn)
	var z0 := AirPlace.cell_z0(cells)
	return {head = head, layer = layer, hc = hc, cells = cells, z0 = z0}


func _loc(pl: Dictionary, month: int, day: int) -> Dictionary:
	var loc: Dictionary = (pl.head.loc as Dictionary).duplicate()
	if month > 0:
		loc.month = month
		loc.day = day
	return loc


func _dump_place(name: String, pl: Dictionary) -> void:
	var dom: Dictionary = PLACES[name]
	var nn := int(dom.n)
	var fr: PackedFloat32Array = pl.cells.fr
	var m: PackedFloat32Array = pl.cells.m
	var f32 := PackedFloat32Array()
	var arrays := {}
	for pair in [["hc", _f32(pl.hc)], ["z0", _f32(pl.z0)], ["fr", fr], ["m", m]]:
		arrays[pair[0]] = [f32.size(), pair[1].size()]
		f32.append_array(pair[1])
	var loc := _loc(pl, 0, 0)
	var ctx := AirPlace.context(pl.layer, loc, WeatherModel.config())
	var data := {
		place = name,
		domain = {x0 = float(dom.x0), y0 = float(dom.y0), nx = nn, ny = nn, dx = DX},
		ctx = ctx,
		z0_eff = AirCase.log_mean(pl.z0),
		arrays = arrays,
	}
	_write_json(_out.path_join("%s.json" % name), data)
	_write_bytes(_out.path_join("%s.bin" % name), f32.to_byte_array())


func _dump_scenario(sc: Dictionary, pl: Dictionary, cfg: Dictionary) -> void:
	var name := String(sc.place)
	var dom: Dictionary = PLACES[name]
	var nn := int(dom.n)
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/cases/%s.json" % [FIX, dom.base]))
	var fc: Dictionary = base.extra.field_conditions
	var loc := _loc(pl, int(sc.month), int(sc.day))
	var hour := float(sc.hour)
	var sky := String(sc.sky)
	var t_max := float(fc.t_max) if is_nan(float(sc.t_max)) else float(sc.t_max)
	var kmh := float(fc.u10) * 3.6
	var u10 := kmh / 3.6
	var wdir := float(fc.wdir)
	var ctx := AirPlace.context(pl.layer, loc, cfg)
	var d := AirPlace.day(ctx, hour, t_max, sky, cfg)
	var st := WeatherModel.diurnal_state(t_max, hour, ctx, cfg)
	var amp := WeatherModel.diurnal_range_k(ctx, cfg)
	var heat := AirPlace.surface_flux(pl.hc, DX, nn, nn, d, ctx, cfg, pl.cells, u10, t_max)
	var c := AirCase.new()
	c.set_z0_map(pl.z0)
	c.set_inflow(u10, 1.0, ctx, hour, float(d.cover))
	var sun_el := WindProfile.sun_elevation(ctx, hour)
	var cls := WindProfile.stability_class(u10, sun_el, float(d.cover))
	var z_sat := WindProfile.z_sat(u10, float(c.p.z0), float(c.p.f_cor), cls)
	var heating := SurfaceHeating.new()
	heating.setup(float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h), cfg)
	var dirs := heating.directions(hour)
	var dirs_out := []
	for v in dirs:
		dirs_out.append([v.x, v.y, v.z])
	var sp := SunClock.solar_position(
		float(ctx.lat), float(ctx.lon), SunClock.day_of_year(int(ctx.month), int(ctx.day)), hour,
		float(ctx.utc_offset_h)
	)
	var wcfg: Dictionary = SurfaceHeat.config().water
	var zv := float(ctx.valley_msl_m)
	var thetas := []
	for z in [zv, zv + 250.0, zv + 1000.0, 2500.0, 4000.0, 6000.0, 9000.0]:
		thetas.append({z = z, theta = AirPlace.theta(d, z), gamma = AirPlace.gamma(d, z)})
	var data := {
		place = name,
		loc = loc,
		scenario = "%s_m%02d_h%02d_%s" % [name, int(ctx.month), int(hour), sky],
		conditions = {
			forecast = {temperature_c = t_max, wind_speed_kmh = kmh, wind_from_deg = wdir, sky = sky},
			start_hour = hour, speed = 1.0, quantum_h = 0.5,
		},
		hour = hour,
		t_max = t_max,
		u10 = u10,
		ctx = ctx,
		diurnal = st,
		amp = amp,
		day = d,
		theta = thetas,
		sun = {az = sp.x, el = sp.y},
		class_sun = dirs_out,
		sun_at = heating.sun_at(hour),
		sunset_h = heating.sunset_h,
		built_night = heating.built_night(hour),
		water = {
			t_valley = SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), zv, ctx, wcfg),
			t_up = SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), zv + 300.0, ctx, wcfg),
			t_down = SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), zv - 100.0, ctx, wcfg),
			air_valley = SurfaceHeat.air_temp_c(hour, t_max, zv, ctx, wcfg),
		},
		z0_eff = float(c.p.z0),
		wind = {
			sun_elev = sun_el, cls = cls, alpha = float(c.p.alpha), z_sat = z_sat,
			max_profile = float(c.p.max_profile),
		},
		climate = _climate(ctx, wcfg),
		heat_n = heat.size(),
	}
	var file := String(data.scenario)
	_write_json(_out.path_join("%s.json" % file), data)
	_write_bytes(_out.path_join("%s.bin" % file), _f32(heat).to_byte_array())


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


## Сетки без места: положение солнца и профиль ветра (класс, α, z_sat, max_profile).
func _misc() -> Dictionary:
	var sun := []
	for lat in [-35.0, 0.0, 50.79, 66.0]:
		for doy in [1, 80, 196, 355]:
			for hour in [0.0, 6.0, 9.0, 12.0, 15.0, 18.0, 23.0]:
				for utc in [NAN, 7.0]:
					var p := SunClock.solar_position(lat, 86.13, doy, hour, utc)
					sun.append({lat = lat, lon = 86.13, doy = doy, hour = hour, utc = utc, az = p.x, el = p.y})
	var prof := []
	for u10 in [0.0, 0.7, 1.0, 2.0, 3.0, 4.5, 5.5, 6.0, 7.0, 8.5, 10.0, 11.0, 13.0]:
		for el in [-5.0, 5.0, 10.0, 20.0, 40.0, 70.0]:
			for cover in [0.0, 0.3, 0.6, 1.0]:
				for z0 in [0.03, 0.1, 1.0]:
					var k := WindProfile.stability_class(u10, el, cover)
					var a := WindProfile.alpha(u10, el, cover)
					prof.append({
						u10 = u10, el = el, cover = cover, z0 = z0, cls = k, alpha = a,
						z_sat = WindProfile.z_sat(u10, z0, AirCase.F_COR, k),
						max_profile = WindProfile.max_profile(a, u10, z0, AirCase.F_COR, k),
					})
	return {sun = sun, profile = prof}


func _f32(a: PackedFloat64Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(a.size())
	for k in a.size():
		o[k] = a[k]
	return o


## Нечисла и бесконечности — null; Vector — массив.
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
		TYPE_VECTOR3:
			return [v.x, v.y, v.z]
	return v


func _write_json(path: String, data: Variant) -> void:
	_write_bytes(path, (JSON.stringify(_clean(data), "\t", true, true) + "\n").to_utf8_buffer())


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	DirAccess.rename_absolute(tmp, path)
