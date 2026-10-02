class_name SunClock
extends Node
## Часы полёта и положение солнца (VR-5): единый источник направления солнца в рантайме.
## Время — поясное время места (utc_offset_h локации; в солнечное — по долготе и уравнению времени).
## configs/world.json → time.utc_offset_h: число — пояс для всех мест, "solar" — солнечное.
## Положение — склонение и часовой угол (формулы NOAA), по широте/долготе локации и дате.
##
## Живёт в SkyEnvironment (sky.clock). Пока не вызван start_flight — «статичное» солнце из
## world.json → sun.azimuth_deg / elevation_deg (превью, тесты рельефа).
## Потребители подписываются на sun_changed(to_sun) и берут текущее to_sun() при старте:
##   sky.clock.sun_changed.connect(func(d: Vector3) -> void: my_node.set_sun(d))
## Время идёт только через advance(dt) — его зовёт Game.tick (пауза и меню время не двигают).
## Параметры — configs/world.json → time. Подробно — docs/guide/game.md → «Время суток».

## Направление НА солнце изменилось (единичный вектор, север −Z, восток +X).
signal sun_changed(to_sun: Vector3)

## Порог, после которого сдвиг солнца считается изменением (не дёргать тени каждый кадр), градусы.
const EMIT_STEP_DEG := 0.05

## true — солнце по часам (после start_flight), false — статичное из конфига.
var active := false
var latitude_deg: float = 51.0
var longitude_deg: float = 85.0
## Часовой пояс места, UTC+N (NAN — не задан: по долготе).
var zone_utc_h: float = NAN
var month: int = 7
var day: int = 15
## Время старта полёта (reset возвращает к нему), часы.
var start_hour: float = 13.0
## Текущее время, часы (6.5 = 6:30).
var hour: float = 13.0
## Скорость времени: 1 — реальное, 60 — минута за секунду, 0 — стоп.
var speed: float = 1.0

var _to_sun := Vector3.UP
var _emitted := Vector3.ZERO


func _init() -> void:
	reload_config()
	_recompute(true)


## Перечитать configs/world.json → time (скорость — пользовательская настройка).
func reload_config() -> void:
	speed = float(Config.value("world", "time.speed", 1.0))


## Солнце по часам: место (градусы), дата и время старта (часы, ограничиваются min..max_hour),
## часовой пояс места UTC+N (NAN — по долготе).
func start_flight(
	lat: float, lon: float, p_month: int, p_day: int, p_hour: float, p_zone_utc_h: float = NAN
) -> void:
	active = true
	latitude_deg = lat
	longitude_deg = lon
	zone_utc_h = p_zone_utc_h
	month = clampi(p_month, 1, 12)
	day = clampi(p_day, 1, days_in_month(month))
	start_hour = clamp_hour(p_hour)
	hour = start_hour
	_recompute(true)


## Вернуть время к старту («Ещё раз»).
func reset() -> void:
	hour = start_hour
	_recompute(false)


## Продвинуть время на dt секунд симуляции × speed. После max_hour время стоит.
func advance(dt_s: float) -> void:
	if not active or speed <= 0.0:
		return
	var h := clamp_hour(hour + dt_s * speed / 3600.0)
	if h != hour:
		hour = h
		_recompute(false)


## Поставить время (часы), с ограничением min..max_hour.
func set_hour(h: float) -> void:
	hour = clamp_hour(h)
	_recompute(false)


## Единичный вектор НА солнце. Для освещения высота не ниже time.min_light_elevation_deg.
func to_sun() -> Vector3:
	return _to_sun


## Настоящие азимут (0 — север, по часовой) и высота солнца, градусы: Vector2(az, el).
func angles() -> Vector2:
	if not active:
		var s: Dictionary = Config.get_config("world").get("sun", {})
		return Vector2(float(s.get("azimuth_deg", 180.0)), float(s.get("elevation_deg", 45.0)))
	return solar_position(latitude_deg, longitude_deg, day_of_year(month, day), hour, _utc_offset())


## «13:05».
func time_text() -> String:
	return format_hour(hour)


func _recompute(force: bool) -> void:
	var a := angles()
	var el := maxf(a.y, float(Config.value("world", "time.min_light_elevation_deg", 2.0)))
	_to_sun = TerrainGeo.sun_direction(a.x, el)
	var moved := rad_to_deg(_to_sun.angle_to(_emitted)) if _emitted != Vector3.ZERO else 180.0
	if force or moved >= EMIT_STEP_DEG:
		_emitted = _to_sun
		sun_changed.emit(_to_sun)


## Смещение часов от UTC для solar_position: NAN — солнечное время.
func _utc_offset() -> float:
	var v: Variant = Config.get_config("world").get("time", {}).get("utc_offset_h")
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	return zone_utc_h if not is_nan(zone_utc_h) else roundf(longitude_deg / 15.0)


static func clamp_hour(h: float) -> float:
	var t: Dictionary = Config.get_config("world").get("time", {})
	return clampf(h, float(t.get("min_hour", 6.0)), float(t.get("max_hour", 20.0)))


## Фиксированные часы старта (world.json → time.start_hours; AM-06 — старт только в них,
## дальше время идёт само). Пустой список в конфиге — запасной [9, 12, 15, 20].
static func start_hours() -> PackedFloat32Array:
	var t: Dictionary = Config.get_config("world").get("time", {})
	var arr: Array = t.get("start_hours", [9.0, 12.0, 15.0, 20.0])
	var out := PackedFloat32Array()
	for h in arr:
		out.append(float(h))
	if out.is_empty():
		out.append(clamp_hour(12.0))
	return out


## Ближайший час старта из start_hours() к h (сохранённая настройка не из списка — не мигрируем,
## просто берём ближайший).
static func nearest_start_hour(h: float) -> float:
	var hours := start_hours()
	var best := hours[0]
	var best_d := absf(h - best)
	for x in hours:
		var d := absf(h - x)
		if d < best_d:
			best_d = d
			best = x
	return best


static func days_in_month(m: int) -> int:
	return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][clampi(m, 1, 12) - 1]


## Номер дня в году (невисокосный), 1..365.
static func day_of_year(m: int, d: int) -> int:
	var n := d
	for i in range(1, clampi(m, 1, 12)):
		n += days_in_month(i)
	return n


static func format_hour(h: float) -> String:
	var mins := int(roundf(h * 60.0))
	return "%02d:%02d" % [int(mins / 60.0), mins % 60]


## Азимут и высота солнца, градусы: Vector2(az, el). clock_h — местное солнечное время (часы),
## если utc_offset_h = NAN, иначе поясное время с этим смещением от UTC.
static func solar_position(
	lat_deg: float, lon_deg: float, doy: int, clock_h: float, utc_offset_h: float = NAN
) -> Vector2:
	var g := TAU / 365.0 * (doy - 1 + (clock_h - 12.0) / 24.0)
	# склонение (рад) и уравнение времени (мин) — ряды Спенсера (NOAA)
	var decl := (
		0.006918
		- 0.399912 * cos(g)
		+ 0.070257 * sin(g)
		- 0.006758 * cos(2.0 * g)
		+ 0.000907 * sin(2.0 * g)
		- 0.002697 * cos(3.0 * g)
		+ 0.00148 * sin(3.0 * g)
	)
	var solar_h := clock_h
	if not is_nan(utc_offset_h):
		var eot := (
			229.18
			* (
				0.000075
				+ 0.001868 * cos(g)
				- 0.032077 * sin(g)
				- 0.014615 * cos(2.0 * g)
				- 0.040849 * sin(2.0 * g)
			)
		)
		solar_h = clock_h + (4.0 * lon_deg - 60.0 * utc_offset_h + eot) / 60.0
	var ha := deg_to_rad(15.0 * (solar_h - 12.0))
	var lat := deg_to_rad(lat_deg)
	var sin_el := sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha)
	var el := asin(clampf(sin_el, -1.0, 1.0))
	# азимут от севера по часовой: утром восток (< 180), после полудня запад (> 180)
	var az := atan2(sin(ha), cos(ha) * sin(lat) - tan(decl) * cos(lat)) + PI
	return Vector2(fposmod(rad_to_deg(az), 360.0), rad_to_deg(el))


## Свет по высоте солнца (world.json → time.light, линейно между узлами):
## {sun_color: Color (× sun.color), sun_energy, sky_energy (множители), horizon_tint: Color,
## disk_energy (× яркость диска солнца), glare (× сила ослепления)}.
static func light_at(elevation_deg: float) -> Dictionary:
	var l: Dictionary = Config.get_config("world").get("time", {}).get("light", {})
	var xs: Array = l.get("elevation_deg", [0.0])
	return {
		"sun_color": _lerp_color(xs, l.get("sun_color", [[1, 1, 1]]), elevation_deg),
		"sun_energy": _lerp_f(xs, l.get("sun_energy", [1.0]), elevation_deg),
		"sky_energy": _lerp_f(xs, l.get("sky_energy", [1.0]), elevation_deg),
		"horizon_tint": _lerp_color(xs, l.get("horizon_tint", [[1, 1, 1]]), elevation_deg),
		"disk_energy": _lerp_f(xs, l.get("disk_energy", [1.0]), elevation_deg),
		"glare": _lerp_f(xs, l.get("glare", [1.0]), elevation_deg),
	}


static func _seg(xs: Array, x: float) -> Vector2:
	# (индекс левого узла, доля) для кусочно-линейной интерполяции
	var n := xs.size()
	if n < 2 or x <= float(xs[0]):
		return Vector2(0, 0)
	for i in range(n - 1):
		var a := float(xs[i])
		var b := float(xs[i + 1])
		if x <= b:
			return Vector2(i, (x - a) / maxf(b - a, 1e-6))
	return Vector2(n - 1, 0)


static func _lerp_f(xs: Array, ys: Array, x: float) -> float:
	var s := _seg(xs, x)
	var i := mini(int(s.x), ys.size() - 1)
	var j := mini(i + 1, ys.size() - 1)
	return lerpf(float(ys[i]), float(ys[j]), s.y)


static func _lerp_color(xs: Array, ys: Array, x: float) -> Color:
	var s := _seg(xs, x)
	var i := mini(int(s.x), ys.size() - 1)
	var j := mini(i + 1, ys.size() - 1)
	var a: Array = ys[i]
	var b: Array = ys[j]
	return Color(float(a[0]), float(a[1]), float(a[2])).lerp(
		Color(float(b[0]), float(b[1]), float(b[2])), s.y
	)
