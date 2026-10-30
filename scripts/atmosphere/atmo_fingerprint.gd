class_name AtmoFingerprint
extends RefCounted
## «Отпечаток» атмосферы для проверки детерминизма (сеть, NET-00): термики (положение, сила,
## радиус, фаза жизни), облака (центр, размеры, стадия) и воздух в 20 точках (5 мест × 4 высоты)
## вокруг центра. Два клиента с одинаковыми параметрами зоны должны получать одно и то же.
##
## Эталонный мир без рельефа из данных: аналитические холмы (растр места W5), источники термиков по
## солнцу, ход дня (прогноз → Weather.derive по часам внутри фасада) — всё, что есть в игре,
## кроме загрузки карты. Только фасад W2 и описания W6: термики — cores(), облака — clouds() и
## cloud_raster(), воздух — air_velocity_at(). Тест — tests/atmosphere/test_determinism.gd; сравнить
## Linux и Windows — scripts/atmosphere/atmo_fingerprint_cli.gd (docs/guide/atmosphere.md →
## «Детерминизм»).

## Центр отпечатка и фокус (пилот) эталонного мира.
const CENTER := Vector3(1500.0, 0.0, -2500.0)
## Термики и облака — в этом радиусе от центра (по положению основания со сносом), м.
const RADIUS_M := 7000.0
## Радиус, где живут термики эталонного мира, м.
const GEN_RADIUS_M := 10000.0
## Растр места эталонного мира: квадрат вокруг центра, шаг, м (как у эталонов RW-1, но реже).
const PLACE_HALF_M := 11000.0
const PLACE_STEP_M := 50.0
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


## Сила источника без времени (солнце из world.json) — для растра влажности места и генератора эталонов.
static func source_static(x: float, z: float) -> float:
	var n := _normal(x, z)
	return clampf(_surface_k(x, z) * (0.35 + 0.8 * n.dot(Vector3(0.3, 0.8, 0.5).normalized())), 0, 1)


static func sun_at_hour(hour: float) -> Vector3:
	var a := SunClock.solar_position(_lat, _lon, SunClock.day_of_year(_month, _day), hour, _utc)
	var el := maxf(a.y, float(Config.value("world", "time.min_light_elevation_deg", 2.0)))
	return TerrainGeo.sun_direction(a.x, el)


## Сила источника в час hour: склон к солнцу × поверхность (как Terrain.thermal_source_strength_at).
static func source_at(x: float, z: float, hour: float) -> float:
	if hour != _sun_h:
		_sun_h = hour
		_sun = sun_at_hour(hour)
	var sd := _sun
	var e := clampf(_normal(x, z).dot(sd), 0.0, 1.0)
	return clampf(_surface_k(x, z) * 1.25 * pow(e, 0.8), 0.0, 1.0)


static func weather_ctx() -> Dictionary:
	var ctx := Weather.reference_context()
	ctx.merge(
		{"month": _month, "day": _day, "lat": _lat, "lon": _lon, "utc_offset_h": _utc}, true
	)
	var g: Dictionary = Config.get_config("atmosphere").ground
	ctx.merge(
		Weather.ground_context(
			height,
			float(g.reference_radius_m),
			int(g.reference_samples),
			float(Weather.config().valley_percentile)
		),
		true
	)
	return ctx


## Место эталонного мира (W5): растр высот и влажности поверхности вокруг центра; площадка
## старта в (0, 0) — опорная высота ветра. loc — из ключа мира (make_world).
static func make_place(loc: Dictionary) -> AirPlaceData:
	var n := int(2.0 * PLACE_HALF_M / PLACE_STEP_M) + 1
	var sites := [{"id": "origin", "x": 0.0, "z": 0.0, "h_msl": height(0.0, 0.0)}]
	return AirPlaceData.from_functions(
		height, _surface_k, loc, CENTER.x - PLACE_HALF_M, CENTER.z - PLACE_HALF_M, PLACE_STEP_M, n,
		n, sites
	)


## Эталонный мир из ключа мира (WorldKey): атмосфера с сидом, прогнозом и ходом дня, фокус —
## CENTER, готовая на t = 0 (READY). Место (для солнца), дата, час старта, прогноз и сид — только
## из ключа. Не в дереве — free().
static func make_world(key: String = DEFAULT_KEY, cfg_over: Dictionary = {}) -> Atmosphere:
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
	var a := Atmosphere.new()
	a.visuals_enabled = false
	var cfg := cfg_over
	if cfg.is_empty():
		# Термики — в 10 км вокруг (в игре 20 км): для отпечатка в 7 км хватает, прогон вчетверо
		# быстрее. Правила те же.
		cfg = Config.get_config("atmosphere").duplicate(true)
		cfg.thermal.generation_radius_m = GEN_RADIUS_M
	a.cfg_override = cfg
	var loc := {
		"id": "fingerprint", "center_lat": _lat, "center_lon": _lon, "utc_offset_h": _utc,
		"month": _month, "day": _day,
	}
	a.configure(int(parsed.seed))
	a.set_conditions({"forecast": forecast, "start_hour": fs.start_hour})
	a.load_place(make_place(loc))
	a.set_static_thermals(PackedFloat32Array([-4000.0, 3000.0, 2.5, 120.0]), 2)
	a.set_focuses(PackedVector3Array([CENTER]), PackedFloat32Array([1.0]))
	jump_to(a, 0.0)
	return a


## Ждать READY, подкачивая воздух (pump) без кадров дерева.
static func wait_ready(a: Atmosphere, max_pumps: int = 100000) -> bool:
	for i in max_pumps:
		if a.is_ready():
			return true
		a.pump(8000)
	return a.is_ready()


## «Прыжок» в t: состояние на t, равное прогону от 0 (start_at), и ожидание READY.
static func jump_to(a: Atmosphere, t: float) -> void:
	a.start_at(t)
	wait_ready(a)


## Прогнать атмосферу до момента t шагом dt (последний шаг — остаток); состояние на t обновлено.
static func run_to(a: Atmosphere, t: float, dt: float) -> void:
	var now := float(a.status().time_s)
	while now < t - 1.0e-9:
		now = minf(now + dt, t)
		a.advance_to(now)
	a.advance_to(t)


## Отпечаток: {thermals: [[id, x, z, y_src, top, w, radius, age, stage, облако, Cb], …] — ядра W6,
## clouds: [[id, x, z, radius, base, top, growth, decay, flags], …] — облака W6,
## field: [[ячейка, покрытие, мощность, стадия, активность], …] — растр облачности (кучевые),
## air: [[x, y, z, vx, vy, vz], …]}. Ядра и облака — по возрастанию id, поле — по ячейке растра.
## Поле зависит от истории (разгон поля при скачке времени ≠ прогон), поэтому «прыжок» с ним не
## сравнивается (diff по умолчанию без поля, with_field = true — для двух прогонов).
static func capture(a: Atmosphere) -> Dictionary:
	var t := float(a.status().time_s)
	var ths: Array = []
	var cores := a.cores(CENTER, RADIUS_M)
	for k in cores.size() / Atmosphere.CORE_STRIDE:
		var o := k * Atmosphere.CORE_STRIDE
		var fl := int(cores[o + Atmosphere.CORE_FLAGS])
		ths.append(
			[
				int(cores[o + Atmosphere.CORE_ID]), cores[o + Atmosphere.CORE_X],
				cores[o + Atmosphere.CORE_Z], cores[o + Atmosphere.CORE_Y_SRC],
				cores[o + Atmosphere.CORE_TOP], cores[o + Atmosphere.CORE_W],
				cores[o + Atmosphere.CORE_RADIUS], cores[o + Atmosphere.CORE_AGE],
				cores[o + Atmosphere.CORE_STAGE], 1 if fl & 2 != 0 else 0, 1 if fl & 4 != 0 else 0
			]
		)
	ths.sort_custom(func(u: Array, v: Array) -> bool: return int(u[0]) < int(v[0]))
	var clouds: Array = []
	var cl := a.clouds(CENTER, RADIUS_M)
	for k in cl.size() / Atmosphere.CLOUD_STRIDE:
		var o := k * Atmosphere.CLOUD_STRIDE
		clouds.append(
			[
				int(cl[o + Atmosphere.CLOUD_ID]), cl[o + Atmosphere.CLOUD_X],
				cl[o + Atmosphere.CLOUD_Z], cl[o + Atmosphere.CLOUD_RADIUS],
				cl[o + Atmosphere.CLOUD_BASE], cl[o + Atmosphere.CLOUD_TOP],
				cl[o + Atmosphere.CLOUD_GROWTH], cl[o + Atmosphere.CLOUD_DECAY],
				int(cl[o + Atmosphere.CLOUD_FLAGS])
			]
		)
	clouds.sort_custom(func(u: Array, v: Array) -> bool: return int(u[0]) < int(v[0]))
	var field_rows: Array = []
	var r := a.cloud_raster()
	if int(r.get("version", 0)) > 0:
		var nx := int(r.nx)
		var r2 := RADIUS_M * RADIUS_M
		for c in nx * int(r.ny):
			if float(r.cover[c]) < 0.05:
				continue
			var cx := float(r.x0) + (c % nx) * float(r.dx)
			var cz := float(r.z0) + (c / nx) * float(r.dx)
			if Vector2(cx - CENTER.x, cz - CENTER.z).length_squared() > r2:
				continue
			field_rows.append([c, r.cover[c], r.depth[c], r.stage[c], r.activity[c]])
	var air: Array = []
	for s in SPOTS:
		for h in HEIGHTS_AGL:
			var x := CENTER.x + s.x
			var z := CENTER.z + s.y
			var p := Vector3(x, height(x, z) + h, z)
			var v := a.air_velocity_at(p)
			air.append([p.x, p.y, p.z, v.x, v.y, v.z])
	return {"t": t, "thermals": ths, "clouds": clouds, "field": field_rows, "air": air}


## Сравнить два отпечатка: "" — совпадают до tol, иначе — первые расхождения (текст).
static func diff(
	a: Dictionary, b: Dictionary, tol: float = 1.0e-3, with_field: bool = false
) -> String:
	var out: PackedStringArray = []
	for key in ["thermals", "clouds", "field", "air"]:
		if key == "field" and not with_field:
			continue
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
	for key in ["thermals", "clouds", "field", "air"]:
		lines.append("%s %d" % [key, (fp[key] as Array).size()])
		for row: Array in fp[key]:
			var parts: PackedStringArray = []
			for v: Variant in row:
				parts.append(str(v) if v is int else "%.6f" % float(v))
			lines.append(" ".join(parts))
	return "\n".join(lines) + "\n"
