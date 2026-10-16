extends RefCounted
## Общие заготовки тестов целей: контекст старта, телеметрия, полёт по отрезку.

const START := Vector3(0.0, 1000.0, 0.0)
const GROUND := 1000.0


static func ctx(extra: Dictionary = {}) -> Dictionary:
	var c := {
		"start_pos": START,
		"start_heading_deg": 0.0,
		"wind_from_deg": 270.0,
		"wind_ms": 0.0,
		"latlon_fn": func(lat: float, lon: float) -> Vector2: return Vector2(lon, -lat),
		"height_fn": func(_x: float, _z: float) -> float: return GROUND,
		"bounds": Rect2(-20000.0, -20000.0, 40000.0, 40000.0),
		"location_id": "test",
	}
	c.merge(extra, true)
	return c


static func make(goals: Array, extra: Dictionary = {}) -> GoalTracker:
	var g := GoalTracker.new()
	g.setup(goals, ctx(extra))
	return g


static func telem(pos: Vector3, time_s: float, phase: String = "flying") -> Telemetry:
	var t := Telemetry.new()
	t.position = pos
	t.altitude_msl = pos.y
	t.altitude_agl = pos.y - GROUND
	t.time_s = time_s
	t.phase = phase
	t.on_ground = phase != "flying"
	return t


## Пролететь по прямой a→b за duration_s с шагом dt; возвращает время конца.
static func fly(
	g: GoalTracker, a: Vector3, b: Vector3, t0: float, duration_s: float, dt: float = 1.0
) -> float:
	var n := maxi(int(duration_s / dt), 1)
	for i in n + 1:
		var k := float(i) / float(n)
		g.update(telem(a.lerp(b, k), t0 + duration_s * k))
	return t0 + duration_s


## Позиция в мире: азимут (0 — север), расстояние, высота.
static func at(heading_deg: float, dist_m: float, y: float = START.y) -> Vector3:
	var d := GoalRouteBuilder.dir_xz(heading_deg) * dist_m
	return Vector3(d.x, y, d.y)
