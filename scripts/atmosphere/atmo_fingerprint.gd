class_name AtmoFingerprint
extends RefCounted
## «Отпечаток» атмосферы для проверки детерминизма (сеть, NET-00): термики (положение, сила,
## радиус, фаза жизни), облака (центр, размеры, стадия) и воздух в 20 точках (5 мест × 4 высоты)
## вокруг центра. Два клиента с одинаковыми параметрами зоны должны получать одно и то же.
##
## Эталонный мир без рельефа из данных: аналитические холмы, источники термиков по солнцу,
## ход дня (WeatherModel.derive по часам, солнце по дате и месту) — всё, что есть в игре, кроме
## загрузки карты. Тест — tests/atmosphere/test_determinism.gd; сравнить Linux и Windows —
## scripts/atmosphere/atmo_fingerprint_cli.gd (docs/guide/atmosphere.md → «Детерминизм»).

## Центр отпечатка и фокус (пилот) эталонного мира.
const CENTER := Vector3(1500.0, 0.0, -2500.0)
## Термики и облака — в этом радиусе от центра (по положению основания со сносом), м.
const RADIUS_M := 7000.0
## Радиус, где живут термики эталонного мира, м.
const GEN_RADIUS_M := 10000.0
## Высоты точек воздуха над рельефом, м.
const HEIGHTS_AGL: Array[float] = [30.0, 300.0, 1000.0, 1800.0]
## Места точек воздуха относительно центра (x, z), м.
const SPOTS: Array[Vector2] = [
	Vector2(0, 0), Vector2(1200, 300), Vector2(-900, 1500), Vector2(2500, -2000),
	Vector2(-3000, -700)
]

## Мир отпечатка по умолчанию — ключ мира (WorldKey): место, дата, время, прогноз, сид.
const DEFAULT_KEY := (
	"deltaplan://world?bots=0&date=2026-07-15&from=250&hour=11.00&lat=51.50000&lon=86.50000"
	+ "&seed=4242&sky=clear&temp=29.0&v=1&wind=3.9"
)
## Курс «старта» эталонного мира (встречный ветер на старте, from=-1), градусы.
const LAUNCH_HEADING := 250.0

static var _sun_h := NAN
static var _sun := Vector3.UP
## Место и дата текущего эталонного мира (make_world): lat, lon, месяц, день, пояс.
static var _lat := 51.5
static var _lon := 86.5
static var _month := 7
static var _day := 15
static var _utc := 6.0


static func height(x: float, z: float) -> float:
	return (
		900.0
		+ 350.0 * sin(x / 3100.0) * cos(z / 4300.0)
		+ 160.0 * sin((x + 0.6 * z) / 1700.0)
		+ 40.0 * cos(x / 450.0 - z / 700.0)
	)


static func _normal(x: float, z: float) -> Vector3:
	var e := 15.0
	var dx := (height(x + e, z) - height(x - e, z)) / (2.0 * e)
	var dz := (height(x, z + e) - height(x, z - e)) / (2.0 * e)
	return Vector3(-dx, 1.0, -dz).normalized()


## «Поверхность»: пятна полей и леса (0,3..1).
static func _surface_k(x: float, z: float) -> float:
	return 0.65 + 0.35 * sin(x / 830.0 + 1.3) * cos(z / 1170.0 - 0.4)


## Сила источника без времени (солнце из world.json) — для GroundField.sun_fn.
static func source_static(x: float, z: float) -> float:
	var n := _normal(x, z)
	return clampf(_surface_k(x, z) * (0.35 + 0.8 * n.dot(Vector3(0.3, 0.8, 0.5).normalized())), 0, 1)


static func sun_at_hour(hour: float) -> Vector3:
	return AtmoDay.sun_direction(hour, _lat, _lon, _month, _day, _utc)


## Сила источника в час hour: склон к солнцу × поверхность (как Terrain.thermal_source_strength_at).
static func source_at(x: float, z: float, hour: float) -> float:
	if hour != _sun_h:
		_sun_h = hour
		_sun = sun_at_hour(hour)
	var sd := _sun
	var e := clampf(_normal(x, z).dot(sd), 0.0, 1.0)
	return clampf(_surface_k(x, z) * 1.25 * pow(e, 0.8), 0.0, 1.0)


static func weather_ctx() -> Dictionary:
	var ctx := WeatherModel.reference_context()
	ctx.merge(
		{"month": _month, "day": _day, "lat": _lat, "lon": _lon, "utc_offset_h": _utc}, true
	)
	var g: Dictionary = Config.get_config("atmosphere").ground
	ctx.merge(
		WeatherModel.ground_context(
			height,
			float(g.reference_radius_m),
			int(g.reference_samples),
			float(WeatherModel.config().valley_percentile)
		),
		true
	)
	return ctx


## Эталонный мир из ключа мира (WorldKey): атмосфера с сидом, прогнозом и ходом дня, фокус —
## CENTER. Место (для солнца), дата, час старта, прогноз и сид — только из ключа. Не в дереве —
## free().
static func make_world(key: String = DEFAULT_KEY, atmo_cfg: Dictionary = {}) -> Atmosphere:
	var parsed := WorldKey.parse(key)
	var fs: FlightSettings = parsed.settings
	var ll := WorldKey.launch_latlon(fs)
	_lat = ll.x
	_lon = ll.y
	_month = fs.month
	_day = fs.day
	_utc = roundf(_lon / 15.0)
	_sun_h = NAN
	var forecast := fs.forecast()
	if fs.wind_into_launch:
		forecast.wind_from_deg = LAUNCH_HEADING
	var ctx := weather_ctx()
	var spacing := float(WeatherModel.derive(forecast, ctx).thermal_spacing_m)
	var derive := func(h: float) -> Dictionary:
		var w := WeatherModel.derive(forecast, ctx, {}, h)
		w.thermal_spacing_m = spacing
		return w
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = int(parsed.seed)
	var cfg := atmo_cfg
	if cfg.is_empty():
		# Термики — в 10 км вокруг (в игре 20 км): для отпечатка в 7 км хватает, прогон вчетверо
		# быстрее. Правила те же.
		cfg = Config.get_config("atmosphere").duplicate(true)
		cfg.thermal.generation_radius_m = GEN_RADIUS_M
	# Поле воздуха (масштаб 1) — у каждого клиента своё и зависит от GPU: отпечаток мира — всегда
	# на аналитике (docs/guide/air-model.md → «Поле на CPU»).
	cfg = cfg.duplicate(true)
	var am: Dictionary = cfg.get("air_model", {})
	am.enabled = "off"
	cfg.air_model = am
	a.configure(cfg, derive.call(fs.start_hour))
	a.set_ground(height, source_static)
	a.set_wind(fs.wind_speed_kmh, float(forecast.wind_from_deg), height(0, 0))
	a.load_static_thermals([{"x_m": -4000.0, "z_m": 3000.0, "strength_ms": 2.5, "radius_m": 120.0}])
	var d := AtmoDay.new()
	d.start_hour = fs.start_hour
	d.quantum_h = float(WeatherModel.config().get("diurnal", {}).get("update_s", 60.0)) / 3600.0
	d.weather_fn = derive
	d.sun_fn = sun_at_hour
	d.source_fn = source_at
	a.set_day(d)
	a.set_focus(CENTER)
	return a


## Прогнать атмосферу до момента t шагом dt (последний шаг — остаток) и обновить на t.
static func run_to(a: Atmosphere, t: float, dt: float) -> void:
	while a.time_s < t - 1.0e-9:
		a.step(minf(dt, t - a.time_s))
	a.time_s = t
	a.refresh_now()


## Отпечаток: {thermals: [[id, x, z, src_y, top, strength, radius, t_birth, env, cloud, cb], …],
## clouds: [[id, cx, cz, rx, rz, depth, grow, decay, active], …], air: [[x, y, z, vx, vy, vz], …]}.
## Термики и облака — по возрастанию id.
static func capture(a: Atmosphere) -> Dictionary:
	var t := a.time_s
	var ths: Array = []
	var clouds: Array = []
	var ids: Array = a.field.thermals.keys()
	ids.sort()
	var model := a.cloud_phys.model
	var r2 := RADIUS_M * RADIUS_M
	for id: int in ids:
		var th: AtmoThermal = a.field.thermals[id]
		th.update_time(t)
		var gx := th.src.x + th.drift.x
		var gz := th.src.z + th.drift.y
		if Vector2(gx - CENTER.x, gz - CENTER.z).length_squared() > r2:
			continue
		ths.append(
			[
				id, gx, gz, th.src.y, th.top, th.strength, th.radius, th.t_birth, th.env,
				1 if th.has_cloud else 0, 1 if th.is_cb else 0
			]
		)
		var st := model.stage(th, t)
		if st.x >= 0.0:
			var c := model.center(th, t)
			var sz := model.size(th, st)
			clouds.append([id, c.x, c.y, sz.x, sz.y, sz.z, st.x, st.y, st.z])
	var air: Array = []
	for s in SPOTS:
		for h in HEIGHTS_AGL:
			var x := CENTER.x + s.x
			var z := CENTER.z + s.y
			var p := Vector3(x, height(x, z) + h, z)
			var v := a.air_velocity_at(p)
			air.append([p.x, p.y, p.z, v.x, v.y, v.z])
	return {"t": t, "thermals": ths, "clouds": clouds, "air": air}


## Сравнить два отпечатка: "" — совпадают до tol, иначе — первые расхождения (текст).
static func diff(a: Dictionary, b: Dictionary, tol: float = 1.0e-3) -> String:
	var out: PackedStringArray = []
	for key in ["thermals", "clouds", "air"]:
		var la: Array = a[key]
		var lb: Array = b[key]
		if la.size() != lb.size():
			out.append("%s: %d против %d" % [key, la.size(), lb.size()])
			out.append("  ids A: %s" % str(_ids(la)))
			out.append("  ids B: %s" % str(_ids(lb)))
			continue
		for i in la.size():
			var ra: Array = la[i]
			var rb: Array = lb[i]
			for j in ra.size():
				if absf(float(ra[j]) - float(rb[j])) > tol:
					out.append("%s[%d][%d]: %s против %s" % [key, i, j, ra[j], rb[j]])
					break
			if out.size() > 12:
				break
	return "\n".join(out)


static func _ids(rows: Array) -> Array:
	var ids: Array = []
	for r: Array in rows:
		ids.append(r[0])
	return ids


## Текст отпечатка (для файла и diff между ОС): одна строка на запись, числа %.6f.
static func to_text(fp: Dictionary) -> String:
	var lines: PackedStringArray = ["t %.3f" % float(fp.t)]
	for key in ["thermals", "clouds", "air"]:
		lines.append("%s %d" % [key, (fp[key] as Array).size()])
		for row: Array in fp[key]:
			var parts: PackedStringArray = []
			for v: Variant in row:
				parts.append(str(v) if v is int else "%.6f" % float(v))
			lines.append(" ".join(parts))
	return "\n".join(lines) + "\n"
