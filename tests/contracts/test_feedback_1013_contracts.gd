extends TestCase
## Контрактные тесты feedback-1013 (docs/contracts/feedback-1013.md). FBW-К2 — время суток и солнце
## для притока тепла и термиков (владелец FBW-1): часы — поясное время места, солнце — SunClock;
## ψ ≤ 0 → K↓ = 0, суша (кроме застройки) H ≤ 0, застройка — ночной спад к пределу, вода — по
## water_flux без солнца, рождений термиков нет; облачность — один раз; поле — по дате полёта.
## Сценарий пилота через сцену игры — tools/research/fb1013_evening/run.sh.

const DOC := "res://docs/contracts/feedback-1013.md"
const VERSIONS := {"FBW-К2": 3}
## Места: широта, долгота, пояс (NAN — по долготе, как точка с карты): широты 40–60°, долготы мест игры.
const PLACES := [
	[40.0, 42.5, NAN], [43.3, 42.5, NAN], [45.0, 59.69, NAN], [50.79, 86.13, 7.0],
	[51.87, 85.87, 7.0], [53.26, 58.54, 5.0], [54.72, 59.69, 5.0], [58.0, 60.0, NAN],
	[60.0, 86.13, NAN],
]
const SKIES := ["clear", "partly", "overcast"]


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


static func _utc(p: Array) -> float:
	return float(p[2]) if not is_nan(float(p[2])) else roundf(float(p[1]) / 15.0)


static func _ctx(p: Array, month: int, day: int) -> Dictionary:
	var c := WeatherModel.reference_context()
	c.merge({"month": month, "day": day, "lat": p[0], "lon": p[1], "utc_offset_h": _utc(p)}, true)
	return c


static func _heating(p: Array, month: int, day: int) -> SurfaceHeating:
	var h := SurfaceHeating.new()
	h.setup(float(p[0]), float(p[1]), month, day, _utc(p))
	return h


static func _onehot(cls: int) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(SurfaceLayer.CLASS_COUNT)
	f[cls] = 1.0
	return f


## H чистого класса cls в час hour места p: склон normal, небо sky, вода — контекст воды месяца.
static func _flux(
	p: Array, month: int, day: int, hour: float, cls: int, normal: Vector3, sky: String
) -> float:
	var heat := _heating(p, month, day)
	var ctx := _ctx(p, month, day)
	var skyp := WeatherModel.sky_params(sky)
	var s := {cover = float(skyp.get("cover", 0.0)), sky_heat = 1.0, night = heat.built_night(hour)}
	var scfg := SurfaceHeat.config()
	var t_max := WeatherModel.typical_max_c(month, day)
	var water := {
		t_water_c = SurfaceHeat.water_temp_c(month, day, 500.0, ctx, scfg.water),
		t_air_c = SurfaceHeat.air_temp_c(hour, t_max, 500.0, ctx, scfg.water),
		u_ms = 7.0,
		z_m = 500.0,
	}
	return SurfaceHeat.mix_flux(
		_onehot(cls), 0, normal, heat.directions(hour), 0.47, s, water, scfg
	)


# ---------------------------------------------------------------- FBW-К2 (владелец FBW-1)
## 15.10 20:00 поясного: солнце под горизонтом; у всех классов нет солнца (с запаздыванием тоже).
func test_k2_evening_sun_below() -> void:
	for p: Array in PLACES:
		var el := SunClock.solar_position(p[0], p[1], SunClock.day_of_year(10, 15), 20.0, _utc(p)).y
		check(el < 0.0, "%s: ψ(15.10 20:00) = %.1f° < 0" % [str(p), el])
		var dirs := _heating(p, 10, 15).directions(20.0)
		for k in dirs.size():
			check(dirs[k] == Vector3.ZERO, "%s: класс %d без солнца" % [str(p), k])
		# запаздывание не тянет солнце за закат: в любую минуту, когда ψ ≤ 0
		var h := _heating(p, 7, 15)
		for m in range(0, 180, 5):
			var hour := h.sunset_h + 0.01 + m / 60.0
			if hour > 24.0:
				break
			for d in h.directions(hour):
				check(d == Vector3.ZERO, "%s: 15.07 через %d мин после заката класс греется" % [str(p), m])


## ψ ≤ 0: суша кроме застройки H ≤ 0 (склоны, все небеса); застройка — предел + спад, не растёт;
## вода — по water_flux, от солнца не зависит.
func test_k2_flux_after_sunset() -> void:
	var normals := [Vector3.UP, Vector3(0.5, 1.0, 0.0), Vector3(-0.5, 1.0, 0.3), Vector3(0.0, 1.0, -0.7)]
	var bc: Dictionary = SurfaceHeat.config().classes.built
	var floor_h := float(bc.night_floor_wm2)
	for p: Array in PLACES:
		for sky: String in SKIES:
			for cls in SurfaceLayer.CLASS_COUNT:
				if cls == SurfaceLayer.WATER or cls == SurfaceLayer.BUILT:
					continue
				for n: Vector3 in normals:
					var hv := _flux(p, 10, 15, 20.0, cls, n, sky)
					check(hv <= 0.0, "%s %s класс %d: H = %.1f ≤ 0" % [str(p), sky, cls, hv])
			var prev := INF
			var heat := _heating(p, 10, 15)
			for m in range(0, 300, 15):
				var hour := heat.sunset_h + 0.01 + m / 60.0
				if hour > 24.0:
					break
				var hb := _flux(p, 10, 15, hour, SurfaceLayer.BUILT, Vector3.UP, sky)
				check(hb >= floor_h - 1e-3, "%s %s застройка %.1f ≥ предела" % [str(p), sky, hb])
				check(hb <= prev + 1e-3, "%s %s застройка не растёт после заката" % [str(p), sky])
				prev = hb
			var hb20 := _flux(p, 10, 15, 20.0, SurfaceLayer.BUILT, Vector3.UP, sky)
			check(hb20 <= 50.0, "%s %s застройка в 20:00: %.1f ≤ 50 Вт/м²" % [str(p), sky, hb20])
	# вода: тот же поток при солнце и без (только T воды − T воздуха)
	var p0: Array = PLACES[3]
	var scfg := SurfaceHeat.config()
	var water := {t_water_c = 10.0, t_air_c = 1.0, u_ms = 7.0, z_m = 500.0}
	var up := PackedVector3Array()
	up.resize(SurfaceLayer.CLASS_COUNT)
	up.fill(Vector3.UP)
	var none := PackedVector3Array()
	none.resize(SurfaceLayer.CLASS_COUNT)
	var w_sun := SurfaceHeat.mix_flux(_onehot(SurfaceLayer.WATER), 0, Vector3.UP, up, 0.5, {cover = 0.0}, water, scfg)
	var w_dark := SurfaceHeat.mix_flux(_onehot(SurfaceLayer.WATER), 0, Vector3.UP, none, 0.5, {cover = 0.0}, water, scfg)
	approx(w_sun, w_dark, 1e-4, "вода не зависит от солнца")
	approx(w_dark, SurfaceHeat.water_flux(10.0, 1.0, 7.0, scfg, 500.0), 1e-4, "вода = water_flux")
	check(w_dark > 0.0, "тёплое озеро вечером: H > 0 (%.0f)" % w_dark)
	check(p0.size() == 3, "места")


## 15.07 13:00 ясно: H > 0 на лугу и застройке.
func test_k2_day_heats() -> void:
	for p: Array in PLACES:
		for cls: int in [SurfaceLayer.GRASS, SurfaceLayer.BUILT, SurfaceLayer.BARE]:
			var hv := _flux(p, 7, 15, 13.0, cls, Vector3.UP, "clear")
			check(hv > 100.0, "%s класс %d днём H = %.0f > 100" % [str(p), cls, hv])


## Погода хода дня: ψ ≤ 0 → прогрев 0, доля рождений 0, сила 0 (все небеса).
func test_k2_weather_evening() -> void:
	var fc := {"temperature_c": 7.0, "wind_speed_kmh": 25.2, "wind_from_deg": 180.0}
	for p: Array in PLACES:
		for sky: String in SKIES:
			fc.sky = sky
			var w := WeatherModel.derive(fc, _ctx(p, 10, 15), {}, 20.0)
			var d: Dictionary = w._derived
			check(float(d.sun_elev_deg) < 0.0, "%s %s: ψ погоды < 0" % [str(p), sky])
			check(float(d.heat) == 0.0, "%s %s: прогрев 0 (%.3f)" % [str(p), sky, d.heat])
			check(float(w.thermal_duty) == 0.0, "%s %s: доля рождений 0" % [str(p), sky])
			check(float(w.thermal_strength_ms[1]) == 0.0, "%s %s: сила 0" % [str(p), sky])
		# сразу после заката (в пределах запаздывания луга) прогрева уже нет
		var heat := _heating(p, 7, 15)
		var w2 := WeatherModel.derive(
			{"temperature_c": 26.0, "wind_speed_kmh": 10.0, "sky": "clear"}, _ctx(p, 7, 15), {},
			heat.sunset_h + 0.05
		)
		check(float(w2._derived.heat) == 0.0, "%s: через 3 мин после заката прогрев 0" % str(p))


## Облачность — один раз: пелена неба прогноза не гасит солнце источникам второй раз, доля
## рождений поля — без duty_k неба (оно уже в K↓ поля).
func test_k2_cloud_once() -> void:
	var p: Array = PLACES[4]
	for sky: String in SKIES:
		var w := WeatherModel.derive(
			{"temperature_c": 26.0, "wind_speed_kmh": 10.0, "sky": sky}, _ctx(p, 7, 15), {}, 13.0
		)
		var sp := WeatherModel.sky_params(sky)
		approx(float(w.sky_cover), float(sp.get("cover", 0.0)), 1e-6, sky + ": sky_cover")
		approx(float(w.sky_duty_k), float(sp.get("duty_k", 1.0)), 1e-6, sky + ": sky_duty_k")
		var extra := WeatherModel.sun_block_cover(w)
		check(
			extra <= maxf(float(w.cirrus_cover) - float(sp.get("cover", 0.0)), 0.0) + 1e-6,
			"%s: пелена сверх неба %.2f" % [sky, extra]
		)
		if sky == "overcast":
			check(extra == 0.0, "облачно: пелена неба второй раз солнце не гасит")


## Поле — по дате полёта: AirPlace.context берёт месяц и день из loc (place_of), без них — опорная.
func test_k2_field_date() -> void:
	var hs := PackedFloat32Array()
	hs.resize(64 * 64)
	hs.fill(1000.0)
	var layer := HeightLayer.from_heights("detail", 64, 64, 25.0, -800.0, -800.0, hs)
	var loc := {center_lat = 50.79, center_lon = 86.13, utc_offset_h = 7.0, month = 10, day = 15}
	var ctx := AirPlace.context(layer, loc, WeatherModel.config())
	check(int(ctx.month) == 10 and int(ctx.day) == 15, "дата полёта в поле: %s.%s" % [ctx.day, ctx.month])
	var d := AirPlace.day(ctx, 20.0, 7.0, "overcast", WeatherModel.config())
	check(float(d.heat) == 0.0, "день поля 15.10 20:00: прогрев 0")
	loc.erase("month")
	loc.erase("day")
	var rc := WeatherModel.reference_context()
	var ctx2 := AirPlace.context(layer, loc, WeatherModel.config())
	check(int(ctx2.month) == int(rc.month), "без даты — опорная")
	# ключ места различает даты (новый полёт в другой день — новое поле)
	var k1 := AirRuntime._key_of({detail = layer, loc = {id = "x", month = 10, day = 15}})
	var k2 := AirRuntime._key_of({detail = layer, loc = {id = "x", month = 7, day = 15}})
	check(k1 != k2, "ключ места с датой")


# ---- рождения: атмосфера с ходом дня (погода, солнце, источники по SurfaceHeating), ровная земля
static func _flat(_x: float, _z: float) -> float:
	return 1000.0


static func _births(p: Array, month: int, day: int, hour: float, sky: String) -> int:
	var fc := {"temperature_c": WeatherModel.typical_max_c(month, day), "wind_speed_kmh": 25.2,
		"wind_from_deg": 180.0, "sky": sky}
	var ctx := _ctx(p, month, day)
	ctx.valley_msl_m = 1000.0
	ctx.mean_msl_m = 1000.0
	var a := Atmosphere.new()
	a.configure(Config.get_config("atmosphere"), WeatherModel.derive(fc, ctx, {}, hour))
	a.turbulence_enabled = false
	var heat := _heating(p, month, day)
	var scfg := SurfaceHeat.config()
	var src := func(_x: float, _z: float, h: float) -> float:
		var hv := SurfaceHeat.mix_flux(
			_onehot(SurfaceLayer.GRASS), 0, Vector3.UP, heat.directions(h), 0.47,
			{cover = 0.0, night = heat.built_night(h)}, {}, scfg
		)
		return clampf(hv / 300.0, 0.0, 1.0)
	a.set_ground(_flat, func(_x: float, _z: float) -> float: return 1.0)
	a.set_wind(25.2, 180.0, 1000.0)
	var d := AtmoDay.new()
	d.start_hour = hour
	d.t0 = 0.0
	d.weather_fn = func(h: float) -> Dictionary: return WeatherModel.derive(fc, ctx, {}, h)
	d.sun_fn = AtmoDay.sun_direction.bind(float(p[0]), float(p[1]), month, day, _utc(p))
	d.source_fn = src
	a.set_day(d)
	a.set_focus(Vector3(0, 1000.0, 0))
	var born := {}
	for i in 120:
		a.step(5.0)
		for th: AtmoThermal in a.field.thermals.values():
			if not th.is_static and th.t_birth >= 0.0:
				born[th.id] = true
	a.free()
	return born.size()


## 15.10 20:00 облачно: рождений 0 за 10 мин; 15.07 13:00 ясно: термики рождаются.
func test_k2_births() -> void:
	for i: int in [1, 3, 6, 7]:
		var p: Array = PLACES[i]
		var n := _births(p, 10, 15, 20.0, "overcast")
		check(n == 0, "%s 15.10 20:00: рождений %d" % [str(p), n])
	var nd := _births(PLACES[4], 7, 15, 13.0, "clear")
	check(nd > 0, "15.07 13:00 ясно: рождений %d > 0" % nd)
